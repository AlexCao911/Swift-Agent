use local_ios_agent_runtime::context::MockTokenizer;
use local_ios_agent_runtime::core::{
    MockStreamingProvider, ProviderBundle, ProviderKind, ProviderProfile, ProviderRegistry,
};

fn profile(id: &str, display_name: &str) -> ProviderProfile {
    ProviderProfile {
        id: id.to_string(),
        display_name: display_name.to_string(),
        kind: ProviderKind::Mock,
        max_context_tokens: 100,
    }
}

#[test]
fn registry_lists_profiles_sorted_by_provider_id() {
    let mut registry = ProviderRegistry::new();
    registry
        .register_factory(profile("zeta", "Zeta"), || ProviderBundle {
            provider: Box::new(MockStreamingProvider::new()),
            tokenizer: Box::new(MockTokenizer::new(100)),
        })
        .unwrap();
    registry
        .register_factory(profile("alpha", "Alpha"), || ProviderBundle {
            provider: Box::new(MockStreamingProvider::new()),
            tokenizer: Box::new(MockTokenizer::new(100)),
        })
        .unwrap();

    let ids: Vec<_> = registry
        .profiles()
        .into_iter()
        .map(|profile| profile.id)
        .collect();

    assert_eq!(ids, vec!["alpha", "zeta"]);
}

#[test]
fn registry_rejects_duplicate_provider_ids() {
    let mut registry = ProviderRegistry::new();
    registry
        .register_factory(profile("mock", "Mock"), || ProviderBundle {
            provider: Box::new(MockStreamingProvider::new()),
            tokenizer: Box::new(MockTokenizer::new(100)),
        })
        .unwrap();

    let error = registry
        .register_factory(profile("mock", "Mock Again"), || ProviderBundle {
            provider: Box::new(MockStreamingProvider::new()),
            tokenizer: Box::new(MockTokenizer::new(100)),
        })
        .unwrap_err();

    assert!(error.to_string().contains("duplicate provider profile"));
}

#[test]
fn registry_builds_provider_and_tokenizer_together() {
    let mut registry = ProviderRegistry::new();
    registry
        .register_factory(profile("mock", "Mock"), || ProviderBundle {
            provider: Box::new(MockStreamingProvider::new()),
            tokenizer: Box::new(MockTokenizer::new(100)),
        })
        .unwrap();

    let bundle = registry.build("mock").unwrap();

    assert_eq!(bundle.provider.id(), "mock");
    assert_eq!(bundle.tokenizer.provider_id(), "mock");
}
