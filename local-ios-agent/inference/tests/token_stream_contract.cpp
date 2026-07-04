#include "token_stream.h"

#include <cassert>
#include <string>
#include <vector>

int main() {
    local_agent::TokenStream stream;
    std::vector<std::string> tokens;
    stream.emit_text_delta("hello", [&](const std::string &json) {
        tokens.push_back(json);
        return true;
    });
    stream.emit_completed("hello", [&](const std::string &json) {
        tokens.push_back(json);
        return true;
    });
    stream.emit_usage({1, 2, 3, true}, [&](const std::string &json) {
        tokens.push_back(json);
        return true;
    });
    assert(tokens.size() == 3);
    assert(tokens[0] == R"({"type":"text_delta","text":"hello"})");
    assert(tokens[1] == R"({"type":"completed","text":"hello"})");
    assert(tokens[2] == R"({"type":"usage","prompt_tokens":1,"completion_tokens":2,"total_tokens":3})");

    stream.cancel();
    assert(stream.is_cancelled());
    return 0;
}
