use crate::model::ModelDescriptor;

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub struct LoadedModelKey {
    provider_id: String,
    model_id: String,
}

impl LoadedModelKey {
    pub fn new(provider_id: impl Into<String>, model_id: impl Into<String>) -> Self {
        Self {
            provider_id: provider_id.into(),
            model_id: model_id.into(),
        }
    }

    pub fn from_model(model: &ModelDescriptor) -> Self {
        Self::new(model.provider_id.clone(), model.id.clone())
    }

    pub fn provider_id(&self) -> &str {
        &self.provider_id
    }

    pub fn model_id(&self) -> &str {
        &self.model_id
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LoadedModel {
    key: LoadedModelKey,
    backend_id: String,
}

impl LoadedModel {
    pub fn new(key: LoadedModelKey, backend_id: impl Into<String>) -> Self {
        Self {
            key,
            backend_id: backend_id.into(),
        }
    }

    pub fn key(&self) -> &LoadedModelKey {
        &self.key
    }

    pub fn backend_id(&self) -> &str {
        &self.backend_id
    }
}
