use crate::context::PromptFrame;
use crate::core::AgentError;
use crate::tool::ToolCall;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ModelProviderOutput {
    TextDelta(String),
    ToolCall(ToolCall),
    Completed(String),
}

pub trait ModelProvider: Send + Sync {
    fn id(&self) -> &str;
    fn stream_chat(&self, frame: &PromptFrame) -> Result<Vec<ModelProviderOutput>, AgentError>;
}

#[derive(Clone, Debug, Default)]
pub struct MockStreamingProvider;

impl MockStreamingProvider {
    pub fn new() -> Self {
        Self
    }
}

impl ModelProvider for MockStreamingProvider {
    fn id(&self) -> &str {
        "mock"
    }

    fn stream_chat(&self, frame: &PromptFrame) -> Result<Vec<ModelProviderOutput>, AgentError> {
        let last_user = frame
            .messages
            .iter()
            .rev()
            .find_map(|message| match message {
                crate::context::PromptMessage::User(content) => Some(content.as_str()),
                _ => None,
            })
            .unwrap_or("");

        if last_user == "use tool debug.echo" {
            return Ok(vec![ModelProviderOutput::ToolCall(ToolCall {
                id: "call_mock_1".to_string(),
                name: "debug.echo".to_string(),
                arguments_json: r#"{"text":"hello"}"#.to_string(),
            })]);
        }

        let response = format!("Mock response to: {last_user}");
        Ok(vec![
            ModelProviderOutput::TextDelta("Mock ".to_string()),
            ModelProviderOutput::TextDelta(format!("response to: {last_user}")),
            ModelProviderOutput::Completed(response),
        ])
    }
}
