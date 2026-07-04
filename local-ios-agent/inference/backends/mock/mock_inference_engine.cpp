#include "mock_inference_engine.h"

#include <chrono>
#include <stdexcept>
#include <thread>
#include <utility>

namespace local_agent {
namespace {

class MockGenerationSession final : public GenerationSession {
public:
    explicit MockGenerationSession(std::vector<ImageInput> images, bool block_until_cancel)
        : images_(std::move(images)),
          block_until_cancel_(block_until_cancel) {}

    void read(const TokenStream::Emit &emit) override {
        if (block_until_cancel_) {
            if (!stream_.emit_structured_delta("blocking_until_cancel", emit)) {
                return;
            }
            while (!stream_.is_cancelled()) {
                std::this_thread::sleep_for(std::chrono::milliseconds(5));
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(200));
            return;
        }
        if (!stream_.emit_text_delta("On-device ", emit)) {
            return;
        }
        if (!stream_.emit_text_delta("mock response", emit)) {
            return;
        }
        if (!images_.empty() && !images_.front().rgb_data.empty()) {
            if (!stream_.emit_structured_delta(
                    "image_rgb_first_byte=" + std::to_string(images_.front().rgb_data.front()),
                    emit
                )) {
                return;
            }
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
    std::vector<ImageInput> images_;
    bool block_until_cancel_ = false;
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
        bool block_until_cancel = false;
        for (const auto &message : request.messages) {
            if (message.content == "block_until_cancel") {
                block_until_cancel = true;
            }
        }
        return std::make_unique<MockGenerationSession>(images, block_until_cancel);
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
