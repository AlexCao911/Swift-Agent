#include "generation_request.h"
#include "litert_api.h"
#include "litert_engine.h"

#include <cassert>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

class FakeLiteRTSession final : public local_agent::LiteRTSession {
public:
    void load(const local_agent::ModelLoadConfig &config) override {
        loaded = true;
        loaded_model_path = config.model_path;
        loaded_model_format = config.model_format;
    }

    local_agent::LiteRTGenerationOutput generate(
        const local_agent::ModelLoadConfig &,
        const local_agent::GenerationRequest &request
    ) override {
        assert(loaded);
        prompts.push_back(request.messages.back().content);
        local_agent::LiteRTGenerationOutput output;
        output.text = "LiteRT response: " + request.messages.back().content;
        output.usage = local_agent::UsageReport{3, 4, 7, true};
        return output;
    }

    void cancel() override {
        cancelled = true;
    }

    bool loaded = false;
    bool cancelled = false;
    std::string loaded_model_path;
    std::string loaded_model_format;
    std::vector<std::string> prompts;
};

int main() {
    auto fake_session = std::make_unique<FakeLiteRTSession>();
    auto *raw_session = fake_session.get();
    local_agent::LiteRTInferenceEngine engine(std::move(fake_session));

    auto capabilities = engine.capabilities();
    assert(capabilities.supports_streaming);
    assert(capabilities.supports_cancellation);
    assert(!capabilities.supports_vision);
    assert(!capabilities.supports_token_usage);

    local_agent::ModelLoadConfig config;
    config.engine = "litert";
    config.model_id = "edge.local";
    config.model_format = "tflite";
    config.model_path = "/tmp/model.tflite";
    config.context_tokens = 128;

    auto model = engine.load_model(config);
    assert(model != nullptr);
    assert(raw_session->loaded);
    assert(raw_session->loaded_model_path == "/tmp/model.tflite");
    assert(raw_session->loaded_model_format == "tflite");
    assert(model->runtime_info().engine_id == "litert");
    assert(model->runtime_info().model_id == "edge.local");

    auto request = local_agent::parse_generation_request(
        R"({"messages":[{"role":"user","content":"hello"}],"sampling":{"max_new_tokens":8}})"
    );
    auto generation = model->start_generation(request, {});
    std::vector<std::string> events;
    generation->read([&](const std::string &event) {
        events.push_back(event);
        return true;
    });

    assert(raw_session->prompts.size() == 1);
    assert(raw_session->prompts[0] == "hello");
    assert(events.size() == 3);
    assert(events[0] == R"({"type":"text_delta","text":"LiteRT response: hello"})");
    assert(events[1].find("\"type\":\"usage\"") != std::string::npos);
    assert(events[2] == R"({"type":"completed","text":"LiteRT response: hello"})");
    assert(generation->usage().available);
    assert(generation->usage().total_tokens == 7);

    auto image_request = local_agent::parse_generation_request(
        R"({"messages":[{"role":"user","content":"describe"}],"images":[{"format":"rgb8","width":1,"height":1}]})"
    );
    bool rejected_image = false;
    try {
        unsigned char pixel[3] = {255, 255, 255};
        (void)model->start_generation(
            image_request,
            {local_agent::ImageInput{
                std::vector<unsigned char>(pixel, pixel + 3),
                1,
                1,
            }}
        );
    } catch (const std::invalid_argument &) {
        rejected_image = true;
    }
    assert(rejected_image);

    bool rejected_format = false;
    try {
        local_agent::ModelLoadConfig bad_config = config;
        bad_config.model_format = "gguf";
        (void)engine.load_model(bad_config);
    } catch (const std::invalid_argument &) {
        rejected_format = true;
    }
    assert(rejected_format);

    return 0;
}
