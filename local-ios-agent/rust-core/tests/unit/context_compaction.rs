use local_ios_agent_runtime::context::{
    compact_tool_results_for_context, CompactionCandidate, ContextWindowPolicy, InferenceOptions,
    ModelContextWindow, PromptDebugSnapshot, PromptFrame, PromptMessage,
};

#[test]
fn compaction_candidate_creates_summary_text() {
    let candidate = CompactionCandidate::new(vec!["hello".into(), "world".into()]);

    assert_eq!(candidate.summary_text(), "hello\nworld");
}

#[test]
fn context_window_policy_derives_the_seventy_percent_trigger_from_the_model() {
    let policy = ContextWindowPolicy::for_model(ModelContextWindow {
        context_window_tokens: 100_000,
        max_output_tokens: 8_000,
    })
    .unwrap();

    assert_eq!(policy.auto_compact_threshold_tokens(), 70_000);
    assert_eq!(policy.model_input_limit_tokens(), 92_000);
}

#[test]
fn old_tool_results_are_omitted_and_the_latest_result_uses_remaining_budget() {
    let old_body = "old ".repeat(2_000);
    let latest_body = format!("BEGIN-OF-LATEST {} END-OF-LATEST", "latest ".repeat(2_000));
    let messages = vec![
        PromptMessage::User("keep this exact user request".into()),
        PromptMessage::ToolResult(old_body),
        PromptMessage::Assistant("next tool call".into()),
        PromptMessage::ToolResult(latest_body),
    ];

    let compacted = compact_tool_results_for_context(messages, 80);

    assert_eq!(
        compacted[1].content(),
        "[Earlier tool output omitted from active context]"
    );
    assert!(compacted[3].content().contains("BEGIN-OF-LATEST"));
    assert!(compacted[3].content().contains("END-OF-LATEST"));
    assert!(!compacted[3].content().contains(&"latest ".repeat(1_000)));
    assert_eq!(compacted[0].content(), "keep this exact user request");
}

#[test]
fn prompt_debug_snapshot_renders_frame() {
    let frame = PromptFrame {
        system_prompt: "system".into(),
        runtime_policy: "policy".into(),
        tool_schemas: Vec::new(),
        inference_options: InferenceOptions::default(),
        messages: Vec::new(),
    };

    assert!(PromptDebugSnapshot::from_frame(&frame)
        .rendered_text
        .contains("system"));
}
