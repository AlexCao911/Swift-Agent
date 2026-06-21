#ifndef LOCAL_AGENT_LLAMA_CPP_PROMPT_H
#define LOCAL_AGENT_LLAMA_CPP_PROMPT_H

#include <string>
#include <vector>

namespace local_agent {

struct LlamaPromptMessage {
    std::string role;
    std::string content;
};

std::vector<LlamaPromptMessage> parse_llama_prompt_messages(const std::string &prompt_json);
std::string render_fallback_chat_prompt(const std::vector<LlamaPromptMessage> &messages);

} // namespace local_agent

#endif
