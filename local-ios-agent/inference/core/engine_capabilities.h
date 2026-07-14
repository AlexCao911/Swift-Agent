#ifndef LOCAL_AGENT_ENGINE_CAPABILITIES_H
#define LOCAL_AGENT_ENGINE_CAPABILITIES_H

#include <string>
#include <optional>
#include <vector>

namespace local_agent {

struct ParameterDescriptor {
    std::string backend_option;
    std::string value_type;
    std::optional<double> minimum;
    std::optional<double> maximum;
};

struct EngineCapabilities {
    bool supports_vision = false;
    bool supports_streaming = true;
    bool supports_cancellation = true;
    bool supports_token_usage = false;
    int max_context_tokens = 0;
    std::vector<std::string> supported_model_formats;
    std::vector<ParameterDescriptor> backend_parameters;
};

struct EngineDescriptor {
    std::string engine_id;
    std::string abi_version;
    std::string engine_version;
    std::string display_name;
    EngineCapabilities capabilities;
    bool test_only = false;
};

std::string engine_descriptor_list_json(const std::vector<EngineDescriptor> &descriptors);
std::string engine_capabilities_json(const EngineDescriptor &descriptor);
std::string engine_parameter_schema_json(const EngineDescriptor &descriptor);

} // namespace local_agent

#endif
