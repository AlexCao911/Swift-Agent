#include "llama_cpp_prompt.h"

#include <stdexcept>

namespace local_agent {
namespace {

void skip_ws(const std::string &json, std::size_t &pos) {
    while (pos < json.size()) {
        char c = json[pos];
        if (c != ' ' && c != '\n' && c != '\r' && c != '\t') {
            break;
        }
        pos += 1;
    }
}

std::string parse_json_string_at(const std::string &json, std::size_t &pos) {
    if (pos >= json.size() || json[pos] != '"') {
        throw std::invalid_argument("expected JSON string");
    }
    pos += 1;
    std::string value;
    while (pos < json.size()) {
        char c = json[pos++];
        if (c == '"') {
            return value;
        }
        if (c != '\\') {
            value.push_back(c);
            continue;
        }
        if (pos >= json.size()) {
            throw std::invalid_argument("unterminated JSON string escape");
        }
        char escaped = json[pos++];
        switch (escaped) {
        case '"':
        case '\\':
        case '/':
            value.push_back(escaped);
            break;
        case 'b':
            value.push_back('\b');
            break;
        case 'f':
            value.push_back('\f');
            break;
        case 'n':
            value.push_back('\n');
            break;
        case 'r':
            value.push_back('\r');
            break;
        case 't':
            value.push_back('\t');
            break;
        default:
            throw std::invalid_argument("unsupported JSON string escape");
        }
    }
    throw std::invalid_argument("unterminated JSON string");
}

std::size_t find_matching(
    const std::string &json,
    std::size_t start,
    char open_char,
    char close_char
) {
    int depth = 0;
    bool in_string = false;
    bool escaped = false;
    for (std::size_t pos = start; pos < json.size(); pos += 1) {
        char c = json[pos];
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }

        if (c == '"') {
            in_string = true;
        } else if (c == open_char) {
            depth += 1;
        } else if (c == close_char) {
            depth -= 1;
            if (depth == 0) {
                return pos;
            }
        }
    }
    throw std::invalid_argument("unterminated JSON container");
}

std::string extract_string_field(const std::string &object_json, const std::string &key) {
    const std::string needle = "\"" + key + "\"";
    std::size_t pos = object_json.find(needle);
    if (pos == std::string::npos) {
        return "";
    }
    pos = object_json.find(':', pos + needle.size());
    if (pos == std::string::npos) {
        return "";
    }
    pos += 1;
    skip_ws(object_json, pos);
    return parse_json_string_at(object_json, pos);
}

} // namespace

std::vector<LlamaPromptMessage> parse_llama_prompt_messages(const std::string &prompt_json) {
    const std::string messages_key = "\"messages\"";
    std::size_t messages_pos = prompt_json.find(messages_key);
    if (messages_pos == std::string::npos) {
        throw std::invalid_argument("prompt JSON must contain messages");
    }

    std::size_t array_start = prompt_json.find('[', messages_pos + messages_key.size());
    if (array_start == std::string::npos) {
        throw std::invalid_argument("prompt JSON messages must be an array");
    }
    std::size_t array_end = find_matching(prompt_json, array_start, '[', ']');

    std::vector<LlamaPromptMessage> messages;
    std::size_t pos = array_start + 1;
    while (pos < array_end) {
        skip_ws(prompt_json, pos);
        if (pos >= array_end) {
            break;
        }
        if (prompt_json[pos] == ',') {
            pos += 1;
            continue;
        }
        if (prompt_json[pos] != '{') {
            throw std::invalid_argument("prompt JSON message must be an object");
        }

        std::size_t object_end = find_matching(prompt_json, pos, '{', '}');
        std::string object_json = prompt_json.substr(pos, object_end - pos + 1);
        std::string role = extract_string_field(object_json, "role");
        std::string content = extract_string_field(object_json, "content");
        if (role.empty()) {
            throw std::invalid_argument("prompt JSON message missing role");
        }
        messages.push_back(LlamaPromptMessage{role, content});
        pos = object_end + 1;
    }

    if (messages.empty()) {
        throw std::invalid_argument("prompt JSON messages must not be empty");
    }
    return messages;
}

std::string render_fallback_chat_prompt(const std::vector<LlamaPromptMessage> &messages) {
    std::string prompt;
    for (const auto &message : messages) {
        prompt += "<|im_start|>";
        prompt += message.role;
        prompt += "\n";
        prompt += message.content;
        prompt += "<|im_end|>\n";
    }
    prompt += "<|im_start|>assistant\n";
    return prompt;
}

} // namespace local_agent
