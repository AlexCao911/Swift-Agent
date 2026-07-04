#include "local_agent_inference.h"

#include <algorithm>
#include <cassert>
#include <string>
#include <vector>

static LocalAgentStatus collect_token(const char *token_json, void *user_data) {
    auto *events = static_cast<std::vector<std::string> *>(user_data);
    events->emplace_back(token_json);
    return LOCAL_AGENT_STATUS_OK;
}

int main() {
    LocalAgentEngineHandle *missing = nullptr;
    assert(local_agent_engine_create("missing_engine", &missing) == LOCAL_AGENT_STATUS_ERROR);
    assert(missing == nullptr);

    char *error_json = nullptr;
    assert(local_agent_last_error(nullptr, &error_json) == LOCAL_AGENT_STATUS_OK);
    assert(std::string(error_json).find("\"code\":\"engine_unavailable\"") != std::string::npos);
    local_agent_string_free(error_json);

    char *engine_list_json = nullptr;
    assert(local_agent_engine_list(&engine_list_json) == LOCAL_AGENT_STATUS_OK);
    assert(engine_list_json != nullptr);
    std::string engine_list(engine_list_json);
    assert(engine_list.find("\"engine_id\":\"mock\"") != std::string::npos);
    local_agent_string_free(engine_list_json);

    LocalAgentEngineHandle *engine = nullptr;
    assert(local_agent_engine_create("mock", &engine) == LOCAL_AGENT_STATUS_OK);
    assert(engine != nullptr);

    char *capabilities_json = nullptr;
    assert(local_agent_engine_capabilities(engine, &capabilities_json) == LOCAL_AGENT_STATUS_OK);
    assert(std::string(capabilities_json).find("\"supports_streaming\":true") != std::string::npos);
    local_agent_string_free(capabilities_json);

    LocalAgentModelHandle *model = nullptr;
    assert(local_agent_model_load(
        engine,
        R"({"engine":"mock","model_id":"mock.local","model_path":"/tmp/mock.gguf","model_format":"mock"})",
        &model
    ) == LOCAL_AGENT_STATUS_OK);

    LocalAgentGenerationHandle *generation = nullptr;
    assert(local_agent_generation_start(
        model,
        R"({"messages":[{"role":"user","content":"hello"}],"sampling":{"max_new_tokens":8}})",
        nullptr,
        0,
        &generation
    ) == LOCAL_AGENT_STATUS_OK);
    assert(generation != nullptr);

    std::vector<std::string> events;
    assert(local_agent_generation_read(generation, collect_token, &events) == LOCAL_AGENT_STATUS_OK);
    assert(events.front().find("\"type\":\"text_delta\"") != std::string::npos);
    assert(std::any_of(events.begin(), events.end(), [](const std::string &event) {
        return event.find("\"type\":\"usage\"") != std::string::npos;
    }));
    assert(events.back().find("\"type\":\"completed\"") != std::string::npos);

    assert(local_agent_generation_release(generation) == LOCAL_AGENT_STATUS_OK);
    assert(local_agent_model_unload(model) == LOCAL_AGENT_STATUS_OK);
    assert(local_agent_engine_release(engine) == LOCAL_AGENT_STATUS_OK);
    assert(local_agent_generation_release(nullptr) == LOCAL_AGENT_STATUS_OK);
    assert(local_agent_model_unload(nullptr) == LOCAL_AGENT_STATUS_OK);
    assert(local_agent_engine_release(nullptr) == LOCAL_AGENT_STATUS_OK);

    LocalAgentEngineHandle *parent_engine = nullptr;
    assert(local_agent_engine_create("mock", &parent_engine) == LOCAL_AGENT_STATUS_OK);

    LocalAgentModelHandle *child_model = nullptr;
    assert(local_agent_model_load(
        parent_engine,
        R"({"engine":"mock","model_id":"mock.parent","model_path":"/tmp/mock.gguf","model_format":"mock"})",
        &child_model
    ) == LOCAL_AGENT_STATUS_OK);

    LocalAgentGenerationHandle *child_generation = nullptr;
    assert(local_agent_generation_start(
        child_model,
        R"({"messages":[{"role":"user","content":"release order"}]})",
        nullptr,
        0,
        &child_generation
    ) == LOCAL_AGENT_STATUS_OK);

    assert(local_agent_engine_release(parent_engine) == LOCAL_AGENT_STATUS_OK);
    assert(local_agent_model_unload(child_model) == LOCAL_AGENT_STATUS_OK);

    std::vector<std::string> out_of_order_events;
    assert(local_agent_generation_read(
        child_generation,
        collect_token,
        &out_of_order_events
    ) == LOCAL_AGENT_STATUS_OK);
    assert(!out_of_order_events.empty());
    assert(local_agent_generation_release(child_generation) == LOCAL_AGENT_STATUS_OK);

    return 0;
}
