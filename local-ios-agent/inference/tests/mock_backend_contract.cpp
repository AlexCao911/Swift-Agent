#include "local_agent_inference.h"

#include <cassert>
#include <string>
#include <vector>

struct CollectedTokens {
    std::vector<std::string> tokens;
};

struct CancelAfterFirstToken {
    std::vector<std::string> tokens;
    LocalAgentBackendStream **stream;
};

static void collect_token(const char *token_json, void *user_data) {
    auto *collected = static_cast<CollectedTokens *>(user_data);
    collected->tokens.emplace_back(token_json);
}

static void cancel_after_first_token(const char *token_json, void *user_data) {
    auto *state = static_cast<CancelAfterFirstToken *>(user_data);
    state->tokens.emplace_back(token_json);
    if (state->tokens.size() == 1) {
        assert(state->stream != nullptr);
        assert(*state->stream != nullptr);
        assert(local_agent_backend_cancel(*state->stream) == LOCAL_AGENT_STATUS_CANCELLED);
    }
}

int main() {
    LocalAgentBackend *backend = nullptr;
    assert(local_agent_backend_init(&backend) == LOCAL_AGENT_STATUS_OK);
    assert(backend != nullptr);

    LocalAgentBackendStream *unloaded_stream = nullptr;
    CollectedTokens unloaded_tokens;
    assert(local_agent_backend_stream_chat(
               backend,
               "{\"messages\":[]}",
               collect_token,
               &unloaded_tokens,
               &unloaded_stream
           ) == LOCAL_AGENT_STATUS_ERROR);
    assert(unloaded_stream == nullptr);
    assert(unloaded_tokens.tokens.empty());

    assert(local_agent_backend_load_model(
               backend,
               "{\"model_path\":\"mock.gguf\"}"
           ) == LOCAL_AGENT_STATUS_OK);

    LocalAgentBackendStream *split_stream = nullptr;
    CollectedTokens split_collected;
    assert(local_agent_backend_start_chat(
               backend,
               "{\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]}",
               &split_stream
           ) == LOCAL_AGENT_STATUS_OK);
    assert(split_stream != nullptr);
    assert(local_agent_backend_read_stream(
               split_stream,
               collect_token,
               &split_collected
           ) == LOCAL_AGENT_STATUS_OK);
    assert(split_collected.tokens == (std::vector<std::string>{
        "{\"type\":\"text_delta\",\"text\":\"On-device \"}",
        "{\"type\":\"text_delta\",\"text\":\"mock response\"}",
        "{\"type\":\"completed\",\"text\":\"On-device mock response\"}",
    }));
    assert(local_agent_backend_release_stream(split_stream) == LOCAL_AGENT_STATUS_OK);

    LocalAgentBackendStream *stream = nullptr;
    CollectedTokens collected;
    assert(local_agent_backend_stream_chat(
               backend,
               "{\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]}",
               collect_token,
               &collected,
               &stream
           ) == LOCAL_AGENT_STATUS_OK);
    assert(stream != nullptr);
    assert(collected.tokens == (std::vector<std::string>{
        "{\"type\":\"text_delta\",\"text\":\"On-device \"}",
        "{\"type\":\"text_delta\",\"text\":\"mock response\"}",
        "{\"type\":\"completed\",\"text\":\"On-device mock response\"}",
    }));
    assert(local_agent_backend_release_stream(stream) == LOCAL_AGENT_STATUS_OK);

    LocalAgentBackendStream *cancelled_stream = nullptr;
    CancelAfterFirstToken cancellation{{}, &cancelled_stream};
    assert(local_agent_backend_stream_chat(
               backend,
               "{\"messages\":[{\"role\":\"user\",\"content\":\"cancel\"}]}",
               cancel_after_first_token,
               &cancellation,
               &cancelled_stream
           ) == LOCAL_AGENT_STATUS_CANCELLED);
    assert(cancelled_stream != nullptr);
    assert(cancellation.tokens == (std::vector<std::string>{
        "{\"type\":\"text_delta\",\"text\":\"On-device \"}",
    }));
    assert(local_agent_backend_release_stream(cancelled_stream) == LOCAL_AGENT_STATUS_OK);
    assert(local_agent_backend_release(backend) == LOCAL_AGENT_STATUS_OK);
}
