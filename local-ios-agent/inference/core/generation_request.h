#ifndef LOCAL_AGENT_GENERATION_REQUEST_H
#define LOCAL_AGENT_GENERATION_REQUEST_H

#include <cstdint>
#include <string>
#include <vector>

namespace local_agent {

struct SamplingConfig {
    float temperature = 0.2f;
    float top_p = 0.9f;
    int top_k = 40;
    float min_p = 0.05f;
    float repeat_penalty = 1.1f;
    int seed = 42;
    int max_new_tokens = 128;
    std::vector<std::string> stop_sequences;
};

struct PromptMessage {
    std::string role;
    std::string content;
};

struct ImageMetadata {
    std::string format;
    uint32_t width = 0;
    uint32_t height = 0;
};

struct GenerationRequest {
    std::vector<PromptMessage> messages;
    std::vector<ImageMetadata> images;
    SamplingConfig sampling;
};

GenerationRequest parse_generation_request(const char *generation_request_json);
std::string prompt_json_from_generation_request(const GenerationRequest &request);

} // namespace local_agent

#endif
