use crate::context::{
    BranchProjector, CompactionCandidate, ContextBudget, PromptLayers, TokenizerAdapter,
};
use crate::core::{AgentError, RuntimeEvent};

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PromptMessage {
    User(String),
    UserWithBlobRefs {
        content: String,
        blob_refs: Vec<String>,
    },
    Assistant(String),
    ToolResult(String),
    Summary(String),
}

impl PromptMessage {
    pub fn content(&self) -> &str {
        match self {
            Self::User(content)
            | Self::UserWithBlobRefs { content, .. }
            | Self::Assistant(content)
            | Self::ToolResult(content)
            | Self::Summary(content) => content,
        }
    }

    pub fn blob_refs(&self) -> &[String] {
        match self {
            Self::UserWithBlobRefs { blob_refs, .. } => blob_refs,
            _ => &[],
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct PromptFrame {
    pub system_prompt: String,
    pub runtime_policy: String,
    pub tool_schemas: Vec<String>,
    pub inference_options: InferenceOptions,
    pub messages: Vec<PromptMessage>,
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct InferenceOptions {
    pub temperature: Option<f32>,
    pub top_p: Option<f32>,
}

pub struct ContextBuildResult {
    pub frame: PromptFrame,
    pub compaction_summary: Option<String>,
}

pub struct ContextController {
    layers: PromptLayers,
    tool_schemas: Vec<String>,
    inference_options: InferenceOptions,
    tokenizer: Box<dyn TokenizerAdapter>,
}

impl ContextController {
    pub fn new(
        system_prompt: impl Into<String>,
        runtime_policy: impl Into<String>,
        tool_schemas: Vec<String>,
        tokenizer: Box<dyn TokenizerAdapter>,
    ) -> Self {
        Self::new_with_memory(
            system_prompt,
            runtime_policy,
            tool_schemas,
            Vec::new(),
            tokenizer,
        )
    }

    pub fn new_with_memory(
        system_prompt: impl Into<String>,
        runtime_policy: impl Into<String>,
        mut tool_schemas: Vec<String>,
        memory: Vec<String>,
        tokenizer: Box<dyn TokenizerAdapter>,
    ) -> Self {
        tool_schemas.sort();
        tool_schemas.dedup();

        Self {
            layers: PromptLayers {
                system: system_prompt.into(),
                policy: runtime_policy.into(),
                memory,
            },
            tool_schemas,
            inference_options: InferenceOptions::default(),
            tokenizer,
        }
    }

    pub fn update_runtime_options(
        &mut self,
        system_prompt: impl Into<String>,
        runtime_policy: impl Into<String>,
        inference_options: InferenceOptions,
    ) {
        self.layers.system = system_prompt.into();
        self.layers.policy = runtime_policy.into();
        self.inference_options = inference_options;
    }

    pub fn build_prompt_frame(&self, branch: Vec<RuntimeEvent>) -> Result<PromptFrame, AgentError> {
        Ok(self.build_prompt_frame_with_compaction(branch)?.frame)
    }

    pub fn build_prompt_frame_with_compaction(
        &self,
        branch: Vec<RuntimeEvent>,
    ) -> Result<ContextBuildResult, AgentError> {
        let messages = BranchProjector::new().project(branch);
        let result = self.fit_messages(messages)?;

        Ok(ContextBuildResult {
            frame: result.0,
            compaction_summary: result.1,
        })
    }

    fn fit_messages(
        &self,
        messages: Vec<PromptMessage>,
    ) -> Result<(PromptFrame, Option<String>), AgentError> {
        let frame = self.frame(messages.clone());
        let usable = self.usable_context_tokens();
        if self.tokenizer.count_prompt_frame(&frame) <= usable {
            return Ok((frame, None));
        }

        let fixed_frame = self.frame(Vec::new());
        let fixed_count = self.tokenizer.count_prompt_frame(&fixed_frame);
        let message_budget = usable.saturating_sub(fixed_count);
        let kept = ContextBudget::with_token_counter(message_budget, |text| {
            self.tokenizer.count_text(text)
        })
        .fit_messages(messages.clone());
        let dropped_count = messages.len().saturating_sub(kept.len());
        let summary = if dropped_count > 0 {
            self.compaction_summary_for_dropped(&messages[..dropped_count])
        } else {
            None
        };

        let frame = self.frame(kept);
        let count = self.tokenizer.count_prompt_frame(&frame);
        if count > usable {
            return Err(AgentError::Provider(format!(
                "prompt frame exceeds mock context budget: {count} > {usable}"
            )));
        }

        Ok((frame, summary))
    }

    fn compaction_summary_for_dropped(&self, dropped_messages: &[PromptMessage]) -> Option<String> {
        let latest_summary_index = dropped_messages
            .iter()
            .rposition(|message| matches!(message, PromptMessage::Summary(_)));

        let dropped = match latest_summary_index {
            Some(index) => {
                let suffix = dropped_messages
                    .iter()
                    .skip(index + 1)
                    .map(|message| message.content().to_string())
                    .collect::<Vec<_>>();
                if suffix.is_empty() {
                    return None;
                }

                let mut messages = Vec::with_capacity(suffix.len() + 1);
                messages.push(dropped_messages[index].content().to_string());
                messages.extend(suffix);
                messages
            }
            None => dropped_messages
                .iter()
                .map(|message| message.content().to_string())
                .collect::<Vec<_>>(),
        };

        Some(CompactionCandidate::new(dropped).summary_text())
    }

    fn frame(&self, messages: Vec<PromptMessage>) -> PromptFrame {
        PromptFrame {
            system_prompt: self.layers.render_system_prompt(),
            runtime_policy: self.layers.policy.clone(),
            tool_schemas: self.tool_schemas.clone(),
            inference_options: self.inference_options,
            messages,
        }
    }

    fn usable_context_tokens(&self) -> usize {
        self.tokenizer
            .max_context_tokens()
            .saturating_sub(self.tokenizer.safety_margin_tokens())
    }
}
