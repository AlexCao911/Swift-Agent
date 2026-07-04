#include "model_config.h"

#include <cassert>
#include <exception>
#include <string>

int main() {
    const std::string json = R"({
      "engine": "llama_cpp",
      "model_id": "local.gguf.simulator",
      "model_format": "gguf",
      "model_path": "/tmp/model.gguf",
      "chat_template": "gguf",
      "context_tokens": 2048,
      "runtime": {
        "n_gpu_layers": 1,
        "n_threads": 6
      }
    })";

    local_agent::ModelLoadConfig config = local_agent::parse_model_load_config(json.c_str());
    assert(config.engine == "llama_cpp");
    assert(config.model_id == "local.gguf.simulator");
    assert(config.model_format == "gguf");
    assert(config.model_path == "/tmp/model.gguf");
    assert(config.chat_template == "gguf");
    assert(config.context_tokens == 2048);
    assert(config.runtime.n_gpu_layers == 1);
    assert(config.runtime.n_threads == 6);

    local_agent::ModelLoadConfig mock_config = local_agent::parse_model_load_config(
        R"({"engine":"mock","model_path":"/tmp/mock.gguf"})"
    );
    assert(mock_config.model_format == "mock");

    local_agent::ModelLoadConfig litert_config = local_agent::parse_model_load_config(
        R"({"engine":"litert","model_path":"/tmp/model.litertlm"})"
    );
    assert(litert_config.engine == "litert");
    assert(litert_config.model_format == "litert_lm");

    bool rejected_empty_model_path = false;
    try {
        local_agent::parse_model_load_config(R"({"engine":"llama_cpp","model_path":""})");
    } catch (const std::exception &) {
        rejected_empty_model_path = true;
    }
    assert(rejected_empty_model_path);

    bool rejected_unknown_backend = false;
    try {
        local_agent::parse_model_load_config(R"({"engine":"one_big_hardcoded_model","model_path":"/tmp/model.gguf"})");
    } catch (const std::exception &) {
        rejected_unknown_backend = true;
    }
    assert(rejected_unknown_backend);

    bool rejected_legacy_backend = false;
    try {
        local_agent::parse_model_load_config(R"({"backend":"llama_cpp","model_path":"/tmp/model.gguf"})");
    } catch (const std::exception &) {
        rejected_legacy_backend = true;
    }
    assert(rejected_legacy_backend);

    return 0;
}
