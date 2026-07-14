#include "llama_cpp_prompt.h"

#include "json_value.h"

#include <sstream>
#include <stdexcept>

namespace local_agent {
namespace {

std::string json_escape(const std::string &value) {
    std::ostringstream out;
    for (char c : value) {
        switch (c) {
        case '"': out << "\\\""; break;
        case '\\': out << "\\\\"; break;
        case '\n': out << "\\n"; break;
        case '\r': out << "\\r"; break;
        case '\t': out << "\\t"; break;
        default: out << c; break;
        }
    }
    return out.str();
}

std::string serialize_json(const json::Value &value) {
    std::ostringstream out;
    switch (value.type()) {
    case json::Value::Type::null_value: out << "null"; break;
    case json::Value::Type::bool_value: out << (value.as_bool() ? "true" : "false"); break;
    case json::Value::Type::number_value: out << value.as_number(); break;
    case json::Value::Type::string_value: out << '"' << json_escape(value.as_string()) << '"'; break;
    case json::Value::Type::array_value: {
        out << '[';
        bool first = true;
        for (const auto &item : value.as_array()) {
            if (!first) out << ',';
            first = false;
            out << serialize_json(item);
        }
        out << ']';
        break;
    }
    case json::Value::Type::object_value: {
        out << '{';
        bool first = true;
        for (const auto &entry : value.as_object()) {
            if (!first) out << ',';
            first = false;
            out << '"' << json_escape(entry.first) << "\":" << serialize_json(entry.second);
        }
        out << '}';
        break;
    }
    }
    return out.str();
}

} // namespace

LlamaPromptInput parse_llama_prompt_input(const std::string &prompt_json) {
    const json::Value root = json::parse(prompt_json.c_str());
    if (!root.is_object()) {
        throw std::invalid_argument("prompt JSON must be an object");
    }
    const json::Value *messages = root.get("messages");
    if (messages == nullptr || !messages->is_array() || messages->as_array().empty()) {
        throw std::invalid_argument("prompt JSON messages must be a non-empty array");
    }

    LlamaPromptInput input;
    for (const auto &message_value : messages->as_array()) {
        if (!message_value.is_object()) {
            throw std::invalid_argument("prompt JSON message must be an object");
        }
        LlamaPromptMessage message;
        message.role = json::require_string(message_value, "role");
        const json::Value *content = message_value.get("content");
        if (content == nullptr || !content->is_array()) {
            throw std::invalid_argument("prompt JSON message content must be an array");
        }
        for (const auto &part : content->as_array()) {
            if (!part.is_object() || json::require_string(part, "type") != "text") {
                throw std::invalid_argument("llama.cpp prompt only accepts text content parts");
            }
            message.content += json::require_string(part, "text");
        }
        input.messages.push_back(std::move(message));
    }

    if (const json::Value *tools = root.get("tool_schema")) {
        input.tool_schema_json = serialize_json(*tools);
    }
    const json::Value *chat_template = root.get("template");
    if (chat_template == nullptr || !chat_template->is_object()) {
        throw std::invalid_argument("prompt JSON template selector is required");
    }
    input.template_source = json::require_string(*chat_template, "source");
    input.template_id = json::require_string(*chat_template, "id");
    return input;
}

std::vector<LlamaPromptMessage> parse_llama_prompt_messages(const std::string &prompt_json) {
    return parse_llama_prompt_input(prompt_json).messages;
}

std::vector<LlamaPromptMessage> llama_messages_for_rendering(const LlamaPromptInput &input) {
    std::vector<LlamaPromptMessage> messages = input.messages;
    if (!input.tool_schema_json.empty()) {
        messages.insert(messages.begin(), LlamaPromptMessage{
            "system",
            "Available tools (canonical JSON): " + input.tool_schema_json,
        });
    }
    return messages;
}

std::string render_fallback_chat_prompt(const LlamaPromptInput &input) {
    return render_fallback_chat_prompt(llama_messages_for_rendering(input));
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
