use std::sync::{Arc, Mutex};

use local_ios_agent_runtime::context::{BranchProjector, ModelContextWindow, PromptMessage};
use local_ios_agent_runtime::conversation::{
    ConversationCommandService, PromptDocumentSnapshot, RunStartSnapshot, SkillDescriptor,
    ToolDefinitionSnapshot, TranscriptCommand, TranscriptCommandError,
};
use local_ios_agent_runtime::core::{EntryId, EventKind, RuntimeEvent, SessionId};
use local_ios_agent_runtime::storage::{
    ConversationEventStore, InMemoryConversationStore, SqliteConversationStore,
};
use serde_json::json;

fn snapshot() -> RunStartSnapshot {
    RunStartSnapshot::make(
        vec![PromptDocumentSnapshot {
            id: "base".into(),
            source: "user".into(),
            markdown: "Be useful.".into(),
        }],
        vec![SkillDescriptor {
            id: "files".into(),
            name: "Files".into(),
            description: "Read files when relevant.".into(),
            location: "/var/localagent/skills/files/SKILL.md".into(),
            enabled: true,
        }],
        vec![ToolDefinitionSnapshot {
            name: "file_read".into(),
            description: "Read a file.".into(),
            input_schema: json!({"type": "object"}),
        }],
        ModelContextWindow {
            context_window_tokens: 8_192,
            max_output_tokens: 1_024,
        },
    )
    .unwrap()
}

fn send(stream: &str, request: &str, text: &str) -> TranscriptCommand {
    TranscriptCommand::Send {
        request_id: request.into(),
        conversation_stream_id: stream.into(),
        client_message_id: format!("{request}-message"),
        text: text.into(),
        attachments: Vec::new(),
        run_start_snapshot: snapshot(),
    }
}

fn transcript_event(
    stream: &str,
    id: &str,
    parent_id: Option<&str>,
    depth: u32,
    kind: EventKind,
    payload: &str,
) -> RuntimeEvent {
    RuntimeEvent::new(
        EntryId(id.into()),
        SessionId(stream.into()),
        parent_id.map(|parent| EntryId(parent.into())),
        None,
        0,
        depth,
        kind,
        payload,
    )
}

#[test]
fn identical_request_returns_first_result_and_writes_once() {
    let store = Arc::new(Mutex::new(InMemoryConversationStore::new()));
    let service = ConversationCommandService::new(store.clone());

    let first = service
        .submit(send("conversation-a", "request-1", "hello"))
        .unwrap();
    let replay = service
        .submit(send("conversation-a", "request-1", "hello"))
        .unwrap();

    assert_eq!(replay, first);
    assert!(first.run_id.is_some());
    let events = store
        .lock()
        .unwrap()
        .events_after(&SessionId("conversation-a".into()), 0)
        .unwrap();
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].kind, EventKind::UserMessage);
}

#[test]
fn changed_payload_for_same_request_is_an_idempotency_conflict() {
    let store = Arc::new(Mutex::new(InMemoryConversationStore::new()));
    let service = ConversationCommandService::new(store);
    service
        .submit(send("conversation-a", "request-1", "hello"))
        .unwrap();

    let error = service
        .submit(send("conversation-a", "request-1", "changed"))
        .unwrap_err();

    assert_eq!(
        error,
        TranscriptCommandError::idempotency_conflict("conversation-a", "request-1")
    );
}

#[test]
fn invalid_run_snapshot_is_rejected_before_canonical_write() {
    let store = Arc::new(Mutex::new(InMemoryConversationStore::new()));
    let service = ConversationCommandService::new(store.clone());
    let mut command = send("conversation-a", "request-invalid", "hello");
    if let TranscriptCommand::Send {
        run_start_snapshot, ..
    } = &mut command
    {
        run_start_snapshot.snapshot_digest = "0".repeat(64);
    }

    let error = service.submit(command).unwrap_err();

    assert_eq!(error.code(), "run_start_snapshot.digest_mismatch");
    assert!(store
        .lock()
        .unwrap()
        .events_after(&SessionId("conversation-a".into()), 0)
        .unwrap()
        .is_empty());
}

#[test]
fn active_run_guard_is_per_conversation_and_busy_is_idempotent() {
    let store = Arc::new(Mutex::new(InMemoryConversationStore::new()));
    let service = ConversationCommandService::new(store);
    let first = service
        .submit(send("conversation-a", "request-1", "first"))
        .unwrap();

    let busy_command = send("conversation-a", "request-2", "second");
    let busy = service.submit(busy_command.clone()).unwrap_err();
    assert_eq!(busy.code(), "conversation_busy");
    assert_eq!(service.submit(busy_command).unwrap_err(), busy);

    let other = service
        .submit(send("conversation-b", "request-1", "parallel"))
        .unwrap();
    assert!(other.run_id.is_some());

    service
        .complete_run("conversation-a", first.run_id.as_deref().unwrap())
        .unwrap();
    let resumed = service
        .submit(send("conversation-a", "request-3", "after"))
        .unwrap();
    assert!(resumed.run_id.is_some());
}

#[test]
fn transcript_mutations_are_append_only_events() {
    let store = Arc::new(Mutex::new(InMemoryConversationStore::new()));
    store
        .lock()
        .unwrap()
        .append_transaction(
            "conversation-a",
            1,
            vec![transcript_event(
                "conversation-a",
                "old-message",
                None,
                0,
                EventKind::UserMessage,
                "old",
            )],
        )
        .unwrap();
    let service = ConversationCommandService::new(store.clone());

    let commands = [
        TranscriptCommand::DeleteMessage {
            request_id: "delete-message".into(),
            conversation_stream_id: "conversation-a".into(),
            target_event_id: "old-message".into(),
        },
        TranscriptCommand::ClearConversation {
            request_id: "clear".into(),
            conversation_stream_id: "conversation-a".into(),
        },
        TranscriptCommand::CreateBranch {
            request_id: "branch".into(),
            conversation_stream_id: "conversation-a".into(),
            anchor_event_id: "old-message".into(),
            new_conversation_stream_id: "conversation-b".into(),
        },
        TranscriptCommand::ArchiveConversation {
            request_id: "archive".into(),
            conversation_stream_id: "conversation-a".into(),
        },
        TranscriptCommand::DeleteConversation {
            request_id: "delete-conversation".into(),
            conversation_stream_id: "conversation-a".into(),
        },
    ];

    for command in commands {
        service.submit(command).unwrap();
    }

    let events = store
        .lock()
        .unwrap()
        .events_after(&SessionId("conversation-a".into()), 0)
        .unwrap();
    assert_eq!(
        events[1..]
            .iter()
            .map(|event| &event.kind)
            .collect::<Vec<_>>(),
        vec![
            &EventKind::MessageDeleted,
            &EventKind::ConversationCleared,
            &EventKind::BranchCreated,
            &EventKind::ConversationArchived,
            &EventKind::ConversationDeleted,
        ]
    );
    assert_eq!(
        events[1..]
            .iter()
            .map(|event| event.sequence)
            .collect::<Vec<_>>(),
        vec![2, 3, 4, 5, 6]
    );
}

#[test]
fn unknown_mutation_target_is_rejected_without_a_canonical_write() {
    let store = Arc::new(Mutex::new(InMemoryConversationStore::new()));
    let service = ConversationCommandService::new(store.clone());

    let error = service
        .submit(TranscriptCommand::DeleteMessage {
            request_id: "delete-missing".into(),
            conversation_stream_id: "conversation-a".into(),
            target_event_id: "missing".into(),
        })
        .unwrap_err();

    assert_eq!(error.code(), "conversation.target_not_found");
    assert!(store
        .lock()
        .unwrap()
        .events_after(&SessionId("conversation-a".into()), 0)
        .unwrap()
        .is_empty());
}

#[test]
fn retry_rejects_an_assistant_anchor_instead_of_replaying_the_old_answer() {
    let store = Arc::new(Mutex::new(InMemoryConversationStore::new()));
    store
        .lock()
        .unwrap()
        .append_transaction(
            "conversation-a",
            1,
            vec![
                transcript_event(
                    "conversation-a",
                    "user-1",
                    None,
                    0,
                    EventKind::UserMessage,
                    "question",
                ),
                transcript_event(
                    "conversation-a",
                    "assistant-1",
                    Some("user-1"),
                    1,
                    EventKind::AssistantMessageCompleted,
                    "old answer",
                ),
            ],
        )
        .unwrap();
    let service = ConversationCommandService::new(store);

    let error = service
        .submit(TranscriptCommand::RetryFrom {
            request_id: "retry".into(),
            conversation_stream_id: "conversation-a".into(),
            anchor_event_id: "assistant-1".into(),
            run_start_snapshot: snapshot(),
        })
        .unwrap_err();

    assert_eq!(error.code(), "conversation.retry_anchor_not_user");
}

#[test]
fn create_branch_materializes_source_history_through_the_anchor() {
    let store = Arc::new(Mutex::new(InMemoryConversationStore::new()));
    store
        .lock()
        .unwrap()
        .append_transaction(
            "conversation-a",
            1,
            vec![
                transcript_event(
                    "conversation-a",
                    "user-1",
                    None,
                    0,
                    EventKind::UserMessage,
                    "first",
                ),
                transcript_event(
                    "conversation-a",
                    "assistant-1",
                    Some("user-1"),
                    1,
                    EventKind::AssistantMessageCompleted,
                    "first answer",
                ),
                transcript_event(
                    "conversation-a",
                    "user-2",
                    Some("assistant-1"),
                    2,
                    EventKind::UserMessage,
                    "not copied",
                ),
            ],
        )
        .unwrap();
    let service = ConversationCommandService::new(store.clone());

    service
        .submit(TranscriptCommand::CreateBranch {
            request_id: "branch".into(),
            conversation_stream_id: "conversation-a".into(),
            anchor_event_id: "assistant-1".into(),
            new_conversation_stream_id: "conversation-b".into(),
        })
        .unwrap();

    let target_events = store
        .lock()
        .unwrap()
        .events_after(&SessionId("conversation-b".into()), 0)
        .unwrap();
    assert_eq!(
        BranchProjector::new().project(target_events),
        vec![
            PromptMessage::User("first".into()),
            PromptMessage::Assistant("first answer".into()),
        ]
    );
}

#[test]
fn sqlite_receipt_replays_after_relaunch_without_duplicate_event() {
    let tempdir = tempfile::tempdir().unwrap();
    let path = tempdir.path().join("conversation.sqlite");
    let command = TranscriptCommand::ArchiveConversation {
        request_id: "archive".into(),
        conversation_stream_id: "conversation-a".into(),
    };
    let first = {
        let store = Arc::new(Mutex::new(SqliteConversationStore::open(&path).unwrap()));
        ConversationCommandService::new(store)
            .submit(command.clone())
            .unwrap()
    };
    let reopened = Arc::new(Mutex::new(SqliteConversationStore::open(&path).unwrap()));
    let replay = ConversationCommandService::new(reopened.clone())
        .submit(command)
        .unwrap();

    assert_eq!(replay, first);
    assert_eq!(
        reopened
            .lock()
            .unwrap()
            .events_after(&SessionId("conversation-a".into()), 0)
            .unwrap()
            .len(),
        1
    );
}
