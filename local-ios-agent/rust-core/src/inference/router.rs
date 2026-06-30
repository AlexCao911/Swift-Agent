use std::collections::{HashMap, VecDeque};
use std::fmt;
use std::sync::Mutex;

use crate::inference::{
    egress_requires_approval, BackendCapabilities, BackendFailure, BackendFailureKind,
    BackendRuntimeEvent, GenerationRequest, GenerationSession, InferenceBackend, InferenceResult,
    LoadedModel, LoadedModelKey, RouterGenerationPermit,
};
use crate::model::ModelDescriptor;
use crate::security::OperationDescriptor;

pub struct InferenceRouter {
    backends: Vec<Box<dyn InferenceBackend>>,
    loaded_models: Mutex<LoadedModelCache>,
    runtime_events: Mutex<Vec<BackendRuntimeEvent>>,
    loaded_model_capacity: usize,
}

impl InferenceRouter {
    pub fn new(backends: Vec<Box<dyn InferenceBackend>>) -> Self {
        Self {
            backends,
            loaded_models: Mutex::new(LoadedModelCache::default()),
            runtime_events: Mutex::new(Vec::new()),
            loaded_model_capacity: 8,
        }
    }

    pub fn with_loaded_model_capacity(mut self, capacity: usize) -> Self {
        self.loaded_model_capacity = capacity;
        self
    }

    pub fn select_backend(&self, model: &ModelDescriptor) -> InferenceResult<SelectedBackend<'_>> {
        self.select_backend_ref(model)
            .map(|backend| SelectedBackend { backend })
    }

    fn select_backend_ref(
        &self,
        model: &ModelDescriptor,
    ) -> InferenceResult<&dyn InferenceBackend> {
        self.backends
            .iter()
            .find(|backend| backend.can_load(model))
            .map(|backend| backend.as_ref())
            .ok_or_else(|| {
                BackendFailure::new(
                    BackendFailureKind::UnsupportedModelFormat,
                    format!("no inference backend can load model {}", model.id),
                )
            })
    }

    fn backend_by_id(&self, backend_id: &str) -> InferenceResult<&dyn InferenceBackend> {
        self.backends
            .iter()
            .find(|backend| backend.backend_id() == backend_id)
            .map(|backend| backend.as_ref())
            .ok_or_else(|| {
                BackendFailure::new(
                    BackendFailureKind::BackendUnavailable,
                    format!("loaded model backend {backend_id} is not registered"),
                )
            })
    }

    pub fn load_or_get(&self, model: &ModelDescriptor) -> InferenceResult<LoadedModel> {
        let key = LoadedModelKey::from_model(model);
        let mut cache = self
            .loaded_models
            .lock()
            .expect("loaded model cache poisoned");
        if let Some(loaded) = cache.get_and_touch(&key) {
            return Ok(loaded);
        }

        let backend = self.select_backend_ref(model)?;
        let loaded = backend.load_model(model)?;
        self.validate_loaded_model_identity(&key, backend.backend_id(), &loaded)?;
        let evicted = cache.insert(
            key,
            loaded.clone(),
            self.loaded_model_capacity,
            backend
                .capabilities()
                .max_loaded_models()
                .unwrap_or(self.loaded_model_capacity),
        );
        self.record_runtime_events(evicted.into_iter().map(|loaded| {
            BackendRuntimeEvent::loaded_model_evicted(
                loaded.backend_id().to_string(),
                loaded.key().clone(),
            )
        }));
        Ok(loaded)
    }

    pub fn start_session(
        &self,
        model: &ModelDescriptor,
        request: GenerationRequest,
    ) -> InferenceResult<GenerationSession> {
        self.validate_request_model_binding(model, &request)?;
        let selected_backend = self.select_backend_ref(model)?;
        self.validate_generation_request(&selected_backend.capabilities(), &request)?;
        let loaded_model = self.load_or_get(model)?;
        let backend = self.backend_by_id(loaded_model.backend_id())?;
        let capabilities = backend.capabilities();
        self.validate_generation_request(&capabilities, &request)?;
        let runtime_event =
            self.remote_generation_started_event(backend.backend_id(), &loaded_model, &request);
        let session = backend.start_session(request, RouterGenerationPermit::new())?;
        if let Some(event) = runtime_event {
            self.record_runtime_event(event);
        }
        Ok(session)
    }

    pub fn loaded_model(&self, key: &LoadedModelKey) -> Option<LoadedModel> {
        self.loaded_models
            .lock()
            .expect("loaded model cache poisoned")
            .models
            .get(key)
            .cloned()
    }

    pub fn runtime_events(&self) -> Vec<BackendRuntimeEvent> {
        self.runtime_events
            .lock()
            .expect("backend runtime events poisoned")
            .clone()
    }

    fn validate_generation_request(
        &self,
        capabilities: &BackendCapabilities,
        request: &GenerationRequest,
    ) -> InferenceResult<()> {
        if !capabilities.is_remote() {
            return Ok(());
        }

        let Some(destination) = capabilities.egress_destination() else {
            return Err(remote_egress_required(
                "remote inference backend must declare egress destination",
            ));
        };
        let Some(decision) = request.egress_decision.as_ref() else {
            return Err(remote_egress_required(
                "remote inference requires egress decision",
            ));
        };
        let operation = OperationDescriptor::new("remote.inference.generate");
        if decision.operation() != &operation
            || !decision.allowlist_result().is_allowed()
            || decision.policy().destination().as_str() != destination
        {
            return Err(remote_egress_required(
                "remote inference egress decision does not match backend",
            ));
        }
        if egress_requires_approval(decision)
            && !request
                .approval_grant
                .as_ref()
                .map(|grant| grant.matches_egress(&operation, decision))
                .unwrap_or(false)
        {
            return Err(remote_egress_required(
                "remote inference requires matching egress approval",
            ));
        }

        Ok(())
    }

    fn validate_request_model_binding(
        &self,
        model: &ModelDescriptor,
        request: &GenerationRequest,
    ) -> InferenceResult<()> {
        if request.model_id == model.id {
            return Ok(());
        }

        Err(BackendFailure::new(
            BackendFailureKind::GenerationRejected,
            format!(
                "generation request model {} does not match resolved model {}",
                request.model_id, model.id
            ),
        ))
    }

    fn validate_loaded_model_identity(
        &self,
        requested_key: &LoadedModelKey,
        backend_id: &str,
        loaded: &LoadedModel,
    ) -> InferenceResult<()> {
        if loaded.key() == requested_key && loaded.backend_id() == backend_id {
            return Ok(());
        }

        Err(BackendFailure::new(
            BackendFailureKind::ModelLoadFailed,
            format!(
                "backend {backend_id} returned loaded model key {:?} from backend {} for requested key {:?}",
                loaded.key(),
                loaded.backend_id(),
                requested_key
            ),
        ))
    }

    fn remote_generation_started_event(
        &self,
        backend_id: &str,
        loaded_model: &LoadedModel,
        request: &GenerationRequest,
    ) -> Option<BackendRuntimeEvent> {
        let decision = request.egress_decision.as_ref()?;
        Some(BackendRuntimeEvent::remote_generation_started(
            backend_id.to_string(),
            loaded_model.key().clone(),
            decision.disclosure_id().as_str().to_string(),
            decision.policy().destination().as_str().to_string(),
        ))
    }

    fn record_runtime_event(&self, event: BackendRuntimeEvent) {
        self.runtime_events
            .lock()
            .expect("backend runtime events poisoned")
            .push(event);
    }

    fn record_runtime_events<I>(&self, events: I)
    where
        I: IntoIterator<Item = BackendRuntimeEvent>,
    {
        let mut runtime_events = self
            .runtime_events
            .lock()
            .expect("backend runtime events poisoned");
        runtime_events.extend(events);
    }
}

pub struct SelectedBackend<'a> {
    backend: &'a dyn InferenceBackend,
}

impl SelectedBackend<'_> {
    pub fn backend_id(&self) -> &str {
        self.backend.backend_id()
    }

    pub fn capabilities(&self) -> BackendCapabilities {
        self.backend.capabilities()
    }
}

impl fmt::Debug for SelectedBackend<'_> {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("SelectedBackend")
            .field("backend_id", &self.backend_id())
            .finish()
    }
}

#[derive(Default)]
struct LoadedModelCache {
    models: HashMap<LoadedModelKey, LoadedModel>,
    global_lru: VecDeque<LoadedModelKey>,
    backend_lru: HashMap<String, VecDeque<LoadedModelKey>>,
}

impl LoadedModelCache {
    fn get_and_touch(&mut self, key: &LoadedModelKey) -> Option<LoadedModel> {
        let loaded = self.models.get(key).cloned()?;
        self.touch(key, loaded.backend_id());
        Some(loaded)
    }

    fn insert(
        &mut self,
        key: LoadedModelKey,
        loaded: LoadedModel,
        global_capacity: usize,
        backend_capacity: usize,
    ) -> Vec<LoadedModel> {
        if global_capacity == 0 || backend_capacity == 0 {
            return Vec::new();
        }
        let mut evicted = Vec::new();
        let backend_id = loaded.backend_id().to_string();
        self.models.insert(key.clone(), loaded);
        self.touch(&key, &backend_id);
        evicted.extend(self.evict_backend_over_capacity(&backend_id, backend_capacity));
        evicted.extend(self.evict_global_over_capacity(global_capacity));
        evicted
    }

    fn touch(&mut self, key: &LoadedModelKey, backend_id: &str) {
        self.global_lru.retain(|existing| existing != key);
        self.global_lru.push_back(key.clone());
        let backend_lru = self.backend_lru.entry(backend_id.to_string()).or_default();
        backend_lru.retain(|existing| existing != key);
        backend_lru.push_back(key.clone());
    }

    fn evict_backend_over_capacity(
        &mut self,
        backend_id: &str,
        capacity: usize,
    ) -> Vec<LoadedModel> {
        let mut evicted_models = Vec::new();
        loop {
            let Some(backend_lru) = self.backend_lru.get_mut(backend_id) else {
                break;
            };
            backend_lru.retain(|key| self.models.contains_key(key));
            if backend_lru.len() <= capacity {
                break;
            }
            if let Some(evicted) = backend_lru.pop_front() {
                if let Some(loaded) = self.remove(&evicted) {
                    evicted_models.push(loaded);
                }
            }
        }
        evicted_models
    }

    fn evict_global_over_capacity(&mut self, capacity: usize) -> Vec<LoadedModel> {
        let mut evicted_models = Vec::new();
        while self.models.len() > capacity {
            self.global_lru.retain(|key| self.models.contains_key(key));
            let Some(evicted) = self.global_lru.pop_front() else {
                break;
            };
            if let Some(loaded) = self.remove(&evicted) {
                evicted_models.push(loaded);
            }
        }
        evicted_models
    }

    fn remove(&mut self, key: &LoadedModelKey) -> Option<LoadedModel> {
        if let Some(loaded) = self.models.remove(key) {
            self.global_lru.retain(|existing| existing != key);
            if let Some(backend_lru) = self.backend_lru.get_mut(loaded.backend_id()) {
                backend_lru.retain(|existing| existing != key);
            }
            return Some(loaded);
        }
        None
    }
}

fn remote_egress_required(message: impl Into<String>) -> BackendFailure {
    BackendFailure::new(BackendFailureKind::RemoteEgressRequired, message)
}
