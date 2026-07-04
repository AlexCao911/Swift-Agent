#ifndef LOCAL_AGENT_INFERENCE_ENGINE_H
#define LOCAL_AGENT_INFERENCE_ENGINE_H

#include "engine_capabilities.h"
#include "loaded_model.h"
#include "model_config.h"

#include <memory>

namespace local_agent {

class InferenceEngine {
public:
    virtual ~InferenceEngine() = default;
    virtual EngineCapabilities capabilities() const = 0;
    virtual std::unique_ptr<LoadedModel> load_model(const ModelLoadConfig &config) = 0;
};

std::unique_ptr<InferenceEngine> make_inference_engine(const ModelConfig &config);

} // namespace local_agent

#endif
