use crate::inference::LoadedModelKey;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum BackendRuntimeEventKind {
    LoadedModelEvicted,
    RemoteGenerationStarted,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BackendRuntimeEvent {
    kind: BackendRuntimeEventKind,
    backend_id: String,
    model_key: Option<LoadedModelKey>,
    egress_disclosure_id: Option<String>,
    redacted_destination: Option<String>,
}

impl BackendRuntimeEvent {
    pub fn loaded_model_evicted(backend_id: impl Into<String>, model_key: LoadedModelKey) -> Self {
        Self {
            kind: BackendRuntimeEventKind::LoadedModelEvicted,
            backend_id: backend_id.into(),
            model_key: Some(model_key),
            egress_disclosure_id: None,
            redacted_destination: None,
        }
    }

    pub fn remote_generation_started(
        backend_id: impl Into<String>,
        model_key: LoadedModelKey,
        disclosure_id: impl Into<String>,
        redacted_destination: impl Into<String>,
    ) -> Self {
        Self {
            kind: BackendRuntimeEventKind::RemoteGenerationStarted,
            backend_id: backend_id.into(),
            model_key: Some(model_key),
            egress_disclosure_id: Some(disclosure_id.into()),
            redacted_destination: Some(redacted_destination.into()),
        }
    }

    pub fn kind(&self) -> BackendRuntimeEventKind {
        self.kind.clone()
    }

    pub fn backend_id(&self) -> &str {
        &self.backend_id
    }

    pub fn model_key(&self) -> Option<&LoadedModelKey> {
        self.model_key.as_ref()
    }

    pub fn egress_disclosure_id(&self) -> Option<&str> {
        self.egress_disclosure_id.as_deref()
    }

    pub fn redacted_destination(&self) -> Option<&str> {
        self.redacted_destination.as_deref()
    }
}
