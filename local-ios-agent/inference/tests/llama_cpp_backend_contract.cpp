#include "llama_cpp_engine.h"
#include "model_config.h"

#include <cassert>
#include <cstdlib>
#include <string>
#include <vector>

int main() {
    const char *model_path = std::getenv("LOCAL_AGENT_SIMULATOR_GGUF");
    if (model_path == nullptr || std::string(model_path).empty()) {
        return 77;
    }
    const char *mmproj_path_env = std::getenv("LOCAL_AGENT_SIMULATOR_MMPROJ");
    const std::string mmproj_path = mmproj_path_env == nullptr ? "" : mmproj_path_env;

    std::string config_json = std::string(R"({
      "backend":"llama_cpp",
      "model_id":"local.gguf.simulator",
      "model_path":")") + model_path + R"(",
      "chat_template":"gguf",
      "max_context_tokens":512,
      "generation":{"temperature":0.0,"top_p":1.0,"max_new_tokens":16,"seed":42},
      "llama_cpp":{"n_gpu_layers":0,"n_threads":2,"mmproj_path":")" + mmproj_path + R"("}
    })";

    local_agent::ModelConfig config = local_agent::parse_model_config(config_json.c_str());
    local_agent::LlamaCppEngine engine;
    engine.load(config);

    auto stream = engine.start_chat(R"({"messages":[{"role":"user","content":"Say hi."}]})");
    std::vector<std::string> tokens;
    engine.read_stream(*stream, [&](const std::string &token_json) {
        tokens.push_back(token_json);
    });

    assert(!tokens.empty());
    assert(tokens.back().find("\"type\":\"completed\"") != std::string::npos);

    if (!mmproj_path.empty()) {
        unsigned char white_pixel[3] = {255, 255, 255};
        auto image_stream = engine.start_chat_with_image(
            R"({"messages":[{"role":"user","content":"Describe this image."}]})",
            local_agent::ImageInput{
                std::vector<unsigned char>(white_pixel, white_pixel + 3),
                1,
                1
            }
        );
        std::vector<std::string> image_tokens;
        engine.read_stream(*image_stream, [&](const std::string &token_json) {
            image_tokens.push_back(token_json);
        });
        assert(!image_tokens.empty());
    }
    return 0;
}
