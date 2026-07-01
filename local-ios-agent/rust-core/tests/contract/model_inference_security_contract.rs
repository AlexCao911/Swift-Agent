use local_ios_agent_runtime::inference::{FakeInferenceBackend, InferenceRouter};
use local_ios_agent_runtime::model::{
    ModelDescriptor, ModelFormat, ModelListRequest, ProviderAccount,
    ProviderAccountValidationRequest, ProviderDefinition, ResolvedModelBinding,
};
use local_ios_agent_runtime::{
    core::{EntryId, RunId},
    security::{
        ApprovalProtocolResponse, ApprovalScope, CredentialPurpose, CredentialRef,
        DataEgressRequest, EgressDestination, OperationDescriptor, SecurityManager,
        SecurityPermissionService, StaticSecurityPermissionService,
    },
};

fn remote_account() -> ProviderAccount {
    ProviderAccount::remote(
        "account.openai-main",
        "provider.openai",
        "https://api.openai.com",
        CredentialRef::new("credential.openai-main"),
    )
}

fn approved_egress_grant(
    operation: OperationDescriptor,
    request: DataEgressRequest,
) -> (
    local_ios_agent_runtime::security::DataEgressDecision,
    local_ios_agent_runtime::security::ApprovalGrant,
) {
    let service = StaticSecurityPermissionService::default()
        .allow_destination(EgressDestination::new("https://api.openai.com"));
    let decision = service.evaluate_egress(request);
    let mut manager = SecurityManager::new();
    manager
        .request_approval(
            "approval_1",
            RunId("run_1".to_string()),
            EntryId("entry_1".to_string()),
            "Allow egress?",
            false,
            ApprovalScope::egress(operation, &decision).unwrap(),
        )
        .unwrap();
    let grant = manager
        .issue_egress_grant(ApprovalProtocolResponse {
            approval_id: "approval_1".to_string(),
            approved: true,
            reason: None,
        })
        .unwrap();

    (decision, grant)
}

#[test]
fn remote_model_validation_rejects_list_models_decision() {
    let account = remote_account();
    let (decision, grant) = approved_egress_grant(
        ModelListRequest::remote_operation(),
        DataEgressRequest::remote_provider_list(account.destination().unwrap()),
    );
    let request = ProviderAccountValidationRequest::remote(
        account,
        decision,
        Some(grant),
        CredentialPurpose::RemoteProvider,
    )
    .unwrap();

    assert!(
        !request.remote_egress_is_approved(),
        "validation must not accept a list-models egress decision"
    );
}

#[test]
fn remote_inference_rejects_provider_validation_decision() {
    let provider = ProviderDefinition::new("provider.remote", "Remote");
    let model = ModelDescriptor::new("gpt-4.1-mini", provider.id(), ModelFormat::RemoteChat);
    let (decision, grant) = approved_egress_grant(
        ProviderAccountValidationRequest::remote_operation(),
        DataEgressRequest::remote_provider_validation("https://api.openai.com"),
    );

    let error =
        ResolvedModelBinding::remote(model, "https://api.openai.com", decision, Some(grant))
            .unwrap_err();

    assert_eq!(error.code(), "model_binding.egress_mismatch");
}

#[test]
fn local_provider_and_local_inference_do_not_fabricate_egress_decisions() {
    let local_account = ProviderAccount::local("account.local", "provider.local");
    let validation_request = ProviderAccountValidationRequest::local(local_account.clone())
        .expect("local validation request");
    let list_request = ModelListRequest::local(local_account).expect("local model list request");

    assert!(validation_request.egress_decision().is_none());
    assert!(list_request.egress_decision().is_none());

    let backend = FakeInferenceBackend::local_gguf();
    let router = InferenceRouter::new(vec![Box::new(backend)]);
    let provider = ProviderDefinition::new("provider.local", "Local");
    let model = ModelDescriptor::new("llama-3.2", provider.id(), ModelFormat::Gguf);
    let binding = ResolvedModelBinding::local(model);

    assert!(binding.egress_decision().is_none());
    assert!(router.start_session_from_binding(&binding).is_ok());
}
