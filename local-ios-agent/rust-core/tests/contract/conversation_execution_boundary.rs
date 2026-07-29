use std::sync::Arc;

use local_ios_agent_runtime::context::ModelInputRole;
use local_ios_agent_runtime::conversation::{
    AttachmentRef, ConversationCommitService, ConversationFrameId, ConversationFrameMessage,
    ConversationFrameRepository, ConversationLineage, ConversationRunFrame,
    ConversationRunFrameRef, InMemoryConversationFrameRepository,
};
use local_ios_agent_runtime::core::{EntryId, SessionId};
use local_ios_agent_runtime::execution::{
    CompletedRunRecord, CompletedRunRegistry, ExecutionContextInputAssembler, ExecutionEventLog,
    ExecutionService, RunLifecycleService,
};
use local_ios_agent_runtime::storage::agent_os_state::SharedAgentOSStateStore;

fn frame_ref(id: &str) -> ConversationRunFrameRef {
    ConversationRunFrameRef::new(
        ConversationFrameId::new(id),
        SessionId("session_1".into()),
        EntryId("branch_head_1".into()),
        EntryId("user_turn_1".into()),
    )
}

fn frame(reference: ConversationRunFrameRef) -> ConversationRunFrame {
    ConversationRunFrame::new(
        reference,
        None,
        vec![ConversationFrameMessage::user(
            EntryId("user_turn_1".into()),
            "hello",
        )],
        vec![AttachmentRef::new("attachment_1")],
        ConversationLineage::new(EntryId("branch_head_1".into()), None, None),
    )
}

#[test]
fn conversation_run_frame_ref_pins_branch_and_user_turn() {
    let reference = frame_ref("frame_1");

    assert_eq!(reference.frame_id().as_str(), "frame_1");
    assert_eq!(reference.session_id().0, "session_1");
    assert_eq!(reference.branch_head_id().0, "branch_head_1");
    assert_eq!(reference.user_turn_id().0, "user_turn_1");
}

#[test]
fn frame_repository_rejects_tampered_identity() {
    let repository = InMemoryConversationFrameRepository::default();
    let reference = frame_ref("frame_1");
    repository.put(frame(reference.clone()));
    let tampered = ConversationRunFrameRef::new(
        ConversationFrameId::new("frame_1"),
        SessionId("other_session".into()),
        EntryId("branch_head_1".into()),
        EntryId("user_turn_1".into()),
    );

    assert!(repository.get(&reference).is_some());
    assert!(repository.get(&tampered).is_none());
}

#[test]
fn execution_events_replay_then_tail_live_events() {
    let log = ExecutionEventLog::default();
    let lifecycle = RunLifecycleService::new(log.clone());
    let handle = lifecycle.start_run("run_1");
    let mut stream = log.subscribe("run_1", handle.replay_from_sequence());
    log.append("run_1", "assistant.delta");

    assert_eq!(stream.next_live().unwrap().code(), "assistant.delta");
}

#[test]
fn context_assembler_uses_only_the_pinned_conversation_frame() {
    let reference = frame_ref("frame_context");
    let input = ExecutionContextInputAssembler::new()
        .assemble_initial(&frame(reference))
        .unwrap();

    assert!(input.messages().iter().any(|message| {
        message.role() == ModelInputRole::User && message.content() == "hello"
    }));
    assert!(!input
        .messages()
        .iter()
        .any(|message| message.role() == ModelInputRole::System));
}

#[test]
fn assistant_commit_is_idempotent() {
    let completed = CompletedRunRegistry::default();
    let service = ConversationCommitService::new(completed.clone());
    let reference = frame_ref("frame_commit");
    completed.record_completed("run_1", "final_1", reference.clone());

    let first = service
        .commit_assistant_result("run_1", "final_1", &reference)
        .unwrap();
    let second = service
        .commit_assistant_result("run_1", "final_1", &reference)
        .unwrap();

    assert_eq!(first.assistant_message_id(), second.assistant_message_id());
    assert_eq!(service.commit_count(), 1);
}

#[test]
fn assistant_commit_recovers_durable_completion_after_restart() {
    let reference = frame_ref("frame_commit");
    let recovered = reference.clone();
    let service = ConversationCommitService::with_recovery(
        CompletedRunRegistry::default(),
        Arc::new(move |run_id, message_id| {
            Ok(Some(CompletedRunRecord::restored(
                run_id,
                message_id,
                recovered.clone(),
                "persisted answer",
            )))
        }),
    );

    let result = service
        .commit_assistant_result_with_persist(
            "run_1",
            "assistant:run_1:turn_1",
            &reference,
            |_| Ok("assistant.persisted".into()),
        )
        .unwrap();

    assert_eq!(result.assistant_message_id(), "assistant.persisted");
}

#[test]
fn host_completion_has_one_terminal_authority() {
    let log = ExecutionEventLog::default();
    let completed = CompletedRunRegistry::default();
    let service = ExecutionService::with_agent_os_state(
        log.clone(),
        completed.clone(),
        SharedAgentOSStateStore::in_memory(),
        "epoch-test",
    );
    let reference = frame_ref("frame_host");
    log.append_with_payload(
        "run-host",
        "run.completed",
        r#"{"message_id":"assistant:run-host:turn-1"}"#,
    );

    service
        .record_external_completed(
            "run-host",
            reference,
            "event-1",
            "assistant:run-host:turn-1",
            "answer",
            "stop",
        )
        .unwrap();

    assert_eq!(
        log.replay("run-host", None)
            .iter()
            .filter(|event| event.code() == "run.completed")
            .count(),
        1
    );
    assert!(completed
        .get("run-host", "assistant:run-host:turn-1")
        .is_some());
}
