#include "engine_registry.h"

#include "inference_engine.h"

#include <sstream>
#include <utility>

#ifdef LOCAL_AGENT_ENABLE_TEST_ENGINES
#include "mock_inference_engine.h"
#endif

#ifdef LOCAL_AGENT_ENABLE_LLAMA_CPP
#include "llama_cpp_engine.h"
#endif

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

std::string bool_json(bool value) {
    return value ? "true" : "false";
}

EngineDescriptor mock_descriptor() {
    EngineDescriptor descriptor;
    descriptor.engine_id = "mock";
    descriptor.display_name = "Mock Test Engine";
    descriptor.capabilities.supports_vision = false;
    descriptor.capabilities.supports_streaming = true;
    descriptor.capabilities.supports_cancellation = true;
    descriptor.capabilities.supports_token_usage = true;
    descriptor.capabilities.max_context_tokens = 2048;
    descriptor.capabilities.supported_model_formats = {"mock"};
    descriptor.test_only = true;
    return descriptor;
}

EngineDescriptor llama_cpp_descriptor() {
    EngineDescriptor descriptor;
    descriptor.engine_id = "llama_cpp";
    descriptor.display_name = "llama.cpp";
    descriptor.capabilities.supports_vision = true;
    descriptor.capabilities.supports_streaming = true;
    descriptor.capabilities.supports_cancellation = true;
    descriptor.capabilities.supports_token_usage = true;
    descriptor.capabilities.max_context_tokens = 0;
    descriptor.capabilities.supported_model_formats = {"gguf"};
    return descriptor;
}

void append_descriptor_json(std::ostringstream &out, const EngineDescriptor &descriptor) {
    out << "{"
        << "\"engine_id\":\"" << json_escape(descriptor.engine_id) << "\","
        << "\"display_name\":\"" << json_escape(descriptor.display_name) << "\","
        << "\"test_only\":" << bool_json(descriptor.test_only) << ","
        << "\"capabilities\":" << engine_capabilities_json(descriptor)
        << "}";
}

} // namespace

std::string engine_descriptor_list_json(const std::vector<EngineDescriptor> &descriptors) {
    std::ostringstream out;
    out << "[";
    for (size_t i = 0; i < descriptors.size(); ++i) {
        if (i > 0) {
            out << ",";
        }
        append_descriptor_json(out, descriptors[i]);
    }
    out << "]";
    return out.str();
}

std::string engine_capabilities_json(const EngineDescriptor &descriptor) {
    const auto &capabilities = descriptor.capabilities;
    std::ostringstream out;
    out << "{"
        << "\"supports_vision\":" << bool_json(capabilities.supports_vision) << ","
        << "\"supports_streaming\":" << bool_json(capabilities.supports_streaming) << ","
        << "\"supports_cancellation\":" << bool_json(capabilities.supports_cancellation) << ","
        << "\"supports_token_usage\":" << bool_json(capabilities.supports_token_usage) << ","
        << "\"max_context_tokens\":" << capabilities.max_context_tokens << ","
        << "\"supported_model_formats\":[";
    for (size_t i = 0; i < capabilities.supported_model_formats.size(); ++i) {
        if (i > 0) {
            out << ",";
        }
        out << "\"" << json_escape(capabilities.supported_model_formats[i]) << "\"";
    }
    out << "]}";
    return out.str();
}

EngineRegistry EngineRegistry::production() {
    std::vector<EngineDescriptor> descriptors;
#ifdef LOCAL_AGENT_ENABLE_LLAMA_CPP
    descriptors.push_back(llama_cpp_descriptor());
#endif
    return EngineRegistry(std::move(descriptors));
}

EngineRegistry EngineRegistry::test() {
    std::vector<EngineDescriptor> descriptors = EngineRegistry::production().list();
#ifdef LOCAL_AGENT_ENABLE_TEST_ENGINES
    descriptors.push_back(mock_descriptor());
#endif
    return EngineRegistry(std::move(descriptors));
}

EngineRegistry::EngineRegistry(std::vector<EngineDescriptor> descriptors)
    : descriptors_(std::move(descriptors)) {}

std::vector<EngineDescriptor> EngineRegistry::list() const {
    return descriptors_;
}

const EngineDescriptor *EngineRegistry::find(const std::string &engine_id) const {
    for (const auto &descriptor : descriptors_) {
        if (descriptor.engine_id == engine_id) {
            return &descriptor;
        }
    }
    return nullptr;
}

std::unique_ptr<InferenceEngine> EngineRegistry::create(const std::string &engine_id) const {
    if (find(engine_id) == nullptr) {
        return nullptr;
    }
#ifdef LOCAL_AGENT_ENABLE_TEST_ENGINES
    if (engine_id == "mock") {
        return std::make_unique<MockInferenceEngine>();
    }
#endif
#ifdef LOCAL_AGENT_ENABLE_LLAMA_CPP
    if (engine_id == "llama_cpp") {
        return std::make_unique<LlamaCppEngine>();
    }
#endif
    return nullptr;
}

} // namespace local_agent
