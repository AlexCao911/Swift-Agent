#include "generation_request.h"

#include "json_value.h"

#include <cmath>
#include <set>
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

void reject_unknown_keys(const json::Value &object, const std::set<std::string> &allowed) {
    for (const auto &entry : object.as_object()) {
        if (allowed.count(entry.first) == 0) {
            throw std::invalid_argument("unsupported generation request field: " + entry.first);
        }
    }
}

SamplingConfig parse_sampling(const json::Value &root) {
    SamplingConfig sampling;
    const auto *value = root.get("sampling");
    if (value == nullptr) return sampling;
    if (!value->is_object()) throw std::invalid_argument("sampling must be an object");
    reject_unknown_keys(*value, {
        "temperature", "top_p", "top_k", "min_p", "repeat_penalty",
        "seed", "max_new_tokens", "stop_sequences"
    });
    for (const auto &entry : value->as_object()) {
        sampling.provided_options.insert(entry.first);
    }
    sampling.temperature = json::optional_float(*value, "temperature", sampling.temperature);
    sampling.top_p = json::optional_float(*value, "top_p", sampling.top_p);
    sampling.top_k = json::optional_int(*value, "top_k", sampling.top_k);
    sampling.min_p = json::optional_float(*value, "min_p", sampling.min_p);
    sampling.repeat_penalty = json::optional_float(*value, "repeat_penalty", sampling.repeat_penalty);
    sampling.seed = json::optional_int(*value, "seed", sampling.seed);
    sampling.max_new_tokens = json::optional_int(*value, "max_new_tokens", sampling.max_new_tokens);
    const auto *stops = value->get("stop_sequences");
    if (stops != nullptr) {
        for (const auto &stop : stops->as_array()) sampling.stop_sequences.push_back(stop.as_string());
    }
    if (!std::isfinite(sampling.temperature) || sampling.temperature < 0.0f || sampling.temperature > 2.0f ||
        sampling.top_p <= 0.0f || sampling.top_p > 1.0f ||
        sampling.top_k < 0 || sampling.top_k > 10000 ||
        sampling.min_p < 0.0f || sampling.min_p > 1.0f ||
        sampling.repeat_penalty <= 0.0f || sampling.repeat_penalty > 2.0f ||
        sampling.max_new_tokens <= 0) {
        throw std::invalid_argument("sampling parameter is out of range");
    }
    return sampling;
}

} // namespace

GenerationRequest parse_generation_request(const char *generation_request_json) {
    json::Value root = json::parse(generation_request_json);
    if (!root.is_object()) throw std::invalid_argument("generation request must be an object");
    reject_unknown_keys(root, {
        "schema_version", "messages", "tool_schema", "template",
        "tool_call_codec_id", "images", "sampling"
    });
    GenerationRequest request;
    request.schema_version = json::require_string(root, "schema_version");
    if (request.schema_version != "2") throw std::invalid_argument("unsupported generation schema");
    const auto *messages = root.get("messages");
    if (messages == nullptr || !messages->is_array()) throw std::invalid_argument("messages required");
    const std::set<std::string> roles{"system", "user", "assistant", "tool"};
    for (const auto &message_value : messages->as_array()) {
        reject_unknown_keys(message_value, {
            "role", "content", "tool_calls", "tool_call_id", "name"
        });
        PromptMessage message;
        message.role = json::require_string(message_value, "role");
        if (roles.count(message.role) == 0) throw std::invalid_argument("unsupported message role");
        const auto *content = message_value.get("content");
        if (content == nullptr || !content->is_array() || content->as_array().empty()) {
            throw std::invalid_argument("message content parts required");
        }
        for (const auto &part_value : content->as_array()) {
            reject_unknown_keys(part_value, {"type", "text"});
            PromptContentPart part;
            part.type = json::require_string(part_value, "type");
            part.text = json::require_string(part_value, "text");
            if (part.type != "text") throw std::invalid_argument("unsupported content type");
            message.content.push_back(std::move(part));
        }
        if (const auto *tool_calls = message_value.get("tool_calls")) {
            if (message.role != "assistant" || !tool_calls->is_array() || tool_calls->as_array().empty()) {
                throw std::invalid_argument("tool_calls require an assistant message");
            }
            std::set<std::string> call_ids;
            for (const auto &call_value : tool_calls->as_array()) {
                reject_unknown_keys(call_value, {"id", "type", "function"});
                if (json::require_string(call_value, "type") != "function") {
                    throw std::invalid_argument("only function tool calls are supported");
                }
                const auto *function = call_value.get("function");
                if (function == nullptr || !function->is_object()) {
                    throw std::invalid_argument("tool call function is required");
                }
                reject_unknown_keys(*function, {"name", "arguments"});
                PromptToolCall call;
                call.id = json::require_string(call_value, "id");
                call.name = json::require_string(*function, "name");
                call.arguments_json = json::require_string(*function, "arguments");
                if (call.id.empty() || call.name.empty() || !call_ids.insert(call.id).second) {
                    throw std::invalid_argument("tool call identities must be unique and non-empty");
                }
                const auto arguments = json::parse(call.arguments_json.c_str());
                if (!arguments.is_object()) {
                    throw std::invalid_argument("tool call arguments must be a JSON object");
                }
                call.arguments_json = serialize_json(arguments);
                message.tool_calls.push_back(std::move(call));
            }
        }
        if (message.role == "tool") {
            message.tool_call_id = json::require_string(message_value, "tool_call_id");
            message.tool_name = json::require_string(message_value, "name");
            if (message.tool_call_id.empty() || message.tool_name.empty()) {
                throw std::invalid_argument("tool result identity is required");
            }
        } else if (message_value.get("tool_call_id") != nullptr || message_value.get("name") != nullptr) {
            throw std::invalid_argument("tool result fields require a tool message");
        }
        request.messages.push_back(std::move(message));
    }
    if (request.messages.empty()) throw std::invalid_argument("messages must not be empty");

    const auto *template_value = root.get("template");
    if (template_value == nullptr || !template_value->is_object()) throw std::invalid_argument("template required");
    reject_unknown_keys(*template_value, {"source", "id"});
    request.chat_template.source = json::require_string(*template_value, "source");
    request.chat_template.id = json::require_string(*template_value, "id");
    if ((request.chat_template.source != "gguf" && request.chat_template.source != "catalog_artifact") ||
        request.chat_template.id.empty()) throw std::invalid_argument("unsupported template selector");

    if (const auto *tools = root.get("tool_schema")) {
        if (!tools->is_object() || tools->get("tools") == nullptr || !tools->get("tools")->is_array()) {
            throw std::invalid_argument("tool_schema.tools must be an array");
        }
        reject_unknown_keys(*tools, {"tools"});
        for (const auto &tool : tools->get("tools")->as_array()) {
            if (!tool.is_object()) throw std::invalid_argument("tool schema entry must be an object");
            reject_unknown_keys(tool, {"name", "description", "input_schema"});
            if (json::require_string(tool, "name").empty()) {
                throw std::invalid_argument("tool schema name must not be empty");
            }
            const auto *input_schema = tool.get("input_schema");
            if (input_schema == nullptr || !input_schema->is_object()) {
                throw std::invalid_argument("tool input_schema must be an object");
            }
        }
        request.tool_schema = CanonicalToolSchema{serialize_json(*tools)};
    }
    if (const auto *codec = root.get("tool_call_codec_id")) {
        request.tool_call_codec_id = codec->as_string();
        if (request.tool_call_codec_id->empty()) throw std::invalid_argument("codec id must not be empty");
    }
    if (const auto *images = root.get("images")) {
        if (!images->is_array()) throw std::invalid_argument("images must be an array");
        for (const auto &image_value : images->as_array()) {
            reject_unknown_keys(image_value, {"format", "width", "height"});
            ImageMetadata image;
            image.format = json::require_string(image_value, "format");
            const int width = json::optional_int(image_value, "width", 0);
            const int height = json::optional_int(image_value, "height", 0);
            if (image.format != "rgb8" || width <= 0 || height <= 0) {
                throw std::invalid_argument("image metadata requires non-zero rgb8 dimensions");
            }
            image.width = static_cast<uint32_t>(width);
            image.height = static_cast<uint32_t>(height);
            request.images.push_back(std::move(image));
        }
    }
    if (request.tool_schema && !request.tool_call_codec_id) {
        throw std::invalid_argument("tool schema requires a tool-call codec");
    }
    request.sampling = parse_sampling(root);
    return request;
}

std::string prompt_message_text(const PromptMessage &message) {
    std::string result;
    for (const auto &part : message.content) {
        if (part.type == "text") result += part.text;
    }
    return result;
}

std::string prompt_json_from_generation_request(const GenerationRequest &request) {
    std::ostringstream out;
    out << "{\"messages\":[";
    for (size_t i = 0; i < request.messages.size(); ++i) {
        if (i > 0) out << ',';
        out << "{\"role\":\"" << json_escape(request.messages[i].role) << "\",\"content\":[";
        for (size_t j = 0; j < request.messages[i].content.size(); ++j) {
            if (j > 0) out << ',';
            out << "{\"type\":\"text\",\"text\":\""
                << json_escape(request.messages[i].content[j].text) << "\"}";
        }
        out << "]";
        if (!request.messages[i].tool_calls.empty()) {
            out << ",\"tool_calls\":[";
            for (size_t j = 0; j < request.messages[i].tool_calls.size(); ++j) {
                if (j > 0) out << ',';
                const auto &call = request.messages[i].tool_calls[j];
                out << "{\"id\":\"" << json_escape(call.id)
                    << "\",\"type\":\"function\",\"function\":{\"name\":\""
                    << json_escape(call.name) << "\",\"arguments\":\""
                    << json_escape(call.arguments_json) << "\"}}";
            }
            out << ']';
        }
        if (!request.messages[i].tool_call_id.empty()) {
            out << ",\"tool_call_id\":\"" << json_escape(request.messages[i].tool_call_id)
                << "\",\"name\":\"" << json_escape(request.messages[i].tool_name) << "\"";
        }
        out << "}";
    }
    out << ']';
    if (request.tool_schema) out << ",\"tool_schema\":" << request.tool_schema->json;
    out << ",\"template\":{\"source\":\"" << json_escape(request.chat_template.source)
        << "\",\"id\":\"" << json_escape(request.chat_template.id) << "\"}}";
    return out.str();
}

} // namespace local_agent
