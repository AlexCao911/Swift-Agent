#include "litert_engine.h"

#include <stdexcept>

namespace local_agent {

EngineCapabilities LiteRTInferenceEngine::capabilities() const {
    EngineCapabilities capabilities;
    capabilities.supports_vision = false;
    capabilities.supports_streaming = true;
    capabilities.supports_cancellation = true;
    capabilities.supports_token_usage = false;
    capabilities.supported_model_formats = {"litert", "tflite"};
    return capabilities;
}

std::unique_ptr<LoadedModel> LiteRTInferenceEngine::load_model(const ModelLoadConfig &config) {
    if (config.engine != "litert") {
        throw std::invalid_argument("LiteRTInferenceEngine requires engine=litert");
    }
    throw std::runtime_error("LiteRT vendor runtime is not linked in this build");
}

} // namespace local_agent
