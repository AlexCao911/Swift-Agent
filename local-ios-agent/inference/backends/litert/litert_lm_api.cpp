#include "litert_api.h"

#if !defined(LOCAL_AGENT_ENABLE_LITERT_VENDOR)
#error "litert_lm_api.cpp must only be compiled with LOCAL_AGENT_ENABLE_LITERT_VENDOR"
#endif

#include "litert_active_generation.h"

#include "runtime/conversation/conversation.h"
#include "runtime/engine/engine_factory.h"
#include "runtime/engine/engine_settings.h"
#include "runtime/proto/sampler_params.pb.h"

#include "absl/status/status.h"
#include "absl/time/time.h"
#include "nlohmann/json.hpp"

#include <atomic>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <utility>

namespace local_agent {
namespace {

std::runtime_error litert_error(const std::string &context, const absl::Status &status) {
    return std::runtime_error(context + ": " + std::string(status.message()));
}

bool is_cancelled_status(const absl::Status &status) {
    return status.code() == absl::StatusCode::kCancelled;
}

absl::Status wait_until_generation_quiesced(litert::lm::Engine &engine) {
    for (;;) {
        absl::Status status = engine.WaitUntilDone(litert::lm::Engine::kDefaultTimeout);
        if (status.ok() || is_cancelled_status(status)) {
            return status;
        }
    }
}

std::string normalized_litert_role(const std::string &role) {
    if (role == "assistant") {
        return "assistant";
    }
    if (role == "model") {
        return "model";
    }
    if (role == "system" || role == "tool" || role == "user") {
        return role;
    }
    return "user";
}

litert::lm::Message to_litert_message(const GenerationRequest &request) {
    nlohmann::ordered_json messages = nlohmann::ordered_json::array();
    for (const auto &message : request.messages) {
        messages.push_back({
            {"role", normalized_litert_role(message.role)},
            {"content", message.content},
        });
    }
    return messages;
}

void append_text_content(const nlohmann::ordered_json &content, std::string &out) {
    if (content.is_string()) {
        out += content.get<std::string>();
        return;
    }
    if (content.is_object()) {
        auto text = content.find("text");
        if (text != content.end() && text->is_string()) {
            out += text->get<std::string>();
        }
        return;
    }
    if (!content.is_array()) {
        return;
    }
    for (const auto &part : content) {
        if (part.is_string()) {
            out += part.get<std::string>();
            continue;
        }
        if (!part.is_object()) {
            continue;
        }
        auto text = part.find("text");
        if (text != part.end() && text->is_string()) {
            out += text->get<std::string>();
        }
    }
}

std::string text_from_litert_message(const litert::lm::Message &message) {
    if (message.empty() || !message.is_object()) {
        return "";
    }
    auto content = message.find("content");
    if (content == message.end()) {
        return "";
    }
    std::string text;
    append_text_content(*content, text);
    return text;
}

void apply_sampling_to_session_config(
    const SamplingConfig &sampling,
    litert::lm::SessionConfig &session_config
) {
    if (sampling.max_new_tokens > 0) {
        session_config.SetMaxOutputTokens(sampling.max_new_tokens);
    }

    auto &sampler = session_config.GetMutableSamplerParams();
    if (sampling.top_p > 0.0f && sampling.top_p <= 1.0f) {
        sampler.set_type(litert::lm::proto::SamplerParameters::TOP_P);
        sampler.set_p(sampling.top_p);
        sampler.set_k(sampling.top_k > 0 ? sampling.top_k : 40);
    } else if (sampling.top_k > 0) {
        sampler.set_type(litert::lm::proto::SamplerParameters::TOP_K);
        sampler.set_k(sampling.top_k);
    }
    if (sampling.temperature >= 0.0f) {
        sampler.set_temperature(sampling.temperature);
    }
    if (sampling.seed >= 0) {
        sampler.set_seed(sampling.seed);
    }
}

class LiteRTLMVendorSession final : public LiteRTSession {
public:
    ~LiteRTLMVendorSession() override {
        cancel();
    }

    void load(const ModelLoadConfig &config) override {
        if (config.model_path.empty()) {
            throw std::invalid_argument("LiteRT-LM model_path is empty");
        }

        auto model_assets = litert::lm::ModelAssets::Create(config.model_path);
        if (!model_assets.ok()) {
            throw litert_error("LiteRT-LM failed to create model assets", model_assets.status());
        }

        auto settings = litert::lm::EngineSettings::CreateDefault(
            std::move(*model_assets),
            litert::lm::Backend::CPU
        );
        if (!settings.ok()) {
            throw litert_error("LiteRT-LM failed to create engine settings", settings.status());
        }

        auto engine = litert::lm::EngineFactory::CreateDefault(std::move(*settings));
        if (!engine.ok()) {
            throw litert_error("LiteRT-LM failed to create engine", engine.status());
        }

        std::lock_guard<std::mutex> lock(mutex_);
        engine_ = std::move(*engine);
        active_generation_.finish();
        cancelled_.store(false);
    }

    LiteRTGenerationOutput stream_generate(
        const ModelLoadConfig &,
        const GenerationRequest &request,
        const LiteRTTokenEmit &emit
    ) override {
        if (request.messages.empty()) {
            throw std::invalid_argument("LiteRT-LM generation requires at least one message");
        }

        litert::lm::Engine *engine = nullptr;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (!engine_) {
                throw std::runtime_error("LiteRT-LM model is not loaded");
            }
            engine = engine_.get();
        }

        litert::lm::SessionConfig session_config = litert::lm::SessionConfig::CreateDefault();
        apply_sampling_to_session_config(request.sampling, session_config);

        auto conversation_config = litert::lm::ConversationConfig::Builder()
            .SetSessionConfig(session_config)
            .Build(*engine);
        if (!conversation_config.ok()) {
            throw litert_error(
                "LiteRT-LM failed to create conversation config",
                conversation_config.status()
            );
        }

        auto conversation = litert::lm::Conversation::Create(*engine, *conversation_config);
        if (!conversation.ok()) {
            throw litert_error("LiteRT-LM failed to create conversation", conversation.status());
        }
        std::shared_ptr<litert::lm::Conversation> conversation_owner(std::move(*conversation));

        cancelled_.store(false);
        const std::string task_group_id = next_task_group_id();
        active_generation_.start([conversation_owner, task_group_id]() {
            if (!task_group_id.empty()) {
                conversation_owner->CancelGroup(task_group_id);
            }
            conversation_owner->CancelProcess();
        });

        std::string completed_text;
        std::mutex completed_mutex;
        absl::Status callback_status = absl::OkStatus();

        litert::lm::OptionalArgs args;
        if (request.sampling.max_new_tokens > 0) {
            args.max_output_tokens = request.sampling.max_new_tokens;
        }
        args.task_group_id = task_group_id;

        absl::Status start_status = conversation_owner->SendMessageAsync(
            to_litert_message(request),
            [&](absl::StatusOr<litert::lm::Message> message) {
                if (!message.ok()) {
                    std::lock_guard<std::mutex> lock(completed_mutex);
                    callback_status = message.status();
                    return;
                }
                if (message->empty()) {
                    return;
                }
                const std::string delta = text_from_litert_message(*message);
                if (delta.empty()) {
                    return;
                }
                {
                    std::lock_guard<std::mutex> lock(completed_mutex);
                    completed_text += delta;
                }
                if (!emit(delta)) {
                    cancelled_.store(true);
                    active_generation_.cancel();
                }
            },
            args
        );
        if (!start_status.ok()) {
            active_generation_.finish();
            throw litert_error("LiteRT-LM failed to start generation", start_status);
        }

        absl::Status wait_status = engine->WaitUntilDone(litert::lm::Engine::kDefaultTimeout);
        if (!wait_status.ok() && !is_cancelled_status(wait_status)) {
            absl::Status original_status = wait_status;
            cancelled_.store(true);
            active_generation_.cancel();
            wait_status = wait_until_generation_quiesced(*engine);
            active_generation_.finish();
            throw litert_error("LiteRT-LM generation did not finish", original_status);
        }
        active_generation_.finish();

        if (!wait_status.ok() && !(cancelled_.load() && is_cancelled_status(wait_status))) {
            throw litert_error("LiteRT-LM generation did not finish", wait_status);
        }

        {
            std::lock_guard<std::mutex> lock(completed_mutex);
            if (!callback_status.ok()
                && !(cancelled_.load() && is_cancelled_status(callback_status))) {
                throw litert_error("LiteRT-LM generation callback failed", callback_status);
            }
            LiteRTGenerationOutput output;
            output.text = completed_text;
            return output;
        }
    }

    void cancel() override {
        cancelled_.store(true);
        active_generation_.cancel();
    }

private:
    std::mutex mutex_;
    std::unique_ptr<litert::lm::Engine> engine_;
    LiteRTActiveGeneration active_generation_;
    std::atomic<int> next_task_group_sequence_{1};
    std::atomic<bool> cancelled_{false};

    std::string next_task_group_id() {
        const int sequence = next_task_group_sequence_.fetch_add(1);
        return "local_agent_litert_generation_" + std::to_string(sequence);
    }

};

} // namespace

std::unique_ptr<LiteRTSession> make_litert_session() {
    return std::make_unique<LiteRTLMVendorSession>();
}

} // namespace local_agent
