use local_ios_agent_runtime::context::ContextInjectionPolicy;
use local_ios_agent_runtime::context::PromptLayers;
use local_ios_agent_runtime::context::{BranchProjector, PromptMessage};
use local_ios_agent_runtime::core::{EntryId, EventKind, RuntimeEvent, SessionId};
use local_ios_agent_runtime::tool::{RetentionPolicy, Sensitivity, ToolResult};

fn event(id: &str, kind: EventKind, payload: &str) -> RuntimeEvent {
    RuntimeEvent::new(
        EntryId(id.into()),
        SessionId("session_1".into()),
        None,
        None,
        1,
        0,
        kind,
        payload,
    )
}

#[test]
fn projector_preserves_model_visible_branch_events() {
    let messages = BranchProjector::new().project(vec![
        event("summary", EventKind::BranchSummaryCreated, "summary so far"),
        event("user", EventKind::UserMessage, "hello"),
        event("tool", EventKind::ToolResultMessage, "tool result"),
        event("assistant", EventKind::AssistantMessageCompleted, "done"),
    ]);

    assert_eq!(
        messages,
        vec![
            PromptMessage::Summary("summary so far".into()),
            PromptMessage::User("hello".into()),
            PromptMessage::ToolResult("tool result".into()),
            PromptMessage::Assistant("done".into()),
        ]
    );
}

#[test]
fn projector_excludes_audit_only_and_secret_tool_results_from_context() {
    let secret_result = ToolResult {
        display_text: "display".into(),
        model_text: "secret model text".into(),
        structured_json: "{}".into(),
        audit_text: "audit".into(),
        sensitivity: Sensitivity::Secret,
        retention: RetentionPolicy::AuditOnly,
        provenance: "tool.test".into(),
        is_error: false,
    };

    let messages = BranchProjector::new().project(vec![
        event("user", EventKind::UserMessage, "hello"),
        event(
            "tool",
            EventKind::ToolResultMessage,
            &secret_result.to_event_payload(),
        ),
    ]);

    assert_eq!(messages, vec![PromptMessage::User("hello".into())]);
}

#[test]
fn projector_treats_summary_as_history_boundary() {
    let messages = BranchProjector::new().project(vec![
        event("old_user", EventKind::UserMessage, "old user"),
        event(
            "old_assistant",
            EventKind::AssistantMessageCompleted,
            "old assistant",
        ),
        event("summary", EventKind::BranchSummaryCreated, "summary so far"),
        event("new_user", EventKind::UserMessage, "new user"),
    ]);

    assert_eq!(
        messages,
        vec![
            PromptMessage::Summary("summary so far".into()),
            PromptMessage::User("new user".into()),
        ]
    );
}

#[test]
fn projector_drops_malformed_structured_tool_result_payload() {
    let messages = BranchProjector::new().project(vec![event(
        "tool",
        EventKind::ToolResultMessage,
        r#"{"type":"tool_result","model_text":"secret"}"#,
    )]);

    assert!(messages.is_empty());
}

#[test]
fn projector_keeps_legacy_plain_text_tool_result_payload() {
    let messages = BranchProjector::new().project(vec![event(
        "tool",
        EventKind::ToolResultMessage,
        "legacy text result",
    )]);

    assert_eq!(
        messages,
        vec![PromptMessage::ToolResult("legacy text result".into())]
    );
}

#[test]
fn retry_projects_history_through_the_user_anchor_without_the_old_answer() {
    let messages = BranchProjector::new().project(vec![
        event("user-1", EventKind::UserMessage, "first"),
        event(
            "assistant-1",
            EventKind::AssistantMessageCompleted,
            "first answer",
        ),
        event("user-2", EventKind::UserMessage, "second"),
        event(
            "assistant-2",
            EventKind::AssistantMessageCompleted,
            "second answer",
        ),
        event(
            "retry",
            EventKind::TranscriptRetryRequested,
            r#"{"command":{"anchor_event_id":"user-1"}}"#,
        ),
    ]);

    assert_eq!(messages, vec![PromptMessage::User("first".into())]);
}

#[test]
fn edit_replaces_the_target_and_discards_its_descendants() {
    let messages = BranchProjector::new().project(vec![
        event("user-1", EventKind::UserMessage, "first"),
        event(
            "assistant-1",
            EventKind::AssistantMessageCompleted,
            "stale answer",
        ),
        event(
            "edit",
            EventKind::MessageEdited,
            r#"{"command":{"target_event_id":"user-1","replacement_text":"replacement","replacement_attachments":[{"attachment_id":"attachment-1","content_digest":"sha256:attachment"}]}}"#,
        ),
    ]);

    assert_eq!(
        messages,
        vec![PromptMessage::UserWithBlobRefs {
            content: "replacement".into(),
            blob_refs: vec!["attachment-1".into()],
        }]
    );
}

#[test]
fn delete_removes_the_target_and_its_descendants() {
    let messages = BranchProjector::new().project(vec![
        event("user-1", EventKind::UserMessage, "first"),
        event(
            "assistant-1",
            EventKind::AssistantMessageCompleted,
            "first answer",
        ),
        event("user-2", EventKind::UserMessage, "second"),
        event(
            "assistant-2",
            EventKind::AssistantMessageCompleted,
            "second answer",
        ),
        event(
            "delete",
            EventKind::MessageDeleted,
            r#"{"command":{"target_event_id":"user-2"}}"#,
        ),
    ]);

    assert_eq!(
        messages,
        vec![
            PromptMessage::User("first".into()),
            PromptMessage::Assistant("first answer".into()),
        ]
    );
}

#[test]
fn clear_removes_prior_history_but_keeps_later_messages() {
    let messages = BranchProjector::new().project(vec![
        event("old-user", EventKind::UserMessage, "old"),
        event(
            "old-assistant",
            EventKind::AssistantMessageCompleted,
            "old answer",
        ),
        event(
            "clear",
            EventKind::ConversationCleared,
            r#"{"command":{"kind":"clear_conversation"}}"#,
        ),
        event("new-user", EventKind::UserMessage, "new"),
    ]);

    assert_eq!(messages, vec![PromptMessage::User("new".into())]);
}

#[test]
fn prompt_layers_render_system_policy_and_memory() {
    let layers = PromptLayers {
        system: "system".into(),
        policy: "policy".into(),
        memory: vec!["memory one".into()],
    };

    assert!(layers.render_system_prompt().contains("system"));
    assert!(layers.render_system_prompt().contains("memory one"));
}

#[test]
fn context_sorts_tool_schemas_for_stable_prompt_frames() {
    let controller = local_ios_agent_runtime::context::ContextController::new(
        "system",
        "policy",
        vec!["z.tool".into(), "a.tool".into()],
        Box::new(local_ios_agent_runtime::context::MockTokenizer::new(100)),
    );

    let frame = controller.build_prompt_frame(Vec::new()).unwrap();

    assert_eq!(frame.tool_schemas, vec!["a.tool", "z.tool"]);
}

#[test]
fn context_controller_injects_memory_snippets_into_system_prompt() {
    let controller = local_ios_agent_runtime::context::ContextController::new_with_memory(
        "system",
        "policy",
        Vec::new(),
        vec!["likes quiet mornings".into()],
        Box::new(local_ios_agent_runtime::context::MockTokenizer::new(100)),
    );

    let frame = controller.build_prompt_frame(Vec::new()).unwrap();

    assert!(frame.system_prompt.contains("likes quiet mornings"));
}

#[test]
fn injection_policy_excludes_audit_only_and_secret_tool_results() {
    let policy = ContextInjectionPolicy::default();
    let result = ToolResult {
        display_text: "display".into(),
        model_text: "secret".into(),
        structured_json: "{}".into(),
        audit_text: "audit".into(),
        sensitivity: Sensitivity::Secret,
        retention: RetentionPolicy::AuditOnly,
        provenance: "tool.test".into(),
        is_error: false,
    };

    assert!(!policy.should_inject_tool_result(&result));
}
