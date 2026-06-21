#include "local_agent_inference.h"

#include "inference_engine.h"
#include "mock_inference_engine.h"
#include "model_config.h"

#include <cstddef>
#include <exception>
#include <memory>
#include <string>

struct LocalAgentBackend {
    local_agent::ModelConfig config;
    std::unique_ptr<local_agent::InferenceEngine> engine;
};

struct LocalAgentBackendStream {
    local_agent::InferenceEngine *engine = nullptr;
    std::unique_ptr<local_agent::TokenStream> stream;
};

namespace local_agent {

std::unique_ptr<InferenceEngine> make_inference_engine(const ModelConfig &config) {
    if (config.backend == "mock") {
        return std::make_unique<MockInferenceEngine>();
    }
    throw std::invalid_argument("unsupported backend in this build: " + config.backend);
}

} // namespace local_agent

namespace {

LocalAgentStatus map_exception() {
    try {
        throw;
    } catch (const std::invalid_argument &) {
        return LOCAL_AGENT_STATUS_INVALID_ARGUMENT;
    } catch (const std::exception &) {
        return LOCAL_AGENT_STATUS_ERROR;
    } catch (...) {
        return LOCAL_AGENT_STATUS_ERROR;
    }
}

} // namespace

extern "C" {

LocalAgentStatus local_agent_backend_init(LocalAgentBackend **out_backend) {
    if (out_backend == nullptr) {
        return LOCAL_AGENT_STATUS_INVALID_ARGUMENT;
    }
    *out_backend = new LocalAgentBackend();
    return LOCAL_AGENT_STATUS_OK;
}

LocalAgentStatus local_agent_backend_load_model(
    LocalAgentBackend *backend,
    const char *model_config_json
) {
    if (backend == nullptr || model_config_json == nullptr) {
        return LOCAL_AGENT_STATUS_INVALID_ARGUMENT;
    }
    try {
        backend->config = local_agent::parse_model_config(model_config_json);
        backend->engine = local_agent::make_inference_engine(backend->config);
        backend->engine->load(backend->config);
        return LOCAL_AGENT_STATUS_OK;
    } catch (...) {
        return map_exception();
    }
}

LocalAgentStatus local_agent_backend_stream_chat(
    LocalAgentBackend *backend,
    const char *prompt_json,
    local_agent_token_callback callback,
    void *user_data,
    LocalAgentBackendStream **out_stream
) {
    LocalAgentStatus start = local_agent_backend_start_chat(
        backend,
        prompt_json,
        out_stream
    );
    if (start != LOCAL_AGENT_STATUS_OK) {
        return start;
    }
    return local_agent_backend_read_stream(*out_stream, callback, user_data);
}

LocalAgentStatus local_agent_backend_start_chat(
    LocalAgentBackend *backend,
    const char *prompt_json,
    LocalAgentBackendStream **out_stream
) {
    if (out_stream == nullptr) {
        return LOCAL_AGENT_STATUS_INVALID_ARGUMENT;
    }
    *out_stream = nullptr;
    if (backend == nullptr || prompt_json == nullptr) {
        return LOCAL_AGENT_STATUS_INVALID_ARGUMENT;
    }
    if (!backend->engine) {
        return LOCAL_AGENT_STATUS_ERROR;
    }
    try {
        auto stream = new LocalAgentBackendStream();
        stream->engine = backend->engine.get();
        stream->stream = backend->engine->start_chat(prompt_json);
        *out_stream = stream;
        return LOCAL_AGENT_STATUS_OK;
    } catch (...) {
        return map_exception();
    }
}

LocalAgentStatus local_agent_backend_start_chat_with_image(
    LocalAgentBackend *backend,
    const char *prompt_json,
    const unsigned char *rgb_data,
    uint32_t width,
    uint32_t height,
    LocalAgentBackendStream **out_stream
) {
    if (out_stream == nullptr) {
        return LOCAL_AGENT_STATUS_INVALID_ARGUMENT;
    }
    *out_stream = nullptr;
    if (
        backend == nullptr ||
        prompt_json == nullptr ||
        rgb_data == nullptr ||
        width == 0 ||
        height == 0
    ) {
        return LOCAL_AGENT_STATUS_INVALID_ARGUMENT;
    }
    if (!backend->engine) {
        return LOCAL_AGENT_STATUS_ERROR;
    }
    try {
        local_agent::ImageInput image;
        image.width = width;
        image.height = height;
        image.rgb_data.assign(
            rgb_data,
            rgb_data + (static_cast<size_t>(width) * static_cast<size_t>(height) * 3)
        );

        auto stream = new LocalAgentBackendStream();
        stream->engine = backend->engine.get();
        stream->stream = backend->engine->start_chat_with_image(prompt_json, image);
        *out_stream = stream;
        return LOCAL_AGENT_STATUS_OK;
    } catch (...) {
        return map_exception();
    }
}

LocalAgentStatus local_agent_backend_read_stream(
    LocalAgentBackendStream *stream,
    local_agent_token_callback callback,
    void *user_data
) {
    if (
        stream == nullptr ||
        stream->engine == nullptr ||
        stream->stream == nullptr ||
        callback == nullptr
    ) {
        return LOCAL_AGENT_STATUS_INVALID_ARGUMENT;
    }
    if (stream->stream->is_cancelled()) {
        return LOCAL_AGENT_STATUS_CANCELLED;
    }
    try {
        auto emit = [&](const std::string &json) {
            callback(json.c_str(), user_data);
        };
        stream->engine->read_stream(*stream->stream, emit);
        return stream->stream->is_cancelled()
            ? LOCAL_AGENT_STATUS_CANCELLED
            : LOCAL_AGENT_STATUS_OK;
    } catch (...) {
        return map_exception();
    }
}

LocalAgentStatus local_agent_backend_cancel(LocalAgentBackendStream *stream) {
    if (stream == nullptr || stream->stream == nullptr) {
        return LOCAL_AGENT_STATUS_INVALID_ARGUMENT;
    }
    stream->stream->cancel();
    return LOCAL_AGENT_STATUS_CANCELLED;
}

LocalAgentStatus local_agent_backend_release_stream(LocalAgentBackendStream *stream) {
    if (stream == nullptr) {
        return LOCAL_AGENT_STATUS_INVALID_ARGUMENT;
    }
    delete stream;
    return LOCAL_AGENT_STATUS_OK;
}

LocalAgentStatus local_agent_backend_release(LocalAgentBackend *backend) {
    if (backend == nullptr) {
        return LOCAL_AGENT_STATUS_INVALID_ARGUMENT;
    }
    delete backend;
    return LOCAL_AGENT_STATUS_OK;
}

} // extern "C"
