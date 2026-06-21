#ifndef LOCAL_AGENT_MODEL_CONFIG_H
#define LOCAL_AGENT_MODEL_CONFIG_H

#include <string>

namespace local_agent {

struct GenerationConfig {
    float temperature = 0.2f;
    float top_p = 0.9f;
    int max_new_tokens = 128;
    int seed = 42;
};

struct LlamaCppConfig {
    int n_gpu_layers = 0;
    int n_threads = 4;
    std::string mmproj_path;
};

struct ModelConfig {
    std::string backend;
    std::string model_id;
    std::string model_path;
    std::string chat_template;
    int max_context_tokens = 2048;
    GenerationConfig generation;
    LlamaCppConfig llama_cpp;
};

ModelConfig parse_model_config(const char *model_config_json);
std::string require_json_string(const std::string &json, const std::string &key);
int optional_json_int(const std::string &json, const std::string &key, int fallback);
float optional_json_float(const std::string &json, const std::string &key, float fallback);
std::string optional_json_string(
    const std::string &json,
    const std::string &key,
    const std::string &fallback
);

} // namespace local_agent

#endif
