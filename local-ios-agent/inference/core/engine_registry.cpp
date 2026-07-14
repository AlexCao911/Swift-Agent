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

#if defined(LOCAL_AGENT_ENABLE_LITERT) && defined(LOCAL_AGENT_ENABLE_LITERT_VENDOR)
#include "litert_engine.h"
#define LOCAL_AGENT_HAS_LITERT 1
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

ParameterDescriptor parameter(
    std::string name,
    std::string type,
    std::optional<double> minimum = std::nullopt,
    std::optional<double> maximum = std::nullopt
) {
    return ParameterDescriptor{
        std::move(name),
        std::move(type),
        minimum,
        maximum,
    };
}

std::vector<ParameterDescriptor> common_sampling_parameters(bool stop_sequences) {
    std::vector<ParameterDescriptor> parameters{
        parameter("temperature", "number", 0.0, 2.0),
        parameter("top_p", "number", 0.0, 1.0),
        parameter("top_k", "integer", 0.0, 10000.0),
        parameter("min_p", "number", 0.0, 1.0),
        parameter("repeat_penalty", "number", 0.0, 2.0),
        parameter("max_new_tokens", "integer", 1.0),
        parameter("seed", "integer"),
    };
    if (stop_sequences) {
        parameters.push_back(parameter("stop_sequences", "string_array"));
    }
    return parameters;
}

EngineDescriptor mock_descriptor() {
    EngineDescriptor descriptor;
    descriptor.engine_id = "mock";
    descriptor.abi_version = "2";
    descriptor.engine_version = "mock-v2";
    descriptor.display_name = "Mock Test Engine";
    descriptor.capabilities.supports_vision = true;
    descriptor.capabilities.supports_streaming = true;
    descriptor.capabilities.supports_cancellation = true;
    descriptor.capabilities.supports_token_usage = true;
    descriptor.capabilities.max_context_tokens = 2048;
    descriptor.capabilities.supported_model_formats = {"mock"};
    descriptor.capabilities.backend_parameters = common_sampling_parameters(false);
    descriptor.test_only = true;
    return descriptor;
}

EngineDescriptor llama_cpp_descriptor() {
    EngineDescriptor descriptor;
    descriptor.engine_id = "llama_cpp";
    descriptor.abi_version = "2";
#ifdef LOCAL_AGENT_ENABLE_LLAMA_CPP
#ifndef LOCAL_AGENT_LLAMA_CPP_VERSION
#error "LOCAL_AGENT_LLAMA_CPP_VERSION is required when llama.cpp is enabled"
#endif
    descriptor.engine_version = LOCAL_AGENT_LLAMA_CPP_VERSION;
#else
    descriptor.engine_version = "unavailable";
#endif
    descriptor.display_name = "llama.cpp";
#ifdef LOCAL_AGENT_ENABLE_LLAMA_CPP_MTMD
    descriptor.capabilities.supports_vision = true;
#else
    descriptor.capabilities.supports_vision = false;
#endif
    descriptor.capabilities.supports_streaming = true;
    descriptor.capabilities.supports_cancellation = true;
    descriptor.capabilities.supports_token_usage = false;
    descriptor.capabilities.max_context_tokens = 0;
    descriptor.capabilities.supported_model_formats = {"gguf"};
    descriptor.capabilities.backend_parameters = common_sampling_parameters(false);
    return descriptor;
}

EngineDescriptor litert_descriptor() {
    EngineDescriptor descriptor;
    descriptor.engine_id = "litert";
    descriptor.abi_version = "2";
#ifdef LOCAL_AGENT_HAS_LITERT
#ifndef LOCAL_AGENT_LITERT_VERSION
#error "LOCAL_AGENT_LITERT_VERSION is required when LiteRT is enabled"
#endif
    descriptor.engine_version = LOCAL_AGENT_LITERT_VERSION;
#else
    descriptor.engine_version = "unavailable";
#endif
    descriptor.display_name = "LiteRT";
    descriptor.capabilities.supports_vision = false;
    descriptor.capabilities.supports_streaming = true;
    descriptor.capabilities.supports_cancellation = true;
    descriptor.capabilities.supports_token_usage = false;
    descriptor.capabilities.supported_model_formats = {"litert_lm", "litertlm", "task", "tflite"};
    descriptor.capabilities.backend_parameters = {
        parameter("temperature", "number", 0.0, 2.0),
        parameter("top_p", "number", 0.0, 1.0),
        parameter("top_k", "integer", 0.0, 10000.0),
        parameter("max_new_tokens", "integer", 1.0),
        parameter("seed", "integer"),
    };
    return descriptor;
}

void append_descriptor_json(std::ostringstream &out, const EngineDescriptor &descriptor) {
    out << "{"
        << "\"engine_id\":\"" << json_escape(descriptor.engine_id) << "\","
        << "\"abi_version\":\"" << json_escape(descriptor.abi_version) << "\","
        << "\"engine_version\":\"" << json_escape(descriptor.engine_version) << "\","
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
        << "\"max_context_tokens\":";
    if (capabilities.max_context_tokens > 0) {
        out << capabilities.max_context_tokens;
    } else {
        out << "null";
    }
    out << ","
        << "\"supported_model_formats\":[";
    for (size_t i = 0; i < capabilities.supported_model_formats.size(); ++i) {
        if (i > 0) {
            out << ",";
        }
        out << "\"" << json_escape(capabilities.supported_model_formats[i]) << "\"";
    }
    out << "],\"backend_parameters\":[";
    for (size_t i = 0; i < capabilities.backend_parameters.size(); ++i) {
        if (i > 0) out << ',';
        const auto &parameter = capabilities.backend_parameters[i];
        out << "{\"backend_option\":\"" << json_escape(parameter.backend_option)
            << "\",\"value_type\":\"" << json_escape(parameter.value_type) << "\","
            << "\"minimum\":";
        if (parameter.minimum) out << *parameter.minimum; else out << "null";
        out << ",\"maximum\":";
        if (parameter.maximum) out << *parameter.maximum; else out << "null";
        out << '}';
    }
    out << "]}";
    return out.str();
}

std::string engine_parameter_schema_json(const EngineDescriptor &descriptor) {
    const std::string capabilities = engine_capabilities_json(descriptor);
    const std::string marker = "\"backend_parameters\":";
    const size_t start = capabilities.find(marker);
    if (start == std::string::npos) {
        return "{\"backend_parameters\":[]}";
    }
    return "{" + capabilities.substr(start);
}

EngineRegistry EngineRegistry::production() {
    std::vector<EngineDescriptor> descriptors;
#ifdef LOCAL_AGENT_ENABLE_LLAMA_CPP
    descriptors.push_back(llama_cpp_descriptor());
#endif
#ifdef LOCAL_AGENT_HAS_LITERT
    descriptors.push_back(litert_descriptor());
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
#ifdef LOCAL_AGENT_HAS_LITERT
    if (engine_id == "litert") {
        return std::make_unique<LiteRTInferenceEngine>();
    }
#endif
    return nullptr;
}

} // namespace local_agent
