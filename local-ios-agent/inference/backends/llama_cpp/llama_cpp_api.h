#ifndef LOCAL_AGENT_LLAMA_CPP_API_H
#define LOCAL_AGENT_LLAMA_CPP_API_H

#include "model_config.h"

#include <functional>
#include <memory>
#include <string>

namespace local_agent {

struct ImageInput;

using LlamaTokenEmit = std::function<bool(const std::string &)>;

class LlamaCppSession {
public:
    virtual ~LlamaCppSession() = default;
    virtual void load(const ModelConfig &config) = 0;
    virtual void stream_generate(
        const std::string &prompt_json,
        const ModelConfig &config,
        const LlamaTokenEmit &emit
    ) = 0;
    virtual void stream_generate_with_image(
        const std::string &prompt_json,
        const ImageInput &image,
        const ModelConfig &config,
        const LlamaTokenEmit &emit
    ) = 0;
};

std::unique_ptr<LlamaCppSession> make_llama_cpp_session();

} // namespace local_agent

#endif
