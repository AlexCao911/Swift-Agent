#include "generation_request.h"

#include "json_value.h"

#include <sstream>
#include <stdexcept>

namespace local_agent {
namespace {

std::string json_escape(const std::string &value) {
    std::ostringstream out;
    for (char c : value) {
        switch (c) {
        case '"':
            out << "\\\"";
            break;
        case '\\':
            out << "\\\\";
            break;
        case '\n':
            out << "\\n";
            break;
        case '\r':
            out << "\\r";
            break;
        case '\t':
            out << "\\t";
            break;
        default:
            out << c;
            break;
        }
    }
    return out.str();
}

SamplingConfig parse_sampling(const json::Value &root) {
    SamplingConfig sampling;
    const auto *sampling_json = root.get("sampling");
    if (sampling_json == nullptr) {
        return sampling;
    }
    sampling.temperature = json::optional_float(*sampling_json, "temperature", sampling.temperature);
    sampling.top_p = json::optional_float(*sampling_json, "top_p", sampling.top_p);
    sampling.top_k = json::optional_int(*sampling_json, "top_k", sampling.top_k);
    sampling.min_p = json::optional_float(*sampling_json, "min_p", sampling.min_p);
    sampling.repeat_penalty = json::optional_float(*sampling_json, "repeat_penalty", sampling.repeat_penalty);
    sampling.seed = json::optional_int(*sampling_json, "seed", sampling.seed);
    sampling.max_new_tokens = json::optional_int(*sampling_json, "max_new_tokens", sampling.max_new_tokens);
    const auto *stops = sampling_json->get("stop_sequences");
    if (stops != nullptr) {
        for (const auto &stop : stops->as_array()) {
            sampling.stop_sequences.push_back(stop.as_string());
        }
    }
    return sampling;
}

} // namespace

GenerationRequest parse_generation_request(const char *generation_request_json) {
    json::Value root = json::parse(generation_request_json);
    if (!root.is_object()) {
        throw std::invalid_argument("generation request must be a json object");
    }

    GenerationRequest request;
    const auto *messages_json = root.get("messages");
    if (messages_json == nullptr || !messages_json->is_array()) {
        throw std::invalid_argument("generation request requires messages array");
    }
    for (const auto &message_json : messages_json->as_array()) {
        PromptMessage message;
        message.role = json::require_string(message_json, "role");
        message.content = json::require_string(message_json, "content");
        if (message.role.empty()) {
            throw std::invalid_argument("message role must not be empty");
        }
        request.messages.push_back(std::move(message));
    }
    if (request.messages.empty()) {
        throw std::invalid_argument("generation request messages must not be empty");
    }

    const auto *images_json = root.get("images");
    if (images_json != nullptr) {
        for (const auto &image_json : images_json->as_array()) {
            ImageMetadata image;
            image.format = json::require_string(image_json, "format");
            image.width = static_cast<uint32_t>(json::optional_int(image_json, "width", 0));
            image.height = static_cast<uint32_t>(json::optional_int(image_json, "height", 0));
            request.images.push_back(std::move(image));
        }
    }

    request.sampling = parse_sampling(root);
    if (request.sampling.max_new_tokens <= 0) {
        throw std::invalid_argument("max_new_tokens must be positive");
    }
    return request;
}

std::string prompt_json_from_generation_request(const GenerationRequest &request) {
    std::ostringstream out;
    out << "{\"messages\":[";
    for (size_t i = 0; i < request.messages.size(); ++i) {
        if (i > 0) {
            out << ",";
        }
        out << "{\"role\":\"" << json_escape(request.messages[i].role)
            << "\",\"content\":\"" << json_escape(request.messages[i].content) << "\"}";
    }
    out << "]}";
    return out.str();
}

} // namespace local_agent
