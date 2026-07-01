use local_ios_agent_runtime::{
    core::{EntryId, RunId},
    memory::{
        HttpMemoryConnectorSpec, MemoryContribution, MemoryContributionId, MemoryProfile,
        MemoryProvider, MemoryProviderId, MemoryQuery, MemoryQueryResult, MemoryReadinessIssue,
        MemoryResolver, MemoryResolverInput, MemoryRetrievalTrace, Provenance, RetentionPolicy,
        SensitivityLevel, StaticMemoryResolver,
    },
    security::{
        ApprovalProtocolResponse, ApprovalScope, CredentialRef, DataEgressRequest,
        EgressDestination, OperationDescriptor, SecurityManager, SecurityPermissionService,
        StaticSecurityPermissionService,
    },
};

#[test]
fn memory_contribution_requires_provenance_confidence_and_sensitivity() {
    let contribution = MemoryContribution::new("User prefers concise answers")
        .with_id(MemoryContributionId::new("contribution_1"))
        .with_provenance(Provenance::local("memory_1"))
        .with_confidence(0.91)
        .with_sensitivity(SensitivityLevel::Normal)
        .build()
        .unwrap();

    assert_eq!(contribution.id.as_str(), "contribution_1");
    assert_eq!(contribution.confidence, 0.91);
    assert_eq!(contribution.provenance.source_id(), "memory_1");
    assert_eq!(contribution.sensitivity, SensitivityLevel::Normal);
}

#[test]
fn memory_contribution_without_id_is_rejected() {
    let result = MemoryContribution::new("User prefers concise answers")
        .with_provenance(Provenance::local("memory_1"))
        .with_confidence(0.91)
        .with_sensitivity(SensitivityLevel::Normal)
        .build();

    assert!(result.unwrap_err().to_string().contains("id"));
}

#[test]
fn memory_contribution_without_provenance_is_rejected() {
    let result = MemoryContribution::new("User prefers concise answers")
        .with_id(MemoryContributionId::new("contribution_1"))
        .with_confidence(0.91)
        .with_sensitivity(SensitivityLevel::Normal)
        .build();

    assert!(result.unwrap_err().to_string().contains("provenance"));
}

#[test]
fn memory_contribution_rejects_invalid_confidence() {
    let result = MemoryContribution::new("User prefers concise answers")
        .with_id(MemoryContributionId::new("contribution_1"))
        .with_provenance(Provenance::local("memory_1"))
        .with_confidence(1.5)
        .with_sensitivity(SensitivityLevel::Normal)
        .build();

    assert!(result.unwrap_err().to_string().contains("confidence"));
}

#[test]
fn http_memory_connector_is_query_only_by_default() {
    let spec = HttpMemoryConnectorSpec::query_only("https://memory.example.com/search");

    assert!(spec.can_query());
    assert!(!spec.can_write());
}

#[test]
fn http_memory_connector_external_write_requires_explicit_gate() {
    let spec = HttpMemoryConnectorSpec::query_only("https://memory.example.com/search")
        .with_credential_ref(CredentialRef::new("memory.http"));

    let result = spec.clone().try_configure_external_write(None);

    assert!(result
        .unwrap_err()
        .to_string()
        .contains("safety disclosure"));
    assert!(!spec.can_write());
}

#[test]
fn http_memory_connector_write_request_has_memory_egress_disclosure() {
    let spec = HttpMemoryConnectorSpec::query_only("https://memory.example.com/search")
        .with_credential_ref(CredentialRef::new("memory.http"))
        .with_external_write_configured("Allow writing memory content to memory.example.com")
        .unwrap();

    let request = spec.external_write_egress_request().unwrap();

    assert_eq!(
        request,
        DataEgressRequest::external_memory_write("https://memory.example.com")
    );
    assert!(spec.write_configured());
    assert!(!spec.can_write());
}

#[test]
fn http_memory_connector_requires_matching_egress_grant_before_write() {
    let spec = HttpMemoryConnectorSpec::query_only("https://memory.example.com/search")
        .with_credential_ref(CredentialRef::new("memory.http"))
        .with_external_write_configured("Allow writing memory content to memory.example.com")
        .unwrap();
    let decision = external_memory_write_decision(&spec);
    let grant = approved_egress_grant(&decision);

    let authorized = spec.authorize_external_write(&decision, &grant).unwrap();

    assert!(authorized.write_configured());
    assert!(authorized.can_write());
}

#[test]
fn http_memory_connector_rejects_mismatched_egress_grant() {
    let spec = HttpMemoryConnectorSpec::query_only("https://memory.example.com/search")
        .with_credential_ref(CredentialRef::new("memory.http"))
        .with_external_write_configured("Allow writing memory content to memory.example.com")
        .unwrap();
    let decision = external_memory_write_decision(&spec);
    let other_decision = StaticSecurityPermissionService::default()
        .allow_destination(EgressDestination::new("api.example.com"))
        .evaluate_egress(DataEgressRequest::remote_inference("api.example.com"));
    let other_grant = approved_egress_grant(&other_decision);

    let error = spec
        .authorize_external_write(&decision, &other_grant)
        .unwrap_err();

    assert!(error.to_string().contains("matching approval grant"));
}

#[test]
fn memory_connector_does_not_expose_plaintext_credential() {
    let spec = HttpMemoryConnectorSpec::query_only("https://memory.example.com/search")
        .with_credential_ref(CredentialRef::new("memory.http"));
    let debug = format!("{spec:?}");

    assert!(debug.contains("memory.http"));
    assert!(!debug.contains("secret"));
}

#[test]
fn memory_delete_emits_audit_event() {
    let mut profile = MemoryProfile::new("default").with_retention(RetentionPolicy::days(30));
    let event = profile.delete_memory("memory_1").unwrap();

    assert_eq!(event.code, "memory.deleted");
    assert_eq!(event.subject_id, "memory_1");
    assert_eq!(event.profile_id, "default");
}

#[test]
fn external_memory_write_failure_emits_non_rollback_audit_event() {
    let profile = MemoryProfile::new("default").with_retention(RetentionPolicy::days(30));
    let failure = profile.external_write_failed("memory.http", "timeout");

    assert_eq!(failure.audit.code, "memory.external_write_failed");
    assert_eq!(failure.audit.subject_id, "memory.http");
    assert_eq!(failure.reason, "timeout");
    assert!(!failure.rollback_run_output);
}

#[test]
fn memory_query_result_carries_trace_and_readiness_issues() {
    let result = MemoryQueryResult::from_contributions(vec![memory_contribution("memory_1")])
        .with_trace(MemoryRetrievalTrace::provider(MemoryProviderId::new(
            "memory.http",
        )))
        .with_readiness_issue(MemoryReadinessIssue::blocked(
            MemoryProviderId::new("memory.http"),
            "permission not granted",
        ));

    assert_eq!(
        result.trace.provider_id().map(MemoryProviderId::as_str),
        Some("memory.http")
    );
    assert_eq!(result.readiness_issues[0].code(), "memory.provider_blocked");
    assert_eq!(
        result.readiness_issues[0].message(),
        "permission not granted"
    );
}

#[test]
fn memory_resolver_outputs_only_memory_contributions() {
    let provider = StaticProvider::new(MemoryQueryResult::from_contributions(vec![
        memory_contribution("memory_1"),
    ]));
    let resolver = StaticMemoryResolver::new(vec![Box::new(provider)]);

    let result = resolver.resolve(MemoryResolverInput {
        query: MemoryQuery::new("How should I answer?"),
    });

    assert_eq!(result.contributions.len(), 1);
    assert_eq!(
        result.contributions[0].content,
        "User prefers concise answers"
    );
    assert_eq!(result.traces.len(), 1);
    assert!(result.readiness_issues.is_empty());
}

#[test]
fn memory_resolver_aggregates_provider_trace_and_readiness_issues() {
    let query_result = MemoryQueryResult::from_contributions(Vec::new())
        .with_trace(MemoryRetrievalTrace::provider(MemoryProviderId::new(
            "memory.http",
        )))
        .with_readiness_issue(MemoryReadinessIssue::blocked(
            MemoryProviderId::new("memory.http"),
            "permission not granted",
        ));
    let resolver = StaticMemoryResolver::new(vec![Box::new(StaticProvider::new(query_result))]);

    let result = resolver.resolve(MemoryResolverInput {
        query: MemoryQuery::new("How should I answer?"),
    });

    assert!(result.contributions.is_empty());
    assert_eq!(result.traces.len(), 1);
    assert_eq!(result.readiness_issues.len(), 1);
    assert_eq!(result.readiness_issues[0].code(), "memory.provider_blocked");
}

#[derive(Debug)]
struct StaticProvider {
    result: MemoryQueryResult,
}

impl StaticProvider {
    fn new(result: MemoryQueryResult) -> Self {
        Self { result }
    }
}

impl MemoryProvider for StaticProvider {
    fn provider_id(&self) -> MemoryProviderId {
        MemoryProviderId::new("static")
    }

    fn query(&self, _query: &MemoryQuery) -> MemoryQueryResult {
        self.result.clone()
    }
}

fn memory_contribution(source_id: &str) -> MemoryContribution {
    MemoryContribution::new("User prefers concise answers")
        .with_id(MemoryContributionId::new(format!(
            "contribution_{source_id}"
        )))
        .with_provenance(Provenance::local(source_id))
        .with_confidence(0.91)
        .with_sensitivity(SensitivityLevel::Normal)
        .build()
        .unwrap()
}

fn external_memory_write_decision(
    spec: &HttpMemoryConnectorSpec,
) -> local_ios_agent_runtime::security::DataEgressDecision {
    StaticSecurityPermissionService::default()
        .allow_destination(EgressDestination::new("https://memory.example.com"))
        .with_external_memory_write_enabled(true)
        .evaluate_egress(spec.external_write_egress_request().unwrap())
}

fn approved_egress_grant(
    decision: &local_ios_agent_runtime::security::DataEgressDecision,
) -> local_ios_agent_runtime::security::ApprovalGrant {
    let mut manager = SecurityManager::new();
    manager
        .request_approval(
            "approval_1",
            RunId("run_1".to_string()),
            EntryId("entry_1".to_string()),
            "Allow memory write?",
            false,
            ApprovalScope::egress(
                OperationDescriptor::new(decision.operation().as_str()),
                decision,
            )
            .unwrap(),
        )
        .unwrap();
    manager
        .issue_egress_grant(ApprovalProtocolResponse {
            approval_id: "approval_1".to_string(),
            approved: true,
            reason: None,
        })
        .unwrap()
}
