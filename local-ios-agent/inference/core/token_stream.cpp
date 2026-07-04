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

bool TokenStream::emit_usage(const UsageReport &usage, const Emit &emit) {
    if (is_cancelled() || !usage.available) {
        return false;
    }
    return emit(token_usage_event_json(usage));
}

bool TokenStream::emit_completed(const std::string &text, const Emit &emit) {
    if (is_cancelled()) {
        return false;
    }
    return emit(token_event_json("completed", text));
}

} // namespace local_agent
