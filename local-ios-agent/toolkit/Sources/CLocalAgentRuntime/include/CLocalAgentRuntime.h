#ifndef CLOCAL_AGENT_RUNTIME_H
#define CLOCAL_AGENT_RUNTIME_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct LocalAgentRuntimeBridge LocalAgentRuntimeBridge;
typedef int (*LocalAgentRuntimeEventCallback)(const char *event_json, void *user_data);

typedef enum {
  LOCAL_AGENT_LLM_HOST_COPIED = 0,
  LOCAL_AGENT_LLM_HOST_BACKPRESSURE = 1,
  LOCAL_AGENT_LLM_HOST_UNAVAILABLE = 2
} local_agent_llm_host_copy_receipt_t;

typedef local_agent_llm_host_copy_receipt_t (*local_agent_llm_host_command_fn)(
    const uint8_t *bytes,
    size_t length,
    void *context
);

typedef struct {
  uint32_t abi_version;
  local_agent_llm_host_command_fn submit_command;
  void (*release_context)(void *context);
  void *context;
} local_agent_llm_host_vtable_t;

LocalAgentRuntimeBridge *local_agent_runtime_bridge_new(void);
LocalAgentRuntimeBridge *local_agent_runtime_bridge_new_with_config(const char *config_json);
void local_agent_runtime_bridge_free(LocalAgentRuntimeBridge *runtime);
void local_agent_runtime_bridge_string_free(char *value);
int local_agent_runtime_bridge_install_llm_host(
    LocalAgentRuntimeBridge *runtime,
    const local_agent_llm_host_vtable_t *vtable
);
int local_agent_runtime_bridge_uninstall_llm_host(LocalAgentRuntimeBridge *runtime);
int local_agent_runtime_bridge_suspend_llm_host(LocalAgentRuntimeBridge *runtime);
int local_agent_runtime_bridge_resume_llm_host(LocalAgentRuntimeBridge *runtime);
int local_agent_runtime_bridge_drive_llm_host(LocalAgentRuntimeBridge *runtime);
char *local_agent_runtime_bridge_submit_llm_command_ack(
    LocalAgentRuntimeBridge *runtime,
    const char *acknowledgement_json
);
char *local_agent_runtime_bridge_submit_llm_event(
    LocalAgentRuntimeBridge *runtime,
    const char *event_json
);

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
char *local_agent_runtime_bridge_profile_execution_route(LocalAgentRuntimeBridge *runtime, const char *request_json);
char *local_agent_runtime_bridge_prepare_profile_publish(LocalAgentRuntimeBridge *runtime, const char *request_json);
char *local_agent_runtime_bridge_commit_profile_publish(LocalAgentRuntimeBridge *runtime, const char *request_json);
char *local_agent_runtime_bridge_begin_package_binding(LocalAgentRuntimeBridge *runtime, const char *request_json);
char *local_agent_runtime_bridge_attach_host_binding(LocalAgentRuntimeBridge *runtime, const char *request_json);
char *local_agent_runtime_bridge_confirm_host_binding_activation(LocalAgentRuntimeBridge *runtime, const char *request_json);
char *local_agent_runtime_bridge_preview_run_preparation(LocalAgentRuntimeBridge *runtime, const char *request_json);
char *local_agent_runtime_bridge_renew_run_preparation(LocalAgentRuntimeBridge *runtime, const char *request_json);
char *local_agent_runtime_bridge_register_prepared_session(LocalAgentRuntimeBridge *runtime, const char *request_json);
char *local_agent_runtime_bridge_commit_prepared_start(LocalAgentRuntimeBridge *runtime, const char *request_json);
char *local_agent_runtime_bridge_reconcile_preparation(LocalAgentRuntimeBridge *runtime, const char *request_json);
char *local_agent_runtime_bridge_begin_abort_preparation(LocalAgentRuntimeBridge *runtime, const char *request_json);
char *local_agent_runtime_bridge_ack_prepared_session_cleanup(LocalAgentRuntimeBridge *runtime, const char *request_json);
char *local_agent_runtime_bridge_confirm_prepared_session_closed(LocalAgentRuntimeBridge *runtime, const char *request_json);
char *local_agent_runtime_bridge_list_agent_profiles(
    LocalAgentRuntimeBridge *runtime,
    const char *request_json
);
char *local_agent_runtime_bridge_build_agent(
    LocalAgentRuntimeBridge *runtime,
    const char *request_json
);
char *local_agent_runtime_bridge_build_agent_v2(
    LocalAgentRuntimeBridge *runtime,
    const char *request_json
);
char *local_agent_runtime_bridge_preview_context(
    LocalAgentRuntimeBridge *runtime,
    const char *request_json
);
char *local_agent_runtime_bridge_prepare_user_turn(
    LocalAgentRuntimeBridge *runtime,
    const char *request_json
);
char *local_agent_runtime_bridge_observe_events(
    LocalAgentRuntimeBridge *runtime,
    const char *request_json
);
char *local_agent_runtime_bridge_observe_events_streaming(
    LocalAgentRuntimeBridge *runtime,
    const char *request_json,
    LocalAgentRuntimeEventCallback callback,
    void *user_data
);
char *local_agent_runtime_bridge_commit_assistant_result(
    LocalAgentRuntimeBridge *runtime,
    const char *request_json
);
char *local_agent_runtime_bridge_approve_tool(
    LocalAgentRuntimeBridge *runtime,
    const char *request_json
);
char *local_agent_runtime_bridge_cancel_run(
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
