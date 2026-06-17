use local_ios_agent_runtime::context::{PromptFrame, PromptMessage};
use local_ios_agent_runtime::core::{MockStreamingProvider, ModelProvider, ModelProviderOutput};

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

    let output = provider.stream_chat(&frame).unwrap();

    assert_eq!(
        output,
        vec![
            ModelProviderOutput::TextDelta("Mock ".to_string()),
            ModelProviderOutput::TextDelta("response to: second".to_string()),
            ModelProviderOutput::Completed("Mock response to: second".to_string())
        ]
    );
}
