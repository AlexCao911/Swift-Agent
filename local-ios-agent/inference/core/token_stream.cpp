#include "token_stream.h"

#include "token_event.h"

namespace local_agent {

void TokenStream::cancel() {
    cancelled_.store(true);
}

bool TokenStream::is_cancelled() const {
    return cancelled_.load();
}

void TokenStream::emit_text_delta(const std::string &text, const Emit &emit) {
    if (!is_cancelled()) {
        emit(token_event_json("text_delta", text));
    }
}

void TokenStream::emit_completed(const std::string &text, const Emit &emit) {
    if (!is_cancelled()) {
        emit(token_event_json("completed", text));
    }
}

} // namespace local_agent
