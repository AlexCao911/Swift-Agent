#ifndef LOCAL_AGENT_MOCK_INFERENCE_ENGINE_H
#define LOCAL_AGENT_MOCK_INFERENCE_ENGINE_H

#include "inference_engine.h"

namespace local_agent {

class MockInferenceEngine final : public InferenceEngine {
public:
    void load(const ModelConfig &config) override;
    std::unique_ptr<TokenStream> start_chat(const std::string &prompt_json) override;
    void read_stream(TokenStream &stream, const TokenStream::Emit &emit) override;

private:
    bool loaded_ = false;
};

} // namespace local_agent

#endif
