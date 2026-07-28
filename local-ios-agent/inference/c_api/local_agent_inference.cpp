#include "local_agent_inference.h"

#include "cancel_arbiter.h"
#include "engine_registry.h"
#include "generation_request.h"
#include "inference_engine.h"
#include "model_config.h"

#include <cstdlib>
#include <cstring>
#include <exception>
#include <algorithm>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace {

enum class LocalAgentErrorCode {
    ok,
    invalid_argument,
    engine_unavailable,
    unsupported_model_format,
    model_file_missing,
    model_load_failed,
    model_busy,
    context_too_large,
    vision_not_supported,
    generation_cancelled,
    generation_failed,
    stream_interrupted,
    usage_unavailable,
    internal_error,
};

struct LocalAgentError {
    LocalAgentErrorCode code = LocalAgentErrorCode::ok;
    std::string message;
    std::string engine;
    bool recoverable = false;
};

struct LocalAgentEngineState {
    std::string engine_id;
    local_agent::EngineDescriptor descriptor;
    std::unique_ptr<local_agent::InferenceEngine> engine;
    std::mutex error_mutex;
    LocalAgentError last_error;
};

struct LocalAgentModelState {
    std::shared_ptr<LocalAgentEngineState> engine_state;
    std::unique_ptr<local_agent::LoadedModel> model;
    local_agent::ModelRuntimeInfo runtime_info;
    local_agent::ModelLoadConfig load_config;
    std::mutex generation_mutex;
    bool generation_active = false;
};

struct LocalAgentGenerationState {
    std::shared_ptr<LocalAgentModelState> model_state;
    std::unique_ptr<local_agent::GenerationSession> generation;
    local_agent::CancelArbiter cancel_arbiter;
    std::mutex lifecycle_mutex;
    bool reading = false;
    bool terminal = false;
};

thread_local LocalAgentError thread_last_error;

const char *error_code_string(LocalAgentErrorCode code) {
    switch (code) {
    case LocalAgentErrorCode::ok:
        return "ok";
    case LocalAgentErrorCode::invalid_argument:
        return "invalid_argument";
    case LocalAgentErrorCode::engine_unavailable:
        return "engine_unavailable";
    case LocalAgentErrorCode::unsupported_model_format:
        return "unsupported_model_format";
    case LocalAgentErrorCode::model_file_missing:
        return "model_file_missing";
    case LocalAgentErrorCode::model_load_failed:
        return "model_load_failed";
    case LocalAgentErrorCode::model_busy:
        return "model_busy";
    case LocalAgentErrorCode::context_too_large:
        return "context_too_large";
    case LocalAgentErrorCode::vision_not_supported:
        return "vision_not_supported";
    case LocalAgentErrorCode::generation_cancelled:
        return "generation_cancelled";
    case LocalAgentErrorCode::generation_failed:
        return "generation_failed";
    case LocalAgentErrorCode::stream_interrupted:
        return "stream_interrupted";
    case LocalAgentErrorCode::usage_unavailable:
        return "usage_unavailable";
    case LocalAgentErrorCode::internal_error:
        return "internal_error";
    }
    return "internal_error";
}

std::string escape_json(const std::string &value) {
    std::string escaped;
    for (char c : value) {
        switch (c) {
        case '\\':
            escaped += "\\\\";
            break;
        case '"':
            escaped += "\\\"";
            break;
        case '\n':
            escaped += "\\n";
            break;
        case '\r':
            escaped += "\\r";
            break;
        case '\t':
            escaped += "\\t";
            break;
        default:
            escaped.push_back(c);
            break;
        }
    }
    return escaped;
}

std::string error_json(const LocalAgentError &error) {
    return "{\"code\":\"" + std::string(error_code_string(error.code)) +
        "\",\"message\":\"" + escape_json(error.message) +
        "\",\"engine\":\"" + escape_json(error.engine) +
        "\",\"recoverable\":" + (error.recoverable ? "true" : "false") + "}";
}

char *copy_c_string(const std::string &value) {
    char *buffer = static_cast<char *>(std::malloc(value.size() + 1));
    if (buffer == nullptr) {
        throw std::bad_alloc();
    }
    std::memcpy(buffer, value.c_str(), value.size() + 1);
    return buffer;
}

void set_error(
    LocalAgentError &target,
    LocalAgentErrorCode code,
    std::string message,
    std::string engine = "",
    bool recoverable = false
) {
    target.code = code;
    target.message = std::move(message);
    target.engine = std::move(engine);
    target.recoverable = recoverable;
}

void set_thread_error(
    LocalAgentErrorCode code,
    std::string message,
    std::string engine = "",
    bool recoverable = false
) {
    set_error(thread_last_error, code, std::move(message), std::move(engine), recoverable);
}

void set_engine_error(
    const std::shared_ptr<LocalAgentEngineState> &engine_state,
    LocalAgentErrorCode code,
    std::string message,
    bool recoverable = false
) {
    std::string engine_id;
    if (engine_state) {
        engine_id = engine_state->engine_id;
        std::lock_guard<std::mutex> lock(engine_state->error_mutex);
        set_error(engine_state->last_error, code, message, engine_id, recoverable);
    }
    set_thread_error(code, std::move(message), std::move(engine_id), recoverable);
}

bool reserve_active_generation(const std::shared_ptr<LocalAgentModelState> &model_state) {
    std::lock_guard<std::mutex> lock(model_state->generation_mutex);
    if (model_state->generation_active) {
        return false;
    }
    model_state->generation_active = true;
    return true;
}

void clear_active_generation(const std::shared_ptr<LocalAgentModelState> &model_state) {
    if (!model_state) {
        return;
    }
    std::lock_guard<std::mutex> lock(model_state->generation_mutex);
    model_state->generation_active = false;
}

LocalAgentStatus status_from_exception(
    const std::shared_ptr<LocalAgentEngineState> &engine_state,
    LocalAgentErrorCode fallback_code
) {
    try {
        throw;
    } catch (const std::invalid_argument &error) {
        set_engine_error(engine_state, LocalAgentErrorCode::invalid_argument, error.what());
        return LOCAL_AGENT_STATUS_INVALID_ARGUMENT;
    } catch (const std::bad_alloc &error) {
        set_engine_error(engine_state, LocalAgentErrorCode::internal_error, error.what());
        return LOCAL_AGENT_STATUS_ERROR;
    } catch (const std::exception &error) {
        set_engine_error(engine_state, fallback_code, error.what());
        return LOCAL_AGENT_STATUS_ERROR;
    } catch (...) {
        set_engine_error(engine_state, LocalAgentErrorCode::internal_error, "unknown local inference error");
        return LOCAL_AGENT_STATUS_ERROR;
    }
}

local_agent::EngineRegistry active_registry() {
#ifdef LOCAL_AGENT_ENABLE_TEST_ENGINES
    return local_agent::EngineRegistry::test();
#else
    return local_agent::EngineRegistry::production();
#endif
}

std::vector<local_agent::ImageInput> copy_image_inputs(
    const LocalAgentImageInput *images,
    uint64_t image_count
) {
    std::vector<local_agent::ImageInput> copied;
    if (image_count == 0) {
        return copied;
    }
    if (images == nullptr) {
        throw std::invalid_argument("image_count requires image input array");
    }
    copied.reserve(static_cast<size_t>(image_count));
    for (uint64_t index = 0; index < image_count; index += 1) {
        const auto &image = images[index];
        if (image.bytes == nullptr || image.pixel_format == nullptr) {
            throw std::invalid_argument("image input requires bytes and pixel_format");
        }
        if (std::string(image.pixel_format) != "rgb8") {
            throw std::invalid_argument("only rgb8 image input is supported");
        }
        const uint64_t expected = static_cast<uint64_t>(image.width) *
            static_cast<uint64_t>(image.height) * 3;
        if (image.width == 0 || image.height == 0 || image.byte_count != expected) {
            throw std::invalid_argument("rgb8 image byte_count does not match dimensions");
        }
        local_agent::ImageInput copied_image;
        copied_image.width = image.width;
        copied_image.height = image.height;
        copied_image.rgb_data.assign(image.bytes, image.bytes + image.byte_count);
        copied.push_back(std::move(copied_image));
    }
    return copied;
}

void validate_image_metadata_matches_buffers(
    const std::vector<local_agent::ImageMetadata> &metadata,
    const LocalAgentImageInput *images,
    uint64_t image_count
) {
    if (metadata.size() != static_cast<size_t>(image_count)) {
        throw std::invalid_argument("image metadata count must match image buffer count");
    }
    if (image_count == 0) {
        return;
    }
    if (images == nullptr) {
        throw std::invalid_argument("image_count requires image input array");
    }
    for (uint64_t index = 0; index < image_count; index += 1) {
        const auto &image = images[index];
        const auto &image_metadata = metadata[static_cast<size_t>(index)];
        if (image.pixel_format == nullptr) {
            throw std::invalid_argument("image input requires pixel_format");
        }
        if (image_metadata.format != image.pixel_format) {
            throw std::invalid_argument("image metadata format must match image buffer format");
        }
        if (image_metadata.width != image.width || image_metadata.height != image.height) {
            throw std::invalid_argument("image metadata dimensions must match image buffer dimensions");
        }
    }
}

bool supports_model_format(
    const local_agent::EngineDescriptor &descriptor,
    const std::string &format
) {
    const auto &formats = descriptor.capabilities.supported_model_formats;
    return std::find(formats.begin(), formats.end(), format) != formats.end();
}

bool supports_backend_parameter(
    const local_agent::EngineDescriptor &descriptor,
    const std::string &name
) {
    const auto &parameters = descriptor.capabilities.backend_parameters;
    return std::any_of(parameters.begin(), parameters.end(), [&](const auto &parameter) {
        return parameter.backend_option == name;
    });
}

void validate_model_config(
    const std::shared_ptr<LocalAgentEngineState> &engine_state,
    const local_agent::ModelLoadConfig &config
) {
    if (config.engine != engine_state->engine_id) {
        throw std::invalid_argument("model config engine does not match engine handle");
    }
    if (!supports_model_format(engine_state->descriptor, config.model_format)) {
        throw std::invalid_argument("model format is not supported by engine");
    }
    if (config.runtime.n_threads <= 0 || config.runtime.n_gpu_layers < 0) {
        throw std::invalid_argument("model runtime options are out of range");
    }
    const int maximum = engine_state->descriptor.capabilities.max_context_tokens;
    if (maximum > 0 && config.context_tokens > maximum) {
        throw std::invalid_argument("model context exceeds verified engine maximum");
    }
    if ((config.chat_template_source != "gguf" &&
         config.chat_template_source != "catalog_artifact") ||
        config.chat_template_id.empty()) {
        throw std::invalid_argument("model config requires an approved chat template selector");
    }
    if (config.tool_call_codec_id == "llama_cpp_native_tools_v1" &&
        !engine_state->descriptor.capabilities.supports_native_tool_calling) {
        throw std::invalid_argument("loaded engine does not support native tool calling");
    }
}

void validate_generation_request(
    const std::shared_ptr<LocalAgentModelState> &model_state,
    const local_agent::GenerationRequest &request
) {
    if (request.chat_template.source != model_state->load_config.chat_template_source ||
        request.chat_template.id != model_state->load_config.chat_template_id) {
        throw std::invalid_argument("generation template does not match loaded model selector");
    }
    if (request.sampling.max_new_tokens > model_state->runtime_info.context_tokens) {
        throw std::invalid_argument("generation output exceeds loaded model context");
    }
    for (const auto &option : request.sampling.provided_options) {
        if (!supports_backend_parameter(model_state->engine_state->descriptor, option)) {
            throw std::invalid_argument("generation parameter is not supported by engine: " + option);
        }
    }
    if (!request.images.empty() &&
        !model_state->engine_state->descriptor.capabilities.supports_vision) {
        throw std::invalid_argument("loaded engine does not support image input");
    }
    if (request.images.size() > 1) {
        throw std::invalid_argument("local generation supports at most one image");
    }
    if (request.tool_call_codec_id &&
        (model_state->load_config.tool_call_codec_id.empty() ||
         *request.tool_call_codec_id != model_state->load_config.tool_call_codec_id)) {
        throw std::invalid_argument("tool-call codec does not match loaded model");
    }
    if (request.tool_call_codec_id == std::optional<std::string>("llama_cpp_native_tools_v1") &&
        !model_state->engine_state->descriptor.capabilities.supports_native_tool_calling) {
        throw std::invalid_argument("loaded engine does not support native tool calling");
    }
}

LocalAgentStatus cancel_generation(
    const std::shared_ptr<LocalAgentGenerationState> &state,
    local_agent::CancelClaim claim
) {
    if (claim == local_agent::CancelClaim::wait) {
        claim = state->cancel_arbiter.wait_for_ownership_or_confirmation();
    }
    if (claim == local_agent::CancelClaim::generation_terminal) {
        return LOCAL_AGENT_STATUS_OK;
    }
    if (claim == local_agent::CancelClaim::wait) {
        return state->cancel_arbiter.confirmed_status();
    }
    try {
        state->generation->cancel();
        state->cancel_arbiter.confirm(LOCAL_AGENT_STATUS_CANCELLED);
        return LOCAL_AGENT_STATUS_CANCELLED;
    } catch (...) {
        state->cancel_arbiter.confirm(LOCAL_AGENT_STATUS_ERROR);
        return status_from_exception(
            state->model_state->engine_state,
            LocalAgentErrorCode::generation_failed
        );
    }
}

LocalAgentStatus resolved_generation_status(
    const std::shared_ptr<LocalAgentGenerationState> &state
) {
    const local_agent::CancelClaim resolution =
        state->cancel_arbiter.wait_for_ownership_or_confirmation();
    if (resolution == local_agent::CancelClaim::generation_terminal) {
        return LOCAL_AGENT_STATUS_OK;
    }
    return state->cancel_arbiter.confirmed_status();
}

} // namespace

struct LocalAgentEngineHandle {
    std::shared_ptr<LocalAgentEngineState> state;
};

struct LocalAgentModelHandle {
    std::shared_ptr<LocalAgentModelState> state;
};

struct LocalAgentGenerationHandle {
    std::shared_ptr<LocalAgentGenerationState> state;
};

extern "C" {

uint32_t local_agent_link_anchor(void) {
    volatile uintptr_t addresses = reinterpret_cast<uintptr_t>(&local_agent_string_free);
    addresses ^= reinterpret_cast<uintptr_t>(&local_agent_engine_list);
    addresses ^= reinterpret_cast<uintptr_t>(&local_agent_engine_create);
    addresses ^= reinterpret_cast<uintptr_t>(&local_agent_engine_capabilities);
    addresses ^= reinterpret_cast<uintptr_t>(&local_agent_engine_parameter_schema);
    addresses ^= reinterpret_cast<uintptr_t>(&local_agent_engine_release);
    addresses ^= reinterpret_cast<uintptr_t>(&local_agent_model_load);
    addresses ^= reinterpret_cast<uintptr_t>(&local_agent_model_validate);
    addresses ^= reinterpret_cast<uintptr_t>(&local_agent_model_unload);
    addresses ^= reinterpret_cast<uintptr_t>(&local_agent_generation_start);
    addresses ^= reinterpret_cast<uintptr_t>(&local_agent_generation_validate);
    addresses ^= reinterpret_cast<uintptr_t>(&local_agent_generation_read);
    addresses ^= reinterpret_cast<uintptr_t>(&local_agent_generation_cancel);
    addresses ^= reinterpret_cast<uintptr_t>(&local_agent_generation_release);
    addresses ^= reinterpret_cast<uintptr_t>(&local_agent_last_error);
    (void)addresses;
    return 15;
}

void local_agent_string_free(char *value) {
    std::free(value);
}

LocalAgentStatus local_agent_engine_list(char **out_json) {
    if (out_json == nullptr) {
        set_thread_error(LocalAgentErrorCode::invalid_argument, "out_json must not be null");
        return LOCAL_AGENT_STATUS_INVALID_ARGUMENT;
    }
    *out_json = nullptr;
    try {
        *out_json = copy_c_string(local_agent::engine_descriptor_list_json(active_registry().list()));
        return LOCAL_AGENT_STATUS_OK;
    } catch (...) {
        return status_from_exception(nullptr, LocalAgentErrorCode::internal_error);
    }
}

LocalAgentStatus local_agent_engine_create(
    const char *engine_id,
    LocalAgentEngineHandle **out_engine
) {
    if (out_engine == nullptr) {
        set_thread_error(LocalAgentErrorCode::invalid_argument, "out_engine must not be null");
        return LOCAL_AGENT_STATUS_INVALID_ARGUMENT;
    }
    *out_engine = nullptr;
    if (engine_id == nullptr) {
        set_thread_error(LocalAgentErrorCode::invalid_argument, "engine_id must not be null");
        return LOCAL_AGENT_STATUS_INVALID_ARGUMENT;
    }

    try {
        local_agent::EngineRegistry registry = active_registry();
        const local_agent::EngineDescriptor *descriptor = registry.find(engine_id);
        if (descriptor == nullptr) {
            set_thread_error(
                LocalAgentErrorCode::engine_unavailable,
                std::string("engine is not available: ") + engine_id,
                engine_id
            );
            return LOCAL_AGENT_STATUS_ERROR;
        }
        auto engine = registry.create(engine_id);
        if (!engine) {
            set_thread_error(
                LocalAgentErrorCode::engine_unavailable,
                std::string("engine cannot be created: ") + engine_id,
                engine_id
            );
            return LOCAL_AGENT_STATUS_ERROR;
        }

        auto state = std::make_shared<LocalAgentEngineState>();
        state->engine_id = engine_id;
        state->descriptor = *descriptor;
        state->engine = std::move(engine);

        auto *handle = new LocalAgentEngineHandle();
        handle->state = std::move(state);
        *out_engine = handle;
        return LOCAL_AGENT_STATUS_OK;
    } catch (...) {
        return status_from_exception(nullptr, LocalAgentErrorCode::internal_error);
    }
}

LocalAgentStatus local_agent_engine_capabilities(
    LocalAgentEngineHandle *engine,
    char **out_json
) {
    if (out_json == nullptr) {
        set_thread_error(LocalAgentErrorCode::invalid_argument, "out_json must not be null");
        return LOCAL_AGENT_STATUS_INVALID_ARGUMENT;
    }
    *out_json = nullptr;
    if (engine == nullptr || !engine->state) {
        set_thread_error(LocalAgentErrorCode::invalid_argument, "engine handle must not be null");
        return LOCAL_AGENT_STATUS_INVALID_ARGUMENT;
    }
    try {
        *out_json = copy_c_string(local_agent::engine_capabilities_json(engine->state->descriptor));
        return LOCAL_AGENT_STATUS_OK;
    } catch (...) {
        return status_from_exception(engine->state, LocalAgentErrorCode::internal_error);
    }
}

LocalAgentStatus local_agent_engine_parameter_schema(
    LocalAgentEngineHandle *engine,
    char **out_json
) {
    if (out_json == nullptr) {
        set_thread_error(LocalAgentErrorCode::invalid_argument, "out_json must not be null");
        return LOCAL_AGENT_STATUS_INVALID_ARGUMENT;
    }
    *out_json = nullptr;
    if (engine == nullptr || !engine->state) {
        set_thread_error(LocalAgentErrorCode::invalid_argument, "engine handle must not be null");
        return LOCAL_AGENT_STATUS_INVALID_ARGUMENT;
    }
    try {
        *out_json = copy_c_string(local_agent::engine_parameter_schema_json(engine->state->descriptor));
        return LOCAL_AGENT_STATUS_OK;
    } catch (...) {
        return status_from_exception(engine->state, LocalAgentErrorCode::internal_error);
    }
}

LocalAgentStatus local_agent_engine_release(LocalAgentEngineHandle *engine) {
    if (engine == nullptr) {
        return LOCAL_AGENT_STATUS_OK;
    }
    delete engine;
    return LOCAL_AGENT_STATUS_OK;
}

LocalAgentStatus local_agent_model_load(
    LocalAgentEngineHandle *engine,
    const char *model_config_json,
    LocalAgentModelHandle **out_model
) {
    if (out_model == nullptr) {
        set_thread_error(LocalAgentErrorCode::invalid_argument, "out_model must not be null");
        return LOCAL_AGENT_STATUS_INVALID_ARGUMENT;
    }
    *out_model = nullptr;
    if (engine == nullptr || !engine->state || model_config_json == nullptr) {
        set_thread_error(LocalAgentErrorCode::invalid_argument, "engine and model_config_json are required");
        return LOCAL_AGENT_STATUS_INVALID_ARGUMENT;
    }
    try {
        local_agent::ModelLoadConfig config = local_agent::parse_model_load_config(model_config_json);
        validate_model_config(engine->state, config);
        auto model = engine->state->engine->load_model(config);
        if (!model) {
            throw std::runtime_error("engine returned null loaded model");
        }

        auto state = std::make_shared<LocalAgentModelState>();
        state->engine_state = engine->state;
        state->model = std::move(model);
        state->runtime_info = state->model->runtime_info();
        state->load_config = std::move(config);

        auto *handle = new LocalAgentModelHandle();
        handle->state = std::move(state);
        *out_model = handle;
        return LOCAL_AGENT_STATUS_OK;
    } catch (...) {
        return status_from_exception(engine->state, LocalAgentErrorCode::model_load_failed);
    }
}

LocalAgentStatus local_agent_model_validate(
    LocalAgentEngineHandle *engine,
    const char *model_config_json
) {
    if (engine == nullptr || !engine->state || model_config_json == nullptr) {
        set_thread_error(LocalAgentErrorCode::invalid_argument, "engine and model_config_json are required");
        return LOCAL_AGENT_STATUS_INVALID_ARGUMENT;
    }
    try {
        const local_agent::ModelLoadConfig config =
            local_agent::parse_model_load_config(model_config_json);
        validate_model_config(engine->state, config);
        return LOCAL_AGENT_STATUS_OK;
    } catch (...) {
        return status_from_exception(engine->state, LocalAgentErrorCode::invalid_argument);
    }
}

LocalAgentStatus local_agent_model_unload(LocalAgentModelHandle *model) {
    if (model == nullptr) {
        return LOCAL_AGENT_STATUS_OK;
    }
    if (!model->state) {
        set_thread_error(LocalAgentErrorCode::invalid_argument, "model handle state must not be null");
        return LOCAL_AGENT_STATUS_INVALID_ARGUMENT;
    }
    bool busy = false;
    {
        std::lock_guard<std::mutex> lock(model->state->generation_mutex);
        busy = model->state->generation_active;
    }
    if (busy) {
        set_engine_error(
            model->state->engine_state,
            LocalAgentErrorCode::model_busy,
            "model has an active generation",
            true
        );
        return LOCAL_AGENT_STATUS_ERROR;
    }
    delete model;
    return LOCAL_AGENT_STATUS_OK;
}

LocalAgentStatus local_agent_generation_start(
    LocalAgentModelHandle *model,
    const char *generation_request_json,
    const LocalAgentImageInput *images,
    uint64_t image_count,
    LocalAgentGenerationHandle **out_generation
) {
    if (out_generation == nullptr) {
        set_thread_error(LocalAgentErrorCode::invalid_argument, "out_generation must not be null");
        return LOCAL_AGENT_STATUS_INVALID_ARGUMENT;
    }
    *out_generation = nullptr;
    if (model == nullptr || !model->state || generation_request_json == nullptr) {
        set_thread_error(LocalAgentErrorCode::invalid_argument, "model and generation_request_json are required");
        return LOCAL_AGENT_STATUS_INVALID_ARGUMENT;
    }
    try {
        local_agent::GenerationRequest request =
            local_agent::parse_generation_request(generation_request_json);
        validate_generation_request(model->state, request);
        validate_image_metadata_matches_buffers(request.images, images, image_count);
        std::vector<local_agent::ImageInput> image_inputs = copy_image_inputs(images, image_count);
        if (!reserve_active_generation(model->state)) {
            set_engine_error(
                model->state->engine_state,
                LocalAgentErrorCode::generation_failed,
                "model already has an active generation",
                true
            );
            return LOCAL_AGENT_STATUS_ERROR;
        }

        std::unique_ptr<local_agent::GenerationSession> generation;
        try {
            generation = model->state->model->start_generation(request, image_inputs);
            if (!generation) {
                throw std::runtime_error("model returned null generation session");
            }
        } catch (...) {
            clear_active_generation(model->state);
            throw;
        }

        auto state = std::make_shared<LocalAgentGenerationState>();
        state->model_state = model->state;
        state->generation = std::move(generation);

        try {
            auto *handle = new LocalAgentGenerationHandle();
            handle->state = std::move(state);
            *out_generation = handle;
        } catch (...) {
            clear_active_generation(model->state);
            throw;
        }
        return LOCAL_AGENT_STATUS_OK;
    } catch (...) {
        return status_from_exception(model->state->engine_state, LocalAgentErrorCode::generation_failed);
    }
}

LocalAgentStatus local_agent_generation_validate(
    LocalAgentModelHandle *model,
    const char *generation_request_json
) {
    if (model == nullptr || !model->state || generation_request_json == nullptr) {
        set_thread_error(LocalAgentErrorCode::invalid_argument, "model and generation_request_json are required");
        return LOCAL_AGENT_STATUS_INVALID_ARGUMENT;
    }
    try {
        const local_agent::GenerationRequest request =
            local_agent::parse_generation_request(generation_request_json);
        validate_generation_request(model->state, request);
        return LOCAL_AGENT_STATUS_OK;
    } catch (...) {
        return status_from_exception(model->state->engine_state, LocalAgentErrorCode::invalid_argument);
    }
}

LocalAgentStatus local_agent_generation_read(
    LocalAgentGenerationHandle *generation,
    local_agent_token_callback callback,
    void *user_data
) {
    if (generation == nullptr || !generation->state || callback == nullptr) {
        set_thread_error(LocalAgentErrorCode::invalid_argument, "generation and callback are required");
        return LOCAL_AGENT_STATUS_INVALID_ARGUMENT;
    }

    auto state = generation->state;
    {
        std::lock_guard<std::mutex> lock(state->lifecycle_mutex);
        if (state->terminal) {
            set_engine_error(
                state->model_state->engine_state,
                LocalAgentErrorCode::stream_interrupted,
                "generation stream has already reached a terminal state",
                true
            );
            return LOCAL_AGENT_STATUS_ERROR;
        }
        if (state->reading) {
            set_engine_error(
                state->model_state->engine_state,
                LocalAgentErrorCode::stream_interrupted,
                "generation stream is already being read",
                true
            );
            return LOCAL_AGENT_STATUS_ERROR;
        }
        state->reading = true;
    }

    auto mark_terminal = [&]() {
        state->cancel_arbiter.mark_generation_terminal();
        {
            std::lock_guard<std::mutex> lock(state->lifecycle_mutex);
            state->reading = false;
            state->terminal = true;
        }
        clear_active_generation(state->model_state);
    };

    LocalAgentStatus callback_status = LOCAL_AGENT_STATUS_OK;
    LocalAgentStatus cancel_status = LOCAL_AGENT_STATUS_OK;
    auto emit = [&](const std::string &token_json) -> bool {
        state->cancel_arbiter.callback_entered();
        callback_status = callback(token_json.c_str(), user_data);
        const local_agent::CancelClaim claim =
            state->cancel_arbiter.callback_returned(callback_status);
        if (claim == local_agent::CancelClaim::owner) {
            cancel_status = cancel_generation(state, claim);
        }
        if (callback_status != LOCAL_AGENT_STATUS_OK ||
            cancel_status != LOCAL_AGENT_STATUS_OK) {
            return false;
        }
        return true;
    };

    try {
        state->generation->read(emit);
        mark_terminal();
        const LocalAgentStatus terminal_status = resolved_generation_status(state);
        if (terminal_status != LOCAL_AGENT_STATUS_OK) {
            set_engine_error(
                state->model_state->engine_state,
                terminal_status == LOCAL_AGENT_STATUS_CANCELLED
                    ? LocalAgentErrorCode::generation_cancelled
                    : LocalAgentErrorCode::generation_failed,
                "generation terminated by cancellation"
            );
            return terminal_status;
        }
        if (callback_status != LOCAL_AGENT_STATUS_OK) {
            set_engine_error(
                state->model_state->engine_state,
                LocalAgentErrorCode::generation_cancelled,
                "token callback stopped generation"
            );
            return callback_status;
        }
        return LOCAL_AGENT_STATUS_OK;
    } catch (...) {
        mark_terminal();
        const LocalAgentStatus terminal_status = resolved_generation_status(state);
        if (terminal_status != LOCAL_AGENT_STATUS_OK) {
            return terminal_status;
        }
        return status_from_exception(
            state->model_state->engine_state,
            LocalAgentErrorCode::generation_failed
        );
    }
}

LocalAgentStatus local_agent_generation_cancel(LocalAgentGenerationHandle *generation) {
    if (generation == nullptr || !generation->state) {
        set_thread_error(LocalAgentErrorCode::invalid_argument, "generation handle must not be null");
        return LOCAL_AGENT_STATUS_INVALID_ARGUMENT;
    }
    auto state = generation->state;
    const LocalAgentStatus cancel_status = cancel_generation(
        state,
        state->cancel_arbiter.claim_from_external()
    );
    if (cancel_status == LOCAL_AGENT_STATUS_ERROR) {
        return cancel_status;
    }
    bool clear_active = false;
    {
        std::lock_guard<std::mutex> lock(state->lifecycle_mutex);
        state->terminal = true;
        clear_active = !state->reading;
    }
    set_engine_error(
        state->model_state->engine_state,
        LocalAgentErrorCode::generation_cancelled,
        "generation cancelled"
    );
    if (clear_active) {
        clear_active_generation(state->model_state);
    }
    return cancel_status == LOCAL_AGENT_STATUS_OK
        ? LOCAL_AGENT_STATUS_OK
        : LOCAL_AGENT_STATUS_CANCELLED;
}

LocalAgentStatus local_agent_generation_release(LocalAgentGenerationHandle *generation) {
    if (generation == nullptr) {
        return LOCAL_AGENT_STATUS_OK;
    }
    auto state = generation->state;
    if (state) {
        const LocalAgentStatus cancel_status = cancel_generation(
            state,
            state->cancel_arbiter.claim_from_external()
        );
        if (cancel_status == LOCAL_AGENT_STATUS_ERROR) {
            return cancel_status;
        }
        bool clear_active = false;
        {
            std::lock_guard<std::mutex> lock(state->lifecycle_mutex);
            state->terminal = true;
            clear_active = !state->reading;
        }
        if (clear_active) {
            clear_active_generation(state->model_state);
        }
    }
    delete generation;
    return LOCAL_AGENT_STATUS_OK;
}

LocalAgentStatus local_agent_last_error(
    LocalAgentEngineHandle *engine,
    char **out_json
) {
    if (out_json == nullptr) {
        set_thread_error(LocalAgentErrorCode::invalid_argument, "out_json must not be null");
        return LOCAL_AGENT_STATUS_INVALID_ARGUMENT;
    }
    *out_json = nullptr;
    try {
        LocalAgentError error = thread_last_error;
        if (engine != nullptr && engine->state) {
            std::lock_guard<std::mutex> lock(engine->state->error_mutex);
            error = engine->state->last_error;
        }
        *out_json = copy_c_string(error_json(error));
        return LOCAL_AGENT_STATUS_OK;
    } catch (...) {
        return status_from_exception(
            engine == nullptr ? nullptr : engine->state,
            LocalAgentErrorCode::internal_error
        );
    }
}

} // extern "C"
