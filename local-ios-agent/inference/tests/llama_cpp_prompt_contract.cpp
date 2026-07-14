#include "llama_cpp_prompt.h"

#include <cassert>
#include <string>

int main() {
    const std::string prompt_json =
        R"({"messages":[{"role":"system","content":[{"type":"text","text":"policy\n"},{"type":"text","text":"line"}]},{"role":"user","content":[{"type":"text","text":"say \"hi\""}]}],"tool_schema":{"tools":[{"name":"search","input_schema":{"type":"object"}}]},"template":{"source":"gguf","id":"gemma"}})";

    auto input = local_agent::parse_llama_prompt_input(prompt_json);
    assert(input.messages.size() == 2);
    assert(input.messages[0].role == "system");
    assert(input.messages[0].content == "policy\nline");
    assert(input.messages[1].role == "user");
    assert(input.messages[1].content == "say \"hi\"");
    assert(input.tool_schema_json.find("\"name\":\"search\"") != std::string::npos);
    assert(input.template_source == "gguf");
    assert(input.template_id == "gemma");

    std::string prompt = local_agent::render_fallback_chat_prompt(input);
    assert(prompt.find("<|im_start|>system\npolicy\nline<|im_end|>") != std::string::npos);
    assert(prompt.find("<|im_start|>user\nsay \"hi\"<|im_end|>") != std::string::npos);
    assert(prompt.find("<|im_start|>assistant\n") != std::string::npos);
    assert(prompt.find("Available tools (canonical JSON)") != std::string::npos);
    assert(prompt.find("\"name\":\"search\"") != std::string::npos);
    assert(prompt.find("\"messages\"") == std::string::npos);
    assert(prompt.find("tool_call_codec") == std::string::npos);
    return 0;
}
