#ifndef LOCAL_AGENT_MOCK_INFERENCE_ENGINE_H
#define LOCAL_AGENT_MOCK_INFERENCE_ENGINE_H

#include "inference_engine.h"

namespace local_agent {

class MockInferenceEngine final : public InferenceEngine {
public:
    EngineCapabilities capabilities() const override;
    std::unique_ptr<LoadedModel> load_model(const ModelLoadConfig &config) override;
};

} // namespace local_agent

#endif
