use local_ios_agent_runtime::context::{
    ContextAssembler, ContextBudget, ContextGraph, ContextPolicy, ContextSegment,
    ContextSensitivity, ModelInputRole, PromptMessage, SegmentSource,
};
use local_ios_agent_runtime::memory::{
    MemoryContribution, MemoryContributionId, Provenance, SensitivityLevel as MemorySensitivity,
};
use local_ios_agent_runtime::tool::{RetentionPolicy, Sensitivity as ToolSensitivity, ToolResult};

#[test]
fn context_graph_order_is_deterministic() {
    let graph = ContextGraph::from_segments(vec![
        ContextSegment::memory("memory.b", "remembered b").with_priority(20),
        ContextSegment::prompt("prompt.system", "system").with_priority(100),
        ContextSegment::memory("memory.a", "remembered a").with_priority(20),
    ])
    .unwrap();

    assert_eq!(
        graph.segment_ids(),
        vec!["prompt.system", "memory.a", "memory.b"]
    );
    assert_eq!(graph.ordered_segments()[0].source(), SegmentSource::Prompt);
}

#[test]
fn context_graph_rejects_duplicate_segment_ids_before_accounting() {
    let error = ContextAssembler::new()
        .with_segment(ContextSegment::memory("duplicate", "memory"))
        .with_segment(ContextSegment::tool_result("duplicate", "tool"))
        .assemble_default()
        .unwrap_err();

    assert!(error.to_string().contains("context.duplicate_segment_id"));
}

#[test]
fn assembler_preserves_conversation_roles_and_blob_refs_in_model_input() {
    let result = ContextAssembler::new()
        .with_conversation_messages(vec![
            PromptMessage::User("hello".into()),
            PromptMessage::Assistant("hi".into()),
            PromptMessage::ToolResult("lookup result".into()),
            PromptMessage::Summary("earlier summary".into()),
            PromptMessage::UserWithBlobRefs {
                content: "look at this".into(),
                blob_refs: vec!["blob.image.1".into()],
            },
        ])
        .assemble_default()
        .unwrap();

    let model_input = result.model_input_messages();
    let messages = model_input.messages();

    assert_eq!(
        messages
            .iter()
            .map(|message| message.role())
            .collect::<Vec<_>>(),
        vec![
            ModelInputRole::User,
            ModelInputRole::Assistant,
            ModelInputRole::Tool,
            ModelInputRole::Summary,
            ModelInputRole::User
        ]
    );
    assert_eq!(messages[4].blob_refs(), &["blob.image.1".to_string()]);
}

#[test]
fn assembler_records_dropped_segments_when_global_budget_trims() {
    let assembler = ContextAssembler::new()
        .with_segment(ContextSegment::prompt("prompt.system", "system prompt").with_priority(100))
        .with_segment(ContextSegment::memory(
            "memory.long",
            "one two three four five six seven eight nine ten",
        ));

    let result = assembler.assemble(ContextBudget::tokens(4)).unwrap();

    assert!(result.segment_ids().contains(&"prompt.system".to_string()));
    assert!(result
        .trace()
        .dropped_segments()
        .iter()
        .any(|drop| { drop.segment_id() == "memory.long" && drop.reason() == "budget.exceeded" }));
}

#[test]
fn context_policy_applies_per_source_budget_splits() {
    let assembler = ContextAssembler::new()
        .with_segment(ContextSegment::prompt("prompt.system", "system prompt").with_priority(100))
        .with_segment(ContextSegment::memory(
            "memory.long",
            "one two three four five six seven eight nine ten",
        ))
        .with_segment(ContextSegment::tool_result(
            "tool.lookup",
            "tool result payload",
        ));
    let policy = ContextPolicy::new()
        .with_source_budget(SegmentSource::Prompt, 10)
        .with_source_budget(SegmentSource::Memory, 3)
        .with_source_budget(SegmentSource::ToolResult, 10);

    let result = assembler.assemble_with_policy(policy).unwrap();

    assert!(result.trace().kept_tokens_for(SegmentSource::Prompt) <= 10);
    assert!(result.trace().kept_tokens_for(SegmentSource::Memory) <= 3);
    assert!(result
        .trace()
        .dropped_segments()
        .iter()
        .any(|drop| drop.source() == SegmentSource::Memory));
    assert!(result.segment_ids().contains(&"prompt.system".to_string()));
}

#[test]
fn required_segments_fail_closed_across_budget_boundaries() {
    for budget in 0.."must-keep".len() {
        let error = ContextAssembler::new()
            .with_segment(
                ContextSegment::system_guardrail("system.guardrail", "must-keep")
                    .required_for_model_input(),
            )
            .assemble(ContextBudget::with_token_counter_named(
                budget,
                "test.characters",
                |text| text.len(),
            ))
            .unwrap_err();

        assert!(
            error
                .to_string()
                .contains("context.required_segment_exceeds_budget"),
            "budget {budget} returned {error}"
        );
    }
}

#[test]
fn conversation_budgeting_keeps_a_contiguous_recent_suffix_property() {
    for budget in 1..=8 {
        let result = ContextAssembler::new()
            .with_conversation_messages(vec![
                PromptMessage::User("a".into()),
                PromptMessage::Assistant("bbbb".into()),
                PromptMessage::User("cc".into()),
                PromptMessage::Assistant("d".into()),
            ])
            .assemble(ContextBudget::with_token_counter_named(
                budget,
                "test.characters",
                |text| text.len(),
            ))
            .unwrap();

        let kept_conversation_indexes = result
            .segment_ids()
            .into_iter()
            .filter_map(|id| conversation_index(&id))
            .collect::<Vec<_>>();

        assert!(
            is_contiguous_suffix(&kept_conversation_indexes, 4),
            "budget {budget} kept non-contiguous conversation ids: {kept_conversation_indexes:?}"
        );
    }
}

#[test]
fn budget_split_trimming_uses_stable_segment_order() {
    let assembler = ContextAssembler::new()
        .with_segment(ContextSegment::memory("memory.b", "one two three").with_priority(10))
        .with_segment(ContextSegment::memory("memory.a", "four five six").with_priority(10));
    let policy = ContextPolicy::new().with_source_budget(SegmentSource::Memory, 3);

    let first = assembler.assemble_with_policy(policy.clone()).unwrap();
    let second = assembler.assemble_with_policy(policy).unwrap();

    assert_eq!(first.segment_ids(), second.segment_ids());
    assert_eq!(
        first.trace().dropped_segment_ids(),
        second.trace().dropped_segment_ids()
    );
    assert_eq!(first.segment_ids(), vec!["memory.a"]);
}

#[test]
fn preview_and_archive_use_same_assembly_path() {
    let assembler = ContextAssembler::new()
        .with_segment(ContextSegment::prompt("prompt.system", "system"))
        .with_segment(ContextSegment::memory("memory.one", "remembered"));

    let preview = assembler.preview().unwrap();
    let archive = assembler.assemble_default().unwrap().archive("run_1");

    assert_eq!(preview.segment_ids(), archive.segment_ids());
}

#[test]
fn context_archive_keeps_prompt_source_map_backlink_for_checkpoint_debugging() {
    let compiled = local_ios_agent_runtime::prompt::PromptCompiler::default()
        .compile(local_ios_agent_runtime::prompt::PromptStack::fixture_identity_persona())
        .unwrap();
    let expected_entries = compiled.source_map.entries.clone();

    let archive = ContextAssembler::new()
        .with_compiled_prompt(compiled)
        .assemble_default()
        .unwrap()
        .archive("run_1");
    let segment = archive.segment("prompt.compiled").unwrap();

    assert_eq!(
        segment.prompt_source_map().unwrap().entries,
        expected_entries
    );
    assert!(segment
        .source_links()
        .iter()
        .any(|link| link.kind() == "prompt_document"));
}

#[test]
fn context_archive_has_stable_archive_id_and_creation_timestamp() {
    let archive = ContextAssembler::new()
        .with_segment(ContextSegment::prompt("prompt.system", "system"))
        .assemble_default()
        .unwrap()
        .archive("run_1");
    let same_context_archive = ContextAssembler::new()
        .with_segment(ContextSegment::prompt("prompt.system", "system"))
        .assemble_default()
        .unwrap()
        .archive("run_1");

    assert_eq!(archive.archive_id(), same_context_archive.archive_id());
    assert!(archive.archive_id().starts_with("context_archive:run_1:"));
    assert!(archive.created_at_millis() > 0);
}

#[test]
fn context_archive_ids_differ_for_distinct_model_call_contexts_in_same_run() {
    let first = ContextAssembler::new()
        .with_segment(ContextSegment::prompt("prompt.system", "system"))
        .with_conversation_messages(vec![PromptMessage::User("first call".into())])
        .assemble_default()
        .unwrap()
        .archive("run_1");
    let second = ContextAssembler::new()
        .with_segment(ContextSegment::prompt("prompt.system", "system"))
        .with_conversation_messages(vec![PromptMessage::User("post tool call".into())])
        .assemble_default()
        .unwrap()
        .archive("run_1");

    assert_ne!(first.archive_id(), second.archive_id());
    assert!(first.archive_id().starts_with("context_archive:run_1:"));
    assert!(second.archive_id().starts_with("context_archive:run_1:"));
}

#[test]
fn archive_debug_summary_keeps_dropped_reason_tokens_and_tokenizer_source() {
    let result = ContextAssembler::new()
        .with_segment(ContextSegment::prompt("prompt.system", "system prompt"))
        .with_segment(ContextSegment::memory(
            "memory.long",
            "one two three four five six",
        ))
        .assemble(ContextBudget::tokens(2))
        .unwrap();
    let summary = result.archive("run_1").debug_summary();

    assert_eq!(summary.trace.tokenizer_source, "context_budget.whitespace");
    assert_eq!(summary.trace.dropped_segments.len(), 1);
    assert_eq!(summary.trace.dropped_segments[0].id, "memory.long");
    assert_eq!(summary.trace.dropped_segments[0].reason, "budget.exceeded");
    assert_eq!(summary.trace.dropped_segments[0].tokens, 6);
}

fn conversation_index(segment_id: &str) -> Option<usize> {
    segment_id
        .strip_prefix("conversation.")
        .and_then(|suffix| suffix.parse::<usize>().ok())
}

fn is_contiguous_suffix(indexes: &[usize], message_count: usize) -> bool {
    let Some(first) = indexes.first().copied() else {
        return true;
    };
    indexes.iter().copied().eq(first..message_count)
}

#[test]
fn archive_redacts_sensitive_tool_result_and_preserves_provenance() {
    let tool_result = ToolResult {
        display_text: "display".into(),
        model_text: "user email alice@example.com".into(),
        structured_json: "{}".into(),
        audit_text: "audit".into(),
        sensitivity: ToolSensitivity::Private,
        retention: RetentionPolicy::RunOnly,
        provenance: "tool.lookup_user".into(),
        is_error: false,
    };
    let archive = ContextAssembler::new()
        .with_tool_result("tool.lookup_user", tool_result)
        .assemble_default()
        .unwrap()
        .archive("run_1");
    let segment = archive.segment("tool.lookup_user").unwrap();

    assert_eq!(segment.redacted_content(), "[redacted]");
    assert_eq!(segment.provenance().as_str(), "tool.lookup_user");
    assert!(segment
        .source_links()
        .iter()
        .any(|link| link.kind() == "tool_result" && link.id() == "tool.lookup_user"));
}

#[test]
fn memory_contribution_becomes_segment_with_provenance_and_sensitivity() {
    let memory = MemoryContribution::new("likes quiet mornings")
        .with_id(MemoryContributionId::new("memory.local.1"))
        .with_provenance(Provenance::local("memory-db"))
        .with_confidence(0.8)
        .with_sensitivity(MemorySensitivity::Normal)
        .build()
        .unwrap();

    let result = ContextAssembler::new()
        .with_memory_contribution(memory)
        .assemble_default()
        .unwrap();
    let segment = result.graph().segment("memory.local.1").unwrap();

    assert_eq!(segment.source(), SegmentSource::Memory);
    assert_eq!(segment.provenance().as_str(), "memory.local:memory-db");
    assert_eq!(segment.sensitivity(), ContextSensitivity::Normal);
    assert!(segment
        .source_links()
        .iter()
        .any(|link| link.kind() == "memory_contribution" && link.id() == "memory.local.1"));
}

#[test]
fn secret_tool_result_is_excluded_before_budget_and_visible_in_trace() {
    let tool_result = ToolResult {
        display_text: "display".into(),
        model_text: "sk-secret-token".into(),
        structured_json: "{}".into(),
        audit_text: "audit".into(),
        sensitivity: ToolSensitivity::Secret,
        retention: RetentionPolicy::AuditOnly,
        provenance: "tool.secret".into(),
        is_error: false,
    };

    let result = ContextAssembler::new()
        .with_tool_result("tool.secret", tool_result)
        .assemble(ContextBudget::tokens(100))
        .unwrap();

    assert!(result.segment_ids().is_empty());
    assert!(result.trace().dropped_segments().iter().any(|drop| {
        drop.segment_id() == "tool.secret" && drop.reason() == "sensitivity.excluded"
    }));
}
