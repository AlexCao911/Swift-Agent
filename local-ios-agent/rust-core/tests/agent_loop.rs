use local_ios_agent_runtime::context::MockTokenizer;
use local_ios_agent_runtime::core::{
    AgentRuntime, AgentRuntimeConfig, AgentTurnResult, EventKind, MockStreamingProvider, RunState,
    SendMessageInput,
};

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
    });
    let session_id = runtime.create_session().unwrap();

    let result = runtime
        .send_message_turn(SendMessageInput {
            session_id,
            parent_event_id: None,
            text: "use tool debug.echo".into(),
        })
        .unwrap();

    assert_eq!(result.state, RunState::WaitingTool);
    assert!(result
        .events
        .iter()
        .any(|event| event.kind == EventKind::ToolCallRequested));
}
