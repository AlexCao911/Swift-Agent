#ifndef LOCAL_AGENT_LITERT_API_H
#define LOCAL_AGENT_LITERT_API_H

#include "generation_request.h"
#include "model_config.h"
#include "token_stream.h"

#include <functional>
#include <memory>
#include <string>

namespace local_agent {

struct LiteRTGenerationOutput {
    std::string text;
    UsageReport usage;
};

using LiteRTTokenEmit = std::function<bool(const std::string &)>;

class LiteRTSession {
public:
    virtual ~LiteRTSession() = default;
    virtual void load(const ModelLoadConfig &config) = 0;
    virtual LiteRTGenerationOutput stream_generate(
        const ModelLoadConfig &config,
        const GenerationRequest &request,
        const LiteRTTokenEmit &emit
    ) = 0;
    virtual void cancel() = 0;
};

std::unique_ptr<LiteRTSession> make_litert_session();

} // namespace local_agent

#endif
