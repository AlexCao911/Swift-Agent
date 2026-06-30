use local_ios_agent_runtime::inference::{
    BackendCapabilities, BackendFailure, BackendFailureKind, BackendRuntimeEventKind,
    FakeInferenceBackend, GenerationRequest, GenerationSession, InferenceBackend, InferenceResult,
    InferenceRouter, LoadedModel, LoadedModelKey, RouterGenerationPermit, UsageReport,
};
use local_ios_agent_runtime::model::{ModelDescriptor, ModelFormat, ProviderDefinition};
use local_ios_agent_runtime::{
    core::{EntryId, RunId},
    security::{
        ApprovalProtocolResponse, ApprovalScope, DataEgressRequest, EgressDestination,
        OperationDescriptor, SecurityManager, SecurityPermissionService,
        StaticSecurityPermissionService,
    },
};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

#[test]
fn backend_failure_has_stable_kind_codes() {
    let failure = BackendFailure::new(BackendFailureKind::GenerationTimeout, "timed out");

    assert_eq!(failure.kind().code(), "generation.timeout");
}

#[test]
fn router_rejects_unsupported_model_format() {
    let provider = ProviderDefinition::new("provider.local", "Local");
    let model = ModelDescriptor::new("remote-only", provider.id(), ModelFormat::RemoteChat);
    let router = InferenceRouter::new(vec![Box::new(FakeInferenceBackend::local_gguf())]);

    let error = router.select_backend(&model).unwrap_err();

    assert_eq!(error.kind().code(), "unsupported.model_format");
}

#[test]
fn router_rejects_remote_generation_without_egress_decision_before_backend_start() {
    let backend = PermissiveRemoteBackend::new("https://api.openai.com");
    let started = backend.started.clone();
    let router = InferenceRouter::new(vec![Box::new(backend)]);
    let provider = ProviderDefinition::new("provider.remote", "Remote");
    let model = ModelDescriptor::new("remote-model", provider.id(), ModelFormat::RemoteChat);
    let request = GenerationRequest::fixture_remote_without_egress();

    let error = router.start_session(&model, request).unwrap_err();

    assert_eq!(error.kind().code(), "remote.egress_required");
    assert_eq!(started.load(Ordering::SeqCst), 0);
}

#[test]
fn router_rejects_remote_generation_without_required_approval_grant() {
    let backend = FakeInferenceBackend::remote_http("https://api.openai.com");
    let router = InferenceRouter::new(vec![Box::new(backend)]);
    let provider = ProviderDefinition::new("provider.remote", "Remote");
    let model = ModelDescriptor::new("gpt-4.1-mini", provider.id(), ModelFormat::RemoteChat);
    let service = StaticSecurityPermissionService::default()
        .allow_destination(EgressDestination::new("https://api.openai.com"));
    let decision = service.evaluate_egress(DataEgressRequest::remote_inference(
        "https://api.openai.com",
    ));
    let request = GenerationRequest::remote("gpt-4.1-mini", decision, None);

    let error = router.start_session(&model, request).unwrap_err();

    assert_eq!(error.kind().code(), "remote.egress_required");
}

#[test]
fn router_starts_local_generation_without_egress_decision() {
    let backend = FakeInferenceBackend::local_gguf();
    let router = InferenceRouter::new(vec![Box::new(backend)]);
    let provider = ProviderDefinition::new("provider.local", "Local");
    let model = ModelDescriptor::new("llama-3.2", provider.id(), ModelFormat::Gguf);
    let request = GenerationRequest::local("llama-3.2");

    let session = router.start_session(&model, request).unwrap();

    assert_eq!(session.model_id(), "llama-3.2");
}

#[test]
fn start_session_loads_model_once_and_reuses_loaded_model() {
    let backend = FakeInferenceBackend::local_gguf().with_model_id("llama-3.2");
    let router = InferenceRouter::new(vec![Box::new(backend.clone())]);
    let provider = ProviderDefinition::new("provider.local", "Local");
    let model = ModelDescriptor::new("llama-3.2", provider.id(), ModelFormat::Gguf);

    router
        .start_session(&model, GenerationRequest::local("llama-3.2"))
        .unwrap();
    router
        .start_session(&model, GenerationRequest::local("llama-3.2"))
        .unwrap();

    assert_eq!(backend.load_count("llama-3.2"), 1);
    assert!(router
        .loaded_model(&LoadedModelKey::from_model(&model))
        .is_some());
}

#[test]
fn router_rejects_generation_request_for_different_model_id() {
    let backend = FakeInferenceBackend::local_gguf();
    let router = InferenceRouter::new(vec![Box::new(backend)]);
    let provider = ProviderDefinition::new("provider.local", "Local");
    let model = ModelDescriptor::new("llama-3.2", provider.id(), ModelFormat::Gguf);

    let error = router
        .start_session(&model, GenerationRequest::local("other-model"))
        .unwrap_err();

    assert_eq!(error.kind().code(), "generation.rejected");
}

#[test]
fn router_starts_remote_generation_with_matching_egress_approval() {
    let backend = FakeInferenceBackend::remote_http("https://api.openai.com");
    let router = InferenceRouter::new(vec![Box::new(backend)]);
    let provider = ProviderDefinition::new("provider.remote", "Remote");
    let model = ModelDescriptor::new("gpt-4.1-mini", provider.id(), ModelFormat::RemoteChat);
    let (decision, grant) = approved_remote_inference_egress("https://api.openai.com");
    let request = GenerationRequest::remote("gpt-4.1-mini", decision, Some(grant));

    let session = router.start_session(&model, request).unwrap();

    assert_eq!(session.model_id(), "gpt-4.1-mini");
}

#[test]
fn generation_session_can_be_cancelled() {
    let mut session = GenerationSession::new("llama-3.2").with_tokens(["hello"]);

    session.cancel();

    assert!(session.is_cancelled());
    assert_eq!(
        session.next_token().unwrap_err().kind().code(),
        "generation.cancelled"
    );
}

#[test]
fn fake_backend_streams_fixture_tokens() {
    let backend = FakeInferenceBackend::local_gguf().with_tokens(["hello", " world"]);
    let router = InferenceRouter::new(vec![Box::new(backend)]);
    let provider = ProviderDefinition::new("provider.local", "Local");
    let model = ModelDescriptor::new("llama-3.2", provider.id(), ModelFormat::Gguf);

    let mut session = router
        .start_session(&model, GenerationRequest::local("llama-3.2"))
        .unwrap();

    assert_eq!(session.next_token().unwrap(), Some("hello".to_string()));
    assert_eq!(session.next_token().unwrap(), Some(" world".to_string()));
    assert_eq!(session.next_token().unwrap(), None);
}

#[test]
fn usage_report_normalizes_local_and_remote_sessions() {
    let local_backend = FakeInferenceBackend::local_gguf().with_usage(UsageReport::new(12, 4));
    let remote_backend = FakeInferenceBackend::remote_http("https://api.openai.com")
        .with_usage(UsageReport::new(20, 8));
    let local_router = InferenceRouter::new(vec![Box::new(local_backend)]);
    let remote_router = InferenceRouter::new(vec![Box::new(remote_backend)]);
    let local_provider = ProviderDefinition::new("provider.local", "Local");
    let remote_provider = ProviderDefinition::new("provider.remote", "Remote");
    let local_model = ModelDescriptor::new("llama-3.2", local_provider.id(), ModelFormat::Gguf);
    let remote_model = ModelDescriptor::new(
        "gpt-4.1-mini",
        remote_provider.id(),
        ModelFormat::RemoteChat,
    );
    let (decision, grant) = approved_remote_inference_egress("https://api.openai.com");

    let local_session = local_router
        .start_session(&local_model, GenerationRequest::local("llama-3.2"))
        .unwrap();
    let remote_session = remote_router
        .start_session(
            &remote_model,
            GenerationRequest::remote("gpt-4.1-mini", decision, Some(grant)),
        )
        .unwrap();

    assert_eq!(local_session.usage().unwrap().total_tokens(), 16);
    assert_eq!(remote_session.usage().unwrap().total_tokens(), 28);
}

#[test]
fn router_uses_backend_max_loaded_model_capacity() {
    let backend = FakeInferenceBackend::local_gguf().with_max_loaded_models(1);
    let router = InferenceRouter::new(vec![Box::new(backend)]);
    let provider = ProviderDefinition::new("provider.local", "Local");

    router
        .load_or_get(&ModelDescriptor::new(
            "model.a",
            provider.id(),
            ModelFormat::Gguf,
        ))
        .unwrap();
    router
        .load_or_get(&ModelDescriptor::new(
            "model.b",
            provider.id(),
            ModelFormat::Gguf,
        ))
        .unwrap();

    assert!(router
        .loaded_model(&LoadedModelKey::new("provider.local", "model.a"))
        .is_none());
    assert!(router
        .loaded_model(&LoadedModelKey::new("provider.local", "model.b"))
        .is_some());
}

#[test]
fn backend_loaded_model_identity_must_match_request() {
    let provider = ProviderDefinition::new("provider.local", "Local");
    let model = ModelDescriptor::new("llama-3.2", provider.id(), ModelFormat::Gguf);
    let wrong_key_backend = MisreportingLoadedModelBackend::new(
        "backend.local",
        LoadedModel::new(
            LoadedModelKey::new("provider.local", "other-model"),
            "backend.local",
        ),
    );
    let router = InferenceRouter::new(vec![Box::new(wrong_key_backend)]);

    let wrong_key_error = router.load_or_get(&model).unwrap_err();

    assert_eq!(wrong_key_error.kind().code(), "model.load_failed");

    let wrong_backend = MisreportingLoadedModelBackend::new(
        "backend.local",
        LoadedModel::new(LoadedModelKey::from_model(&model), "backend.other"),
    );
    let router = InferenceRouter::new(vec![Box::new(wrong_backend)]);

    let wrong_backend_error = router.load_or_get(&model).unwrap_err();

    assert_eq!(wrong_backend_error.kind().code(), "model.load_failed");
}

#[test]
fn cache_eviction_emits_backend_runtime_event() {
    let backend = FakeInferenceBackend::local_gguf().with_max_loaded_models(1);
    let router = InferenceRouter::new(vec![Box::new(backend)]);
    let provider = ProviderDefinition::new("provider.local", "Local");

    router
        .load_or_get(&ModelDescriptor::new(
            "model.a",
            provider.id(),
            ModelFormat::Gguf,
        ))
        .unwrap();
    router
        .load_or_get(&ModelDescriptor::new(
            "model.b",
            provider.id(),
            ModelFormat::Gguf,
        ))
        .unwrap();

    let events = router.runtime_events();
    let eviction = events
        .iter()
        .find(|event| event.kind() == BackendRuntimeEventKind::LoadedModelEvicted)
        .unwrap();

    assert_eq!(eviction.backend_id(), "fake.local_gguf");
    assert_eq!(
        eviction.model_key(),
        Some(&LoadedModelKey::new("provider.local", "model.a"))
    );
}

#[test]
fn remote_generation_event_records_redacted_egress_metadata() {
    let backend = FakeInferenceBackend::remote_http("https://api.openai.com");
    let router = InferenceRouter::new(vec![Box::new(backend)]);
    let provider = ProviderDefinition::new("provider.remote", "Remote");
    let model = ModelDescriptor::new("gpt-4.1-mini", provider.id(), ModelFormat::RemoteChat);
    let (decision, grant) = approved_remote_inference_egress("https://api.openai.com");
    let disclosure_id = decision.disclosure_id().as_str().to_string();

    router
        .start_session(
            &model,
            GenerationRequest::remote("gpt-4.1-mini", decision, Some(grant)),
        )
        .unwrap();

    let events = router.runtime_events();
    let started = events
        .iter()
        .find(|event| event.kind() == BackendRuntimeEventKind::RemoteGenerationStarted)
        .unwrap();

    assert_eq!(started.backend_id(), "fake.remote_http");
    assert_eq!(started.egress_disclosure_id(), Some(disclosure_id.as_str()));
    assert_eq!(
        started.redacted_destination(),
        Some("https://api.openai.com")
    );
    assert!(!format!("{started:?}").contains("conversation.content"));
}

#[test]
fn backend_loaded_model_capacity_only_evicts_models_for_that_backend() {
    let backend_a = FakeInferenceBackend::local_gguf()
        .with_backend_id("backend.a")
        .with_provider_id("provider.a")
        .with_max_loaded_models(1);
    let backend_b = FakeInferenceBackend::local_gguf()
        .with_backend_id("backend.b")
        .with_provider_id("provider.b")
        .with_max_loaded_models(1);
    let router = InferenceRouter::new(vec![Box::new(backend_a), Box::new(backend_b)]);

    router
        .load_or_get(&ModelDescriptor::new(
            "model.a1",
            "provider.a",
            ModelFormat::Gguf,
        ))
        .unwrap();
    router
        .load_or_get(&ModelDescriptor::new(
            "model.b1",
            "provider.b",
            ModelFormat::Gguf,
        ))
        .unwrap();
    router
        .load_or_get(&ModelDescriptor::new(
            "model.a2",
            "provider.a",
            ModelFormat::Gguf,
        ))
        .unwrap();

    assert!(router
        .loaded_model(&LoadedModelKey::new("provider.a", "model.a1"))
        .is_none());
    assert!(router
        .loaded_model(&LoadedModelKey::new("provider.a", "model.a2"))
        .is_some());
    assert!(router
        .loaded_model(&LoadedModelKey::new("provider.b", "model.b1"))
        .is_some());
}

#[test]
fn router_routes_by_provider_binding_when_formats_overlap() {
    let openai_backend = FakeInferenceBackend::remote_http("https://api.openai.com")
        .with_backend_id("backend.openai")
        .with_provider_id("provider.openai");
    let anthropic_backend = FakeInferenceBackend::remote_http("https://api.anthropic.com")
        .with_backend_id("backend.anthropic")
        .with_provider_id("provider.anthropic");
    let router = InferenceRouter::new(vec![Box::new(openai_backend), Box::new(anthropic_backend)]);
    let provider = ProviderDefinition::new("provider.anthropic", "Anthropic");
    let model = ModelDescriptor::new("claude", provider.id(), ModelFormat::RemoteChat);

    let loaded = router.load_or_get(&model).unwrap();

    assert_eq!(loaded.backend_id(), "backend.anthropic");
}

#[test]
fn backend_enforces_max_sessions_per_model() {
    let backend = FakeInferenceBackend::local_gguf().with_max_sessions_per_model(1);
    let router = InferenceRouter::new(vec![Box::new(backend)]);
    let provider = ProviderDefinition::new("provider.local", "Local");
    let model = ModelDescriptor::new("llama-3.2", provider.id(), ModelFormat::Gguf);
    let first = router
        .start_session(&model, GenerationRequest::local("llama-3.2"))
        .unwrap();

    let error = router
        .start_session(&model, GenerationRequest::local("llama-3.2"))
        .unwrap_err();
    assert_eq!(error.kind().code(), "generation.rejected");

    drop(first);
    router
        .start_session(&model, GenerationRequest::local("llama-3.2"))
        .unwrap();
}

#[test]
fn load_or_get_reuses_loaded_model_for_same_key() {
    let backend = FakeInferenceBackend::local_gguf().with_model_id("llama-3.2");
    let router = InferenceRouter::new(vec![Box::new(backend.clone())]);
    let provider = ProviderDefinition::new("provider.local", "Local");
    let model = ModelDescriptor::new("llama-3.2", provider.id(), ModelFormat::Gguf);
    let key = LoadedModelKey::from_model(&model);

    let first = router.load_or_get(&model).unwrap();
    let second = router.load_or_get(&model).unwrap();

    assert_eq!(first.key(), &key);
    assert_eq!(second.key(), &key);
    assert_eq!(backend.load_count("llama-3.2"), 1);
}

#[test]
fn load_or_get_evicts_least_recently_used_model_when_capacity_is_reached() {
    let backend = FakeInferenceBackend::local_gguf();
    let router =
        InferenceRouter::new(vec![Box::new(backend.clone())]).with_loaded_model_capacity(1);
    let provider = ProviderDefinition::new("provider.local", "Local");

    router
        .load_or_get(&ModelDescriptor::new(
            "model.a",
            provider.id(),
            ModelFormat::Gguf,
        ))
        .unwrap();
    router
        .load_or_get(&ModelDescriptor::new(
            "model.b",
            provider.id(),
            ModelFormat::Gguf,
        ))
        .unwrap();

    assert!(router
        .loaded_model(&LoadedModelKey::new("provider.local", "model.a"))
        .is_none());
    assert!(router
        .loaded_model(&LoadedModelKey::new("provider.local", "model.b"))
        .is_some());
}

#[derive(Debug)]
struct PermissiveRemoteBackend {
    capabilities: BackendCapabilities,
    started: Arc<AtomicUsize>,
}

impl PermissiveRemoteBackend {
    fn new(destination: &str) -> Self {
        Self {
            capabilities: BackendCapabilities::remote(vec![ModelFormat::RemoteChat])
                .with_egress_destination(destination)
                .with_provider_id("provider.remote"),
            started: Arc::new(AtomicUsize::new(0)),
        }
    }
}

#[derive(Debug)]
struct MisreportingLoadedModelBackend {
    backend_id: String,
    loaded_model: LoadedModel,
}

impl MisreportingLoadedModelBackend {
    fn new(backend_id: impl Into<String>, loaded_model: LoadedModel) -> Self {
        Self {
            backend_id: backend_id.into(),
            loaded_model,
        }
    }
}

impl InferenceBackend for MisreportingLoadedModelBackend {
    fn backend_id(&self) -> &str {
        &self.backend_id
    }

    fn capabilities(&self) -> BackendCapabilities {
        BackendCapabilities::local(vec![ModelFormat::Gguf])
    }

    fn load_model(&self, _model: &ModelDescriptor) -> InferenceResult<LoadedModel> {
        Ok(self.loaded_model.clone())
    }

    fn start_session(
        &self,
        request: GenerationRequest,
        _permit: RouterGenerationPermit,
    ) -> InferenceResult<GenerationSession> {
        Ok(GenerationSession::new(request.model_id))
    }
}

impl InferenceBackend for PermissiveRemoteBackend {
    fn backend_id(&self) -> &str {
        "permissive.remote"
    }

    fn capabilities(&self) -> BackendCapabilities {
        self.capabilities.clone()
    }

    fn load_model(&self, model: &ModelDescriptor) -> InferenceResult<LoadedModel> {
        Ok(LoadedModel::new(
            LoadedModelKey::from_model(model),
            self.backend_id(),
        ))
    }

    fn start_session(
        &self,
        request: GenerationRequest,
        _permit: RouterGenerationPermit,
    ) -> InferenceResult<GenerationSession> {
        self.started.fetch_add(1, Ordering::SeqCst);
        Ok(GenerationSession::new(request.model_id))
    }
}

fn approved_remote_inference_egress(
    destination: &str,
) -> (
    local_ios_agent_runtime::security::DataEgressDecision,
    local_ios_agent_runtime::security::ApprovalGrant,
) {
    let service = StaticSecurityPermissionService::default()
        .allow_destination(EgressDestination::new(destination));
    let decision = service.evaluate_egress(DataEgressRequest::remote_inference(destination));
    let mut manager = SecurityManager::new();
    manager
        .request_approval(
            "approval_1",
            RunId("run_1".to_string()),
            EntryId("entry_1".to_string()),
            "Allow remote inference?",
            false,
            ApprovalScope::egress(
                OperationDescriptor::new("remote.inference.generate"),
                &decision,
            )
            .unwrap(),
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
