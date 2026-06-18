use std::collections::BTreeMap;

use crate::context::TokenizerAdapter;
use crate::core::{AgentError, ModelProvider, ProviderProfile};

pub struct ProviderBundle {
    pub provider: Box<dyn ModelProvider>,
    pub tokenizer: Box<dyn TokenizerAdapter>,
}

struct ProviderEntry {
    profile: ProviderProfile,
    factory: Box<dyn Fn() -> ProviderBundle + Send + Sync>,
}

#[derive(Default)]
pub struct ProviderRegistry {
    entries: BTreeMap<String, ProviderEntry>,
}

impl ProviderRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn register_factory(
        &mut self,
        profile: ProviderProfile,
        factory: impl Fn() -> ProviderBundle + Send + Sync + 'static,
    ) -> Result<(), AgentError> {
        if self.entries.contains_key(&profile.id) {
            return Err(AgentError::Provider(format!(
                "duplicate provider profile: {}",
                profile.id
            )));
        }

        self.entries.insert(
            profile.id.clone(),
            ProviderEntry {
                profile,
                factory: Box::new(factory),
            },
        );
        Ok(())
    }

    pub fn profiles(&self) -> Vec<ProviderProfile> {
        self.entries
            .values()
            .map(|entry| entry.profile.clone())
            .collect()
    }

    pub fn build(&self, provider_id: &str) -> Result<ProviderBundle, AgentError> {
        self.entries
            .get(provider_id)
            .map(|entry| (entry.factory)())
            .ok_or_else(|| AgentError::Provider(format!("unknown provider: {provider_id}")))
    }
}
