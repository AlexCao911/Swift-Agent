use std::collections::BTreeMap;

use crate::context::{MockTokenizer, TokenizerAdapter};
use crate::core::{
    AgentError, MockStreamingProvider, ModelProvider, ProviderKind, ProviderProfile,
};

pub struct ProviderBundle {
    pub provider: Box<dyn ModelProvider>,
    pub tokenizer: Box<dyn TokenizerAdapter>,
}

struct ProviderEntry {
    profile: ProviderProfile,
    factory: Box<dyn Fn() -> Result<ProviderBundle, AgentError> + Send + Sync>,
}

#[derive(Default)]
pub struct ProviderRegistry {
    entries: BTreeMap<String, ProviderEntry>,
}

impl ProviderRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_mock() -> Self {
        let mut registry = Self::new();
        registry
            .register_factory(
                ProviderProfile {
                    id: "mock".into(),
                    display_name: "Mock Provider".into(),
                    kind: ProviderKind::Mock,
                    max_context_tokens: 100,
                },
                || ProviderBundle {
                    provider: Box::new(MockStreamingProvider::new()),
                    tokenizer: Box::new(MockTokenizer::new(100)),
                },
            )
            .expect("built-in mock provider profile should be unique");
        registry
    }

    pub fn register_factory(
        &mut self,
        profile: ProviderProfile,
        factory: impl Fn() -> ProviderBundle + Send + Sync + 'static,
    ) -> Result<(), AgentError> {
        self.register_fallible_factory(profile, move || Ok(factory()))
    }

    pub fn register_fallible_factory(
        &mut self,
        profile: ProviderProfile,
        factory: impl Fn() -> Result<ProviderBundle, AgentError> + Send + Sync + 'static,
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

    pub fn profile(&self, provider_id: &str) -> Option<ProviderProfile> {
        self.entries
            .get(provider_id)
            .map(|entry| entry.profile.clone())
    }

    pub fn build(&self, provider_id: &str) -> Result<ProviderBundle, AgentError> {
        let entry = self
            .entries
            .get(provider_id)
            .ok_or_else(|| AgentError::Provider(format!("unknown provider: {provider_id}")))?;
        let bundle = (entry.factory)()?;
        validate_bundle(&entry.profile, &bundle)?;
        Ok(bundle)
    }
}

fn validate_bundle(profile: &ProviderProfile, bundle: &ProviderBundle) -> Result<(), AgentError> {
    if bundle.provider.id() != profile.id {
        return Err(AgentError::Provider(format!(
            "provider id mismatch for profile {}: {}",
            profile.id,
            bundle.provider.id()
        )));
    }
    if bundle.tokenizer.provider_id() != profile.id {
        return Err(AgentError::Provider(format!(
            "tokenizer id mismatch for profile {}: {}",
            profile.id,
            bundle.tokenizer.provider_id()
        )));
    }
    if bundle.tokenizer.max_context_tokens() != profile.max_context_tokens {
        return Err(AgentError::Provider(format!(
            "tokenizer context mismatch for profile {}: {} != {}",
            profile.id,
            bundle.tokenizer.max_context_tokens(),
            profile.max_context_tokens
        )));
    }
    Ok(())
}
