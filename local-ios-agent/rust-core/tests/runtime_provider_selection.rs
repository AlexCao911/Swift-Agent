use local_ios_agent_runtime::context::{MockTokenizer, PromptFrame, TokenizerAdapter};
use local_ios_agent_runtime::core::{
    AgentError, AgentRuntime, AgentRuntimeConfig, CancellationToken, EventKind,
    MockStreamingProvider, ModelProvider, ModelProviderOutput, ProviderBundle, ProviderKind,
    ProviderProfile, ProviderRegistry, SendMessageInput,
};
use local_ios_agent_runtime::memory::{EventStore, InMemoryEventStore, SqliteEventStore};

fn mock_config() -> AgentRuntimeConfig {
    AgentRuntimeConfig {
        system_prompt: "system".into(),
        runtime_policy: "policy".into(),
        tool_schemas: vec!["debug.echo".into()],
        tokenizer: Box::new(MockTokenizer::new(100)),
        provider: Box::new(MockStreamingProvider::new()),
        tool_router: None,
    }
}

fn alt_profile() -> ProviderProfile {
    ProviderProfile {
        id: "alt".into(),
        display_name: "Alt Provider".into(),
        kind: ProviderKind::Mock,
        max_context_tokens: 64,
    }
}

fn registry_with_alt() -> ProviderRegistry {
    let mut registry = ProviderRegistry::with_mock();
    registry
        .register_factory(alt_profile(), || ProviderBundle {
            provider: Box::new(StaticProvider {
                id: "alt",
                response: "Alt response",
            }),
            tokenizer: Box::new(StaticTokenizer {
                provider_id: "alt",
                max_context_tokens: 64,
            }),
        })
        .unwrap();
    registry
}

#[derive(Debug)]
struct StaticProvider {
    id: &'static str,
    response: &'static str,
}

impl ModelProvider for StaticProvider {
    fn id(&self) -> &str {
        self.id
    }

    fn stream_chat(
        &self,
        _frame: &PromptFrame,
        _cancellation: CancellationToken,
        on_output: &mut dyn FnMut(ModelProviderOutput) -> Result<(), AgentError>,
    ) -> Result<(), AgentError> {
        on_output(ModelProviderOutput::Completed(self.response.into()))?;
        Ok(())
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
fn set_provider_replaces_active_bundle_persists_setting_and_emits_event() {
    let tempdir = tempfile::tempdir().unwrap();
    let db_path = tempdir.path().join("agent.sqlite");
    let store = SqliteEventStore::open(&db_path).unwrap();
    let mut runtime =
        AgentRuntime::with_store_and_registry(mock_config(), store, registry_with_alt()).unwrap();
    let session_id = runtime.create_session().unwrap();

    assert_eq!(runtime.active_provider().id, "mock");
    assert_eq!(
        runtime
            .provider_profiles()
            .into_iter()
            .map(|profile| profile.id)
            .collect::<Vec<_>>(),
        vec!["alt", "mock"]
    );

    let event = runtime.set_provider(session_id.clone(), "alt").unwrap();

    assert_eq!(event.kind, EventKind::ProviderChanged);
    assert!(event.payload.contains("alt"));
    assert_eq!(runtime.active_provider(), alt_profile());

    let turn = runtime
        .send_message_turn(SendMessageInput {
            session_id: session_id.clone(),
            parent_event_id: None,
            text: "hello".into(),
        })
        .unwrap();
    assert!(turn
        .events
        .iter()
        .any(|event| event.payload == "Alt response"));

    let store = SqliteEventStore::open(&db_path).unwrap();
    let setting =
        <SqliteEventStore as EventStore>::load_provider_setting(&store, "active_provider")
            .unwrap()
            .unwrap();
    assert_eq!(setting.value, "alt");
}

#[test]
fn runtime_restores_persisted_active_provider_when_registry_can_build_it() {
    let tempdir = tempfile::tempdir().unwrap();
    let db_path = tempdir.path().join("agent.sqlite");
    let session_id = {
        let store = SqliteEventStore::open(&db_path).unwrap();
        let mut runtime =
            AgentRuntime::with_store_and_registry(mock_config(), store, registry_with_alt())
                .unwrap();
        let session_id = runtime.create_session().unwrap();
        runtime.set_provider(session_id.clone(), "alt").unwrap();
        session_id
    };

    let store = SqliteEventStore::open(&db_path).unwrap();
    let runtime =
        AgentRuntime::with_store_and_registry(mock_config(), store, registry_with_alt()).unwrap();

    assert_eq!(runtime.session_ids(), vec![session_id]);
    assert_eq!(runtime.active_provider().id, "alt");
}

#[test]
fn runtime_restores_last_global_provider_setting_across_sessions() {
    let tempdir = tempfile::tempdir().unwrap();
    let db_path = tempdir.path().join("agent.sqlite");
    {
        let store = SqliteEventStore::open(&db_path).unwrap();
        let mut runtime =
            AgentRuntime::with_store_and_registry(mock_config(), store, registry_with_alt())
                .unwrap();
        let first_session = runtime.create_session().unwrap();
        let second_session = runtime.create_session().unwrap();
        runtime.set_provider(first_session, "alt").unwrap();
        runtime.set_provider(second_session, "mock").unwrap();
    }

    let store = SqliteEventStore::open(&db_path).unwrap();
    let runtime =
        AgentRuntime::with_store_and_registry(mock_config(), store, registry_with_alt()).unwrap();

    assert_eq!(runtime.active_provider().id, "mock");
}

#[test]
fn set_provider_rejects_runs_that_may_continue_generation() {
    let mut runtime = AgentRuntime::with_store_and_registry(
        mock_config(),
        InMemoryEventStore::new(),
        registry_with_alt(),
    )
    .unwrap();
    let session_id = runtime.create_session().unwrap();
    let turn = runtime
        .send_message_turn(SendMessageInput {
            session_id: session_id.clone(),
            parent_event_id: None,
            text: "use tool debug.echo".into(),
        })
        .unwrap();

    let error = runtime.set_provider(session_id, "alt").unwrap_err();

    assert!(error
        .to_string()
        .contains(&format!("provider_switch_blocked({})", turn.run_id)));
    assert_eq!(runtime.active_provider().id, "mock");
}

#[test]
fn set_provider_rejects_runs_that_may_continue_generation_in_other_sessions() {
    let mut runtime = AgentRuntime::with_store_and_registry(
        mock_config(),
        InMemoryEventStore::new(),
        registry_with_alt(),
    )
    .unwrap();
    let running_session = runtime.create_session().unwrap();
    let selector_session = runtime.create_session().unwrap();
    let turn = runtime
        .send_message_turn(SendMessageInput {
            session_id: running_session,
            parent_event_id: None,
            text: "use tool debug.echo".into(),
        })
        .unwrap();

    let error = runtime.set_provider(selector_session, "alt").unwrap_err();

    assert!(error
        .to_string()
        .contains(&format!("provider_switch_blocked({})", turn.run_id)));
    assert_eq!(runtime.active_provider().id, "mock");
}
