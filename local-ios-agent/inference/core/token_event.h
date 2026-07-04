#ifndef LOCAL_AGENT_TOKEN_EVENT_H
#define LOCAL_AGENT_TOKEN_EVENT_H

#include <string>

namespace local_agent {

struct UsageReport;

inline std::string escape_json_text(const std::string &text) {
    std::string escaped;
    for (char c : text) {
        if (c == '\\') {
            escaped += "\\\\";
        } else if (c == '"') {
            escaped += "\\\"";
        } else if (c == '\n') {
            escaped += "\\n";
        } else {
            escaped += c;
        }
    }
    return escaped;
}

inline std::string token_event_json(const std::string &type, const std::string &text) {
    return "{\"type\":\"" + type + "\",\"text\":\"" + escape_json_text(text) + "\"}";
}

inline std::string token_usage_event_json(const UsageReport &usage) {
    return "{\"type\":\"usage\",\"prompt_tokens\":" + std::to_string(usage.prompt_tokens) +
        ",\"completion_tokens\":" + std::to_string(usage.completion_tokens) +
        ",\"total_tokens\":" + std::to_string(usage.total_tokens) + "}";
}

} // namespace local_agent

#endif
