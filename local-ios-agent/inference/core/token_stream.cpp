#include "token_stream.h"

#include "token_event.h"

namespace local_agent {

void TokenStream::cancel() {
    cancelled_.store(true);
}

bool TokenStream::is_cancelled() const {
    return cancelled_.load();
}

bool TokenStream::emit_text_delta(const std::string &text, const Emit &emit) {
    if (is_cancelled()) {
        return false;
    }
    return emit(token_event_json("text_delta", text));
}

bool TokenStream::emit_structured_delta(const std::string &text, const Emit &emit) {
    if (is_cancelled()) {
        return false;
    }
    return emit(token_event_json("structured_delta", text));
}

bool TokenStream::emit_usage(const UsageReport &usage, const Emit &emit) {
    if (is_cancelled() || !usage.available) {
        return false;
    }
    return emit(token_usage_event_json(usage));
}

bool TokenStream::emit_native_tool_result(
    const std::string &visible_text,
    const std::vector<NativeToolCallResult> &calls,
    const Emit &emit
) {
    if (is_cancelled()) {
        return false;
    }
    std::string json = "{\"type\":\"native_tool_result\",\"text\":\"" +
        escape_json_text(visible_text) + "\",\"tool_calls\":[";
    for (size_t index = 0; index < calls.size(); ++index) {
        if (index > 0) {
            json += ",";
        }
        const auto &call = calls[index];
        json += "{\"id\":\"" + escape_json_text(call.id) +
            "\",\"name\":\"" + escape_json_text(call.name) +
            "\",\"arguments_json\":\"" + escape_json_text(call.arguments_json) + "\"}";
    }
    json += "]}";
    return emit(json);
}

bool TokenStream::emit_completed(const std::string &text, const Emit &emit) {
    if (is_cancelled()) {
        return false;
    }
    return emit(token_event_json("completed", text));
}

} // namespace local_agent
