use std::sync::{Arc, Mutex};
use std::thread;

use local_ios_agent_runtime::conversation::{
    ConversationCommandService, ObserveTranscriptProjectionsRequest, PromptDocumentSnapshot,
    RunStartSnapshot, SkillDescriptor, ToolDefinitionSnapshot, TranscriptCommand,
    TranscriptProjectionKind,
};
use local_ios_agent_runtime::storage::InMemoryConversationStore;
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
    )
    .unwrap()
}

fn send(stream: &str, request: &str) -> TranscriptCommand {
    TranscriptCommand::Send {
        request_id: request.into(),
        conversation_stream_id: stream.into(),
        client_message_id: format!("{request}-message"),
        text: request.into(),
        attachments: Vec::new(),
        run_start_snapshot: snapshot(),
    }
}

#[test]
fn replay_uses_conversation_sequence_across_runs_and_streams() {
    let store = Arc::new(Mutex::new(InMemoryConversationStore::new()));
    let service = ConversationCommandService::new(store.clone());

    let first = service.submit(send("conversation-a", "one")).unwrap();
    service
        .complete_run("conversation-a", first.run_id.as_deref().unwrap())
        .unwrap();
    service.submit(send("conversation-a", "two")).unwrap();
    service.submit(send("conversation-b", "one")).unwrap();

    let mut feed = service
        .projection_registry()
        .observe(
            store,
            ObserveTranscriptProjectionsRequest {
                subscription_id: "replay-a".into(),
                conversation_stream_id: "conversation-a".into(),
                after_sequence: 1,
            },
        )
        .unwrap();
    let event = feed.next().unwrap().unwrap();
    assert_eq!(event.sequence, 2);
    assert_eq!(event.conversation_stream_id, "conversation-a");
}

#[test]
fn non_run_terminal_commands_are_delivered_through_the_same_feed() {
    let store = Arc::new(Mutex::new(InMemoryConversationStore::new()));
    let service = ConversationCommandService::new(store.clone());
    let mut feed = service
        .projection_registry()
        .observe(
            store,
            ObserveTranscriptProjectionsRequest {
                subscription_id: "archive-feed".into(),
                conversation_stream_id: "conversation-a".into(),
                after_sequence: 0,
            },
        )
        .unwrap();

    service
        .submit(TranscriptCommand::ArchiveConversation {
            request_id: "archive".into(),
            conversation_stream_id: "conversation-a".into(),
        })
        .unwrap();

    let event = feed.next().unwrap().unwrap();
    assert_eq!(event.sequence, 1);
    assert_eq!(event.kind, TranscriptProjectionKind::ConversationArchived);
    assert!(event.run_id.is_none());
}

#[test]
fn cancelling_idle_feed_wakes_receiver_and_unregisters_listener() {
    let store = Arc::new(Mutex::new(InMemoryConversationStore::new()));
    let service = ConversationCommandService::new(store.clone());
    let registry = service.projection_registry();
    let mut feed = registry
        .observe(
            store,
            ObserveTranscriptProjectionsRequest {
                subscription_id: "idle".into(),
                conversation_stream_id: "conversation-a".into(),
                after_sequence: 0,
            },
        )
        .unwrap();

    let waiter = thread::spawn(move || feed.next().unwrap());
    registry.cancel("idle");

    assert_eq!(waiter.join().unwrap(), None);
    assert_eq!(registry.listener_count(), 0);
}

#[test]
fn cancelling_one_subscription_does_not_cancel_another() {
    let store = Arc::new(Mutex::new(InMemoryConversationStore::new()));
    let service = ConversationCommandService::new(store.clone());
    let registry = service.projection_registry();
    let first = registry
        .observe(
            store.clone(),
            ObserveTranscriptProjectionsRequest {
                subscription_id: "first".into(),
                conversation_stream_id: "conversation-a".into(),
                after_sequence: 0,
            },
        )
        .unwrap();
    let mut second = registry
        .observe(
            store,
            ObserveTranscriptProjectionsRequest {
                subscription_id: "second".into(),
                conversation_stream_id: "conversation-a".into(),
                after_sequence: 0,
            },
        )
        .unwrap();

    registry.cancel("first");
    drop(first);
    service
        .submit(TranscriptCommand::DeleteConversation {
            request_id: "delete".into(),
            conversation_stream_id: "conversation-a".into(),
        })
        .unwrap();

    assert_eq!(
        second.next().unwrap().unwrap().kind,
        TranscriptProjectionKind::ConversationDeleted
    );
    assert_eq!(registry.listener_count(), 1);
}
