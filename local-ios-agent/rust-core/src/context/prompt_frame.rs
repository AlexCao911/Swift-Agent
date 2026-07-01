use crate::context::{
    BranchProjector, CompactionCandidate, ContextAssembler, ContextAssemblyResult, ContextBudget,
    ContextSegment, ModelInputRole, PromptLayers, TokenizerAdapter,
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
    pub assembly: ContextAssemblyResult,
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
        Ok(self.build_prompt_frame_from_context_assembly(branch)?.frame)
    }

    pub fn build_prompt_frame_with_compaction(
        &self,
        branch: Vec<RuntimeEvent>,
    ) -> Result<ContextBuildResult, AgentError> {
        self.build_prompt_frame_from_context_assembly(branch)
    }

    pub fn build_prompt_frame_from_context_assembly(
        &self,
        branch: Vec<RuntimeEvent>,
    ) -> Result<ContextBuildResult, AgentError> {
        let messages = BranchProjector::new().project(branch);
        let full_frame = self.frame(messages.clone());
        let assembly = self.assembly_for_frame(&full_frame)?;
        let frame = prompt_frame_from_context_assembly(&assembly, full_frame.inference_options);
        let dropped_count = dropped_conversation_prefix_count(&assembly, messages.len());
        let compaction_summary = if dropped_count > 0 {
            self.compaction_summary_for_dropped(&messages[..dropped_count])
        } else {
            None
        };

        let count = self.tokenizer.count_prompt_frame(&frame);
        if count > self.usable_context_tokens() {
            return Err(AgentError::Provider(format!(
                "prompt frame exceeds mock context budget: {} > {}",
                count,
                self.usable_context_tokens()
            )));
        }

        Ok(ContextBuildResult {
            frame,
            compaction_summary,
            assembly,
        })
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

    fn assembly_for_frame(&self, frame: &PromptFrame) -> Result<ContextAssemblyResult, AgentError> {
        let mut assembler = ContextAssembler::new();
        if !frame.system_prompt.is_empty() {
            assembler = assembler.with_segment(
                ContextSegment::system_guardrail("prompt.system", frame.system_prompt.clone())
                    .with_priority(110)
                    .with_provenance("prompt.system")
                    .required_for_model_input(),
            );
        }
        if !frame.runtime_policy.is_empty() {
            assembler = assembler.with_segment(
                ContextSegment::system_guardrail(
                    "prompt.runtime_policy",
                    frame.runtime_policy.clone(),
                )
                .with_priority(109)
                .with_provenance("prompt.runtime_policy")
                .required_for_model_input(),
            );
        }
        if !frame.tool_schemas.is_empty() {
            assembler = assembler.with_segment(
                ContextSegment::system_guardrail(
                    "prompt.tool_schemas",
                    frame.tool_schemas.join("\n"),
                )
                .with_priority(108)
                .with_provenance("prompt.tool_schemas")
                .required_for_model_input(),
            );
        }

        assembler
            .with_conversation_messages(frame.messages.clone())
            .assemble(ContextBudget::with_token_counter_named(
                self.usable_context_tokens(),
                format!("tokenizer.{}", self.tokenizer.provider_id()),
                |text| self.tokenizer.count_text(text),
            ))
            .map_err(|error| AgentError::Provider(error.to_string()))
    }
}

fn dropped_conversation_prefix_count(
    assembly: &ContextAssemblyResult,
    message_count: usize,
) -> usize {
    let dropped = assembly.trace().dropped_segment_ids();
    let mut count = 0;
    while count < message_count {
        let segment_id = format!("conversation.{count:04}");
        if dropped.contains(&segment_id) {
            count += 1;
        } else {
            break;
        }
    }
    count
}

fn prompt_frame_from_context_assembly(
    assembly: &ContextAssemblyResult,
    inference_options: InferenceOptions,
) -> PromptFrame {
    let mut system_prompt = String::new();
    let mut runtime_policy = String::new();
    let mut tool_schemas = Vec::new();
    let mut messages = Vec::new();

    for message in assembly.model_input_messages().messages() {
        match (message.source_segment_id(), message.role()) {
            ("prompt.system", ModelInputRole::System) => {
                system_prompt = message.content().to_string();
            }
            ("prompt.runtime_policy", ModelInputRole::System) => {
                runtime_policy = message.content().to_string();
            }
            ("prompt.tool_schemas", ModelInputRole::System) => {
                tool_schemas = message
                    .content()
                    .lines()
                    .filter(|line| !line.is_empty())
                    .map(ToString::to_string)
                    .collect();
            }
            (_, ModelInputRole::System) => {
                if !system_prompt.is_empty() {
                    system_prompt.push('\n');
                }
                system_prompt.push_str(message.content());
            }
            (_, ModelInputRole::User) => {
                if message.blob_refs().is_empty() {
                    messages.push(PromptMessage::User(message.content().to_string()));
                } else {
                    messages.push(PromptMessage::UserWithBlobRefs {
                        content: message.content().to_string(),
                        blob_refs: message.blob_refs().to_vec(),
                    });
                }
            }
            (_, ModelInputRole::Assistant) => {
                messages.push(PromptMessage::Assistant(message.content().to_string()));
            }
            (_, ModelInputRole::Tool) => {
                messages.push(PromptMessage::ToolResult(message.content().to_string()));
            }
            (_, ModelInputRole::Summary) => {
                messages.push(PromptMessage::Summary(message.content().to_string()));
            }
        }
    }

    PromptFrame {
        system_prompt,
        runtime_policy,
        tool_schemas,
        inference_options,
        messages,
    }
}
