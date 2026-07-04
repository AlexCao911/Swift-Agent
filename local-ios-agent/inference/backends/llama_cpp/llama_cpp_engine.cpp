#include "llama_cpp_engine.h"

#include <stdexcept>
#include <utility>

namespace local_agent {
namespace {

ModelConfig to_llama_model_config(
    const ModelLoadConfig &load_config,
    const SamplingConfig &sampling = SamplingConfig()
) {
    ModelConfig config;
    config.backend = "llama_cpp";
    config.model_id = load_config.model_id;
    config.model_path = load_config.model_path;
    config.chat_template = load_config.chat_template;
    config.max_context_tokens = load_config.context_tokens;
    config.generation.temperature = sampling.temperature;
    config.generation.top_p = sampling.top_p;
    config.generation.max_new_tokens = sampling.max_new_tokens;
    config.generation.seed = sampling.seed;
    config.llama_cpp.n_gpu_layers = load_config.runtime.n_gpu_layers;
    config.llama_cpp.n_threads = load_config.runtime.n_threads;
    config.llama_cpp.mmproj_path = load_config.mmproj_path;
    return config;
}

class LlamaCppGenerationSession final : public GenerationSession {
public:
    LlamaCppGenerationSession(
        LlamaCppSession &session,
        ModelLoadConfig load_config,
        GenerationRequest request,
        std::vector<ImageInput> images
    )
        : session_(session),
          load_config_(std::move(load_config)),
          request_(std::move(request)),
          images_(std::move(images)) {}

    void read(const TokenStream::Emit &emit) override {
        std::string completed;
        bool stopped_by_emit = false;
        const std::string prompt_json = prompt_json_from_generation_request(request_);
        const ModelConfig generation_config = to_llama_model_config(load_config_, request_.sampling);

        auto on_delta = [&](const std::string &delta) -> bool {
            if (stream_.is_cancelled()) {
                return false;
            }
            if (!stream_.emit_text_delta(delta, emit)) {
                stopped_by_emit = true;
                return false;
            }
            completed += delta;
            return true;
        };

        if (!images_.empty()) {
            session_.stream_generate_with_image(prompt_json, images_.front(), generation_config, on_delta);
        } else {
            session_.stream_generate(prompt_json, generation_config, on_delta);
        }

        if (!stream_.is_cancelled() && !stopped_by_emit) {
            stream_.emit_completed(completed, emit);
        }
    }

    void cancel() override {
        stream_.cancel();
    }

    UsageReport usage() const override {
        return usage_;
    }

private:
    LlamaCppSession &session_;
    ModelLoadConfig load_config_;
    GenerationRequest request_;
    std::vector<ImageInput> images_;
    TokenStream stream_;
    UsageReport usage_;
};

class LlamaCppLoadedModel final : public LoadedModel {
public:
    LlamaCppLoadedModel(ModelLoadConfig config, std::unique_ptr<LlamaCppSession> session)
        : config_(std::move(config)),
          session_(std::move(session)) {
        session_->load(to_llama_model_config(config_));
    }

    ModelRuntimeInfo runtime_info() const override {
        return ModelRuntimeInfo{
            config_.engine,
            config_.model_id,
            config_.context_tokens,
            !config_.mmproj_path.empty(),
        };
    }

    std::unique_ptr<GenerationSession> start_generation(
        const GenerationRequest &request,
        const std::vector<ImageInput> &images
    ) override {
        if (request.messages.empty()) {
            throw std::invalid_argument("llama.cpp generation requires at least one message");
        }
        if (images.size() > 1) {
            throw std::invalid_argument("llama.cpp generation supports one image buffer per request");
        }
        return std::make_unique<LlamaCppGenerationSession>(*session_, config_, request, images);
    }

private:
    ModelLoadConfig config_;
    std::unique_ptr<LlamaCppSession> session_;
};

} // namespace

LlamaCppEngine::LlamaCppEngine()
    : session_(make_llama_cpp_session()) {}

LlamaCppEngine::LlamaCppEngine(std::unique_ptr<LlamaCppSession> session)
    : session_(std::move(session)) {
    if (!session_) {
        throw std::invalid_argument("LlamaCppEngine session must not be null");
    }
}

EngineCapabilities LlamaCppEngine::capabilities() const {
    EngineCapabilities capabilities;
    capabilities.supports_vision = true;
    capabilities.supports_streaming = true;
    capabilities.supports_cancellation = true;
    capabilities.supports_token_usage = false;
    capabilities.supported_model_formats = {"gguf"};
    return capabilities;
}

std::unique_ptr<LoadedModel> LlamaCppEngine::load_model(const ModelLoadConfig &config) {
    if (config.engine != "llama_cpp") {
        throw std::invalid_argument("LlamaCppEngine requires engine=llama_cpp");
    }
    if (config.model_format != "gguf") {
        throw std::invalid_argument("LlamaCppEngine requires model_format=gguf");
    }
    if (config.model_path.empty()) {
        throw std::invalid_argument("llama.cpp model_path must not be empty");
    }
    return std::make_unique<LlamaCppLoadedModel>(config, std::move(session_));
}

} // namespace local_agent
