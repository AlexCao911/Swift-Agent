use local_ios_agent_runtime::context::MockTokenizer;
use local_ios_agent_runtime::core::{
    AgentRuntime, AgentRuntimeConfig, AgentTurnResult, EventKind, MockStreamingProvider, RunState,
    SendMessageInput,
};
use local_ios_agent_runtime::tool::{RetentionPolicy, Sensitivity, ToolResult};

#[test]
fn turn_result_reports_waiting_tool_state() {
    let result = AgentTurnResult {
        run_id: "run_1".into(),
        state: RunState::WaitingTool,
        events: Vec::new(),
        pending_tool_call_id: Some("call_1".into()),
    };

    assert_eq!(result.pending_tool_call_id, Some("call_1".into()));
}

#[test]
fn runtime_stops_at_tool_call_and_marks_waiting_tool() {
    let mut runtime = AgentRuntime::new(AgentRuntimeConfig {
        system_prompt: "system".into(),
        runtime_policy: "policy".into(),
        tool_schemas: vec!["debug.echo".into()],
        tokenizer: Box::new(MockTokenizer::new(100)),
        provider: Box::new(MockStreamingProvider::new()),
        tool_router: None,
    });
    let session_id = runtime.create_session().unwrap();

    let result = runtime
        .send_message_turn(SendMessageInput {
            session_id,
            parent_event_id: None,
            text: "use tool debug.echo".into(),
            blob_refs: Vec::new(),
        })
        .unwrap();

    assert_eq!(result.state, RunState::WaitingTool);
    assert!(result
        .events
        .iter()
        .any(|event| event.kind == EventKind::ToolCallRequested));
}

#[test]
fn runtime_resumes_from_tool_result_and_completes() {
    let mut runtime = AgentRuntime::new(AgentRuntimeConfig {
        system_prompt: "system".into(),
        runtime_policy: "policy".into(),
        tool_schemas: vec!["debug.echo".into()],
        tokenizer: Box::new(MockTokenizer::new(100)),
        provider: Box::new(MockStreamingProvider::new()),
        tool_router: None,
    });
    let session_id = runtime.create_session().unwrap();
    let turn = runtime
        .send_message_turn(SendMessageInput {
            session_id: session_id.clone(),
            parent_event_id: None,
            text: "use tool debug.echo".into(),
            blob_refs: Vec::new(),
        })
        .unwrap();

    let resumed = runtime
        .submit_tool_result(
            turn.run_id.clone(),
            ToolResult {
                display_text: "echoed".into(),
                model_text: "tool said hello".into(),
                structured_json: "{}".into(),
                audit_text: "audit".into(),
                sensitivity: Sensitivity::Public,
                retention: RetentionPolicy::RunOnly,
                provenance: "tool.test".into(),
                is_error: false,
            },
        )
        .unwrap();

    assert_eq!(resumed.state, RunState::Completed);
    assert!(resumed
        .events
        .iter()
        .any(|event| event.kind == EventKind::ToolResultMessage));
    assert!(resumed
        .events
        .iter()
        .any(|event| event.kind == EventKind::AssistantMessageCompleted));
}

#[test]
fn runtime_cancel_appends_run_cancelled() {
    let mut runtime = AgentRuntime::new(AgentRuntimeConfig {
        system_prompt: "system".into(),
        runtime_policy: "policy".into(),
        tool_schemas: vec!["debug.echo".into()],
        tokenizer: Box::new(MockTokenizer::new(100)),
        provider: Box::new(MockStreamingProvider::new()),
        tool_router: None,
    });
    let session_id = runtime.create_session().unwrap();
    let turn = runtime
        .send_message_turn(SendMessageInput {
            session_id,
            parent_event_id: None,
            text: "use tool debug.echo".into(),
            blob_refs: Vec::new(),
        })
        .unwrap();

    let event = runtime.cancel(turn.run_id).unwrap();

    assert_eq!(event.kind, EventKind::RunCancelled);
}
