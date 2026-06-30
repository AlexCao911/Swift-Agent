use local_ios_agent_runtime::security::{
    ApprovalRequirement, CapabilityRequirement, CredentialPurpose, CredentialRef,
    EgressDestination, InMemoryCredentialResolver, OperationDescriptor, PermissionState,
    RuntimeSecretPrompt, SecurityAuditEvent, SecurityManager, SecurityPermissionService,
    StaticApprovalPolicy, StaticSecurityPermissionService,
};
use local_ios_agent_runtime::{
    core::{EntryId, RunId},
    security::ApprovalProtocolResponse,
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

    assert_eq!(resolver.redact("sk-live-value").as_str(), "[redacted]");
    assert!(!format!("{resolver:?}").contains("sk-live-value"));
    assert!(!format!("{secret:?}").contains("sk-live-value"));
}

#[test]
fn credential_resolver_rejects_wrong_purpose() {
    let resolver = InMemoryCredentialResolver::default().with_secret_for(
        "openai-main",
        "sk-live-value",
        [CredentialPurpose::RemoteProvider],
    );

    let error = resolver
        .resolve(
            &CredentialRef::new("openai-main"),
            CredentialPurpose::HttpTool,
        )
        .unwrap_err();

    assert_eq!(error.code(), "security.credential_purpose_mismatch");
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

    assert!(decision.allowlist_result().is_allowed());
    assert_eq!(
        decision.approval_requirement(),
        ApprovalRequirement::Required
    );
    assert!(!decision.disclosure_id().as_str().is_empty());
}

#[test]
fn data_egress_request_does_not_expose_caller_controlled_policy_fields() {
    let source = std::fs::read_to_string(
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/security/data_egress.rs"),
    )
    .unwrap();
    let request_source = source
        .split("pub struct DataEgressRequest {")
        .nth(1)
        .and_then(|tail| tail.split("}\n\nimpl DataEgressRequest").next())
        .expect("DataEgressRequest source block");

    for forbidden in [
        "pub operation:",
        "pub destination:",
        "pub data_classes:",
        "pub sensitivity:",
    ] {
        assert!(
            !request_source.contains(forbidden),
            "DataEgressRequest must derive policy from typed constructors, not expose {forbidden}"
        );
    }
}

#[test]
fn approval_grant_and_data_egress_decision_cannot_be_minted_by_callers() {
    let approval_source = std::fs::read_to_string(
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/security/approval.rs"),
    )
    .unwrap();
    let egress_source = std::fs::read_to_string(
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/security/data_egress.rs"),
    )
    .unwrap();
    let credential_source = std::fs::read_to_string(
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/security/credential.rs"),
    )
    .unwrap();
    let approval_id_source = approval_source
        .split("impl ApprovalId {")
        .nth(1)
        .and_then(|tail| {
            tail.split(
                "}\n\n#[derive(Clone, Debug, Eq, PartialEq)]\npub struct OperationDescriptor",
            )
            .next()
        })
        .expect("ApprovalId source block");

    assert!(!approval_source.contains("pub fn new(approval_id: ApprovalId"));
    assert!(!approval_id_source.contains("pub fn new("));
    assert!(!approval_source.contains("pub fn for_egress("));
    assert!(!egress_source.contains("pub disclosure_id:"));
    assert!(!egress_source.contains("pub allowlist_result:"));
    assert!(!egress_source.contains("pub approval_requirement:"));
    assert!(!egress_source.contains("pub policy:"));
    assert!(!egress_source.contains("pub fn fixture_allowed"));
    assert!(!credential_source.contains("pub fn expose_for_test"));
}

#[test]
fn every_remote_egress_kind_requires_disclosure_allowlist_and_approval() {
    let service = StaticSecurityPermissionService::default()
        .allow_destination(EgressDestination::new("https://api.openai.com"))
        .allow_destination(EgressDestination::new("https://tool.example.com"))
        .allow_destination(EgressDestination::new("https://memory.example.com"))
        .with_external_memory_write_enabled(true);
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

        assert!(decision.policy().requires_disclosure());
        assert!(decision.allowlist_result().is_allowed());
        assert_eq!(
            decision.approval_requirement(),
            ApprovalRequirement::Required
        );
    }
}

#[test]
fn external_memory_write_is_disabled_by_default_until_explicitly_enabled() {
    let disabled = StaticSecurityPermissionService::default()
        .allow_destination(EgressDestination::new("https://memory.example.com"));
    let disabled_decision = disabled.evaluate_egress(
        local_ios_agent_runtime::security::DataEgressRequest::external_memory_write(
            "https://memory.example.com",
        ),
    );

    assert!(!disabled_decision.allowlist_result().is_allowed());
    assert_eq!(
        disabled_decision.approval_requirement(),
        ApprovalRequirement::Required
    );

    let enabled = StaticSecurityPermissionService::default()
        .allow_destination(EgressDestination::new("https://memory.example.com"))
        .with_external_memory_write_enabled(true);
    let enabled_decision = enabled.evaluate_egress(
        local_ios_agent_runtime::security::DataEgressRequest::external_memory_write(
            "https://memory.example.com",
        ),
    );

    assert!(enabled_decision.allowlist_result().is_allowed());
    assert_eq!(
        enabled_decision.approval_requirement(),
        ApprovalRequirement::Required
    );
}

#[test]
fn network_allowlist_denies_unlisted_egress_destination() {
    let service = StaticSecurityPermissionService::default();
    let decision = service.evaluate_egress(
        local_ios_agent_runtime::security::DataEgressRequest::remote_inference(
            "https://api.openai.com",
        ),
    );

    assert!(!decision.allowlist_result().is_allowed());
    assert_eq!(
        decision.approval_requirement(),
        ApprovalRequirement::Required
    );
}

#[test]
fn permission_state_aggregates_denied_and_restricted_fail_closed() {
    let service = StaticSecurityPermissionService::default()
        .with_permission("calendar.read", PermissionState::Granted)
        .with_permission("contacts.read", PermissionState::Denied)
        .with_permission("photos.read", PermissionState::Restricted);

    assert_eq!(
        service.permission_state(&[
            CapabilityRequirement::new("calendar.read"),
            CapabilityRequirement::new("contacts.read"),
        ]),
        PermissionState::Denied
    );
    assert_eq!(
        service.permission_state(&[
            CapabilityRequirement::new("calendar.read"),
            CapabilityRequirement::new("photos.read"),
        ]),
        PermissionState::Restricted
    );
    assert_eq!(
        service.permission_state(&[
            CapabilityRequirement::new("calendar.read"),
            CapabilityRequirement::new("unknown.read"),
        ]),
        PermissionState::NotDetermined
    );
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
fn approved_response_issues_operation_scoped_grant() {
    let mut manager = SecurityManager::new();
    manager.request_approval(
        "approval_1",
        RunId("run_1".to_string()),
        EntryId("entry_1".to_string()),
        "Allow remote inference?",
        false,
    );
    let grant = manager
        .issue_grant(
            ApprovalProtocolResponse {
                approval_id: "approval_1".to_string(),
                approved: true,
                reason: None,
            },
            OperationDescriptor::new("remote.inference"),
        )
        .unwrap();

    assert!(grant.matches(&OperationDescriptor::new("remote.inference")));
    assert!(!grant.matches(&OperationDescriptor::new("http.tool")));
}

#[test]
fn approval_grant_does_not_match_different_egress_decision() {
    let service = StaticSecurityPermissionService::default()
        .allow_destination(EgressDestination::new("https://api.openai.com"))
        .allow_destination(EgressDestination::new("https://api.other-model.com"))
        .allow_destination(EgressDestination::new("https://tool.example.com"));
    let original = service.evaluate_egress(
        local_ios_agent_runtime::security::DataEgressRequest::remote_inference(
            "https://api.openai.com",
        ),
    );
    let different_destination = service.evaluate_egress(
        local_ios_agent_runtime::security::DataEgressRequest::remote_inference(
            "https://api.other-model.com",
        ),
    );
    let different_data_class = service.evaluate_egress(
        local_ios_agent_runtime::security::DataEgressRequest::http_tool("https://tool.example.com"),
    );
    let mut manager = SecurityManager::new();
    manager.request_approval(
        "approval_1",
        RunId("run_1".to_string()),
        EntryId("entry_1".to_string()),
        "Allow remote inference?",
        false,
    );
    let grant = manager
        .issue_egress_grant(
            ApprovalProtocolResponse {
                approval_id: "approval_1".to_string(),
                approved: true,
                reason: None,
            },
            OperationDescriptor::new("remote.inference"),
            &original,
        )
        .unwrap();

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
fn required_approval_fails_closed_for_sensitive_and_unknown_operations() {
    let service = StaticSecurityPermissionService::default();
    let policy = StaticApprovalPolicy;

    assert_eq!(
        service.required_approval(&OperationDescriptor::new("remote.inference.generate")),
        ApprovalRequirement::Required
    );
    assert_eq!(
        policy.required_for(&OperationDescriptor::new("http.tool.request")),
        ApprovalRequirement::Required
    );
    assert_eq!(
        service.required_approval(&OperationDescriptor::new("unknown.future.operation")),
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

#[test]
fn runtime_secret_prompt_drops_secret_after_operation() {
    let mut prompt = RuntimeSecretPrompt::new(
        OperationDescriptor::new("remote.provider.validate_account"),
        CredentialPurpose::RemoteProvider,
    );
    prompt.submit_secret("sk-live-value");

    assert!(prompt
        .secret_for(
            &OperationDescriptor::new("remote.provider.validate_account"),
            CredentialPurpose::RemoteProvider,
        )
        .is_some());
    assert!(prompt
        .secret_for(
            &OperationDescriptor::new("http.tool.request"),
            CredentialPurpose::HttpTool,
        )
        .is_none());
    assert!(!format!("{prompt:?}").contains("sk-live-value"));

    prompt.finish_operation();

    assert!(prompt
        .secret_for(
            &OperationDescriptor::new("remote.provider.validate_account"),
            CredentialPurpose::RemoteProvider,
        )
        .is_none());
    assert!(!format!("{prompt:?}").contains("sk-live-value"));
}
