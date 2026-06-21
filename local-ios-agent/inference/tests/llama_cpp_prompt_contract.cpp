#include "llama_cpp_prompt.h"

#include <cassert>
#include <string>

int main() {
    const std::string prompt_json =
        R"({"model":"local","messages":[{"role":"system","content":"policy\nline"},{"role":"user","content":"say \"hi\""}],"stream":true})";

    auto messages = local_agent::parse_llama_prompt_messages(prompt_json);
    assert(messages.size() == 2);
    assert(messages[0].role == "system");
    assert(messages[0].content == "policy\nline");
    assert(messages[1].role == "user");
    assert(messages[1].content == "say \"hi\"");

    std::string prompt = local_agent::render_fallback_chat_prompt(messages);
    assert(prompt.find("<|im_start|>system\npolicy\nline<|im_end|>") != std::string::npos);
    assert(prompt.find("<|im_start|>user\nsay \"hi\"<|im_end|>") != std::string::npos);
    assert(prompt.find("<|im_start|>assistant\n") != std::string::npos);
    assert(prompt.find("\"messages\"") == std::string::npos);
    return 0;
}
