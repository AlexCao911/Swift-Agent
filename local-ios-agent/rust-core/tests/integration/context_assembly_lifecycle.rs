use local_ios_agent_runtime::context::{
    ContextAssembler, ContextBudget, ContextController, ModelInputRole, PromptFrame, PromptMessage,
    TokenizerAdapter,
};
use local_ios_agent_runtime::core::{EntryId, EventKind, RuntimeEvent, SessionId};
use local_ios_agent_runtime::memory::{
    MemoryContribution, MemoryContributionId, Provenance, SensitivityLevel as MemorySensitivity,
};
use local_ios_agent_runtime::prompt::{PromptCompiler, PromptStack};
use local_ios_agent_runtime::tool::{RetentionPolicy, Sensitivity as ToolSensitivity, ToolResult};

#[derive(Clone)]
struct CharacterTokenizer {
    max_context_tokens: usize,
}

impl TokenizerAdapter for CharacterTokenizer {
    fn provider_id(&self) -> &str {
        "integration-character"
    }

    fn max_context_tokens(&self) -> usize {
        self.max_context_tokens
    }

    fn safety_margin_tokens(&self) -> usize {
        0
    }

    fn count_text(&self, text: &str) -> usize {
        text.len()
    }

    fn count_prompt_frame(&self, frame: &PromptFrame) -> usize {
        self.count_text(&frame.system_prompt)
            + self.count_text(&frame.runtime_policy)
            + frame
                .tool_schemas
                .iter()
                .map(|schema| self.count_text(schema))
                .sum::<usize>()
            + frame
                .messages
                .iter()
                .map(|message| self.count_text(message.content()))
                .sum::<usize>()
    }

    fn boxed_clone(&self) -> Box<dyn TokenizerAdapter> {
        Box::new(self.clone())
    }
}

fn runtime_message(kind: EventKind, payload: &str) -> RuntimeEvent {
    RuntimeEvent::new(
        EntryId(format!("entry_{payload}")),
        SessionId("session.context.integration".to_string()),
        None,
        None,
        1,
        0,
        kind,
        payload,
    )
}

#[test]
fn context_assembler_combines_prompt_memory_tool_and_conversation_without_calling_runtime() {
    let compiled_prompt = PromptCompiler::default()
        .compile(PromptStack::fixture_identity_persona())
        .unwrap();
    let memory = MemoryContribution::new("prefers concise answers")
        .with_id(MemoryContributionId::new("memory.local.preference"))
        .with_provenance(Provenance::local("profile-memory"))
        .with_confidence(0.9)
        .with_sensitivity(MemorySensitivity::Normal)
        .build()
        .unwrap();
    let tool_result = ToolResult::public_with_provenance(
        "display",
        "calendar has no events",
        "{}",
        "audit",
        "tool.calendar.search",
    );

    let result = ContextAssembler::new()
        .with_compiled_prompt(compiled_prompt)
        .with_memory_contribution(memory)
        .with_tool_result("tool.calendar.search", tool_result)
        .with_conversation_messages(vec![PromptMessage::User("What is next?".into())])
        .assemble(ContextBudget::tokens(100))
        .unwrap();

    assert_eq!(
        result.segment_ids(),
        vec![
            "prompt.compiled",
            "conversation.0000",
            "memory.local.preference",
            "tool.calendar.search"
        ]
    );
    assert!(result.model_input_text().contains("You are concise."));
    assert!(result
        .model_input_text()
        .contains("prefers concise answers"));
    assert!(result.model_input_text().contains("calendar has no events"));
    assert_eq!(
        result.model_input_messages().messages()[0].role(),
        ModelInputRole::System
    );
    assert!(result
        .model_input_messages()
        .messages()
        .iter()
        .any(|message| message.role() == ModelInputRole::Tool
            && message.source_segment_id() == "tool.calendar.search"));
    assert!(result.trace().dropped_segments().is_empty());
}

#[test]
fn context_controller_fails_closed_when_required_guardrail_cannot_fit() {
    for budget in 1.."non-droppable-system".len() {
        let controller = ContextController::new(
            "non-droppable-system",
            "",
            Vec::new(),
            Box::new(CharacterTokenizer {
                max_context_tokens: budget,
            }),
        );

        let error =
            match controller.build_prompt_frame_from_context_assembly(vec![runtime_message(
                EventKind::UserMessage,
                "hi",
            )]) {
                Ok(_) => panic!("expected required guardrail budget failure"),
                Err(error) => error,
            };

        assert!(
            error
                .to_string()
                .contains("context.required_segment_exceeds_budget"),
            "budget {budget} returned {error}"
        );
    }
}

#[test]
fn context_controller_keeps_recent_contiguous_conversation_window_and_compacts_gap() {
    let controller = ContextController::new(
        "",
        "",
        Vec::new(),
        Box::new(CharacterTokenizer {
            max_context_tokens: 9,
        }),
    );

    let result = controller
        .build_prompt_frame_with_compaction(vec![
            runtime_message(EventKind::UserMessage, "aa"),
            runtime_message(EventKind::AssistantMessageCompleted, "bbbbbbbb"),
            runtime_message(EventKind::UserMessage, "cc"),
        ])
        .unwrap();

    assert_eq!(
        result.frame.messages,
        vec![PromptMessage::User("cc".to_string())]
    );
    assert_eq!(result.compaction_summary, Some("aa\nbbbbbbbb".into()));
    assert_eq!(
        result.assembly.trace().dropped_segment_ids(),
        vec![
            "conversation.0001".to_string(),
            "conversation.0000".to_string()
        ]
    );
}

#[test]
fn context_archive_redacts_secret_tool_result_without_losing_trace() {
    let tool_result = ToolResult {
        display_text: "display".into(),
        model_text: "token sk-secret".into(),
        structured_json: "{}".into(),
        audit_text: "audit".into(),
        sensitivity: ToolSensitivity::Secret,
        retention: RetentionPolicy::Session,
        provenance: "tool.secret_lookup".into(),
        is_error: false,
    };

    let result = ContextAssembler::new()
        .with_tool_result("tool.secret_lookup", tool_result)
        .assemble(ContextBudget::tokens(100))
        .unwrap();
    let archive = result.archive("run.integration");

    assert!(result.segment_ids().is_empty());
    assert!(archive
        .trace()
        .dropped_segment_ids()
        .contains(&"tool.secret_lookup".to_string()));
    assert!(archive.segment("tool.secret_lookup").is_none());
}
