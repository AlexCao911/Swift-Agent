#ifndef LOCAL_AGENT_ENGINE_REGISTRY_H
#define LOCAL_AGENT_ENGINE_REGISTRY_H

#include "engine_capabilities.h"

#include <memory>

namespace local_agent {

class InferenceEngine;

class EngineRegistry {
public:
    static EngineRegistry production();
    static EngineRegistry test();

    std::vector<EngineDescriptor> list() const;
    const EngineDescriptor *find(const std::string &engine_id) const;
    std::unique_ptr<InferenceEngine> create(const std::string &engine_id) const;

private:
    explicit EngineRegistry(std::vector<EngineDescriptor> descriptors);

    std::vector<EngineDescriptor> descriptors_;
};

} // namespace local_agent

#endif
