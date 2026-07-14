#include "local_agent_inference.h"

#include <cassert>

int main() {
    LocalAgentEngineHandle *engine = nullptr;
    assert(local_agent_engine_create("mock", &engine) == LOCAL_AGENT_STATUS_OK);

    assert(local_agent_model_validate(
        engine,
        R"({"engine":"mock","model_path":"fail_if_loaded","model_format":"mock","chat_template_source":"catalog_artifact","chat_template_id":"mock"})"
    ) == LOCAL_AGENT_STATUS_OK);
    assert(local_agent_model_validate(
        engine,
        R"({"engine":"mock","model_path":"/tmp/mock.gguf","model_format":"gguf","chat_template_source":"catalog_artifact","chat_template_id":"mock"})"
    ) == LOCAL_AGENT_STATUS_INVALID_ARGUMENT);
    assert(local_agent_model_validate(
        engine,
        R"({"engine":"mock","model_path":"/tmp/mock.gguf","model_format":"mock"})"
    ) == LOCAL_AGENT_STATUS_INVALID_ARGUMENT);

    LocalAgentModelHandle *model = nullptr;
    assert(local_agent_model_load(
        engine,
        R"({"engine":"mock","model_path":"/tmp/mock.gguf","model_format":"mock","chat_template_source":"catalog_artifact","chat_template_id":"mock","tool_call_codec_id":"json_tool_calls_v1"})",
        &model
    ) == LOCAL_AGENT_STATUS_OK);

    assert(local_agent_generation_validate(
        model,
        R"({"schema_version":"2","messages":[{"role":"user","content":[{"type":"text","text":"hello"}]}],"template":{"source":"catalog_artifact","id":"mock"},"sampling":{"stop_sequences":["stop"]}})"
    ) == LOCAL_AGENT_STATUS_INVALID_ARGUMENT);
    assert(local_agent_generation_validate(
        model,
        R"({"schema_version":"2","messages":[{"role":"user","content":[{"type":"text","text":"hello"}]}],"template":{"source":"catalog_artifact","id":"mock"},"sampling":{"max_new_tokens":2049}})"
    ) == LOCAL_AGENT_STATUS_INVALID_ARGUMENT);
    assert(local_agent_generation_validate(
        model,
        R"({"schema_version":"2","messages":[{"role":"user","content":[{"type":"text","text":"hello"}]}],"tool_schema":{"tools":[{"name":"search","input_schema":{"type":"object"}}]},"template":{"source":"catalog_artifact","id":"mock"},"tool_call_codec_id":"other_codec"})"
    ) == LOCAL_AGENT_STATUS_INVALID_ARGUMENT);

    assert(local_agent_model_unload(model) == LOCAL_AGENT_STATUS_OK);
    assert(local_agent_engine_release(engine) == LOCAL_AGENT_STATUS_OK);
    return 0;
}
