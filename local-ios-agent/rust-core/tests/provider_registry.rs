use local_ios_agent_runtime::context::{MockTokenizer, PromptFrame, TokenizerAdapter};
use local_ios_agent_runtime::core::{
    register_desktop_minicpm_provider, AgentError, CancellationToken, DesktopMiniCPMSettings,
    MockStreamingProvider, ModelProvider, ModelProviderOutput, ProviderBundle, ProviderKind,
    ProviderProfile, ProviderRegistry,
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

#[derive(Debug)]
struct StaticProvider {
    id: &'static str,
}

impl ModelProvider for StaticProvider {
    fn id(&self) -> &str {
        self.id
    }

    fn stream_chat(
        &self,
        _frame: &PromptFrame,
        _cancellation: CancellationToken,
    ) -> Result<Vec<ModelProviderOutput>, AgentError> {
        Ok(vec![ModelProviderOutput::Completed("ok".into())])
    }
}

#[derive(Clone, Debug)]
struct StaticTokenizer {
    provider_id: &'static str,
    max_context_tokens: usize,
}

impl TokenizerAdapter for StaticTokenizer {
    fn provider_id(&self) -> &str {
        self.provider_id
    }

    fn max_context_tokens(&self) -> usize {
        self.max_context_tokens
    }

    fn safety_margin_tokens(&self) -> usize {
        0
    }

    fn count_text(&self, text: &str) -> usize {
        text.split_whitespace().count()
    }

    fn count_prompt_frame(&self, frame: &PromptFrame) -> usize {
        self.count_text(&frame.system_prompt)
            + self.count_text(&frame.runtime_policy)
            + frame
                .tool_schemas
                .iter()
                .map(|tool| self.count_text(tool))
                .sum::<usize>()
            + frame
                .messages
                .iter()
                .map(|message| self.count_text(message.content()))
                .sum::<usize>()
    }

    fn boxed_clone(&self) -> Box<dyn TokenizerAdapter> {
        Box::new(self.clone())
    }
}

#[test]
fn registry_rejects_factory_bundle_that_does_not_match_profile() {
    let mut registry = ProviderRegistry::new();
    registry
        .register_factory(profile("expected", "Expected"), || ProviderBundle {
            provider: Box::new(StaticProvider { id: "other" }),
            tokenizer: Box::new(StaticTokenizer {
                provider_id: "expected",
                max_context_tokens: 100,
            }),
        })
        .unwrap();

    let error = match registry.build("expected") {
        Ok(_) => panic!("expected provider id mismatch"),
        Err(error) => error,
    };

    assert!(error.to_string().contains("provider id mismatch"));
}

#[test]
fn registry_rejects_factory_tokenizer_that_does_not_match_profile() {
    let mut registry = ProviderRegistry::new();
    registry
        .register_factory(profile("expected", "Expected"), || ProviderBundle {
            provider: Box::new(StaticProvider { id: "expected" }),
            tokenizer: Box::new(StaticTokenizer {
                provider_id: "other",
                max_context_tokens: 100,
            }),
        })
        .unwrap();

    let error = match registry.build("expected") {
        Ok(_) => panic!("expected tokenizer id mismatch"),
        Err(error) => error,
    };

    assert!(error.to_string().contains("tokenizer id mismatch"));
}

#[test]
fn registry_rejects_factory_tokenizer_context_window_that_does_not_match_profile() {
    let mut registry = ProviderRegistry::new();
    registry
        .register_factory(profile("expected", "Expected"), || ProviderBundle {
            provider: Box::new(StaticProvider { id: "expected" }),
            tokenizer: Box::new(StaticTokenizer {
                provider_id: "expected",
                max_context_tokens: 64,
            }),
        })
        .unwrap();

    let error = match registry.build("expected") {
        Ok(_) => panic!("expected tokenizer context mismatch"),
        Err(error) => error,
    };

    assert!(error.to_string().contains("tokenizer context mismatch"));
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
