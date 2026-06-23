#include "llama_cpp_api.h"

#include "inference_engine.h"
#include "llama_cpp_prompt.h"

#if defined(LOCAL_AGENT_ENABLE_LLAMA_CPP)
#include "llama.h"
#endif

#if defined(LOCAL_AGENT_ENABLE_LLAMA_CPP_MTMD)
#include "mtmd.h"
#include "mtmd-helper.h"
#endif

#include <stdexcept>
#include <string>
#include <vector>

namespace local_agent {
namespace {

class UnavailableLlamaCppSession final : public LlamaCppSession {
public:
    void load(const ModelConfig &) override {
        throw std::runtime_error("llama.cpp backend is not linked in this build");
    }

    void stream_generate(
        const std::string &,
        const ModelConfig &,
        const LlamaTokenEmit &
    ) override {
        throw std::runtime_error("llama.cpp backend is not linked in this build");
    }

    void stream_generate_with_image(
        const std::string &,
        const ImageInput &,
        const ModelConfig &,
        const LlamaTokenEmit &
    ) override {
        throw std::runtime_error("llama.cpp multimodal backend is not linked in this build");
    }
};

std::string render_prompt_for_llama_cpp(
    const std::string &prompt_json,
    const ModelConfig &config
#if defined(LOCAL_AGENT_ENABLE_LLAMA_CPP)
    ,
    const llama_model *model
#endif
    ,
    const char *media_marker
) {
    std::vector<LlamaPromptMessage> parsed_messages = parse_llama_prompt_messages(prompt_json);
    if (media_marker != nullptr && media_marker[0] != '\0') {
        bool injected = false;
        for (auto message = parsed_messages.rbegin(); message != parsed_messages.rend(); ++message) {
            if (message->role == "user") {
                message->content = std::string(media_marker) + "\n" + message->content;
                injected = true;
                break;
            }
        }
        if (!injected) {
            throw std::invalid_argument("image input requires a user prompt message");
        }
    }

#if defined(LOCAL_AGENT_ENABLE_LLAMA_CPP)
    const char *chat_template = nullptr;
    if (config.chat_template.empty() || config.chat_template == "gguf") {
        chat_template = llama_model_chat_template(model, nullptr);
        if (chat_template == nullptr) {
            throw std::runtime_error("llama.cpp model does not expose a GGUF chat template");
        }
    } else {
        chat_template = config.chat_template.c_str();
    }

    std::vector<llama_chat_message> messages;
    messages.reserve(parsed_messages.size());
    for (const auto &message : parsed_messages) {
        messages.push_back(llama_chat_message{
            message.role.c_str(),
            message.content.c_str(),
        });
    }

    int32_t required = llama_chat_apply_template(
        chat_template,
        messages.data(),
        messages.size(),
        true,
        nullptr,
        0
    );
    if (required == 0) {
        throw std::runtime_error("llama.cpp chat template produced an empty prompt");
    }
    if (required < 0) {
        required = -required;
    }

    std::vector<char> buffer(static_cast<size_t>(required) + 1);
    int32_t written = llama_chat_apply_template(
        chat_template,
        messages.data(),
        messages.size(),
        true,
        buffer.data(),
        static_cast<int32_t>(buffer.size())
    );
    if (written < 0) {
        written = -written;
        buffer.assign(static_cast<size_t>(written) + 1, '\0');
        written = llama_chat_apply_template(
            chat_template,
            messages.data(),
            messages.size(),
            true,
            buffer.data(),
            static_cast<int32_t>(buffer.size())
        );
    }
    if (written <= 0) {
        throw std::runtime_error("llama.cpp failed to apply chat template");
    }

    return std::string(buffer.data(), static_cast<size_t>(written));
#else
    if (!config.chat_template.empty() && config.chat_template != "gguf") {
        throw std::invalid_argument(
            "llama.cpp chat_template requires linked llama.cpp for custom templates"
        );
    }
    return render_fallback_chat_prompt(parsed_messages);
#endif
}

#if defined(LOCAL_AGENT_ENABLE_LLAMA_CPP)
class LinkedLlamaCppSession final : public LlamaCppSession {
public:
    ~LinkedLlamaCppSession() override {
        release();
    }

    void load(const ModelConfig &config) override {
        if (config.model_path.empty()) {
            throw std::invalid_argument("llama.cpp model_path is empty");
        }

        release();
        llama_backend_init();

        llama_model_params model_params = llama_model_default_params();
        model_params.n_gpu_layers = config.llama_cpp.n_gpu_layers;
        model_ = llama_model_load_from_file(config.model_path.c_str(), model_params);
        if (model_ == nullptr) {
            throw std::runtime_error("llama.cpp failed to load model: " + config.model_path);
        }

        llama_context_params context_params = llama_context_default_params();
        context_params.n_ctx = static_cast<uint32_t>(config.max_context_tokens);
        context_params.n_threads = config.llama_cpp.n_threads;
        context_params.n_threads_batch = config.llama_cpp.n_threads;
        context_ = llama_init_from_model(model_, context_params);
        if (context_ == nullptr) {
            throw std::runtime_error("llama.cpp failed to create context");
        }

#if defined(LOCAL_AGENT_ENABLE_LLAMA_CPP_MTMD)
        if (!config.llama_cpp.mmproj_path.empty()) {
            mtmd_context_params mtmd_params = mtmd_context_params_default();
            mtmd_params.n_threads = config.llama_cpp.n_threads;
            mtmd_ = mtmd_init_from_file(config.llama_cpp.mmproj_path.c_str(), model_, mtmd_params);
            if (mtmd_ == nullptr) {
                throw std::runtime_error(
                    "llama.cpp failed to load mmproj: " + config.llama_cpp.mmproj_path
                );
            }
        }
#endif
    }

    void stream_generate(
        const std::string &prompt_json,
        const ModelConfig &config,
        const LlamaTokenEmit &emit
    ) override {
        require_loaded();
        run_llama_generation(prompt_json, config, emit);
    }

    void stream_generate_with_image(
        const std::string &prompt_json,
        const ImageInput &image,
        const ModelConfig &config,
        const LlamaTokenEmit &emit
    ) override {
        require_loaded();
        if (config.llama_cpp.mmproj_path.empty()) {
            throw std::invalid_argument("llama.cpp mmproj_path is required for image input");
        }
#if defined(LOCAL_AGENT_ENABLE_LLAMA_CPP_MTMD)
        run_mtmd_prefill(prompt_json, image, config);
        sample_from_context(config, emit);
#else
        throw std::runtime_error("llama.cpp mtmd backend is not linked in this build");
#endif
    }

private:
    llama_model *model_ = nullptr;
    llama_context *context_ = nullptr;
#if defined(LOCAL_AGENT_ENABLE_LLAMA_CPP_MTMD)
    mtmd_context *mtmd_ = nullptr;
#endif

    void require_loaded() const {
        if (model_ == nullptr || context_ == nullptr) {
            throw std::runtime_error("llama.cpp model is not loaded");
        }
    }

    void release() {
#if defined(LOCAL_AGENT_ENABLE_LLAMA_CPP_MTMD)
        if (mtmd_ != nullptr) {
            mtmd_free(mtmd_);
            mtmd_ = nullptr;
        }
#endif
        if (context_ != nullptr) {
            llama_free(context_);
            context_ = nullptr;
        }
        if (model_ != nullptr) {
            llama_model_free(model_);
            model_ = nullptr;
        }
    }

    void run_llama_generation(
        const std::string &prompt_json,
        const ModelConfig &config,
        const LlamaTokenEmit &emit
    ) {
        const llama_vocab *vocab = llama_model_get_vocab(model_);
        if (vocab == nullptr) {
            throw std::runtime_error("llama.cpp model has no vocabulary");
        }

        llama_memory_clear(llama_get_memory(context_), true);

        const std::string prompt = render_prompt_for_llama_cpp(prompt_json, config, model_, nullptr);

        int prompt_token_count = -llama_tokenize(
            vocab,
            prompt.c_str(),
            static_cast<int32_t>(prompt.size()),
            nullptr,
            0,
            true,
            true
        );
        if (prompt_token_count <= 0) {
            throw std::runtime_error("llama.cpp failed to count prompt tokens");
        }

        std::vector<llama_token> prompt_tokens(static_cast<size_t>(prompt_token_count));
        int actual_prompt_tokens = llama_tokenize(
            vocab,
            prompt.c_str(),
            static_cast<int32_t>(prompt.size()),
            prompt_tokens.data(),
            static_cast<int32_t>(prompt_tokens.size()),
            true,
            true
        );
        if (actual_prompt_tokens < 0) {
            throw std::runtime_error("llama.cpp failed to tokenize prompt");
        }
        prompt_tokens.resize(static_cast<size_t>(actual_prompt_tokens));

        llama_batch prompt_batch = llama_batch_get_one(
            prompt_tokens.data(),
            static_cast<int32_t>(prompt_tokens.size())
        );
        if (llama_decode(context_, prompt_batch) != 0) {
            throw std::runtime_error("llama.cpp failed to decode prompt");
        }

        sample_from_context(config, emit);
    }

    void sample_from_context(const ModelConfig &config, const LlamaTokenEmit &emit) {
        const llama_vocab *vocab = llama_model_get_vocab(model_);
        if (vocab == nullptr) {
            throw std::runtime_error("llama.cpp model has no vocabulary");
        }

        llama_sampler *sampler = llama_sampler_chain_init(llama_sampler_chain_default_params());
        llama_sampler_chain_add(sampler, llama_sampler_init_top_p(config.generation.top_p, 1));
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(config.generation.temperature));
        llama_sampler_chain_add(
            sampler,
            llama_sampler_init_dist(static_cast<uint32_t>(config.generation.seed))
        );

        for (int i = 0; i < config.generation.max_new_tokens; i += 1) {
            llama_token token = llama_sampler_sample(sampler, context_, -1);
            if (llama_vocab_is_eog(vocab, token)) {
                break;
            }

            char piece[512];
            int piece_size = llama_token_to_piece(vocab, token, piece, sizeof(piece), 0, true);
            if (piece_size > 0) {
                if (!emit(std::string(piece, static_cast<size_t>(piece_size)))) {
                    break;
                }
            }

            llama_batch next_batch = llama_batch_get_one(&token, 1);
            if (llama_decode(context_, next_batch) != 0) {
                llama_sampler_free(sampler);
                throw std::runtime_error("llama.cpp failed to decode generated token");
            }
        }

        llama_sampler_free(sampler);
    }

#if defined(LOCAL_AGENT_ENABLE_LLAMA_CPP_MTMD)
    void run_mtmd_prefill(
        const std::string &prompt_json,
        const ImageInput &image,
        const ModelConfig &config
    ) {
        if (mtmd_ == nullptr) {
            throw std::runtime_error("llama.cpp mtmd context is not loaded");
        }
        if (
            image.rgb_data.size() !=
            static_cast<size_t>(image.width) * static_cast<size_t>(image.height) * 3
        ) {
            throw std::invalid_argument("image RGB buffer size does not match width and height");
        }

        mtmd_bitmap *bitmap = mtmd_bitmap_init(
            image.width,
            image.height,
            image.rgb_data.data()
        );
        if (bitmap == nullptr) {
            throw std::runtime_error("llama.cpp failed to create mtmd bitmap");
        }

        mtmd_input_chunks *chunks = mtmd_input_chunks_init();
        if (chunks == nullptr) {
            mtmd_bitmap_free(bitmap);
            throw std::runtime_error("llama.cpp failed to create mtmd input chunks");
        }

        llama_memory_clear(llama_get_memory(context_), true);

        const std::string prompt = render_prompt_for_llama_cpp(
            prompt_json,
            config,
            model_,
            mtmd_default_marker()
        );
        mtmd_input_text text;
        text.text = prompt.c_str();
        text.add_special = true;
        text.parse_special = true;
        const mtmd_bitmap *bitmaps[1] = {bitmap};
        int32_t tokenize_status = mtmd_tokenize(mtmd_, chunks, &text, bitmaps, 1);
        if (tokenize_status != 0) {
            mtmd_input_chunks_free(chunks);
            mtmd_bitmap_free(bitmap);
            throw std::runtime_error("llama.cpp mtmd_tokenize failed");
        }

        llama_pos n_past = 0;
        int32_t eval_status = mtmd_helper_eval_chunks(
            mtmd_,
            context_,
            chunks,
            n_past,
            0,
            512,
            true,
            &n_past
        );
        mtmd_input_chunks_free(chunks);
        mtmd_bitmap_free(bitmap);
        if (eval_status != 0) {
            throw std::runtime_error("llama.cpp mtmd chunk evaluation failed");
        }
    }
#endif
};
#endif

} // namespace

std::unique_ptr<LlamaCppSession> make_llama_cpp_session() {
#if defined(LOCAL_AGENT_ENABLE_LLAMA_CPP)
    return std::make_unique<LinkedLlamaCppSession>();
#else
    return std::make_unique<UnavailableLlamaCppSession>();
#endif
}

} // namespace local_agent
