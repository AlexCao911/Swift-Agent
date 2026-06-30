use std::fmt;

use crate::inference::{GenerationRequest, GenerationSession, LoadedModel};
use crate::model::{ModelDescriptor, ModelFormat};

pub type InferenceResult<T> = Result<T, BackendFailure>;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum BackendFailureKind {
    UnsupportedModelFormat,
    ModelLoadFailed,
    BackendUnavailable,
    GenerationRejected,
    GenerationTimeout,
    GenerationCancelled,
    RemoteEgressRequired,
    RemoteRateLimited,
    RemoteAuthFailed,
    TokenStreamInterrupted,
    UsageUnavailable,
}

impl BackendFailureKind {
    pub fn code(&self) -> &'static str {
        match self {
            Self::UnsupportedModelFormat => "unsupported.model_format",
            Self::ModelLoadFailed => "model.load_failed",
            Self::BackendUnavailable => "backend.unavailable",
            Self::GenerationRejected => "generation.rejected",
            Self::GenerationTimeout => "generation.timeout",
            Self::GenerationCancelled => "generation.cancelled",
            Self::RemoteEgressRequired => "remote.egress_required",
            Self::RemoteRateLimited => "remote.rate_limited",
            Self::RemoteAuthFailed => "remote.auth_failed",
            Self::TokenStreamInterrupted => "token_stream.interrupted",
            Self::UsageUnavailable => "usage.unavailable",
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BackendFailure {
    kind: BackendFailureKind,
    message: String,
}

impl BackendFailure {
    pub fn new(kind: BackendFailureKind, message: impl Into<String>) -> Self {
        Self {
            kind,
            message: message.into(),
        }
    }

    pub fn kind(&self) -> &BackendFailureKind {
        &self.kind
    }

    pub fn message(&self) -> &str {
        &self.message
    }
}

impl fmt::Display for BackendFailure {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}: {}", self.kind.code(), self.message)
    }
}

impl std::error::Error for BackendFailure {}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BackendCapabilities {
    supported_formats: Vec<ModelFormat>,
    provider_ids: Vec<String>,
    remote: bool,
    egress_destination: Option<String>,
    max_loaded_models: Option<usize>,
    max_sessions_per_model: Option<usize>,
}

impl BackendCapabilities {
    pub fn local(supported_formats: Vec<ModelFormat>) -> Self {
        Self {
            supported_formats,
            provider_ids: Vec::new(),
            remote: false,
            egress_destination: None,
            max_loaded_models: None,
            max_sessions_per_model: None,
        }
    }

    pub fn remote(supported_formats: Vec<ModelFormat>) -> Self {
        Self {
            supported_formats,
            provider_ids: Vec::new(),
            remote: true,
            egress_destination: None,
            max_loaded_models: None,
            max_sessions_per_model: None,
        }
    }

    pub fn with_provider_id(mut self, provider_id: impl Into<String>) -> Self {
        self.provider_ids.push(provider_id.into());
        self
    }

    pub fn with_egress_destination(mut self, destination: impl Into<String>) -> Self {
        self.egress_destination = Some(destination.into());
        self
    }

    pub fn with_max_loaded_models(mut self, max_loaded_models: usize) -> Self {
        self.max_loaded_models = Some(max_loaded_models);
        self
    }

    pub fn with_max_sessions_per_model(mut self, max_sessions: usize) -> Self {
        self.max_sessions_per_model = Some(max_sessions);
        self
    }

    pub fn supports_model(&self, model: &ModelDescriptor) -> bool {
        let format_matches = model
            .supported_formats
            .iter()
            .any(|format| self.supported_formats.contains(format));
        let provider_matches =
            self.provider_ids.is_empty() || self.provider_ids.contains(&model.provider_id);
        format_matches && provider_matches
    }

    pub fn is_remote(&self) -> bool {
        self.remote
    }

    pub fn egress_destination(&self) -> Option<&str> {
        self.egress_destination.as_deref()
    }

    pub fn max_loaded_models(&self) -> Option<usize> {
        self.max_loaded_models
    }

    pub fn max_sessions_per_model(&self) -> Option<usize> {
        self.max_sessions_per_model
    }
}

#[derive(Debug)]
pub struct RouterGenerationPermit {
    _private: (),
}

impl RouterGenerationPermit {
    pub(in crate::inference) fn new() -> Self {
        Self { _private: () }
    }
}

pub trait InferenceBackend: fmt::Debug + Send + Sync {
    fn backend_id(&self) -> &str;
    fn capabilities(&self) -> BackendCapabilities;

    fn can_load(&self, model: &ModelDescriptor) -> bool {
        self.capabilities().supports_model(model)
    }

    fn load_model(&self, model: &ModelDescriptor) -> InferenceResult<LoadedModel>;

    fn start_session(
        &self,
        request: GenerationRequest,
        permit: RouterGenerationPermit,
    ) -> InferenceResult<GenerationSession>;
}
