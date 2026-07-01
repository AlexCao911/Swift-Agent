use local_ios_agent_runtime::execution::ExecutionPlanner;
use local_ios_agent_runtime::run_snapshot::{RunSnapshotService, StartRunRequest};
use local_ios_agent_runtime::runtime::{RecordingEffectDriver, RunMachine};

#[test]
fn runtime_execution_trace_matches_golden_fixture() {
    let snapshot = RunSnapshotService::fixture()
        .resolve_and_persist(StartRunRequest::new("profile_1", "golden runtime"))
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
