use std::sync::{Arc, Mutex};

use local_ios_agent_runtime::{
    agent_input::{
        AgentInputAssembler, PromptDocumentSnapshot, RunStartSnapshot, SkillDescriptor,
        ToolDefinitionSnapshot,
    },
    conversation::{ConversationCommandService, TranscriptCommand},
    core::{EntryId, EventKind, RuntimeEvent, SessionId},
    memory::{
        MemoryContribution, MemoryContributionId, MemoryProvider, MemoryProviderError,
        MemoryProviderId, MemoryQuery, MemoryQueryResult, Provenance, SensitivityLevel,
    },
    storage::{ConversationEventStore, InMemoryConversationStore},
};
use serde_json::json;

#[test]
fn frozen_prompt_skills_and_tools_are_assembled_once_in_source_order() {
    let snapshot = snapshot();
    let assembler = AgentInputAssembler::new(snapshot, 2_000).unwrap();

    let input = assembler
        .assemble_turn(
            "conversation-1",
            vec![event(1, EventKind::UserMessage, "Hello")],
        )
        .unwrap();

    let system = input.system_prompt();
    assert!(system.find("First document").unwrap() < system.find("Second document").unwrap());
    assert_eq!(system.matches("First document").count(), 1);
    assert_eq!(system.matches("Available Skills").count(), 1);
    assert_eq!(
        system
            .matches("/var/localagent/skills/demo/SKILL.md")
            .count(),
        1
    );
    assert!(!system.contains("FULL SKILL BODY"));
    assert_eq!(input.ordered_tool_definitions().len(), 1);
    assert_eq!(input.ordered_tool_definitions()[0].name, "file_read");
}

#[test]
fn each_turn_rebuilds_canonical_context_and_sees_atomic_tool_results() {
    let snapshot = snapshot();
    let store = Arc::new(Mutex::new(InMemoryConversationStore::default()));
    let commands = ConversationCommandService::new(store.clone());
    commands
        .submit(TranscriptCommand::Send {
            request_id: "request-1".into(),
            conversation_stream_id: "conversation-1".into(),
            client_message_id: "client-1".into(),
            text: "Use the demo skill".into(),
            attachments: Vec::new(),
            run_start_snapshot: snapshot.clone(),
        })
        .unwrap();

    let initial_branch = store
        .lock()
        .unwrap()
        .events_after(&SessionId("conversation-1".into()), 0)
        .unwrap();
    let assembler = AgentInputAssembler::new(snapshot, 2_000).unwrap();
    let initial = assembler
        .assemble_turn("conversation-1", initial_branch)
        .unwrap();
    assert!(input_text(&initial).contains("Use the demo skill"));
    assert!(!input_text(&initial).contains("FULL SKILL BODY"));

    let tool_round = vec![
        event(
            0,
            EventKind::ToolCallRequested,
            r#"{"call_id":"call-1","name":"file_read"}"#,
        ),
        event(
            0,
            EventKind::ToolResultMessage,
            "FULL SKILL BODY loaded through ordinary file_read",
        ),
    ];
    store
        .lock()
        .unwrap()
        .append_transaction("conversation-1", 2, tool_round)
        .unwrap();

    let next_branch = store
        .lock()
        .unwrap()
        .events_after(&SessionId("conversation-1".into()), 0)
        .unwrap();
    let next = assembler
        .assemble_turn("conversation-1", next_branch)
        .unwrap();
    let next_text = input_text(&next);
    assert!(next_text.contains(r#""name":"file_read""#));
    assert!(next_text.contains("FULL SKILL BODY loaded through ordinary file_read"));
}

#[test]
fn every_turn_reruns_memory_sensitivity_and_budget_assembly() {
    let provider = Arc::new(CountingMemoryProvider::default());
    let assembler = AgentInputAssembler::new(snapshot(), 30)
        .unwrap()
        .with_memory_provider(provider.clone());

    let first = assembler
        .assemble_turn(
            "conversation-1",
            vec![
                event(1, EventKind::UserMessage, "old old old old old old"),
                event(2, EventKind::AssistantMessageCompleted, "old answer"),
                event(3, EventKind::UserMessage, "current"),
            ],
        )
        .unwrap();
    let second = assembler
        .assemble_turn(
            "conversation-1",
            vec![
                event(1, EventKind::UserMessage, "old old old old old old"),
                event(2, EventKind::AssistantMessageCompleted, "old answer"),
                event(3, EventKind::UserMessage, "current"),
                event(4, EventKind::AssistantMessageCompleted, "new answer"),
            ],
        )
        .unwrap();

    assert_eq!(provider.recall_count(), 2);
    assert!(first
        .context_trace()
        .dropped_segment_ids()
        .contains(&"memory.secret".to_string()));
    assert!(second
        .context_trace()
        .dropped_segment_ids()
        .contains(&"memory.secret".to_string()));
    assert!(first
        .context_trace()
        .dropped_segment_ids()
        .iter()
        .any(|id| id.starts_with("conversation.")));
    assert!(second
        .context_trace()
        .dropped_segment_ids()
        .iter()
        .any(|id| id.starts_with("conversation.")));
    assert!(first.compaction_summary().is_some());
    assert!(second.compaction_summary().is_some());
    assert_ne!(input_text(&first), input_text(&second));
    assert_eq!(first.system_prompt(), second.system_prompt());
    assert_eq!(
        first.ordered_tool_definitions(),
        second.ordered_tool_definitions()
    );
}

fn snapshot() -> RunStartSnapshot {
    RunStartSnapshot::make(
        vec![
            PromptDocumentSnapshot {
                id: "first".into(),
                source: "settings".into(),
                markdown: "First document".into(),
            },
            PromptDocumentSnapshot {
                id: "second".into(),
                source: "settings".into(),
                markdown: "Second document".into(),
            },
        ],
        vec![SkillDescriptor {
            id: "demo".into(),
            name: "Demo".into(),
            description: "Read only when relevant.".into(),
            location: "/var/localagent/skills/demo/SKILL.md".into(),
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

fn event(sequence: u64, kind: EventKind, payload: &str) -> RuntimeEvent {
    RuntimeEvent::new(
        EntryId(format!("event-{sequence}-{}", kind_name(&kind))),
        SessionId("conversation-1".into()),
        None,
        None,
        sequence,
        sequence as u32,
        kind,
        payload,
    )
}

fn kind_name(kind: &EventKind) -> &'static str {
    match kind {
        EventKind::UserMessage => "user",
        EventKind::AssistantMessageCompleted => "assistant",
        EventKind::ToolCallRequested => "tool-call",
        EventKind::ToolResultMessage => "tool-result",
        _ => "other",
    }
}

fn input_text(input: &local_ios_agent_runtime::context::AgentTurnInput) -> String {
    input
        .ordered_messages()
        .messages()
        .iter()
        .map(|message| message.content())
        .collect::<Vec<_>>()
        .join("\n")
}

#[derive(Debug, Default)]
struct CountingMemoryProvider {
    recalls: Mutex<usize>,
}

impl CountingMemoryProvider {
    fn recall_count(&self) -> usize {
        *self.recalls.lock().unwrap()
    }
}

impl MemoryProvider for CountingMemoryProvider {
    fn provider_id(&self) -> MemoryProviderId {
        MemoryProviderId::new("test.counting")
    }

    fn recall(&self, _query: &MemoryQuery) -> MemoryQueryResult {
        *self.recalls.lock().unwrap() += 1;
        MemoryQueryResult::from_contributions(vec![MemoryContribution::new("never expose this")
            .with_id(MemoryContributionId::new("memory.secret"))
            .with_provenance(Provenance::local("test"))
            .with_confidence(1.0)
            .with_sensitivity(SensitivityLevel::Secret)
            .build()
            .unwrap()])
    }

    fn remember_completed_turn(
        &self,
        _input: &local_ios_agent_runtime::memory::CompletedTurnMemoryInput,
    ) -> Result<(), MemoryProviderError> {
        Ok(())
    }
}
