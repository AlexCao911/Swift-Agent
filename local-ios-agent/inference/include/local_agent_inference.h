#ifndef LOCAL_AGENT_INFERENCE_H
#define LOCAL_AGENT_INFERENCE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum LocalAgentStatus {
    LOCAL_AGENT_STATUS_OK = 0,
    LOCAL_AGENT_STATUS_ERROR = 1,
    LOCAL_AGENT_STATUS_CANCELLED = 2,
    LOCAL_AGENT_STATUS_INVALID_ARGUMENT = 3
} LocalAgentStatus;

typedef struct LocalAgentBackend LocalAgentBackend;
typedef struct LocalAgentBackendStream LocalAgentBackendStream;

typedef LocalAgentStatus (*local_agent_token_callback)(
    const char *token_json,
    void *user_data
);

LocalAgentStatus local_agent_backend_init(
    LocalAgentBackend **out_backend
);

LocalAgentStatus local_agent_backend_load_model(
    LocalAgentBackend *backend,
    const char *model_config_json
);

LocalAgentStatus local_agent_backend_stream_chat(
    LocalAgentBackend *backend,
    const char *prompt_json,
    local_agent_token_callback callback,
    void *user_data,
    LocalAgentBackendStream **out_stream
);

LocalAgentStatus local_agent_backend_start_chat(
    LocalAgentBackend *backend,
    const char *prompt_json,
    LocalAgentBackendStream **out_stream
);

LocalAgentStatus local_agent_backend_start_chat_with_image(
    LocalAgentBackend *backend,
    const char *prompt_json,
    const unsigned char *rgb_data,
    uint32_t width,
    uint32_t height,
    LocalAgentBackendStream **out_stream
);

LocalAgentStatus local_agent_backend_read_stream(
    LocalAgentBackendStream *stream,
    local_agent_token_callback callback,
    void *user_data
);

LocalAgentStatus local_agent_backend_cancel(
    LocalAgentBackendStream *stream
);

LocalAgentStatus local_agent_backend_release_stream(
    LocalAgentBackendStream *stream
);

LocalAgentStatus local_agent_backend_release(
    LocalAgentBackend *backend
);

#ifdef __cplusplus
}
#endif

#endif
