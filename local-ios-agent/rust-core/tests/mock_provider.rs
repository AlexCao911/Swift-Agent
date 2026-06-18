use local_ios_agent_runtime::context::{PromptFrame, PromptMessage};
use local_ios_agent_runtime::core::{
    CancellationToken, MockStreamingProvider, ModelProvider, ModelProviderOutput,
};
use local_ios_agent_runtime::tool::ToolCall;

#[test]
fn mock_provider_streams_response_to_last_user_message() {
    let provider = MockStreamingProvider::new();
    let frame = PromptFrame {
        system_prompt: "system".to_string(),
        runtime_policy: "policy".to_string(),
        tool_schemas: Vec::new(),
        messages: vec![
            PromptMessage::User("first".to_string()),
            PromptMessage::Assistant("ack".to_string()),
            PromptMessage::User("second".to_string()),
        ],
    };

    let output = provider
        .stream_chat(&frame, CancellationToken::default())
        .unwrap();

    assert_eq!(
        output,
        vec![
            ModelProviderOutput::TextDelta("Mock ".to_string()),
            ModelProviderOutput::TextDelta("response to: second".to_string()),
            ModelProviderOutput::Completed("Mock response to: second".to_string())
        ]
    );
}

#[test]
fn mock_provider_can_emit_tool_call() {
    let provider = MockStreamingProvider::new();
    let frame = PromptFrame {
        system_prompt: "system".into(),
        runtime_policy: "policy".into(),
        tool_schemas: vec!["debug.echo".into()],
        messages: vec![PromptMessage::User("use tool debug.echo".into())],
    };

    assert!(matches!(
        provider
            .stream_chat(&frame, CancellationToken::default())
            .unwrap()
            .first(),
        Some(ModelProviderOutput::ToolCall(ToolCall { name, .. })) if name == "debug.echo"
    ));
}
