#include "llama_cpp_engine.h"
#include "model_config.h"
#include "generation_request.h"

#include <cassert>
#include <cstdlib>
#include <memory>
#include <string>
#include <vector>

class FakeLlamaSession final : public local_agent::LlamaCppSession {
public:
    void load(const local_agent::ModelConfig &) override {}

    void stream_generate(
        const std::string &,
        const local_agent::ModelConfig &,
        const local_agent::LlamaTokenEmit &emit
    ) override {
        if (!emit("first")) {
            return;
        }
        emit("second");
    }

    void stream_generate_with_image(
        const std::string &,
        const local_agent::ImageInput &,
        const local_agent::ModelConfig &,
        const local_agent::LlamaTokenEmit &
    ) override {
        assert(false && "image path is not expected in this fake session");
    }
};

void assert_engine_does_not_complete_after_emit_stop() {
    local_agent::ModelLoadConfig config;
    config.engine = "llama_cpp";
    config.model_format = "gguf";
    config.model_path = "fake.gguf";
    config.context_tokens = 128;

    local_agent::LlamaCppEngine engine(std::make_unique<FakeLlamaSession>());
    auto model = engine.load_model(config);
    auto request = local_agent::parse_generation_request(
        R"({"messages":[{"role":"user","content":"stop"}],"sampling":{"max_new_tokens":8}})"
    );
    auto generation = model->start_generation(request, {});

    std::vector<std::string> tokens;
    generation->read([&](const std::string &token_json) {
        tokens.push_back(token_json);
        return false;
    });

    assert(tokens.size() == 1);
    assert(tokens[0].find("\"type\":\"text_delta\"") != std::string::npos);
}

int main() {
    assert_engine_does_not_complete_after_emit_stop();

    const char *model_path = std::getenv("LOCAL_AGENT_SIMULATOR_GGUF");
    if (model_path == nullptr || std::string(model_path).empty()) {
        return 77;
    }
    const char *mmproj_path_env = std::getenv("LOCAL_AGENT_SIMULATOR_MMPROJ");
    const std::string mmproj_path = mmproj_path_env == nullptr ? "" : mmproj_path_env;

    std::string config_json = std::string(R"({
      "engine":"llama_cpp",
      "model_id":"local.gguf.simulator",
      "model_format":"gguf",
      "model_path":")") + model_path + R"(",
      "chat_template":"gguf",
      "context_tokens":512,
      "mmproj_path":")" + mmproj_path + R"(",
      "runtime":{"n_gpu_layers":0,"n_threads":2}
    })";

    local_agent::ModelLoadConfig config = local_agent::parse_model_load_config(config_json.c_str());
    local_agent::LlamaCppEngine engine;
    auto model = engine.load_model(config);

    auto request = local_agent::parse_generation_request(
        R"({"messages":[{"role":"user","content":"Say hi."}],"sampling":{"temperature":0.0,"top_p":1.0,"max_new_tokens":16,"seed":42}})"
    );
    auto generation = model->start_generation(request, {});
    std::vector<std::string> tokens;
    generation->read([&](const std::string &token_json) {
        tokens.push_back(token_json);
        return true;
    });

    assert(!tokens.empty());
    assert(tokens.back().find("\"type\":\"completed\"") != std::string::npos);

    if (!mmproj_path.empty()) {
        unsigned char white_pixel[3] = {255, 255, 255};
        auto image_request = local_agent::parse_generation_request(
            R"({"messages":[{"role":"user","content":"Describe this image."}],"images":[{"format":"rgb8","width":1,"height":1}]})"
        );
        auto image_generation = model->start_generation(
            image_request,
            {local_agent::ImageInput{
                std::vector<unsigned char>(white_pixel, white_pixel + 3),
                1,
                1
            }}
        );
        std::vector<std::string> image_tokens;
        image_generation->read([&](const std::string &token_json) {
            image_tokens.push_back(token_json);
            return true;
        });
        assert(!image_tokens.empty());
    }
    return 0;
}
