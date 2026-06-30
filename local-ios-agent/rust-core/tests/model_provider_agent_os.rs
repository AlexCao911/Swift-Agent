use local_ios_agent_runtime::model::{
    GenerationProfile, ModelCapabilities, ModelCatalogService, ModelDescriptor, ModelFormat,
    ModelListRequest, ModelListResult, ModelProviderAdapter, ProviderAccount,
    ProviderAccountValidation, ProviderAccountValidationRequest, ProviderDefinition,
};
use local_ios_agent_runtime::{
    core::{EntryId, RunId},
    security::{
        ApprovalProtocolResponse, ApprovalRequirement, ApprovalScope, CredentialPurpose,
        CredentialRef, DataEgressRequest, EgressDestination, OperationDescriptor, SecurityManager,
        SecurityPermissionService, StaticSecurityPermissionService,
    },
};
use std::sync::Mutex;

#[test]
fn model_descriptor_records_capabilities_and_format() {
    let provider = ProviderDefinition::new("provider.openai", "OpenAI Compatible");
    let model = ModelDescriptor::new("gpt-4.1-mini", provider.id(), ModelFormat::RemoteChat)
        .with_capabilities(ModelCapabilities::chat().with_temperature());

    assert!(model.capabilities.supports_temperature);
    assert_eq!(model.provider_id, provider.id());
    assert_eq!(model.supported_formats, vec![ModelFormat::RemoteChat]);
}

#[test]
fn provider_validation_requires_egress_decision_and_approval_grant() {
    let adapter = RecordingRemoteProviderAdapter::default();
    let account = remote_account();
    let (decision, grant) = approved_egress_grant(
        ProviderAccountValidationRequest::remote_operation(),
        DataEgressRequest::remote_provider_validation(account.destination().unwrap()),
    );
    let request = ProviderAccountValidationRequest::remote(
        account,
        decision,
        Some(grant),
        CredentialPurpose::RemoteProvider,
    );

    let report = adapter.validate_account(request);

    assert!(report.is_valid);
    assert!(adapter.last_validation_used_egress_decision());
}

#[test]
fn provider_validation_rejects_remote_request_without_matching_grant() {
    let adapter = RecordingRemoteProviderAdapter::default();
    let account = remote_account();
    let service = StaticSecurityPermissionService::default()
        .allow_destination(EgressDestination::new(account.destination().unwrap()));
    let decision = service.evaluate_egress(DataEgressRequest::remote_provider_validation(
        account.destination().unwrap(),
    ));
    let request = ProviderAccountValidationRequest::remote(
        account,
        decision,
        None,
        CredentialPurpose::RemoteProvider,
    );

    let report = adapter.validate_account(request);

    assert!(!report.is_valid);
    assert_eq!(report.issues[0].code, "model.egress_approval_required");
}

#[test]
fn local_provider_validation_does_not_require_egress_decision() {
    let adapter = RecordingLocalProviderAdapter::default();
    let request = ProviderAccountValidationRequest::local(local_account());

    let report = adapter.validate_account(request);

    assert!(report.is_valid);
    assert!(!adapter.last_validation_used_egress_decision());
}

#[test]
fn remote_model_list_requires_egress_decision_and_approval_grant() {
    let adapter = RecordingRemoteProviderAdapter::default();
    let account = remote_account();
    let (decision, grant) = approved_egress_grant(
        ModelListRequest::remote_operation(),
        DataEgressRequest::remote_provider_list(account.destination().unwrap()),
    );
    let request = ModelListRequest::remote(
        account,
        decision,
        Some(grant),
        CredentialPurpose::RemoteProvider,
    );

    let result = adapter.list_models(request);

    assert!(result.is_valid());
    assert_eq!(result.models[0].id, "gpt-4.1-mini");
    assert!(adapter.last_list_used_egress_decision());
}

#[test]
fn model_catalog_service_evaluates_provider_egress_through_security_service() {
    let account = remote_account();
    let catalog = ModelCatalogService::new(
        StaticSecurityPermissionService::default()
            .allow_destination(EgressDestination::new(account.destination().unwrap())),
    );

    let decision = catalog.evaluate_model_list_egress(&account);

    assert!(decision.allowlist_result().is_allowed());
    assert_eq!(
        decision.approval_requirement(),
        ApprovalRequirement::Required
    );
    assert_eq!(
        decision.policy().destination().as_str(),
        account.destination().unwrap()
    );
}

#[test]
fn model_catalog_service_evaluates_account_validation_egress_through_security_service() {
    let account = remote_account();
    let catalog = ModelCatalogService::new(
        StaticSecurityPermissionService::default()
            .allow_destination(EgressDestination::new(account.destination().unwrap())),
    );

    let decision = catalog.evaluate_account_validation_egress(&account);

    assert!(decision.allowlist_result().is_allowed());
    assert_eq!(
        decision.approval_requirement(),
        ApprovalRequirement::Required
    );
    assert_eq!(
        decision.policy().destination().as_str(),
        account.destination().unwrap()
    );
    assert!(decision
        .disclosure_id()
        .as_str()
        .contains("remote.provider.validate_account"));
}

#[test]
fn generation_profile_rejects_unsupported_temperature() {
    let capabilities = ModelCapabilities::chat();
    let profile = GenerationProfile::new("gpt-4.1-mini").with_temperature(0.7);

    let report = profile.validate_against(&capabilities);

    assert!(!report.is_valid());
    assert_eq!(report.issues[0].code, "generation.temperature.unsupported");
}

#[derive(Default)]
struct RecordingRemoteProviderAdapter {
    last_validation_used_egress_decision: Mutex<bool>,
    last_list_used_egress_decision: Mutex<bool>,
}

impl RecordingRemoteProviderAdapter {
    fn last_validation_used_egress_decision(&self) -> bool {
        *self
            .last_validation_used_egress_decision
            .lock()
            .expect("validation recorder poisoned")
    }

    fn last_list_used_egress_decision(&self) -> bool {
        *self
            .last_list_used_egress_decision
            .lock()
            .expect("list recorder poisoned")
    }
}

impl ModelProviderAdapter for RecordingRemoteProviderAdapter {
    fn provider_definition(&self) -> ProviderDefinition {
        ProviderDefinition::new("provider.openai", "OpenAI Compatible")
    }

    fn validate_account(
        &self,
        request: ProviderAccountValidationRequest,
    ) -> ProviderAccountValidation {
        *self
            .last_validation_used_egress_decision
            .lock()
            .expect("validation recorder poisoned") = request.egress_decision().is_some();
        ProviderAccountValidation::from_egress_gate(request.remote_egress_is_approved())
    }

    fn list_models(&self, request: ModelListRequest) -> ModelListResult {
        *self
            .last_list_used_egress_decision
            .lock()
            .expect("list recorder poisoned") = request.egress_decision().is_some();
        if request.remote_egress_is_approved() {
            ModelListResult::valid(vec![ModelDescriptor::new(
                "gpt-4.1-mini",
                "provider.openai",
                ModelFormat::RemoteChat,
            )])
        } else {
            ModelListResult::egress_denied()
        }
    }
}

#[derive(Default)]
struct RecordingLocalProviderAdapter {
    last_validation_used_egress_decision: Mutex<bool>,
}

impl RecordingLocalProviderAdapter {
    fn last_validation_used_egress_decision(&self) -> bool {
        *self
            .last_validation_used_egress_decision
            .lock()
            .expect("validation recorder poisoned")
    }
}

impl ModelProviderAdapter for RecordingLocalProviderAdapter {
    fn provider_definition(&self) -> ProviderDefinition {
        ProviderDefinition::new("provider.local", "Local Provider")
    }

    fn validate_account(
        &self,
        request: ProviderAccountValidationRequest,
    ) -> ProviderAccountValidation {
        *self
            .last_validation_used_egress_decision
            .lock()
            .expect("validation recorder poisoned") = request.egress_decision().is_some();
        ProviderAccountValidation::valid()
    }

    fn list_models(&self, _request: ModelListRequest) -> ModelListResult {
        ModelListResult::valid(Vec::new())
    }
}

fn remote_account() -> ProviderAccount {
    ProviderAccount::remote(
        "account.openai-main",
        "provider.openai",
        "https://api.openai.com",
        CredentialRef::new("credential.openai-main"),
    )
}

fn local_account() -> ProviderAccount {
    ProviderAccount::local("account.local", "provider.local")
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
            "Allow provider egress?",
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
