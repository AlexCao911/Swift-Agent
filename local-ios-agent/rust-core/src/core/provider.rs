use crate::context::PromptFrame;
use crate::core::AgentError;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ModelProviderOutput {
    TextDelta(String),
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

        let response = format!("Mock response to: {last_user}");
        Ok(vec![
            ModelProviderOutput::TextDelta("Mock ".to_string()),
            ModelProviderOutput::TextDelta(format!("response to: {last_user}")),
            ModelProviderOutput::Completed(response),
        ])
    }
}
