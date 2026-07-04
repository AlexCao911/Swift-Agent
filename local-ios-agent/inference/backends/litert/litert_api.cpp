#include "litert_api.h"

#include <stdexcept>

#if defined(LOCAL_AGENT_ENABLE_LITERT_VENDOR)
#error "LOCAL_AGENT_ENABLE_LITERT_VENDOR requires a vendor LiteRT bridge implementation of make_litert_session; do not compile the unavailable fallback litert_api.cpp"
#endif

namespace local_agent {
namespace {

class UnavailableLiteRTSession final : public LiteRTSession {
public:
    void load(const ModelLoadConfig &) override {
        throw std::runtime_error("LiteRT vendor runtime is not linked in this build");
    }

    LiteRTGenerationOutput generate(
        const ModelLoadConfig &,
        const GenerationRequest &
    ) override {
        throw std::runtime_error("LiteRT vendor runtime is not linked in this build");
    }

    void cancel() override {}
};

} // namespace

std::unique_ptr<LiteRTSession> make_litert_session() {
    return std::make_unique<UnavailableLiteRTSession>();
}

} // namespace local_agent
