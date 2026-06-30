use crate::inference::{
    ActiveSessionCounts, BackendCapabilities, BackendFailure, BackendFailureKind,
    GenerationRequest, GenerationSession, InferenceBackend, InferenceResult, LoadedModel,
    LoadedModelKey, RouterGenerationPermit, UsageReport,
};
use crate::model::{ModelDescriptor, ModelFormat};
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

#[derive(Clone, Debug)]
pub struct FakeInferenceBackend {
    backend_id: String,
    capabilities: BackendCapabilities,
    tokens: Vec<String>,
    usage: Option<UsageReport>,
    max_sessions_per_model: usize,
    state: Arc<FakeInferenceBackendState>,
}

#[derive(Debug, Default)]
struct FakeInferenceBackendState {
    load_counts: Mutex<BTreeMap<String, usize>>,
    active_sessions: ActiveSessionCounts,
}

impl FakeInferenceBackend {
    pub fn local_gguf() -> Self {
        Self {
            backend_id: "fake.local_gguf".to_string(),
            capabilities: BackendCapabilities::local(vec![ModelFormat::Gguf]),
            tokens: Vec::new(),
            usage: None,
            max_sessions_per_model: usize::MAX,
            state: Arc::new(FakeInferenceBackendState::default()),
        }
    }

    pub fn remote_http(destination: impl Into<String>) -> Self {
        let destination = destination.into();
        Self {
            backend_id: "fake.remote_http".to_string(),
            capabilities: BackendCapabilities::remote(vec![ModelFormat::RemoteChat])
                .with_egress_destination(destination),
            tokens: Vec::new(),
            usage: None,
            max_sessions_per_model: usize::MAX,
            state: Arc::new(FakeInferenceBackendState::default()),
        }
    }

    pub fn with_model_id(self, _model_id: impl Into<String>) -> Self {
        self
    }

    pub fn with_backend_id(mut self, backend_id: impl Into<String>) -> Self {
        self.backend_id = backend_id.into();
        self
    }

    pub fn with_provider_id(mut self, provider_id: impl Into<String>) -> Self {
        self.capabilities = self.capabilities.with_provider_id(provider_id);
        self
    }

    pub fn with_tokens<I, S>(mut self, tokens: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        self.tokens = tokens.into_iter().map(Into::into).collect();
        self
    }

    pub fn with_usage(mut self, usage: UsageReport) -> Self {
        self.usage = Some(usage);
        self
    }

    pub fn with_max_sessions_per_model(mut self, max_sessions: usize) -> Self {
        self.max_sessions_per_model = max_sessions;
        self.capabilities = self.capabilities.with_max_sessions_per_model(max_sessions);
        self
    }

    pub fn with_max_loaded_models(mut self, max_loaded_models: usize) -> Self {
        self.capabilities = self.capabilities.with_max_loaded_models(max_loaded_models);
        self
    }

    pub fn load_count(&self, model_id: &str) -> usize {
        self.state
            .load_counts
            .lock()
            .expect("fake backend load counts poisoned")
            .get(model_id)
            .copied()
            .unwrap_or(0)
    }
}

impl InferenceBackend for FakeInferenceBackend {
    fn backend_id(&self) -> &str {
        &self.backend_id
    }

    fn capabilities(&self) -> BackendCapabilities {
        self.capabilities.clone()
    }

    fn load_model(&self, model: &ModelDescriptor) -> InferenceResult<LoadedModel> {
        let mut counts = self
            .state
            .load_counts
            .lock()
            .expect("fake backend load counts poisoned");
        *counts.entry(model.id.clone()).or_insert(0) += 1;
        Ok(LoadedModel::new(
            LoadedModelKey::from_model(model),
            self.backend_id.clone(),
        ))
    }

    fn start_session(
        &self,
        request: GenerationRequest,
        _permit: RouterGenerationPermit,
    ) -> InferenceResult<GenerationSession> {
        self.reserve_session(&request.model_id)?;
        let mut session = GenerationSession::new(request.model_id)
            .with_tokens(self.tokens.clone())
            .with_session_lease(self.state.active_sessions.clone());
        if let Some(usage) = self.usage.clone() {
            session = session.with_usage(usage);
        }
        Ok(session)
    }
}

impl FakeInferenceBackend {
    fn reserve_session(&self, model_id: &str) -> InferenceResult<()> {
        let mut active_sessions = self
            .state
            .active_sessions
            .lock()
            .expect("fake backend active sessions poisoned");
        let current = active_sessions.get(model_id).copied().unwrap_or(0);
        if current >= self.max_sessions_per_model {
            return Err(BackendFailure::new(
                BackendFailureKind::GenerationRejected,
                format!("model {model_id} has reached max concurrent generation sessions"),
            ));
        }
        active_sessions.insert(model_id.to_string(), current + 1);
        Ok(())
    }
}
