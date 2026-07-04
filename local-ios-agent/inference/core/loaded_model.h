#ifndef LOCAL_AGENT_LOADED_MODEL_H
#define LOCAL_AGENT_LOADED_MODEL_H

#include "generation_request.h"
#include "generation_session.h"

#include <memory>

namespace local_agent {

class LoadedModel {
public:
    virtual ~LoadedModel() = default;
    virtual ModelRuntimeInfo runtime_info() const = 0;
    virtual std::unique_ptr<GenerationSession> start_generation(
        const GenerationRequest &request,
        const std::vector<ImageInput> &images
    ) = 0;
};

} // namespace local_agent

#endif
