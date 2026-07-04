#include "model_config.h"

#include "json_value.h"

#include <stdexcept>
#include <string>

namespace local_agent {
namespace {

void require_non_empty(const std::string &value, const std::string &key) {
    if (value.empty()) {
        throw std::invalid_argument("missing required model config key: " + key);
    }
}

std::string default_model_format(const std::string &engine) {
    if (engine == "mock") {
        return "mock";
    }
    if (engine == "llama_cpp") {
        return "gguf";
    }
    if (engine == "litert") {
        return "litert_lm";
    }
    return "";
}

void validate_supported_engine(const std::string &engine) {
    if (engine != "mock" && engine != "llama_cpp" && engine != "litert") {
        throw std::invalid_argument("unsupported inference engine: " + engine);
    }
}

} // namespace

std::string require_json_string(const std::string &json, const std::string &key) {
    std::string value = local_agent::json::require_string(local_agent::json::parse(json.c_str()), key);
    require_non_empty(value, key);
    return value;
}

int optional_json_int(const std::string &json, const std::string &key, int fallback) {
    return local_agent::json::optional_int(local_agent::json::parse(json.c_str()), key, fallback);
}

float optional_json_float(const std::string &json, const std::string &key, float fallback) {
    return local_agent::json::optional_float(local_agent::json::parse(json.c_str()), key, fallback);
}

std::string optional_json_string(
    const std::string &json,
    const std::string &key,
    const std::string &fallback
) {
    return local_agent::json::optional_string(local_agent::json::parse(json.c_str()), key, fallback);
}

ModelLoadConfig parse_model_load_config(const char *model_config_json) {
    if (model_config_json == nullptr) {
        throw std::invalid_argument("model config json is null");
    }

    const json::Value root = json::parse(model_config_json);
    if (!root.is_object()) {
        throw std::invalid_argument("model config must be a json object");
    }

    ModelLoadConfig config;
    config.engine = json::require_string(root, "engine");
    require_non_empty(config.engine, "engine");
    validate_supported_engine(config.engine);
    config.model_path = json::require_string(root, "model_path");
    require_non_empty(config.model_path, "model_path");
    config.model_id = json::optional_string(root, "model_id", config.model_path);
    config.model_format = json::optional_string(root, "model_format", default_model_format(config.engine));
    config.mmproj_path = json::optional_string(root, "mmproj_path", "");
    config.chat_template = json::optional_string(root, "chat_template", "gguf");
    config.context_tokens = json::optional_int(root, "context_tokens", 2048);
    const json::Value *runtime = root.get("runtime");
    if (runtime != nullptr) {
        config.runtime.n_threads = json::optional_int(*runtime, "n_threads", config.runtime.n_threads);
        config.runtime.n_gpu_layers = json::optional_int(*runtime, "n_gpu_layers", config.runtime.n_gpu_layers);
    }
    if (config.context_tokens <= 0) {
        throw std::invalid_argument("context_tokens must be positive");
    }
    return config;
}

ModelConfig parse_model_config(const char *model_config_json) {
    const json::Value root = json::parse(model_config_json);

    ModelConfig config;
    config.backend = json::optional_string(root, "backend", json::optional_string(root, "engine", "mock"));
    validate_supported_engine(config.backend);
    config.model_path = json::require_string(root, "model_path");
    require_non_empty(config.model_path, "model_path");
    config.model_id = json::optional_string(root, "model_id", config.model_path);
    config.chat_template = json::optional_string(root, "chat_template", "gguf");
    config.max_context_tokens = json::optional_int(root, "max_context_tokens", json::optional_int(root, "context_tokens", 2048));

    const json::Value *generation = root.get("generation");
    if (generation != nullptr) {
        config.generation.temperature = json::optional_float(*generation, "temperature", config.generation.temperature);
        config.generation.top_p = json::optional_float(*generation, "top_p", config.generation.top_p);
        config.generation.max_new_tokens = json::optional_int(*generation, "max_new_tokens", config.generation.max_new_tokens);
        config.generation.seed = json::optional_int(*generation, "seed", config.generation.seed);
    }
    const json::Value *llama_cpp = root.get("llama_cpp");
    if (llama_cpp != nullptr) {
        config.llama_cpp.n_gpu_layers = json::optional_int(*llama_cpp, "n_gpu_layers", config.llama_cpp.n_gpu_layers);
        config.llama_cpp.n_threads = json::optional_int(*llama_cpp, "n_threads", config.llama_cpp.n_threads);
        config.llama_cpp.mmproj_path = json::optional_string(*llama_cpp, "mmproj_path", config.llama_cpp.mmproj_path);
    }

    if (config.max_context_tokens <= 0) {
        throw std::invalid_argument("max_context_tokens must be positive");
    }
    if (config.generation.max_new_tokens <= 0) {
        throw std::invalid_argument("max_new_tokens must be positive");
    }

    return config;
}

} // namespace local_agent
