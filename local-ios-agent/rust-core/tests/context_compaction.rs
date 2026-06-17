use local_ios_agent_runtime::context::{CompactionCandidate, PromptDebugSnapshot, PromptFrame};

#[test]
fn compaction_candidate_creates_summary_text() {
    let candidate = CompactionCandidate::new(vec!["hello".into(), "world".into()]);

    assert_eq!(candidate.summary_text(), "hello\nworld");
}

#[test]
fn prompt_debug_snapshot_renders_frame() {
    let frame = PromptFrame {
        system_prompt: "system".into(),
        runtime_policy: "policy".into(),
        tool_schemas: Vec::new(),
        messages: Vec::new(),
    };

    assert!(PromptDebugSnapshot::from_frame(&frame)
        .rendered_text
        .contains("system"));
}
