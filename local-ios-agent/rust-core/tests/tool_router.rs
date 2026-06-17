use local_ios_agent_runtime::core::{EntryId, RunId, SessionId};
use local_ios_agent_runtime::tool::{ToolCall, ToolExecutionRequest};

#[test]
fn execution_request_carries_swift_boundary_payload() {
    let request = ToolExecutionRequest::new(
        RunId("run_1".into()),
        SessionId("session_1".into()),
        EntryId("entry_1".into()),
        ToolCall {
            id: "call_1".into(),
            name: "calendar.search_events".into(),
            arguments_json: "{}".into(),
        },
    );

    assert_eq!(request.tool_name, "calendar.search_events");
    assert_eq!(request.arguments_json, "{}");
}
