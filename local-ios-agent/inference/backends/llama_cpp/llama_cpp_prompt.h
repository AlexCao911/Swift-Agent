#ifndef LOCAL_AGENT_LLAMA_CPP_PROMPT_H
#define LOCAL_AGENT_LLAMA_CPP_PROMPT_H

#include <string>
#include <vector>

namespace local_agent {

struct LlamaPromptToolCall {
    std::string id;
    std::string name;
    std::string arguments_json;
};

struct LlamaPromptMessage {
    std::string role;
    std::string content;
    std::vector<LlamaPromptToolCall> tool_calls;
    std::string tool_call_id;
    std::string tool_name;
};

struct LlamaPromptTool {
    std::string name;
    std::string description;
    std::string parameters_json;
};

struct LlamaPromptInput {
    std::vector<LlamaPromptMessage> messages;
    std::vector<LlamaPromptTool> tools;
    std::string tool_schema_json;
    std::string template_source;
    std::string template_id;
};

LlamaPromptInput parse_llama_prompt_input(const std::string &prompt_json);
std::vector<LlamaPromptMessage> parse_llama_prompt_messages(const std::string &prompt_json);
std::vector<LlamaPromptMessage> llama_messages_for_rendering(const LlamaPromptInput &input);
std::string render_fallback_chat_prompt(const LlamaPromptInput &input);
std::string render_fallback_chat_prompt(const std::vector<LlamaPromptMessage> &messages);

} // namespace local_agent

#endif
