use std::sync::{Arc, Mutex};

use local_ios_agent_runtime::conversation::{
    ConversationCommandService, PromptDocumentSnapshot, RunStartSnapshot, SkillDescriptor,
    ToolDefinitionSnapshot, TranscriptCommand, TranscriptCommandError,
};
use local_ios_agent_runtime::core::{EventKind, SessionId};
use local_ios_agent_runtime::storage::{
    ConversationEventStore, InMemoryConversationStore, SqliteConversationStore,
};
use serde_json::json;

fn snapshot() -> RunStartSnapshot {
    RunStartSnapshot {
        ordered_prompt_documents: vec![PromptDocumentSnapshot {
            id: "base".into(),
            source: "user".into(),
            markdown: "Be useful.".into(),
        }],
        skill_descriptors: vec![SkillDescriptor {
            id: "files".into(),
            name: "Files".into(),
            description: "Read files when relevant.".into(),
            location: "/var/localagent/skills/files/SKILL.md".into(),
            enabled: true,
        }],
        ordered_tool_definitions: vec![ToolDefinitionSnapshot {
            name: "file_read".into(),
            description: "Read a file.".into(),
            input_schema: json!({"type": "object"}),
        }],
        snapshot_digest: "0".repeat(64),
    }
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
        events.iter().map(|event| &event.kind).collect::<Vec<_>>(),
        vec![
            &EventKind::MessageDeleted,
            &EventKind::ConversationCleared,
            &EventKind::BranchCreated,
            &EventKind::ConversationArchived,
            &EventKind::ConversationDeleted,
        ]
    );
    assert_eq!(
        events
            .iter()
            .map(|event| event.sequence)
            .collect::<Vec<_>>(),
        vec![1, 2, 3, 4, 5]
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
