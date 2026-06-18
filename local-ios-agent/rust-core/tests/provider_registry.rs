use local_ios_agent_runtime::context::MockTokenizer;
use local_ios_agent_runtime::core::{
    register_desktop_minicpm_provider, DesktopMiniCPMSettings, MockStreamingProvider,
    ProviderBundle, ProviderKind, ProviderProfile, ProviderRegistry,
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

#[test]
fn desktop_minicpm_registration_builds_matching_provider_and_tokenizer() {
    let mut registry = ProviderRegistry::with_mock();

    register_desktop_minicpm_provider(
        &mut registry,
        DesktopMiniCPMSettings {
            endpoint: "http://127.0.0.1:8000/v1/chat/completions".into(),
            model: "minicpm".into(),
            max_context_tokens: 4096,
        },
    )
    .unwrap();

    let profile = registry.profile("desktop_minicpm").unwrap();
    assert_eq!(profile.kind, ProviderKind::DesktopMiniCpm);
    assert_eq!(profile.max_context_tokens, 4096);

    let bundle = registry.build("desktop_minicpm").unwrap();
    assert_eq!(bundle.provider.id(), "desktop_minicpm");
    assert_eq!(bundle.tokenizer.provider_id(), "desktop_minicpm");
    assert_eq!(bundle.tokenizer.max_context_tokens(), 4096);
    assert!(bundle.tokenizer.count_text("abcdefghij") > 1);
}
