use local_ios_agent_runtime::context::{
    ContextController, MockTokenizer, PromptFrame, PromptMessage, TokenizerAdapter,
};
use local_ios_agent_runtime::core::{EntryId, EventKind, RuntimeEvent, SessionId};

fn message(kind: EventKind, payload: &str) -> RuntimeEvent {
    RuntimeEvent::new(
        EntryId(format!("entry_{payload}")),
        SessionId("session_1".to_string()),
        None,
        None,
        1,
        0,
        kind,
        payload,
    )
}

#[derive(Clone)]
struct CharacterTokenizer {
    max_context_tokens: usize,
}

impl TokenizerAdapter for CharacterTokenizer {
    fn provider_id(&self) -> &str {
        "character"
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
                .map(|tool| self.count_text(tool))
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

#[test]
fn prompt_frame_injects_policy_tools_and_recent_messages() {
    let controller = ContextController::new(
        "system prompt",
        "runtime policy",
        vec!["calendar.search_events".to_string()],
        Box::new(MockTokenizer::new(100)),
    );

    let frame = controller
        .build_prompt_frame(vec![
            message(EventKind::UserMessage, "hello"),
            message(EventKind::AssistantMessageCompleted, "hi"),
        ])
        .unwrap();

    assert_eq!(frame.system_prompt, "system prompt");
    assert_eq!(frame.runtime_policy, "runtime policy");
    assert_eq!(frame.tool_schemas, vec!["calendar.search_events"]);
    assert_eq!(
        frame.messages,
        vec![
            PromptMessage::User("hello".to_string()),
            PromptMessage::Assistant("hi".to_string())
        ]
    );
}

#[test]
fn prompt_frame_truncates_oldest_messages_instead_of_erroring() {
    let controller = ContextController::new(
        "system",
        "policy",
        Vec::new(),
        Box::new(MockTokenizer::new(14)),
    );

    let frame = controller
        .build_prompt_frame(vec![
            message(EventKind::UserMessage, "old one two three"),
            message(EventKind::AssistantMessageCompleted, "old four"),
            message(EventKind::UserMessage, "new five six"),
        ])
        .unwrap();

    assert_eq!(
        frame.messages,
        vec![PromptMessage::User("new five six".to_string())]
    );
}

#[test]
fn prompt_frame_fits_messages_using_tokenizer_counts() {
    let controller = ContextController::new(
        "",
        "",
        Vec::new(),
        Box::new(CharacterTokenizer {
            max_context_tokens: 10,
        }),
    );

    let frame = controller
        .build_prompt_frame(vec![
            message(EventKind::UserMessage, "abcdef"),
            message(EventKind::AssistantMessageCompleted, "ghijkl"),
        ])
        .unwrap();

    assert_eq!(
        frame.messages,
        vec![PromptMessage::Assistant("ghijkl".to_string())]
    );
}

#[test]
fn prompt_frame_compacts_dropped_messages_after_existing_summary() {
    let controller = ContextController::new(
        "system",
        "policy",
        Vec::new(),
        Box::new(MockTokenizer::new(16)),
    );

    let result = controller
        .build_prompt_frame_with_compaction(vec![
            message(EventKind::BranchSummaryCreated, "old compacted context"),
            message(EventKind::UserMessage, "middle one two"),
            message(EventKind::AssistantMessageCompleted, "middle three four"),
            message(EventKind::UserMessage, "latest five"),
        ])
        .unwrap();

    assert_eq!(
        result.compaction_summary,
        Some("old compacted context\nmiddle one two".into())
    );
    assert_eq!(
        result.frame.messages,
        vec![
            PromptMessage::Assistant("middle three four".into()),
            PromptMessage::User("latest five".into()),
        ]
    );
}
