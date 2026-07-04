#include "json_value.h"

#include <cassert>
#include <stdexcept>

int main() {
    auto value = local_agent::json::parse(R"({
      "messages":[{"role":"user","content":"hello \"Alex\"\nnext"}],
      "sampling":{"temperature":0.2,"max_new_tokens":32},
      "enabled":true
    })");

    assert(value.is_object());
    const auto *messages = value.get("messages");
    assert(messages != nullptr);
    assert(messages->is_array());
    const auto &first = messages->as_array().at(0);
    assert(local_agent::json::require_string(first, "role") == "user");
    assert(local_agent::json::require_string(first, "content") == "hello \"Alex\"\nnext");

    const auto *sampling = value.get("sampling");
    assert(sampling != nullptr);
    assert(local_agent::json::optional_float(*sampling, "temperature", 1.0f) == 0.2f);
    assert(local_agent::json::optional_int(*sampling, "max_new_tokens", 0) == 32);

    bool rejected_bad_json = false;
    try {
        local_agent::json::parse(R"({"messages":[})");
    } catch (const std::invalid_argument &) {
        rejected_bad_json = true;
    }
    assert(rejected_bad_json);

    bool rejected_trailing = false;
    try {
        local_agent::json::parse(R"({"ok":true} false)");
    } catch (const std::invalid_argument &) {
        rejected_trailing = true;
    }
    assert(rejected_trailing);

    return 0;
}
