use local_ios_agent_runtime::core::{AgentError, RunId, RunRecord, RunState, SessionId};

#[test]
fn run_record_moves_through_waiting_and_completed() {
    let mut run = RunRecord::new(RunId("run_1".into()), SessionId("session_1".into()));

    run.mark_waiting_tool().unwrap();
    assert_eq!(run.state, RunState::WaitingTool);

    run.mark_running().unwrap();
    run.mark_completed().unwrap();
    assert_eq!(run.state, RunState::Completed);
}

#[test]
fn terminal_run_rejects_later_cancellation() {
    let mut run = RunRecord::new(RunId("run_1".into()), SessionId("session_1".into()));
    run.mark_completed().unwrap();

    let error = run.cancel().unwrap_err();

    assert!(matches!(error, AgentError::Cancelled(_)));
}
