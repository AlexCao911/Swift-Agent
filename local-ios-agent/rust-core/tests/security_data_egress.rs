use local_ios_agent_runtime::security::{
    ApprovalGrant, ApprovalId, ApprovalRequirement, CapabilityRequirement, CredentialPurpose,
    CredentialRef, DataEgressDecision, EgressDestination, InMemoryCredentialResolver,
    OperationDescriptor, PermissionState, SecurityAuditEvent, SecurityPermissionService,
    StaticApprovalPolicy, StaticSecurityPermissionService,
};

#[test]
fn credential_resolver_redacts_secret_values() {
    let resolver =
        InMemoryCredentialResolver::default().with_secret("openai-main", "sk-live-value");
    let secret = resolver
        .resolve(
            &CredentialRef::new("openai-main"),
            CredentialPurpose::RemoteProvider,
        )
        .unwrap();

    assert_eq!(secret.expose_for_test(), "sk-live-value");
    assert_eq!(resolver.redact("sk-live-value").as_str(), "[redacted]");
    assert!(!format!("{resolver:?}").contains("sk-live-value"));
    assert!(!format!("{secret:?}").contains("sk-live-value"));
}

#[test]
fn remote_provider_requires_disclosure_and_allowlist_pass() {
    let service = StaticSecurityPermissionService::default()
        .allow_destination(EgressDestination::new("https://api.openai.com"));

    let decision = service.evaluate_egress(
        local_ios_agent_runtime::security::DataEgressRequest::remote_provider_list(
            "https://api.openai.com",
        ),
    );

    assert!(decision.allowlist_result.is_allowed());
    assert_eq!(decision.approval_requirement, ApprovalRequirement::Required);
    assert!(!decision.disclosure_id.as_str().is_empty());
}

#[test]
fn every_remote_egress_kind_requires_disclosure_allowlist_and_approval() {
    let service = StaticSecurityPermissionService::default()
        .allow_destination(EgressDestination::new("https://api.openai.com"))
        .allow_destination(EgressDestination::new("https://tool.example.com"))
        .allow_destination(EgressDestination::new("https://memory.example.com"));
    let requests = [
        local_ios_agent_runtime::security::DataEgressRequest::remote_provider_validation(
            "https://api.openai.com",
        ),
        local_ios_agent_runtime::security::DataEgressRequest::remote_inference(
            "https://api.openai.com",
        ),
        local_ios_agent_runtime::security::DataEgressRequest::http_tool("https://tool.example.com"),
        local_ios_agent_runtime::security::DataEgressRequest::external_memory_write(
            "https://memory.example.com",
        ),
    ];

    for request in requests {
        let decision = service.evaluate_egress(request);

        assert!(decision.policy.requires_disclosure);
        assert!(decision.allowlist_result.is_allowed());
        assert_eq!(decision.approval_requirement, ApprovalRequirement::Required);
    }
}

#[test]
fn network_allowlist_denies_unlisted_egress_destination() {
    let service = StaticSecurityPermissionService::default();
    let decision = service.evaluate_egress(
        local_ios_agent_runtime::security::DataEgressRequest::remote_inference(
            "https://api.openai.com",
        ),
    );

    assert!(!decision.allowlist_result.is_allowed());
    assert_eq!(decision.approval_requirement, ApprovalRequirement::Required);
}

#[test]
fn permission_readiness_reports_missing_capabilities() {
    let service = StaticSecurityPermissionService::default()
        .with_permission("calendar.read", PermissionState::Granted);

    let report = service.permission_readiness(&[
        CapabilityRequirement::new("calendar.read"),
        CapabilityRequirement::new("contacts.read"),
    ]);

    assert!(!report.is_ready());
    assert_eq!(
        report.state_for("calendar.read"),
        Some(PermissionState::Granted)
    );
    assert_eq!(
        report.state_for("contacts.read"),
        Some(PermissionState::NotDetermined)
    );
}

#[test]
fn approval_grant_is_scoped_to_operation() {
    let grant = ApprovalGrant::new(
        ApprovalId::new("approval_1"),
        OperationDescriptor::new("remote.inference"),
    );

    assert!(grant.matches(&OperationDescriptor::new("remote.inference")));
    assert!(!grant.matches(&OperationDescriptor::new("http.tool")));
}

#[test]
fn approval_grant_does_not_match_different_egress_decision() {
    let original = DataEgressDecision::fixture_allowed(
        "disclosure_1",
        "https://api.openai.com",
        vec!["conversation.content"],
    );
    let different_destination = DataEgressDecision::fixture_allowed(
        "disclosure_2",
        "https://api.other-model.com",
        vec!["conversation.content"],
    );
    let different_data_class = DataEgressDecision::fixture_allowed(
        "disclosure_1",
        "https://api.openai.com",
        vec!["calendar.events"],
    );
    let grant = ApprovalGrant::for_egress(
        ApprovalId::new("approval_1"),
        OperationDescriptor::new("remote.inference"),
        &original,
    );

    assert!(grant.matches_egress(&OperationDescriptor::new("remote.inference"), &original));
    assert!(!grant.matches_egress(
        &OperationDescriptor::new("remote.inference"),
        &different_destination
    ));
    assert!(!grant.matches_egress(
        &OperationDescriptor::new("remote.inference"),
        &different_data_class
    ));
}

#[test]
fn approval_policy_inheritance_cannot_reduce_parent_requirement() {
    let policy = StaticApprovalPolicy;

    assert_eq!(
        policy.inherit(
            ApprovalRequirement::Required,
            ApprovalRequirement::NotRequired
        ),
        ApprovalRequirement::Required
    );
    assert_eq!(
        policy.inherit(
            ApprovalRequirement::NotRequired,
            ApprovalRequirement::Required
        ),
        ApprovalRequirement::Required
    );
}

#[test]
fn security_audit_event_stores_redacted_values_only() {
    let resolver =
        InMemoryCredentialResolver::default().with_secret("openai-main", "sk-live-value");
    let event = SecurityAuditEvent::new("RemoteProviderValidated")
        .with_redacted_field("api_key", resolver.redact("sk-live-value"));

    assert_eq!(event.field("api_key"), Some("[redacted]"));
    assert!(!format!("{event:?}").contains("sk-live-value"));
}
