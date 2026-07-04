#include "local_agent_inference.h"

#include "engine_registry.h"
#include "generation_request.h"
#include "inference_engine.h"
#include "model_config.h"

#include <cstdlib>
#include <cstring>
#include <exception>
#include <memory>
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
    LocalAgentError last_error;
};

struct LocalAgentModelState {
    std::shared_ptr<LocalAgentEngineState> engine_state;
    std::unique_ptr<local_agent::LoadedModel> model;
    local_agent::ModelRuntimeInfo runtime_info;
};

struct LocalAgentGenerationState {
    std::shared_ptr<LocalAgentModelState> model_state;
    std::unique_ptr<local_agent::GenerationSession> generation;
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
        set_error(engine_state->last_error, code, message, engine_id, recoverable);
    }
    set_thread_error(code, std::move(message), std::move(engine_id), recoverable);
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
        if (config.engine != engine->state->engine_id) {
            throw std::invalid_argument("model config engine does not match engine handle");
        }
        auto model = engine->state->engine->load_model(config);
        if (!model) {
            throw std::runtime_error("engine returned null loaded model");
        }

        auto state = std::make_shared<LocalAgentModelState>();
        state->engine_state = engine->state;
        state->model = std::move(model);
        state->runtime_info = state->model->runtime_info();

        auto *handle = new LocalAgentModelHandle();
        handle->state = std::move(state);
        *out_model = handle;
        return LOCAL_AGENT_STATUS_OK;
    } catch (...) {
        return status_from_exception(engine->state, LocalAgentErrorCode::model_load_failed);
    }
}

LocalAgentStatus local_agent_model_unload(LocalAgentModelHandle *model) {
    if (model == nullptr) {
        return LOCAL_AGENT_STATUS_OK;
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
        validate_image_metadata_matches_buffers(request.images, images, image_count);
        std::vector<local_agent::ImageInput> image_inputs = copy_image_inputs(images, image_count);
        auto generation = model->state->model->start_generation(request, image_inputs);
        if (!generation) {
            throw std::runtime_error("model returned null generation session");
        }

        auto state = std::make_shared<LocalAgentGenerationState>();
        state->model_state = model->state;
        state->generation = std::move(generation);

        auto *handle = new LocalAgentGenerationHandle();
        handle->state = std::move(state);
        *out_generation = handle;
        return LOCAL_AGENT_STATUS_OK;
    } catch (...) {
        return status_from_exception(model->state->engine_state, LocalAgentErrorCode::generation_failed);
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

    LocalAgentStatus callback_status = LOCAL_AGENT_STATUS_OK;
    auto emit = [&](const std::string &token_json) -> bool {
        callback_status = callback(token_json.c_str(), user_data);
        if (callback_status != LOCAL_AGENT_STATUS_OK) {
            generation->state->generation->cancel();
            return false;
        }
        return true;
    };

    try {
        generation->state->generation->read(emit);
        if (callback_status != LOCAL_AGENT_STATUS_OK) {
            set_engine_error(
                generation->state->model_state->engine_state,
                LocalAgentErrorCode::generation_cancelled,
                "token callback stopped generation"
            );
            return callback_status;
        }
        return LOCAL_AGENT_STATUS_OK;
    } catch (...) {
        return status_from_exception(
            generation->state->model_state->engine_state,
            LocalAgentErrorCode::generation_failed
        );
    }
}

LocalAgentStatus local_agent_generation_cancel(LocalAgentGenerationHandle *generation) {
    if (generation == nullptr || !generation->state) {
        set_thread_error(LocalAgentErrorCode::invalid_argument, "generation handle must not be null");
        return LOCAL_AGENT_STATUS_INVALID_ARGUMENT;
    }
    set_engine_error(
        generation->state->model_state->engine_state,
        LocalAgentErrorCode::generation_cancelled,
        "generation cancelled"
    );
    generation->state->generation->cancel();
    return LOCAL_AGENT_STATUS_CANCELLED;
}

LocalAgentStatus local_agent_generation_release(LocalAgentGenerationHandle *generation) {
    if (generation == nullptr) {
        return LOCAL_AGENT_STATUS_OK;
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
        const LocalAgentError &error = (engine != nullptr && engine->state)
            ? engine->state->last_error
            : thread_last_error;
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
