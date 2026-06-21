use std::collections::HashMap;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Mutex,
};

use crate::context::{PromptFrame, PromptMessage};
use crate::core::{AgentError, RunId};
use crate::tool::ToolCall;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ModelProviderOutput {
    TextDelta(String),
    ToolCall(ToolCall),
    Completed(String),
}

#[derive(Clone, Default)]
pub struct CancellationToken {
    inner: Arc<AtomicBool>,
}

impl CancellationToken {
    pub fn cancel(&self) {
        self.inner.store(true, Ordering::SeqCst);
    }

    pub fn is_cancelled(&self) -> bool {
        self.inner.load(Ordering::SeqCst)
    }
}

#[derive(Clone, Default)]
pub struct ProviderCancellationRegistry {
    inner: Arc<Mutex<HashMap<RunId, CancellationToken>>>,
}

impl ProviderCancellationRegistry {
    pub fn insert(&self, run_id: RunId, token: CancellationToken) {
        self.inner.lock().unwrap().insert(run_id, token);
    }

    pub fn remove(&self, run_id: &RunId) {
        self.inner.lock().unwrap().remove(run_id);
    }

    pub fn contains(&self, run_id: &RunId) -> bool {
        self.inner.lock().unwrap().contains_key(run_id)
    }

    pub fn signal(&self, run_id: &RunId) -> bool {
        let token = self.inner.lock().unwrap().get(run_id).cloned();
        if let Some(token) = token {
            token.cancel();
            true
        } else {
            false
        }
    }
}

pub trait ModelProvider: Send + Sync {
    fn id(&self) -> &str;
    fn stream_chat(
        &self,
        frame: &PromptFrame,
        cancellation: CancellationToken,
        on_output: &mut dyn FnMut(ModelProviderOutput) -> Result<(), AgentError>,
    ) -> Result<(), AgentError>;
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

    fn stream_chat(
        &self,
        frame: &PromptFrame,
        cancellation: CancellationToken,
        on_output: &mut dyn FnMut(ModelProviderOutput) -> Result<(), AgentError>,
    ) -> Result<(), AgentError> {
        if cancellation.is_cancelled() {
            return Err(AgentError::Cancelled("mock provider cancelled".into()));
        }

        if let Some(tool_result) = frame
            .messages
            .iter()
            .rev()
            .find_map(|message| match message {
                PromptMessage::ToolResult(content) => Some(content.as_str()),
                _ => None,
            })
        {
            let response = format!("Mock response after tool: {tool_result}");
            on_output(ModelProviderOutput::TextDelta("Mock response ".to_string()))?;
            on_output(ModelProviderOutput::TextDelta(format!(
                "after tool: {tool_result}"
            )))?;
            on_output(ModelProviderOutput::Completed(response))?;
            return Ok(());
        }

        let last_user = frame
            .messages
            .iter()
            .rev()
            .find_map(|message| match message {
                PromptMessage::User(content) => Some(content.as_str()),
                _ => None,
            })
            .unwrap_or("");

        if last_user == "use tool debug.echo" {
            on_output(ModelProviderOutput::ToolCall(ToolCall {
                id: "call_mock_1".to_string(),
                name: "debug.echo".to_string(),
                arguments_json: r#"{"text":"hello"}"#.to_string(),
            }))?;
            return Ok(());
        }

        let response = format!("Mock response to: {last_user}");
        on_output(ModelProviderOutput::TextDelta("Mock ".to_string()))?;
        on_output(ModelProviderOutput::TextDelta(format!(
            "response to: {last_user}"
        )))?;
        on_output(ModelProviderOutput::Completed(response))?;
        Ok(())
    }
}
