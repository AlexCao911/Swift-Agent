use crate::context::{BranchProjector, PromptLayers, TokenizerAdapter};
use crate::core::{AgentError, RuntimeEvent};

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PromptMessage {
    User(String),
    Assistant(String),
    ToolResult(String),
}

impl PromptMessage {
    pub fn content(&self) -> &str {
        match self {
            Self::User(content) | Self::Assistant(content) | Self::ToolResult(content) => content,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PromptFrame {
    pub system_prompt: String,
    pub runtime_policy: String,
    pub tool_schemas: Vec<String>,
    pub messages: Vec<PromptMessage>,
}

pub struct ContextController {
    layers: PromptLayers,
    tool_schemas: Vec<String>,
    tokenizer: Box<dyn TokenizerAdapter>,
}

impl ContextController {
    pub fn new(
        system_prompt: impl Into<String>,
        runtime_policy: impl Into<String>,
        tool_schemas: Vec<String>,
        tokenizer: Box<dyn TokenizerAdapter>,
    ) -> Self {
        Self {
            layers: PromptLayers {
                system: system_prompt.into(),
                policy: runtime_policy.into(),
                memory: Vec::new(),
            },
            tool_schemas,
            tokenizer,
        }
    }

    pub fn build_prompt_frame(&self, branch: Vec<RuntimeEvent>) -> Result<PromptFrame, AgentError> {
        let messages = BranchProjector::new().project(branch);

        let frame = PromptFrame {
            system_prompt: self.layers.render_system_prompt(),
            runtime_policy: self.layers.policy.clone(),
            tool_schemas: self.tool_schemas.clone(),
            messages,
        };

        let count = self.tokenizer.count_prompt_frame(&frame);
        let usable = self
            .tokenizer
            .max_context_tokens()
            .saturating_sub(self.tokenizer.safety_margin_tokens());
        if count > usable {
            return Err(AgentError::Provider(format!(
                "prompt frame exceeds mock context budget: {count} > {usable}"
            )));
        }

        Ok(frame)
    }
}
