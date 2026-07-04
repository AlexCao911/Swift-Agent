#include "local_agent_inference.h"

static LocalAgentStatus collect_token(const char *token_json, void *user_data) {
    (void)token_json;
    (void)user_data;
    return LOCAL_AGENT_STATUS_OK;
}

int main(void) {
    LocalAgentStatus status = LOCAL_AGENT_STATUS_OK;
    local_agent_token_callback callback = collect_token;
    char *json = 0;
    LocalAgentImageInput image = {0};
    LocalAgentEngineHandle *engine = 0;
    LocalAgentModelHandle *model = 0;
    LocalAgentGenerationHandle *generation = 0;

    status = local_agent_engine_list(&json);
    local_agent_string_free(json);
    status = local_agent_engine_create("mock", &engine);
    status = local_agent_engine_capabilities(engine, &json);
    local_agent_string_free(json);
    status = local_agent_model_load(
        engine,
        "{\"engine\":\"mock\",\"model_path\":\"/tmp/mock.gguf\"}",
        &model
    );
    status = local_agent_generation_start(
        model,
        "{\"messages\":[]}",
        &image,
        0,
        &generation
    );
    status = local_agent_generation_read(
        generation,
        callback,
        0
    );
    status = local_agent_generation_cancel(generation);
    status = local_agent_generation_release(generation);
    status = local_agent_model_unload(model);
    status = local_agent_last_error(engine, &json);
    local_agent_string_free(json);
    status = local_agent_engine_release(engine);

    return (int)status;
}
