#include "model_config.h"

#include <cstdlib>
#include <stdexcept>
#include <string>

namespace local_agent {
namespace {

std::string find_raw_value(const std::string &json, const std::string &key) {
    const std::string needle = "\"" + key + "\"";
    const std::size_t key_pos = json.find(needle);
    if (key_pos == std::string::npos) {
        return "";
    }
    const std::size_t colon_pos = json.find(':', key_pos + needle.size());
    if (colon_pos == std::string::npos) {
        return "";
    }
    const std::size_t value_start = json.find_first_not_of(" \n\r\t", colon_pos + 1);
    if (value_start == std::string::npos) {
        return "";
    }
    if (json[value_start] == '"') {
        const std::size_t value_end = json.find('"', value_start + 1);
        if (value_end == std::string::npos) {
            throw std::invalid_argument("unterminated string for key: " + key);
        }
        return json.substr(value_start + 1, value_end - value_start - 1);
    }
    const std::size_t value_end = json.find_first_of(",}\n\r\t ", value_start);
    return json.substr(value_start, value_end - value_start);
}

void require_non_empty(const std::string &value, const std::string &key) {
    if (value.empty()) {
        throw std::invalid_argument("missing required model config key: " + key);
    }
}

} // namespace

std::string require_json_string(const std::string &json, const std::string &key) {
    std::string value = find_raw_value(json, key);
    require_non_empty(value, key);
    return value;
}

int optional_json_int(const std::string &json, const std::string &key, int fallback) {
    std::string value = find_raw_value(json, key);
    if (value.empty()) {
        return fallback;
    }
    return std::atoi(value.c_str());
}

float optional_json_float(const std::string &json, const std::string &key, float fallback) {
    std::string value = find_raw_value(json, key);
    if (value.empty()) {
        return fallback;
    }
    return static_cast<float>(std::atof(value.c_str()));
}

std::string optional_json_string(
    const std::string &json,
    const std::string &key,
    const std::string &fallback
) {
    std::string value = find_raw_value(json, key);
    if (value.empty()) {
        return fallback;
    }
    return value;
}

ModelConfig parse_model_config(const char *model_config_json) {
    if (model_config_json == nullptr) {
        throw std::invalid_argument("model config json is null");
    }

    const std::string json(model_config_json);
    ModelConfig config;
    config.backend = require_json_string(json, "backend");
    config.model_path = require_json_string(json, "model_path");
    config.model_id = optional_json_string(json, "model_id", config.model_path);
    config.chat_template = optional_json_string(json, "chat_template", "gguf");
    config.max_context_tokens = optional_json_int(json, "max_context_tokens", 2048);
    config.generation.temperature = optional_json_float(json, "temperature", 0.2f);
    config.generation.top_p = optional_json_float(json, "top_p", 0.9f);
    config.generation.max_new_tokens = optional_json_int(json, "max_new_tokens", 128);
    config.generation.seed = optional_json_int(json, "seed", 42);
    config.llama_cpp.n_gpu_layers = optional_json_int(json, "n_gpu_layers", 0);
    config.llama_cpp.n_threads = optional_json_int(json, "n_threads", 4);
    config.llama_cpp.mmproj_path = optional_json_string(json, "mmproj_path", "");

    if (config.backend != "mock" && config.backend != "llama_cpp") {
        throw std::invalid_argument("unsupported inference backend: " + config.backend);
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
