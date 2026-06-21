#ifndef LOCAL_AGENT_INFERENCE_ENGINE_H
#define LOCAL_AGENT_INFERENCE_ENGINE_H

#include "model_config.h"
#include "token_stream.h"

#include <cstdint>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace local_agent {

struct ImageInput {
    std::vector<unsigned char> rgb_data;
    uint32_t width = 0;
    uint32_t height = 0;
};

class InferenceEngine {
public:
    virtual ~InferenceEngine() = default;
    virtual void load(const ModelConfig &config) = 0;
    virtual std::unique_ptr<TokenStream> start_chat(const std::string &prompt_json) = 0;
    virtual std::unique_ptr<TokenStream> start_chat_with_image(
        const std::string &prompt_json,
        const ImageInput &
    ) {
        throw std::invalid_argument("image input is not supported by this backend");
    }
    virtual void read_stream(TokenStream &stream, const TokenStream::Emit &emit) = 0;
};

std::unique_ptr<InferenceEngine> make_inference_engine(const ModelConfig &config);

} // namespace local_agent

#endif
