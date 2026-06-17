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
            PromptMessage::ToolResult("summary so far".into()),
            PromptMessage::User("hello".into()),
            PromptMessage::ToolResult("tool result".into()),
            PromptMessage::Assistant("done".into()),
        ]
    );
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
fn injection_policy_excludes_audit_only_and_secret_tool_results() {
    let policy = ContextInjectionPolicy::default();
    let result = ToolResult {
        display_text: "display".into(),
        model_text: "secret".into(),
        structured_json: "{}".into(),
        audit_text: "audit".into(),
        sensitivity: Sensitivity::Secret,
        retention: RetentionPolicy::AuditOnly,
        is_error: false,
    };

    assert!(!policy.should_inject_tool_result(&result));
}
