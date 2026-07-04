#ifndef LOCAL_AGENT_ENGINE_CAPABILITIES_H
#define LOCAL_AGENT_ENGINE_CAPABILITIES_H

#include <string>
#include <vector>

namespace local_agent {

struct EngineCapabilities {
    bool supports_vision = false;
    bool supports_streaming = true;
    bool supports_cancellation = true;
    bool supports_token_usage = false;
    int max_context_tokens = 0;
    std::vector<std::string> supported_model_formats;
};

struct EngineDescriptor {
    std::string engine_id;
    std::string display_name;
    EngineCapabilities capabilities;
    bool test_only = false;
};

std::string engine_descriptor_list_json(const std::vector<EngineDescriptor> &descriptors);
std::string engine_capabilities_json(const EngineDescriptor &descriptor);

} // namespace local_agent

#endif
