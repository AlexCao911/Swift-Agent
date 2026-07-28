#ifndef LOCAL_AGENT_TOKEN_STREAM_H
#define LOCAL_AGENT_TOKEN_STREAM_H

#include <atomic>
#include <functional>
#include <string>
#include <vector>

namespace local_agent {

struct UsageReport {
    int prompt_tokens = 0;
    int completion_tokens = 0;
    int total_tokens = 0;
    bool available = false;
};

struct NativeToolCallResult {
    std::string id;
    std::string name;
    std::string arguments_json;
};

class TokenStream {
public:
    using Emit = std::function<bool(const std::string &)>;

    void cancel();
    bool is_cancelled() const;
    bool emit_text_delta(const std::string &text, const Emit &emit);
    bool emit_structured_delta(const std::string &text, const Emit &emit);
    bool emit_usage(const UsageReport &usage, const Emit &emit);
    bool emit_native_tool_result(
        const std::string &visible_text,
        const std::vector<NativeToolCallResult> &calls,
        const Emit &emit
    );
    bool emit_completed(const std::string &text, const Emit &emit);

private:
    std::atomic<bool> cancelled_{false};
};

} // namespace local_agent

#endif
