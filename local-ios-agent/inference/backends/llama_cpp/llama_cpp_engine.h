#ifndef LOCAL_AGENT_LLAMA_CPP_ENGINE_H
#define LOCAL_AGENT_LLAMA_CPP_ENGINE_H

#include "inference_engine.h"
#include "llama_cpp_api.h"

namespace local_agent {

class LlamaCppEngine final : public InferenceEngine {
public:
    LlamaCppEngine();
    explicit LlamaCppEngine(std::unique_ptr<LlamaCppSession> session);

    EngineCapabilities capabilities() const override;
    std::unique_ptr<LoadedModel> load_model(const ModelLoadConfig &config) override;

private:
    std::unique_ptr<LlamaCppSession> session_;
};

} // namespace local_agent

#endif
