#ifndef LOCAL_AGENT_GENERATION_SESSION_H
#define LOCAL_AGENT_GENERATION_SESSION_H

#include "token_stream.h"

#include <cstdint>
#include <string>
#include <vector>

namespace local_agent {

struct ModelRuntimeInfo {
    std::string engine_id;
    std::string model_id;
    int context_tokens = 0;
    bool vision_enabled = false;
};

struct ImageInput {
    std::vector<unsigned char> rgb_data;
    uint32_t width = 0;
    uint32_t height = 0;
};

class GenerationSession {
public:
    virtual ~GenerationSession() = default;
    virtual void read(const TokenStream::Emit &emit) = 0;
    virtual void cancel() = 0;
    virtual UsageReport usage() const = 0;
};

} // namespace local_agent

#endif
