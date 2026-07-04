#ifndef LOCAL_AGENT_LITERT_ENGINE_H
#define LOCAL_AGENT_LITERT_ENGINE_H

#include "inference_engine.h"

namespace local_agent {

class LiteRTInferenceEngine final : public InferenceEngine {
public:
    EngineCapabilities capabilities() const override;
    std::unique_ptr<LoadedModel> load_model(const ModelLoadConfig &config) override;
};

} // namespace local_agent

#endif
