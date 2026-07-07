use local_ios_agent_runtime::conversation::{ConversationFrameId, ConversationRunFrameRef};
use local_ios_agent_runtime::core::{EntryId, SessionId};
use local_ios_agent_runtime::execution::{
    ExecutionBudgets, ExecutionPlan, ExecutionPlanner, ExecutionStep,
};
use local_ios_agent_runtime::run_snapshot::{
    ResolvedRunSnapshot, RunSnapshotService, StartRunRequest,
};
use local_ios_agent_runtime::runtime::{
    EffectKind, RecordingEffectDriver, RunMachine, RunMachinePersistence, RunState,
};
use local_ios_agent_runtime::security::PermissionState;
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
fn planner_accepts_resolved_snapshot_not_agent_profile() {
    let snapshot = resolved_snapshot_fixture();

    let plan = ExecutionPlanner::default().plan(snapshot).unwrap();

    assert_eq!(plan.steps()[0].kind().as_str(), "context.assemble");
    assert_eq!(plan.steps()[1].kind().as_str(), "inference.generate");
    assert_eq!(plan.budgets().max_model_input_tokens(), 4096);
    assert!(plan.trace_config().capture_context_archive());
    assert_eq!(plan.snapshot_id().as_u64(), 1);
}

#[test]
fn planner_rejects_unready_snapshot_before_runtime_can_start() {
    let snapshot = RunSnapshotService::fixture_with_permission_state(PermissionState::Denied)
        .preview(StartRunRequest::new(
            "profile_1",
            AgentProfileVersion::initial(),
            "hello runtime",
            frame_ref_fixture(),
        ))
        .unwrap()
        .snapshot()
        .clone();

    let error = ExecutionPlanner::default().plan(snapshot).unwrap_err();

    assert_eq!(error.code(), "execution.snapshot_not_ready");
}

#[test]
fn completed_run_rejects_resume_transition() {
    let mut machine = RunMachine::fixture_completed();

    let error = machine.resume_from_last_checkpoint().unwrap_err();

    assert_eq!(machine.state(), RunState::Completed);
    assert_eq!(error.code(), "run.transition.invalid");
}

#[test]
fn model_call_splits_pre_call_and_post_call_transactions() {
    let mut machine = RunMachine::fixture_with_fake_inference();

    machine.run_to_completion().unwrap();

    let events = machine.event_codes();
    assert_order(
        &events,
        &[
            "run.started",
            "model_call.started",
            "model_call.completed",
            "checkpoint.committed",
        ],
    );
    assert_eq!(
        machine.transaction_event_codes("model_call.pre_call"),
        vec![
            "prompt_archive.appended".to_string(),
            "context_archive.appended".to_string(),
            "model_call.started".to_string(),
        ]
    );
    assert_eq!(
        machine.transaction_event_codes("model_call.post_call"),
        vec!["model_call.completed".to_string()]
    );
    assert!(!machine.fake_inference_observed_open_transaction());
}

#[test]
fn run_machine_consumes_execution_plan_steps_instead_of_hard_coding_model_call() {
    let plan = ExecutionPlan::for_snapshot(resolved_snapshot_fixture().snapshot_id())
        .with_steps(vec![ExecutionStep::new("context.assemble")])
        .without_archive_capture();
    let mut machine = RunMachine::from_plan(plan);

    machine.run_to_completion().unwrap();

    let events = machine.event_codes();
    assert!(events.contains(&"context.assembled".to_string()));
    assert!(!events.contains(&"model_call.started".to_string()));
    assert!(!events.contains(&"model_call.completed".to_string()));
}

#[test]
fn trace_config_controls_prompt_and_context_archive_writes() {
    let plan = ExecutionPlan::for_snapshot(resolved_snapshot_fixture().snapshot_id())
        .with_steps(vec![
            ExecutionStep::new("context.assemble"),
            ExecutionStep::new("inference.generate"),
        ])
        .without_archive_capture();
    let mut machine =
        RunMachine::from_plan_with_effect_driver(plan, RecordingEffectDriver::default());

    machine.run_to_completion().unwrap();

    assert!(machine.archive_records().is_empty());
    assert!(!machine
        .event_codes()
        .contains(&"prompt_archive.appended".to_string()));
    assert!(!machine
        .event_codes()
        .contains(&"context_archive.appended".to_string()));
}

#[test]
fn production_execution_plan_requires_inference_effect_driver() {
    let plan = ExecutionPlanner::default()
        .plan(resolved_snapshot_fixture())
        .unwrap();
    let mut machine = RunMachine::from_plan(plan);

    let error = machine.run_to_completion().unwrap_err();

    assert_eq!(error.code(), "effect.driver_missing");
    assert!(!machine
        .event_codes()
        .contains(&"model_call.completed".to_string()));
}

#[test]
fn run_machine_applies_execution_plan_budget_before_model_call() {
    let plan = ExecutionPlan::for_snapshot(resolved_snapshot_fixture().snapshot_id())
        .with_budgets(ExecutionBudgets::new(0));
    let mut machine = RunMachine::from_plan(plan);

    let error = machine.run_to_completion().unwrap_err();

    assert_eq!(error.code(), "execution.budget_exceeded");
    assert!(!machine
        .event_codes()
        .contains(&"model_call.started".to_string()));
}

#[test]
fn model_call_can_finish_awaiting_tool_without_marking_run_completed() {
    let mut machine = RunMachine::fixture_with_fake_inference();

    machine
        .record_model_call_started("prompt", "context")
        .unwrap();
    machine.record_model_call_awaiting_tool().unwrap();

    assert_eq!(machine.state(), RunState::AwaitingTool);
    assert_eq!(machine.debug_trace().state(), "awaiting_tool");
    assert!(machine
        .event_codes()
        .contains(&"model_call.completed".to_string()));
    assert!(machine
        .event_codes()
        .contains(&"checkpoint.committed".to_string()));
}

#[test]
fn model_call_can_finish_awaiting_approval_without_marking_run_completed() {
    let mut machine = RunMachine::fixture_with_fake_inference();

    machine
        .record_model_call_started("prompt", "context")
        .unwrap();
    machine.record_model_call_awaiting_approval().unwrap();

    assert_eq!(machine.state(), RunState::AwaitingApproval);
    assert_eq!(machine.debug_trace().state(), "awaiting_approval");
    assert!(machine
        .event_codes()
        .contains(&"model_call.completed".to_string()));
    assert!(machine
        .event_codes()
        .contains(&"checkpoint.committed".to_string()));
}

#[test]
fn pre_call_transaction_persists_prompt_and_context_archive_records() {
    let plan = ExecutionPlanner::default()
        .plan(resolved_snapshot_fixture())
        .unwrap();
    let mut machine =
        RunMachine::from_plan_with_effect_driver(plan, RecordingEffectDriver::default());

    machine.run_to_completion().unwrap();

    let archives = machine.archive_records();
    let archive_kinds = archives
        .iter()
        .map(|record| record.kind().to_string())
        .collect::<Vec<_>>();
    assert_eq!(
        archive_kinds,
        vec!["prompt".to_string(), "context".to_string()]
    );
    assert!(archives.iter().all(|record| !record.payload().is_empty()));
}

#[test]
fn inference_generation_uses_injected_effect_driver() {
    let driver = RecordingEffectDriver::default();
    let plan = ExecutionPlanner::default()
        .plan(resolved_snapshot_fixture())
        .unwrap();
    let mut machine = RunMachine::from_plan_with_effect_driver(plan, driver.clone());

    machine.run_to_completion().unwrap();

    assert!(driver
        .recorded_calls()
        .iter()
        .any(|call| call.kind() == &EffectKind::InferenceGenerate));
}

#[test]
fn effect_contract_covers_tool_inference_approval_and_memory_side_effects() {
    assert_eq!(EffectKind::ToolInvoke.operation(), "tool.invoke");
    assert_eq!(
        EffectKind::InferenceGenerate.operation(),
        "inference.generate"
    );
    assert_eq!(EffectKind::ApprovalRequest.operation(), "approval.request");
    assert_eq!(EffectKind::MemoryWrite.operation(), "memory.write");
}

#[test]
fn effect_driver_receives_idempotency_key_and_trace_span() {
    let driver = RecordingEffectDriver::default();
    let mut machine = RunMachine::fixture_with_effect_driver(driver.clone());

    machine.run_next_effect().unwrap();

    let call = driver.recorded_calls()[0].clone();
    assert_eq!(call.idempotency_key().as_str(), "run_1:effect_1");
    assert_eq!(call.trace_span().operation(), "tool.invoke");
    assert!(machine
        .event_codes()
        .contains(&"effect.started".to_string()));
    assert!(machine
        .event_codes()
        .contains(&"effect.completed".to_string()));
}

#[test]
fn completed_effect_idempotency_survives_new_run_machine_instance() {
    let persistence = RunMachinePersistence::default();
    let driver = RecordingEffectDriver::default();
    let mut first =
        RunMachine::fixture_with_effect_driver_and_persistence(driver.clone(), persistence.clone());
    first.run_next_effect().unwrap();

    let mut recovered =
        RunMachine::fixture_with_effect_driver_and_persistence(driver.clone(), persistence);
    recovered.run_next_effect().unwrap();

    assert_eq!(driver.recorded_calls().len(), 1);
    assert!(recovered
        .event_codes()
        .contains(&"effect.idempotent_replay".to_string()));
}

#[test]
fn completed_effect_idempotency_survives_reloaded_persistence_snapshot() {
    let persistence = RunMachinePersistence::default();
    let driver = RecordingEffectDriver::default();
    let mut first =
        RunMachine::fixture_with_effect_driver_and_persistence(driver.clone(), persistence.clone());
    first.run_next_effect().unwrap();

    let reloaded_persistence = RunMachinePersistence::from_snapshot(persistence.export_snapshot());
    let mut recovered = RunMachine::fixture_with_effect_driver_and_persistence(
        driver.clone(),
        reloaded_persistence,
    );
    recovered.run_next_effect().unwrap();

    assert_eq!(driver.recorded_calls().len(), 1);
    assert!(recovered
        .event_codes()
        .contains(&"effect.idempotent_replay".to_string()));
}

#[test]
fn checkpoint_survives_new_run_machine_instance() {
    let persistence = RunMachinePersistence::default();
    let driver = RecordingEffectDriver::failing_with_code("tool.timeout");
    let mut first =
        RunMachine::fixture_with_effect_driver_and_persistence(driver, persistence.clone());
    first.run_next_effect().unwrap_err();

    let recovered = RunMachine::fixture_with_persistence(persistence);

    assert_eq!(
        recovered.last_checkpoint().unwrap().checkpoint_id(),
        "checkpoint_1"
    );
    assert!(recovered.last_checkpoint().unwrap().can_resume());
}

#[test]
fn checkpoint_survives_reloaded_persistence_snapshot() {
    let persistence = RunMachinePersistence::default();
    let driver = RecordingEffectDriver::failing_with_code("tool.timeout");
    let mut first =
        RunMachine::fixture_with_effect_driver_and_persistence(driver, persistence.clone());
    first.run_next_effect().unwrap_err();

    let recovered = RunMachine::fixture_with_persistence(RunMachinePersistence::from_snapshot(
        persistence.export_snapshot(),
    ));

    assert_eq!(
        recovered.last_checkpoint().unwrap().checkpoint_id(),
        "checkpoint_1"
    );
    assert!(recovered.last_checkpoint().unwrap().can_resume());
}

#[test]
fn effect_driver_deduplicates_completed_effect_by_idempotency_key() {
    let driver = RecordingEffectDriver::default();
    let mut machine = RunMachine::fixture_with_effect_driver(driver.clone());

    machine.run_next_effect().unwrap();
    machine.run_next_effect().unwrap();

    assert_eq!(driver.recorded_calls().len(), 1);
    assert!(machine
        .event_codes()
        .contains(&"effect.idempotent_replay".to_string()));
}

#[test]
fn effect_driver_failure_records_checkpointable_runtime_event() {
    let driver = RecordingEffectDriver::failing_with_code("tool.timeout");
    let mut machine = RunMachine::fixture_with_effect_driver(driver);

    let error = machine.run_next_effect().unwrap_err();

    assert_eq!(error.code(), "tool.timeout");
    assert!(machine.event_codes().contains(&"effect.failed".to_string()));
    assert!(machine.last_checkpoint().unwrap().can_resume());
}

#[test]
fn failed_run_with_checkpoint_can_resume_to_running() {
    let driver = RecordingEffectDriver::failing_with_code("tool.timeout");
    let mut machine = RunMachine::fixture_with_effect_driver(driver);
    machine.run_next_effect().unwrap_err();

    assert_eq!(machine.state(), RunState::Failed);

    machine.resume_from_last_checkpoint().unwrap();

    assert_eq!(machine.state(), RunState::Running);
    assert!(machine
        .event_codes()
        .contains(&"checkpoint.resumed".to_string()));
}

fn resolved_snapshot_fixture() -> ResolvedRunSnapshot {
    RunSnapshotService::fixture()
        .resolve_and_persist(StartRunRequest::new(
            "profile_1",
            AgentProfileVersion::initial(),
            "hello runtime",
            frame_ref_fixture(),
        ))
        .unwrap()
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
