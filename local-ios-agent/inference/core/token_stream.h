#ifndef LOCAL_AGENT_TOKEN_STREAM_H
#define LOCAL_AGENT_TOKEN_STREAM_H

#include <atomic>
#include <functional>
#include <string>

namespace local_agent {

class TokenStream {
public:
    using Emit = std::function<void(const std::string &)>;

    void cancel();
    bool is_cancelled() const;
    void emit_text_delta(const std::string &text, const Emit &emit);
    void emit_completed(const std::string &text, const Emit &emit);

private:
    std::atomic<bool> cancelled_{false};
};

} // namespace local_agent

#endif
