use local_ios_agent_runtime::conversation::{ConversationFrameId, ConversationRunFrameRef};
use local_ios_agent_runtime::core::{EntryId, SessionId};
use local_ios_agent_runtime::execution::ExecutionPlanner;
use local_ios_agent_runtime::run_snapshot::{RunSnapshotService, StartRunRequest};
use local_ios_agent_runtime::runtime::{RecordingEffectDriver, RunMachine};
use local_ios_agent_runtime::user_customization::AgentProfileVersion;

fn frame_ref_fixture() -> ConversationRunFrameRef {
    ConversationRunFrameRef::new(
        ConversationFrameId::new("frame_1"),
        SessionId("session_1".into()),
        EntryId("branch_head_1".into()),
        EntryId("user_turn_1".into()),
    )
}

#[test]
fn runtime_execution_trace_matches_golden_fixture() {
    let snapshot = RunSnapshotService::fixture()
        .resolve_and_persist(StartRunRequest::new(
            "profile_1",
            AgentProfileVersion::initial(),
            "golden runtime",
            frame_ref_fixture(),
        ))
        .unwrap();
    let plan = ExecutionPlanner::default().plan(snapshot).unwrap();
    let mut machine =
        RunMachine::from_plan_with_effect_driver(plan, RecordingEffectDriver::default());
    machine.run_to_completion().unwrap();

    let actual = serde_json::to_string_pretty(&machine.debug_trace()).unwrap() + "\n";

    assert_eq!(
        actual,
        include_str!("../fixtures/golden/runtime/runtime_execution_trace.json")
    );
}
