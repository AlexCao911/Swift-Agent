use local_ios_agent_runtime::context::MockTokenizer;
use local_ios_agent_runtime::conversation::{ConversationFrameId, ConversationRunFrameRef};
use local_ios_agent_runtime::core::{
    AgentRuntime, AgentRuntimeConfig, EntryId, MockStreamingProvider, SendMessageInput, SessionId,
};
use local_ios_agent_runtime::execution::ExecutionPlanner;
use local_ios_agent_runtime::run_snapshot::{RunSnapshotService, StartRunRequest};
use local_ios_agent_runtime::runtime::{RecordingEffectDriver, RunMachine, RunState};

fn frame_ref_fixture() -> ConversationRunFrameRef {
    ConversationRunFrameRef::new(
        ConversationFrameId::new("frame_1"),
        SessionId("session_1".into()),
        EntryId("branch_head_1".into()),
        EntryId("user_turn_1".into()),
    )
}

#[test]
fn resolved_snapshot_plans_and_executes_without_profile_or_package_state() {
    let snapshot = RunSnapshotService::fixture()
        .resolve_and_persist(StartRunRequest::new(
            "profile_1",
            "integration hello",
            frame_ref_fixture(),
        ))
        .unwrap();
    let plan = ExecutionPlanner::default().plan(snapshot).unwrap();

    let driver = RecordingEffectDriver::default();
    let mut machine = RunMachine::from_plan_with_effect_driver(plan, driver.clone());
    machine.run_to_completion().unwrap();

    assert_eq!(machine.state(), RunState::Completed);
    assert_eq!(machine.source_snapshot_id().as_u64(), 1);
    assert!(driver
        .recorded_calls()
        .iter()
        .any(|call| call.kind().operation() == "inference.generate"));
    assert_order(
        &machine.event_codes(),
        &[
            "run.started",
            "model_call.started",
            "model_call.completed",
            "checkpoint.committed",
        ],
    );
}

#[test]
fn core_runtime_public_plan_entry_delegates_to_run_machine() {
    let snapshot = RunSnapshotService::fixture()
        .resolve_and_persist(StartRunRequest::new(
            "profile_1",
            "core runtime plan entry",
            frame_ref_fixture(),
        ))
        .unwrap();
    let plan = ExecutionPlanner::default().plan(snapshot).unwrap();
    let driver = RecordingEffectDriver::default();
    let mut runtime = AgentRuntime::new(AgentRuntimeConfig {
        system_prompt: "system".to_string(),
        runtime_policy: "policy".to_string(),
        tool_schemas: Vec::new(),
        tokenizer: Box::new(MockTokenizer::new(100)),
        provider: Box::new(MockStreamingProvider::new()),
        tool_router: None,
    });

    runtime.execute_plan(plan, driver.clone()).unwrap();

    let trace = runtime.latest_runtime_execution_trace().unwrap();
    assert_eq!(trace.state(), "completed");
    assert_eq!(
        trace.event_codes(),
        vec![
            "run.started".to_string(),
            "context.assembled".to_string(),
            "prompt_archive.appended".to_string(),
            "context_archive.appended".to_string(),
            "model_call.started".to_string(),
            "model_call.completed".to_string(),
            "checkpoint.committed".to_string(),
        ]
    );
    assert!(driver
        .recorded_calls()
        .iter()
        .any(|call| call.kind().operation() == "inference.generate"));
}

#[test]
fn legacy_send_message_without_resolved_plan_does_not_mint_agent_os_execution_trace() {
    let mut runtime = AgentRuntime::new(AgentRuntimeConfig {
        system_prompt: "system".to_string(),
        runtime_policy: "policy".to_string(),
        tool_schemas: Vec::new(),
        tokenizer: Box::new(MockTokenizer::new(100)),
        provider: Box::new(MockStreamingProvider::new()),
        tool_router: None,
    });
    let session_id = runtime.create_session().unwrap();

    runtime
        .send_message_turn(SendMessageInput {
            session_id,
            parent_event_id: None,
            text: "hello runtime execution".to_string(),
            blob_refs: Vec::new(),
        })
        .unwrap();

    assert_eq!(runtime.latest_runtime_execution_trace(), None);
}

fn assert_order(events: &[String], expected: &[&str]) {
    let positions = expected
        .iter()
        .map(|expected| {
            events
                .iter()
                .position(|event| event == expected)
                .unwrap_or_else(|| panic!("missing event {expected} in {events:?}"))
        })
        .collect::<Vec<_>>();
    assert!(
        positions.windows(2).all(|pair| pair[0] < pair[1]),
        "events not ordered as expected: {events:?}"
    );
}
