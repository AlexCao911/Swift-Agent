#include "generation_request.h"
#include "mock_inference_engine.h"

#include <cassert>
#include <string>
#include <vector>

int main() {
    local_agent::ModelLoadConfig config;
    config.engine = "mock";
    config.model_id = "mock.local";
    config.model_format = "mock";
    config.model_path = "/tmp/mock.gguf";
    config.context_tokens = 128;

    local_agent::MockInferenceEngine engine;
    auto model = engine.load_model(config);
    assert(model != nullptr);
    assert(model->runtime_info().engine_id == "mock");

    auto request = local_agent::parse_generation_request(
        R"({"messages":[{"role":"user","content":"hello"}],"sampling":{"max_new_tokens":8}})"
    );
    auto generation = model->start_generation(request, {});

    std::vector<std::string> events;
    generation->read([&](const std::string &event) {
        events.push_back(event);
        return true;
    });

    assert(events.size() == 4);
    assert(events[0] == R"({"type":"text_delta","text":"On-device "})");
    assert(events[1] == R"({"type":"text_delta","text":"mock response"})");
    assert(events[2].find("\"type\":\"usage\"") != std::string::npos);
    assert(events[3] == R"({"type":"completed","text":"On-device mock response"})");
    assert(generation->usage().available);
    return 0;
}
