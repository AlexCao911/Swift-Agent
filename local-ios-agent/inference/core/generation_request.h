#ifndef LOCAL_AGENT_GENERATION_REQUEST_H
#define LOCAL_AGENT_GENERATION_REQUEST_H

#include <cstdint>
#include <optional>
#include <set>
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
    std::set<std::string> provided_options;
};

struct PromptContentPart {
    std::string type;
    std::string text;
};

struct PromptToolCall {
    std::string id;
    std::string name;
    std::string arguments_json;
};

struct PromptMessage {
    std::string role;
    std::vector<PromptContentPart> content;
    std::vector<PromptToolCall> tool_calls;
    std::string tool_call_id;
    std::string tool_name;
};

struct CanonicalToolSchema {
    std::string json;
};

struct ChatTemplateSelector {
    std::string source;
    std::string id;
};

struct ImageMetadata {
    std::string format;
    uint32_t width = 0;
    uint32_t height = 0;
};

struct GenerationRequest {
    std::string schema_version;
    std::vector<PromptMessage> messages;
    std::vector<ImageMetadata> images;
    std::optional<CanonicalToolSchema> tool_schema;
    ChatTemplateSelector chat_template;
    std::optional<std::string> tool_call_codec_id;
    SamplingConfig sampling;
};

GenerationRequest parse_generation_request(const char *generation_request_json);
std::string prompt_message_text(const PromptMessage &message);
std::string prompt_json_from_generation_request(const GenerationRequest &request);

} // namespace local_agent

#endif
