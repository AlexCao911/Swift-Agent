#ifndef LOCAL_AGENT_LITERT_ENGINE_H
#define LOCAL_AGENT_LITERT_ENGINE_H

#include "inference_engine.h"

#include <memory>

namespace local_agent {

class LiteRTSession;

class LiteRTInferenceEngine final : public InferenceEngine {
public:
    LiteRTInferenceEngine();
    explicit LiteRTInferenceEngine(std::unique_ptr<LiteRTSession> session);

    EngineCapabilities capabilities() const override;
    std::unique_ptr<LoadedModel> load_model(const ModelLoadConfig &config) override;

private:
    std::unique_ptr<LiteRTSession> session_;
};

} // namespace local_agent

#endif
