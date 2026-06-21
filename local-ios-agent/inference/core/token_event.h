#ifndef LOCAL_AGENT_TOKEN_EVENT_H
#define LOCAL_AGENT_TOKEN_EVENT_H

#include <string>

namespace local_agent {

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

} // namespace local_agent

#endif
