use local_ios_agent_runtime::context::MockTokenizer;
use local_ios_agent_runtime::core::{
    AgentRuntime, AgentRuntimeConfig, EventKind, MockStreamingProvider, SendMessageInput,
};

#[test]
fn runtime_streams_mock_response_and_persists_events() {
    let mut runtime = AgentRuntime::new(AgentRuntimeConfig {
        system_prompt: "system".to_string(),
        runtime_policy: "policy".to_string(),
        tool_schemas: Vec::new(),
        tokenizer: Box::new(MockTokenizer::new(100)),
        provider: Box::new(MockStreamingProvider::new()),
        tool_router: None,
    });

    let session_id = runtime.create_session().unwrap();
    let events = runtime
        .send_message(SendMessageInput {
            session_id,
            parent_event_id: None,
            text: "hello".to_string(),
        })
        .unwrap();

    assert!(events
        .iter()
        .any(|event| event.kind == EventKind::UserMessage));
    assert!(events
        .iter()
        .any(|event| event.kind == EventKind::AssistantTextDelta));
    assert!(events
        .iter()
        .any(|event| event.kind == EventKind::AssistantMessageCompleted));
}
