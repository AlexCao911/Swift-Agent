#include "local_agent_inference.h"

static LocalAgentStatus collect_token(const char *token_json, void *user_data) {
    (void)token_json;
    (void)user_data;
    return LOCAL_AGENT_STATUS_OK;
}

int main(void) {
    LocalAgentBackend *backend = 0;
    LocalAgentBackendStream *stream = 0;
    local_agent_token_callback callback = collect_token;

    LocalAgentStatus status = local_agent_backend_init(&backend);
    status = local_agent_backend_load_model(backend, "{\"model\":\"mock\"}");
    status = local_agent_backend_stream_chat(
        backend,
        "{\"messages\":[]}",
        callback,
        0,
        &stream
    );
    status = local_agent_backend_release_stream(stream);
    stream = 0;
    status = local_agent_backend_start_chat(
        backend,
        "{\"messages\":[]}",
        &stream
    );
    status = local_agent_backend_read_stream(
        stream,
        callback,
        0
    );
    status = local_agent_backend_cancel(stream);
    status = local_agent_backend_release_stream(stream);
    status = local_agent_backend_release(backend);

    return (int)status;
}
