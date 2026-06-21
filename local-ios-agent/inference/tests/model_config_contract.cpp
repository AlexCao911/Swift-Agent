#include "model_config.h"

#include <cassert>
#include <exception>
#include <string>

int main() {
    const std::string json = R"({
      "backend": "llama_cpp",
      "model_id": "local.gguf.simulator",
      "model_path": "/tmp/model.gguf",
      "chat_template": "gguf",
      "max_context_tokens": 2048,
      "generation": {
        "temperature": 0.2,
        "top_p": 0.9,
        "max_new_tokens": 128,
        "seed": 42
      },
      "llama_cpp": {
        "n_gpu_layers": 0,
        "n_threads": 4,
        "mmproj_path": ""
      }
    })";

    local_agent::ModelConfig config = local_agent::parse_model_config(json.c_str());
    assert(config.backend == "llama_cpp");
    assert(config.model_id == "local.gguf.simulator");
    assert(config.model_path == "/tmp/model.gguf");
    assert(config.chat_template == "gguf");
    assert(config.max_context_tokens == 2048);
    assert(config.generation.temperature == 0.2f);
    assert(config.generation.top_p == 0.9f);
    assert(config.generation.max_new_tokens == 128);
    assert(config.generation.seed == 42);
    assert(config.llama_cpp.n_gpu_layers == 0);
    assert(config.llama_cpp.n_threads == 4);
    assert(config.llama_cpp.mmproj_path.empty());

    bool rejected_empty_model_path = false;
    try {
        local_agent::parse_model_config(R"({"backend":"llama_cpp","model_path":""})");
    } catch (const std::exception &) {
        rejected_empty_model_path = true;
    }
    assert(rejected_empty_model_path);

    bool rejected_unknown_backend = false;
    try {
        local_agent::parse_model_config(R"({"backend":"one_big_hardcoded_model","model_path":"/tmp/model.gguf"})");
    } catch (const std::exception &) {
        rejected_unknown_backend = true;
    }
    assert(rejected_unknown_backend);

    return 0;
}
