use crate::context::PromptFrame;
use crate::core::{
    build_openai_chat_request, parse_openai_chat_response, AgentError, CancellationToken,
    ModelProvider, ModelProviderOutput,
};

pub trait DesktopMiniCPMTransport: Send + Sync {
    fn chat_completion(
        &self,
        request_json: String,
        cancellation: CancellationToken,
    ) -> Result<String, AgentError>;
}

pub struct DesktopMiniCPMProvider {
    model: String,
    transport: Box<dyn DesktopMiniCPMTransport>,
}

impl DesktopMiniCPMProvider {
    pub fn new(model: impl Into<String>, transport: Box<dyn DesktopMiniCPMTransport>) -> Self {
        Self {
            model: model.into(),
            transport,
        }
    }
}

impl ModelProvider for DesktopMiniCPMProvider {
    fn id(&self) -> &str {
        "desktop_minicpm"
    }

    fn stream_chat(
        &self,
        frame: &PromptFrame,
        cancellation: CancellationToken,
    ) -> Result<Vec<ModelProviderOutput>, AgentError> {
        if cancellation.is_cancelled() {
            return Err(AgentError::Cancelled("desktop MiniCPM cancelled".into()));
        }

        let request = build_openai_chat_request(&self.model, frame);
        let response = self
            .transport
            .chat_completion(request.to_string(), cancellation.clone())?;

        if cancellation.is_cancelled() {
            return Err(AgentError::Cancelled("desktop MiniCPM cancelled".into()));
        }

        parse_openai_chat_response(&response)
    }
}
