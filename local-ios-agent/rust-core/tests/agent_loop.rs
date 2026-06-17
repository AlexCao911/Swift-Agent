use local_ios_agent_runtime::core::{AgentTurnResult, RunState};

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
