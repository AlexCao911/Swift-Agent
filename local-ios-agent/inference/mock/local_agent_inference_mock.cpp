#include "local_agent_inference.h"

struct LocalAgentBackend {
    bool loaded = false;
};

struct LocalAgentBackendStream {
    LocalAgentBackend *backend = nullptr;
    bool cancelled = false;
};

namespace {

LocalAgentStatus emit_token(
    LocalAgentBackendStream *stream,
    local_agent_token_callback callback,
    void *user_data,
    const char *token_json
) {
    if (stream->cancelled) {
        return LOCAL_AGENT_STATUS_CANCELLED;
    }

    LocalAgentStatus callback_status = callback(token_json, user_data);
    if (callback_status != LOCAL_AGENT_STATUS_OK) {
        stream->cancelled = true;
        return callback_status;
    }

    if (stream->cancelled) {
        return LOCAL_AGENT_STATUS_CANCELLED;
    }
    return LOCAL_AGENT_STATUS_OK;
}

} // namespace

LocalAgentStatus local_agent_backend_init(
    LocalAgentBackend **out_backend
) {
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

    backend->loaded = true;
    return LOCAL_AGENT_STATUS_OK;
}

LocalAgentStatus local_agent_backend_stream_chat(
    LocalAgentBackend *backend,
    const char *prompt_json,
    local_agent_token_callback callback,
    void *user_data,
    LocalAgentBackendStream **out_stream
) {
    LocalAgentStatus status = local_agent_backend_start_chat(
        backend,
        prompt_json,
        out_stream
    );
    if (status != LOCAL_AGENT_STATUS_OK) {
        return status;
    }

    return local_agent_backend_read_stream(
        *out_stream,
        callback,
        user_data
    );
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

    if (
        backend == nullptr ||
        prompt_json == nullptr
    ) {
        return LOCAL_AGENT_STATUS_INVALID_ARGUMENT;
    }

    if (!backend->loaded) {
        return LOCAL_AGENT_STATUS_ERROR;
    }

    auto *stream = new LocalAgentBackendStream();
    stream->backend = backend;
    *out_stream = stream;

    return LOCAL_AGENT_STATUS_OK;
}

LocalAgentStatus local_agent_backend_start_chat_with_image(
    LocalAgentBackend *backend,
    const char *prompt_json,
    const unsigned char *rgb_data,
    uint32_t width,
    uint32_t height,
    LocalAgentBackendStream **out_stream
) {
    if (out_stream != nullptr) {
        *out_stream = nullptr;
    }
    if (
        backend == nullptr ||
        prompt_json == nullptr ||
        rgb_data == nullptr ||
        width == 0 ||
        height == 0 ||
        out_stream == nullptr
    ) {
        return LOCAL_AGENT_STATUS_INVALID_ARGUMENT;
    }
    return LOCAL_AGENT_STATUS_INVALID_ARGUMENT;
}

LocalAgentStatus local_agent_backend_read_stream(
    LocalAgentBackendStream *stream,
    local_agent_token_callback callback,
    void *user_data
) {
    if (stream == nullptr || callback == nullptr) {
        return LOCAL_AGENT_STATUS_INVALID_ARGUMENT;
    }

    const char *tokens[] = {
        "{\"type\":\"text_delta\",\"text\":\"On-device \"}",
        "{\"type\":\"text_delta\",\"text\":\"mock response\"}",
        "{\"type\":\"completed\",\"text\":\"On-device mock response\"}",
    };

    for (const char *token : tokens) {
        LocalAgentStatus status = emit_token(stream, callback, user_data, token);
        if (status != LOCAL_AGENT_STATUS_OK) {
            return status;
        }
    }

    return LOCAL_AGENT_STATUS_OK;
}

LocalAgentStatus local_agent_backend_cancel(
    LocalAgentBackendStream *stream
) {
    if (stream == nullptr) {
        return LOCAL_AGENT_STATUS_INVALID_ARGUMENT;
    }

    stream->cancelled = true;
    return LOCAL_AGENT_STATUS_CANCELLED;
}

LocalAgentStatus local_agent_backend_release_stream(
    LocalAgentBackendStream *stream
) {
    if (stream == nullptr) {
        return LOCAL_AGENT_STATUS_INVALID_ARGUMENT;
    }

    delete stream;
    return LOCAL_AGENT_STATUS_OK;
}

LocalAgentStatus local_agent_backend_release(
    LocalAgentBackend *backend
) {
    if (backend == nullptr) {
        return LOCAL_AGENT_STATUS_INVALID_ARGUMENT;
    }

    delete backend;
    return LOCAL_AGENT_STATUS_OK;
}
