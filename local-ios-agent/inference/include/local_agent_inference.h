#ifndef LOCAL_AGENT_INFERENCE_H
#define LOCAL_AGENT_INFERENCE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum LocalAgentStatus {
    LOCAL_AGENT_STATUS_OK = 0,
    LOCAL_AGENT_STATUS_ERROR = 1,
    LOCAL_AGENT_STATUS_CANCELLED = 2,
    LOCAL_AGENT_STATUS_INVALID_ARGUMENT = 3
} LocalAgentStatus;

typedef struct LocalAgentEngineHandle LocalAgentEngineHandle;
typedef struct LocalAgentModelHandle LocalAgentModelHandle;
typedef struct LocalAgentGenerationHandle LocalAgentGenerationHandle;

typedef struct LocalAgentImageInput {
    /* Borrowed by the caller only for local_agent_generation_start; bytes are copied before return. */
    const uint8_t *bytes;
    uint64_t byte_count;
    uint32_t width;
    uint32_t height;
    /* First v2 implementation accepts "rgb8". */
    const char *pixel_format;
} LocalAgentImageInput;

typedef LocalAgentStatus (*local_agent_token_callback)(
    /* Borrowed and valid only for the callback invocation. */
    const char *token_json,
    void *user_data
);

/* Frees strings returned through char ** out parameters. Passing null is allowed. */
void local_agent_string_free(char *value);

/* Returned char * must be released with local_agent_string_free. */
LocalAgentStatus local_agent_engine_list(
    char **out_json
);

LocalAgentStatus local_agent_engine_create(
    const char *engine_id,
    LocalAgentEngineHandle **out_engine
);

LocalAgentStatus local_agent_engine_capabilities(
    LocalAgentEngineHandle *engine,
    char **out_json
);

/* Release functions accept null. Passing an already released non-null raw handle is invalid. */
LocalAgentStatus local_agent_engine_release(
    LocalAgentEngineHandle *engine
);

LocalAgentStatus local_agent_model_load(
    LocalAgentEngineHandle *engine,
    const char *model_config_json,
    LocalAgentModelHandle **out_model
);

LocalAgentStatus local_agent_model_unload(
    LocalAgentModelHandle *model
);

LocalAgentStatus local_agent_generation_start(
    LocalAgentModelHandle *model,
    const char *generation_request_json,
    const LocalAgentImageInput *images,
    uint64_t image_count,
    LocalAgentGenerationHandle **out_generation
);

LocalAgentStatus local_agent_generation_read(
    LocalAgentGenerationHandle *generation,
    local_agent_token_callback callback,
    void *user_data
);

LocalAgentStatus local_agent_generation_cancel(
    LocalAgentGenerationHandle *generation
);

LocalAgentStatus local_agent_generation_release(
    LocalAgentGenerationHandle *generation
);

LocalAgentStatus local_agent_last_error(
    LocalAgentEngineHandle *engine,
    /* Returned char * must be released with local_agent_string_free. */
    char **out_json
);

#ifdef __cplusplus
}
#endif

#endif
