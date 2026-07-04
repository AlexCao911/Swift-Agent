#include "mock_inference_engine.h"

#include <stdexcept>
#include <utility>

namespace local_agent {
namespace {

class MockGenerationSession final : public GenerationSession {
public:
    void read(const TokenStream::Emit &emit) override {
        if (!stream_.emit_text_delta("On-device ", emit)) {
            return;
        }
        if (!stream_.emit_text_delta("mock response", emit)) {
            return;
        }
        usage_ = UsageReport{1, 2, 3, true};
        if (!stream_.emit_usage(usage_, emit)) {
            return;
        }
        stream_.emit_completed("On-device mock response", emit);
    }

    void cancel() override {
        stream_.cancel();
    }

    UsageReport usage() const override {
        return usage_;
    }

private:
    TokenStream stream_;
    UsageReport usage_;
};

class MockLoadedModel final : public LoadedModel {
public:
    explicit MockLoadedModel(ModelLoadConfig config)
        : config_(std::move(config)) {}

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
            throw std::invalid_argument("mock generation requires at least one message");
        }
        if (!images.empty()) {
            throw std::invalid_argument("mock generation does not support image buffers");
        }
        return std::make_unique<MockGenerationSession>();
    }

private:
    ModelLoadConfig config_;
};

} // namespace

EngineCapabilities MockInferenceEngine::capabilities() const {
    EngineCapabilities capabilities;
    capabilities.supports_streaming = true;
    capabilities.supports_cancellation = true;
    capabilities.supports_token_usage = true;
    capabilities.max_context_tokens = 2048;
    capabilities.supported_model_formats = {"mock"};
    return capabilities;
}

std::unique_ptr<LoadedModel> MockInferenceEngine::load_model(const ModelLoadConfig &config) {
    if (config.engine != "mock") {
        throw std::invalid_argument("MockInferenceEngine requires engine=mock");
    }
    if (config.model_path.empty()) {
        throw std::invalid_argument("mock model_path must not be empty");
    }
    return std::make_unique<MockLoadedModel>(config);
}

} // namespace local_agent
