#include "mock_inference_engine.h"

#include <stdexcept>

namespace local_agent {

void MockInferenceEngine::load(const ModelConfig &config) {
    if (config.model_path.empty()) {
        throw std::invalid_argument("mock model_path must not be empty");
    }
    loaded_ = true;
}

std::unique_ptr<TokenStream> MockInferenceEngine::start_chat(const std::string &prompt_json) {
    if (!loaded_) {
        throw std::runtime_error("mock inference engine is not loaded");
    }
    if (prompt_json.empty()) {
        throw std::invalid_argument("prompt json must not be empty");
    }
    return std::make_unique<TokenStream>();
}

void MockInferenceEngine::read_stream(TokenStream &stream, const TokenStream::Emit &emit) {
    if (!stream.emit_text_delta("On-device ", emit)) {
        return;
    }
    if (!stream.emit_text_delta("mock response", emit)) {
        return;
    }
    stream.emit_completed("On-device mock response", emit);
}

} // namespace local_agent
