#include "litert_engine.h"

#include "litert_api.h"

#include <stdexcept>
#include <utility>

namespace local_agent {
namespace {

class LiteRTGenerationSession final : public GenerationSession {
public:
    LiteRTGenerationSession(
        LiteRTSession &session,
        ModelLoadConfig config,
        GenerationRequest request
    )
        : session_(session),
          config_(std::move(config)),
          request_(std::move(request)) {}

    void read(const TokenStream::Emit &emit) override {
        LiteRTGenerationOutput output = session_.generate(config_, request_);
        usage_ = output.usage;
        if (!output.text.empty() && !stream_.emit_text_delta(output.text, emit)) {
            return;
        }
        if (output.usage.available && !stream_.emit_usage(output.usage, emit)) {
            return;
        }
        stream_.emit_completed(output.text, emit);
    }

    void cancel() override {
        stream_.cancel();
        session_.cancel();
    }

    UsageReport usage() const override {
        return usage_;
    }

private:
    LiteRTSession &session_;
    ModelLoadConfig config_;
    GenerationRequest request_;
    TokenStream stream_;
    UsageReport usage_;
};

class LiteRTLoadedModel final : public LoadedModel {
public:
    LiteRTLoadedModel(ModelLoadConfig config, std::unique_ptr<LiteRTSession> session)
        : config_(std::move(config)),
          session_(std::move(session)) {
        if (!session_) {
            throw std::invalid_argument("LiteRTLoadedModel session must not be null");
        }
        session_->load(config_);
    }

    ModelRuntimeInfo runtime_info() const override {
        return ModelRuntimeInfo{
            config_.engine,
            config_.model_id,
            config_.context_tokens,
            false,
        };
    }

    std::unique_ptr<GenerationSession> start_generation(
        const GenerationRequest &request,
        const std::vector<ImageInput> &images
    ) override {
        if (request.messages.empty()) {
            throw std::invalid_argument("LiteRT generation requires at least one message");
        }
        if (!request.images.empty() || !images.empty()) {
            throw std::invalid_argument("LiteRT adapter does not support image input");
        }
        return std::make_unique<LiteRTGenerationSession>(*session_, config_, request);
    }

private:
    ModelLoadConfig config_;
    std::unique_ptr<LiteRTSession> session_;
};

bool is_supported_litert_format(const std::string &format) {
    return format == "litert" || format == "tflite";
}

} // namespace

LiteRTInferenceEngine::LiteRTInferenceEngine() = default;

LiteRTInferenceEngine::LiteRTInferenceEngine(std::unique_ptr<LiteRTSession> session)
    : session_(std::move(session)) {
    if (!session_) {
        throw std::invalid_argument("LiteRTInferenceEngine session must not be null");
    }
}

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
    if (!is_supported_litert_format(config.model_format)) {
        throw std::invalid_argument("LiteRTInferenceEngine requires model_format=litert or tflite");
    }
    if (config.model_path.empty()) {
        throw std::invalid_argument("LiteRT model_path must not be empty");
    }
    std::unique_ptr<LiteRTSession> session = session_
        ? std::move(session_)
        : make_litert_session();
    return std::make_unique<LiteRTLoadedModel>(config, std::move(session));
}

} // namespace local_agent
