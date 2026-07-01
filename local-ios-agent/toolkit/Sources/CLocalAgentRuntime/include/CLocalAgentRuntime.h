#ifndef CLOCAL_AGENT_RUNTIME_H
#define CLOCAL_AGENT_RUNTIME_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct LocalAgentRuntimeBridge LocalAgentRuntimeBridge;
typedef int (*LocalAgentRuntimeEventCallback)(const char *event_json, void *user_data);

LocalAgentRuntimeBridge *local_agent_runtime_bridge_new(void);
LocalAgentRuntimeBridge *local_agent_runtime_bridge_new_with_config(const char *config_json);
void local_agent_runtime_bridge_free(LocalAgentRuntimeBridge *runtime);
void local_agent_runtime_bridge_string_free(char *value);

char *local_agent_runtime_bridge_create_session(LocalAgentRuntimeBridge *runtime);
char *local_agent_runtime_bridge_session_ids(LocalAgentRuntimeBridge *runtime);
char *local_agent_runtime_bridge_conversation_summaries(LocalAgentRuntimeBridge *runtime);
char *local_agent_runtime_bridge_fork_session(
    LocalAgentRuntimeBridge *runtime,
    const char *session_id,
    const char *leaf_id
);
char *local_agent_runtime_bridge_active_branch(
    LocalAgentRuntimeBridge *runtime,
    const char *session_id,
    const char *leaf_id
);
char *local_agent_runtime_bridge_archive_session(
    LocalAgentRuntimeBridge *runtime,
    const char *session_id
);
char *local_agent_runtime_bridge_rename_session(
    LocalAgentRuntimeBridge *runtime,
    const char *session_id,
    const char *title
);
char *local_agent_runtime_bridge_update_runtime_options(
    LocalAgentRuntimeBridge *runtime,
    const char *options_json
);
char *local_agent_runtime_bridge_delete_session(
    LocalAgentRuntimeBridge *runtime,
    const char *session_id
);
char *local_agent_runtime_bridge_register_tool_schema(
    LocalAgentRuntimeBridge *runtime,
    const char *schema_json
);
char *local_agent_runtime_bridge_set_permission_state(
    LocalAgentRuntimeBridge *runtime,
    const char *state_json
);
char *local_agent_runtime_bridge_send_message(
    LocalAgentRuntimeBridge *runtime,
    const char *input_json
);
char *local_agent_runtime_bridge_send_message_streaming(
    LocalAgentRuntimeBridge *runtime,
    const char *input_json,
    LocalAgentRuntimeEventCallback callback,
    void *user_data
);
char *local_agent_runtime_bridge_pending_tool_requests(LocalAgentRuntimeBridge *runtime);
char *local_agent_runtime_bridge_pending_approval_requests(LocalAgentRuntimeBridge *runtime);
char *local_agent_runtime_bridge_submit_tool_result(
    LocalAgentRuntimeBridge *runtime,
    const char *run_id,
    const char *result_json
);
char *local_agent_runtime_bridge_submit_tool_result_streaming(
    LocalAgentRuntimeBridge *runtime,
    const char *run_id,
    const char *result_json,
    LocalAgentRuntimeEventCallback callback,
    void *user_data
);
char *local_agent_runtime_bridge_submit_approval_response(
    LocalAgentRuntimeBridge *runtime,
    const char *response_json
);
char *local_agent_runtime_bridge_cancel(
    LocalAgentRuntimeBridge *runtime,
    const char *run_id
);
char *local_agent_runtime_bridge_latest_prompt_debug_snapshot(
    LocalAgentRuntimeBridge *runtime
);
char *local_agent_runtime_bridge_provider_profiles(
    LocalAgentRuntimeBridge *runtime
);
char *local_agent_runtime_bridge_active_provider(
    LocalAgentRuntimeBridge *runtime
);
char *local_agent_runtime_bridge_set_provider(
    LocalAgentRuntimeBridge *runtime,
    const char *request_json
);
char *local_agent_runtime_bridge_start_run(
    LocalAgentRuntimeBridge *runtime,
    const char *request_json
);
char *local_agent_runtime_bridge_load_debug_archive(
    LocalAgentRuntimeBridge *runtime,
    const char *run_id
);

#ifdef __cplusplus
}
#endif

#endif
