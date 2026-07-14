#include "generation_request.h"

#include <cassert>
#include <exception>
#include <string>

namespace {

template <typename Function>
void assert_rejected(Function operation) {
    bool rejected = false;
    try {
        operation();
    } catch (const std::exception &) {
        rejected = true;
    }
    assert(rejected);
}

} // namespace

int main() {
    auto request = local_agent::parse_generation_request(R"({
      "schema_version":"2",
      "messages":[
        {"role":"system","content":[{"type":"text","text":"Be concise"}]},
        {"role":"user","content":[{"type":"text","text":"hello"}]}
      ],
      "tool_schema":{"tools":[{"name":"search","input_schema":{"type":"object"}}]},
      "template":{"source":"gguf","id":"catalog-approved"},
      "tool_call_codec_id":"json_tool_calls_v1",
      "images":[{"format":"rgb8","width":1,"height":1}],
      "sampling":{"temperature":0.2,"top_p":0.9,"top_k":40,"min_p":0.05,
                  "repeat_penalty":1.1,"max_new_tokens":128,"seed":42,
                  "stop_sequences":["</tool>"]}
    })");

    assert(request.schema_version == "2");
    assert(request.messages.size() == 2);
    assert(request.messages[1].role == "user");
    assert(request.messages[1].content.size() == 1);
    assert(request.messages[1].content[0].type == "text");
    assert(request.messages[1].content[0].text == "hello");
    assert(request.tool_schema.has_value());
    assert(request.chat_template.source == "gguf");
    assert(request.chat_template.id == "catalog-approved");
    assert(request.tool_call_codec_id.has_value());
    assert(request.sampling.top_k == 40);
    assert(request.sampling.stop_sequences == std::vector<std::string>{"</tool>"});

    const std::string prompt_json = local_agent::prompt_json_from_generation_request(request);
    assert(prompt_json.find("\"content\":[{\"type\":\"text\"") != std::string::npos);
    assert(prompt_json.find("\"tool_schema\"") != std::string::npos);
    assert(prompt_json.find("\"template\":{\"source\":\"gguf\"") != std::string::npos);
    assert(prompt_json.find("tool_call_codec_id") == std::string::npos);

    assert_rejected([] {
        local_agent::parse_generation_request(R"({"schema_version":"1","messages":[]})");
    });
    assert_rejected([] {
        local_agent::parse_generation_request(R"({"schema_version":"2","messages":[{"role":"assistantish","content":[{"type":"text","text":"x"}]}],"template":{"source":"gguf","id":"catalog-approved"}})");
    });
    assert_rejected([] {
        local_agent::parse_generation_request(R"({"schema_version":"2","messages":[{"role":"user","content":[{"type":"binary","text":"x"}]}],"template":{"source":"gguf","id":"catalog-approved"}})");
    });
    assert_rejected([] {
        local_agent::parse_generation_request(R"({"schema_version":"2","messages":[{"role":"user","content":[{"type":"text","text":"x"}]}],"template":{"source":"remote","id":"unapproved"}})");
    });
    assert_rejected([] {
        local_agent::parse_generation_request(R"({"schema_version":"2","messages":[{"role":"user","content":[{"type":"text","text":"x"}]}],"template":{"source":"gguf","id":"catalog-approved"},"sampling":{"temperature":3.0}})");
    });
    assert_rejected([] {
        local_agent::parse_generation_request(R"({"schema_version":"2","messages":[{"role":"user","content":[{"type":"text","text":"x"}]}],"template":{"source":"gguf","id":"catalog-approved"},"sampling":{"unknown":1}})");
    });

    return 0;
}
