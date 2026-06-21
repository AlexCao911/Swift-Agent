#ifndef LOCAL_AGENT_LLAMA_CPP_ENGINE_H
#define LOCAL_AGENT_LLAMA_CPP_ENGINE_H

#include "inference_engine.h"
#include "llama_cpp_api.h"

namespace local_agent {

class LlamaCppEngine final : public InferenceEngine {
public:
    LlamaCppEngine();
    explicit LlamaCppEngine(std::unique_ptr<LlamaCppSession> session);

    void load(const ModelConfig &config) override;
    std::unique_ptr<TokenStream> start_chat(const std::string &prompt_json) override;
    std::unique_ptr<TokenStream> start_chat_with_image(
        const std::string &prompt_json,
        const ImageInput &image
    ) override;
    void read_stream(TokenStream &stream, const TokenStream::Emit &emit) override;

private:
    ModelConfig config_;
    std::string prompt_json_;
    ImageInput image_;
    bool has_image_ = false;
    std::unique_ptr<LlamaCppSession> session_;
};

} // namespace local_agent

#endif
