#include "local_agent_inference.h"

#include <cassert>
#include <string>
#include <vector>

struct CallbackState {
    std::vector<std::string> tokens;
};

struct StopAfterFirstToken {
    std::vector<std::string> tokens;
};

static LocalAgentStatus collect_token(const char *token_json, void *user_data) {
    auto *state = static_cast<CallbackState *>(user_data);
    state->tokens.emplace_back(token_json);
    return LOCAL_AGENT_STATUS_OK;
}

static LocalAgentStatus stop_after_first_token(const char *token_json, void *user_data) {
    auto *state = static_cast<StopAfterFirstToken *>(user_data);
    state->tokens.emplace_back(token_json);
    return LOCAL_AGENT_STATUS_CANCELLED;
}

int main() {
    LocalAgentBackend *backend = nullptr;
    assert(local_agent_backend_init(&backend) == LOCAL_AGENT_STATUS_OK);
    assert(backend != nullptr);

    const char *config = R"({
      "backend":"mock",
      "model_id":"mock.local",
      "model_path":"/tmp/mock.gguf",
      "max_context_tokens":128,
      "generation":{"max_new_tokens":8}
    })";
    assert(local_agent_backend_load_model(backend, config) == LOCAL_AGENT_STATUS_OK);

    LocalAgentBackendStream *stream = nullptr;
    assert(local_agent_backend_start_chat(
        backend,
        R"({"messages":[{"role":"user","content":"hello"}]})",
        &stream
    ) == LOCAL_AGENT_STATUS_OK);
    assert(stream != nullptr);

    CallbackState state;
    assert(local_agent_backend_read_stream(stream, collect_token, &state) == LOCAL_AGENT_STATUS_OK);
    assert(state.tokens.size() == 3);
    assert(state.tokens[0] == R"({"type":"text_delta","text":"On-device "})");
    assert(state.tokens[2] == R"({"type":"completed","text":"On-device mock response"})");
    assert(local_agent_backend_release_stream(stream) == LOCAL_AGENT_STATUS_OK);

    LocalAgentBackendStream *callback_cancelled = nullptr;
    assert(local_agent_backend_start_chat(
        backend,
        R"({"messages":[{"role":"user","content":"stop"}]})",
        &callback_cancelled
    ) == LOCAL_AGENT_STATUS_OK);
    StopAfterFirstToken stopped;
    assert(
        local_agent_backend_read_stream(callback_cancelled, stop_after_first_token, &stopped) ==
        LOCAL_AGENT_STATUS_CANCELLED
    );
    assert(stopped.tokens == (std::vector<std::string>{
        R"({"type":"text_delta","text":"On-device "})",
    }));
    assert(local_agent_backend_release_stream(callback_cancelled) == LOCAL_AGENT_STATUS_OK);

    LocalAgentBackendStream *image_stream = nullptr;
    assert(local_agent_backend_start_chat_with_image(
        backend,
        R"({"messages":[]})",
        nullptr,
        1,
        1,
        &image_stream
    ) == LOCAL_AGENT_STATUS_INVALID_ARGUMENT);
    assert(image_stream == nullptr);

    const unsigned char rgb_pixel[3] = {255, 255, 255};
    assert(local_agent_backend_start_chat_with_image(
        backend,
        R"({"messages":[]})",
        rgb_pixel,
        1,
        1,
        &image_stream
    ) == LOCAL_AGENT_STATUS_INVALID_ARGUMENT);
    assert(image_stream == nullptr);

    LocalAgentBackendStream *cancelled = nullptr;
    assert(local_agent_backend_start_chat(backend, R"({"messages":[]})", &cancelled) == LOCAL_AGENT_STATUS_OK);
    assert(local_agent_backend_cancel(cancelled) == LOCAL_AGENT_STATUS_CANCELLED);
    assert(local_agent_backend_release_stream(cancelled) == LOCAL_AGENT_STATUS_OK);
    assert(local_agent_backend_release(backend) == LOCAL_AGENT_STATUS_OK);
    return 0;
}
