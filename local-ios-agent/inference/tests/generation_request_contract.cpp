#include "generation_request.h"

#include <cassert>
#include <exception>
#include <string>

int main() {
    auto request = local_agent::parse_generation_request(R"({
      "messages":[
        {"role":"system","content":"You are concise."},
        {"role":"user","content":"hello"}
      ],
      "images":[{"format":"rgb8","width":1,"height":1}],
      "sampling":{"temperature":0.1,"top_p":0.8,"max_new_tokens":16,"seed":7}
    })");

    assert(request.messages.size() == 2);
    assert(request.messages[1].role == "user");
    assert(request.messages[1].content == "hello");
    assert(request.images.size() == 1);
    assert(request.images[0].format == "rgb8");
    assert(request.sampling.temperature == 0.1f);
    assert(request.sampling.top_p == 0.8f);
    assert(request.sampling.max_new_tokens == 16);

    const std::string prompt_json = local_agent::prompt_json_from_generation_request(request);
    assert(prompt_json.find("\"messages\"") != std::string::npos);
    assert(prompt_json.find("\"role\":\"user\"") != std::string::npos);

    bool rejected_empty_messages = false;
    try {
        local_agent::parse_generation_request(R"({"messages":[]})");
    } catch (const std::exception &) {
        rejected_empty_messages = true;
    }
    assert(rejected_empty_messages);

    return 0;
}
