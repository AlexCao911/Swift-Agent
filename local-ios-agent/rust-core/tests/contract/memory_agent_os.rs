use local_ios_agent_runtime::memory::{
    MemoryContribution, MemoryContributionBuilder, MemoryContributionId, MemoryProviderId,
    MemoryQuery, MemoryQueryResult, MemoryReadinessIssue, MemoryRetrievalTrace, Provenance,
    SensitivityLevel,
};

#[test]
fn memory_contribution_requires_provenance_confidence_and_sensitivity() {
    let contribution = memory_contribution("memory_1");

    assert_eq!(contribution.id.as_str(), "contribution_memory_1");
    assert_eq!(contribution.confidence, 0.91);
    assert_eq!(contribution.provenance.source_id(), "memory_1");
    assert_eq!(contribution.sensitivity, SensitivityLevel::Normal);
}

#[test]
fn incomplete_or_invalid_memory_contributions_are_rejected() {
    let missing_id = MemoryContributionBuilder::new("User prefers concise answers")
        .with_provenance(Provenance::local("memory_1"))
        .with_confidence(0.91)
        .with_sensitivity(SensitivityLevel::Normal)
        .build();
    let missing_provenance = MemoryContributionBuilder::new("User prefers concise answers")
        .with_id(MemoryContributionId::new("contribution_1"))
        .with_confidence(0.91)
        .with_sensitivity(SensitivityLevel::Normal)
        .build();
    let invalid_confidence = MemoryContributionBuilder::new("User prefers concise answers")
        .with_id(MemoryContributionId::new("contribution_1"))
        .with_provenance(Provenance::local("memory_1"))
        .with_confidence(1.5)
        .with_sensitivity(SensitivityLevel::Normal)
        .build();

    assert!(missing_id.unwrap_err().to_string().contains("id"));
    assert!(missing_provenance
        .unwrap_err()
        .to_string()
        .contains("provenance"));
    assert!(invalid_confidence
        .unwrap_err()
        .to_string()
        .contains("confidence"));
}

#[test]
fn query_is_scoped_to_one_conversation_and_bounded() {
    let query = MemoryQuery::for_conversation("conversation-1", "How should I answer?", 8);

    assert_eq!(query.conversation_stream_id, "conversation-1");
    assert_eq!(query.text(), "How should I answer?");
    assert_eq!(query.limit, 8);
}

#[test]
fn memory_query_result_carries_trace_and_readiness_issues() {
    let result = MemoryQueryResult::from_contributions(vec![memory_contribution("memory_1")])
        .with_trace(MemoryRetrievalTrace::provider(MemoryProviderId::new(
            "memory.future",
        )))
        .with_readiness_issue(MemoryReadinessIssue::blocked(
            MemoryProviderId::new("memory.future"),
            "provider not configured",
        ));

    assert_eq!(
        result.trace.provider_id().map(MemoryProviderId::as_str),
        Some("memory.future")
    );
    assert_eq!(result.readiness_issues[0].code(), "memory.provider_blocked");
    assert_eq!(
        result.readiness_issues[0].message(),
        "provider not configured"
    );
}

fn memory_contribution(source_id: &str) -> MemoryContribution {
    MemoryContributionBuilder::new("User prefers concise answers")
        .with_id(MemoryContributionId::new(format!(
            "contribution_{source_id}"
        )))
        .with_provenance(Provenance::local(source_id))
        .with_confidence(0.91)
        .with_sensitivity(SensitivityLevel::Normal)
        .build()
        .unwrap()
}
