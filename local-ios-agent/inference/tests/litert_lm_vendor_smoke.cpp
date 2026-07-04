#include "local_agent_inference.h"

#include <cassert>
#include <cstdlib>
#include <string>
#include <vector>

namespace {

struct Events {
    std::vector<std::string> values;
};

LocalAgentStatus collect_event(const char *token_json, void *user_data) {
    assert(token_json != nullptr);
    auto *events = static_cast<Events *>(user_data);
    events->values.emplace_back(token_json);
    return LOCAL_AGENT_STATUS_OK;
}

LocalAgentStatus cancel_after_first_event(const char *token_json, void *user_data) {
    assert(token_json != nullptr);
    auto *events = static_cast<Events *>(user_data);
    events->values.emplace_back(token_json);
    return LOCAL_AGENT_STATUS_CANCELLED;
}

bool contains_event(const Events &events, const std::string &needle) {
    for (const auto &event : events.values) {
        if (event.find(needle) != std::string::npos) {
            return true;
        }
    }
    return false;
}

std::string json_escape(const std::string &value) {
    std::string escaped;
    for (char c : value) {
        switch (c) {
        case '"':
            escaped += "\\\"";
            break;
        case '\\':
            escaped += "\\\\";
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

std::string model_config_json(const std::string &model_path) {
    return std::string("{")
        + R"("engine":"litert",)"
        + R"("model_id":"litert_lm.vendor.smoke",)"
        + R"("model_format":"litert_lm",)"
        + R"("model_path":")" + json_escape(model_path) + R"(")"
        + "}";
}

std::string generation_request_json(const char *prompt) {
    std::string text = prompt == nullptr ? "Reply with one short sentence." : prompt;
    return std::string("{")
        + R"("messages":[{"role":"user","content":")" + json_escape(text) + R"("}],)"
        + R"("sampling":{"max_new_tokens":16,"temperature":0.2,"top_p":0.9,"top_k":40,"seed":7})"
        + "}";
}

void release_all(
    LocalAgentEngineHandle *engine,
    LocalAgentModelHandle *model,
    LocalAgentGenerationHandle *generation
) {
    local_agent_generation_release(generation);
    local_agent_model_unload(model);
    local_agent_engine_release(engine);
}

} // namespace

int main() {
    const char *model_path = std::getenv("LOCAL_AGENT_LITERT_LM_MODEL_PATH");
    assert(model_path != nullptr);
    assert(model_path[0] != '\0');

    LocalAgentEngineHandle *engine = nullptr;
    assert(local_agent_engine_create("litert", &engine) == LOCAL_AGENT_STATUS_OK);
    assert(engine != nullptr);

    const std::string config = model_config_json(model_path);
    LocalAgentModelHandle *model = nullptr;
    assert(local_agent_model_load(engine, config.c_str(), &model) == LOCAL_AGENT_STATUS_OK);
    assert(model != nullptr);

    const std::string request = generation_request_json(std::getenv("LOCAL_AGENT_LITERT_LM_PROMPT"));
    LocalAgentGenerationHandle *generation = nullptr;
    assert(local_agent_generation_start(model, request.c_str(), nullptr, 0, &generation) == LOCAL_AGENT_STATUS_OK);
    assert(generation != nullptr);

    Events events;
    assert(local_agent_generation_read(generation, collect_event, &events) == LOCAL_AGENT_STATUS_OK);
    assert(contains_event(events, R"("type":"text_delta")"));
    assert(contains_event(events, R"("type":"completed")"));
    assert(local_agent_generation_release(generation) == LOCAL_AGENT_STATUS_OK);
    generation = nullptr;

    assert(local_agent_generation_start(model, request.c_str(), nullptr, 0, &generation) == LOCAL_AGENT_STATUS_OK);
    assert(generation != nullptr);

    Events cancelled_events;
    LocalAgentStatus cancel_status =
        local_agent_generation_read(generation, cancel_after_first_event, &cancelled_events);
    assert(cancel_status == LOCAL_AGENT_STATUS_CANCELLED);
    assert(contains_event(cancelled_events, R"("type":"text_delta")"));

    release_all(engine, model, generation);
    return 0;
}
