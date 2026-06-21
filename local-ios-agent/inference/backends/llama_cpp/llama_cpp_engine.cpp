#include "llama_cpp_engine.h"

#include <stdexcept>
#include <utility>

namespace local_agent {

LlamaCppEngine::LlamaCppEngine()
    : session_(make_llama_cpp_session()) {}

LlamaCppEngine::LlamaCppEngine(std::unique_ptr<LlamaCppSession> session)
    : session_(std::move(session)) {
    if (!session_) {
        throw std::invalid_argument("LlamaCppEngine session must not be null");
    }
}

void LlamaCppEngine::load(const ModelConfig &config) {
    if (config.backend != "llama_cpp") {
        throw std::invalid_argument("LlamaCppEngine requires backend=llama_cpp");
    }
    config_ = config;
    session_->load(config_);
}

std::unique_ptr<TokenStream> LlamaCppEngine::start_chat(const std::string &prompt_json) {
    if (prompt_json.empty()) {
        throw std::invalid_argument("prompt json must not be empty");
    }
    prompt_json_ = prompt_json;
    image_ = ImageInput();
    has_image_ = false;
    return std::make_unique<TokenStream>();
}

std::unique_ptr<TokenStream> LlamaCppEngine::start_chat_with_image(
    const std::string &prompt_json,
    const ImageInput &image
) {
    if (prompt_json.empty()) {
        throw std::invalid_argument("prompt json must not be empty");
    }
    if (image.rgb_data.empty() || image.width == 0 || image.height == 0) {
        throw std::invalid_argument("image input must contain RGB bytes and dimensions");
    }
    image_ = image;
    prompt_json_ = prompt_json;
    has_image_ = true;
    return std::make_unique<TokenStream>();
}

void LlamaCppEngine::read_stream(TokenStream &stream, const TokenStream::Emit &emit) {
    std::string completed;
    bool stopped_by_emit = false;
    auto on_delta = [&](const std::string &delta) -> bool {
        if (stream.is_cancelled()) {
            return false;
        }
        if (!stream.emit_text_delta(delta, emit)) {
            stopped_by_emit = true;
            return false;
        }
        completed += delta;
        return true;
    };

    if (has_image_) {
        session_->stream_generate_with_image(prompt_json_, image_, config_, on_delta);
    } else {
        session_->stream_generate(prompt_json_, config_, on_delta);
    }

    if (!stream.is_cancelled() && !stopped_by_emit) {
        stream.emit_completed(completed, emit);
    }
}

} // namespace local_agent
