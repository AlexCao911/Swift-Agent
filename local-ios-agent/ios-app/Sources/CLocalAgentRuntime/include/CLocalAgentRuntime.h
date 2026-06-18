#ifndef CLOCAL_AGENT_RUNTIME_H
#define CLOCAL_AGENT_RUNTIME_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct LocalAgentRuntimeBridge LocalAgentRuntimeBridge;

LocalAgentRuntimeBridge *local_agent_runtime_bridge_new(void);
LocalAgentRuntimeBridge *local_agent_runtime_bridge_new_with_config(const char *config_json);
void local_agent_runtime_bridge_free(LocalAgentRuntimeBridge *runtime);
void local_agent_runtime_bridge_string_free(char *value);

char *local_agent_runtime_bridge_create_session(LocalAgentRuntimeBridge *runtime);
char *local_agent_runtime_bridge_session_ids(LocalAgentRuntimeBridge *runtime);
char *local_agent_runtime_bridge_register_tool_schema(
    LocalAgentRuntimeBridge *runtime,
    const char *schema_json
);
char *local_agent_runtime_bridge_send_message(
    LocalAgentRuntimeBridge *runtime,
    const char *input_json
);
char *local_agent_runtime_bridge_pending_tool_requests(LocalAgentRuntimeBridge *runtime);
char *local_agent_runtime_bridge_pending_approval_requests(LocalAgentRuntimeBridge *runtime);
char *local_agent_runtime_bridge_submit_tool_result(
    LocalAgentRuntimeBridge *runtime,
    const char *run_id,
    const char *result_json
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

#ifdef __cplusplus
}
#endif

#endif
