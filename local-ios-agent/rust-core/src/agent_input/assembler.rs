use std::sync::Arc;

use crate::context::{
    approximate_token_count, compact_tool_results_for_context, AgentTurnInput, BranchProjector,
    CompactionCandidate, ContextAssembler, ContextAssemblyTrace, ContextBudget, ContextSegment,
    ContextWindowPolicy, ModelInputMessages, ModelInputRole, PromptMessage,
};
use crate::core::RuntimeEvent;
use crate::memory::{MemoryProvider, MemoryQuery};
use crate::prompt::compile_prompt_documents;
use crate::skills::render_skill_descriptors;

use super::{AgentInputError, RunStartSnapshot};

pub struct AgentInputAssembler {
    snapshot: RunStartSnapshot,
    max_model_input_tokens: usize,
    memory_provider: Option<Arc<dyn MemoryProvider>>,
}

impl AgentInputAssembler {
    pub fn for_run(snapshot: RunStartSnapshot) -> Result<Self, AgentInputError> {
        let input_limit = ContextWindowPolicy::for_model(snapshot.model_context_window)
            .map_err(|error| {
                AgentInputError::new(
                    "agent_input.model_context_window_invalid",
                    error.to_string(),
                )
            })?
            .model_input_limit_tokens();
        Self::new(snapshot, input_limit)
    }

    pub fn new(
        snapshot: RunStartSnapshot,
        max_model_input_tokens: usize,
    ) -> Result<Self, AgentInputError> {
        snapshot.validate()?;
        Ok(Self {
            snapshot,
            max_model_input_tokens,
            memory_provider: None,
        })
    }

    pub fn with_memory_provider(mut self, provider: Arc<dyn MemoryProvider>) -> Self {
        self.memory_provider = Some(provider);
        self
    }

    pub fn assemble_turn(
        &self,
        conversation_stream_id: &str,
        branch: Vec<RuntimeEvent>,
    ) -> Result<AgentTurnInput, AgentInputError> {
        let conversation = compact_tool_results_for_context(
            BranchProjector::new().project(branch),
            self.max_model_input_tokens,
        );
        let mut assembler = ContextAssembler::new().with_required_compiled_prompt(
            compile_prompt_documents(&self.snapshot.ordered_prompt_documents),
        );

        let skill_prompt = render_skill_descriptors(&self.snapshot.skill_descriptors);
        if !skill_prompt.is_empty() {
            assembler = assembler.with_segment(
                ContextSegment::skill_instruction("skills.descriptors", skill_prompt)
                    .with_provenance("skills.descriptors")
                    .required_for_model_input(),
            );
        }

        if let Some(provider) = &self.memory_provider {
            let query = MemoryQuery::for_conversation(
                conversation_stream_id,
                latest_user_text(&conversation),
                10,
            );
            for contribution in provider.recall(&query).contributions {
                assembler = assembler.with_memory_contribution(contribution);
            }
        }

        let assembly = assembler
            .with_conversation_messages(conversation.clone())
            .assemble(ContextBudget::with_token_counter_named(
                self.max_model_input_tokens,
                "context.approximate",
                approximate_token_count,
            ))
            .map_err(|error| {
                AgentInputError::new("agent_input.context_assembly_failed", error.to_string())
            })?;
        let model_input = assembly.model_input_messages();
        let mut system_parts = Vec::new();
        let mut ordered_messages = Vec::new();
        for message in model_input.messages() {
            if message.role() == ModelInputRole::System {
                system_parts.push(message.content().to_string());
            } else {
                ordered_messages.push(message.clone());
            }
        }

        Ok(AgentTurnInput::new(
            system_parts.join("\n\n"),
            ModelInputMessages::new(ordered_messages),
            self.snapshot.ordered_tool_definitions.clone(),
            assembly.trace().clone(),
            compaction_summary(&conversation, assembly.trace()),
        ))
    }
}

fn compaction_summary(
    conversation: &[PromptMessage],
    trace: &ContextAssemblyTrace,
) -> Option<String> {
    let dropped = trace.dropped_segment_ids();
    let dropped_prefix = (0..conversation.len())
        .take_while(|index| dropped.contains(&format!("conversation.{index:04}")))
        .count();
    if dropped_prefix == 0 {
        return None;
    }

    let dropped = &conversation[..dropped_prefix];
    let latest_summary = dropped
        .iter()
        .rposition(|message| matches!(message, PromptMessage::Summary(_)));
    let messages = match latest_summary {
        Some(index) => dropped[index..]
            .iter()
            .map(|message| message.content().to_string())
            .collect(),
        None => dropped
            .iter()
            .map(|message| message.content().to_string())
            .collect(),
    };
    Some(CompactionCandidate::new(messages).summary_text())
}

fn latest_user_text(messages: &[PromptMessage]) -> &str {
    messages
        .iter()
        .rev()
        .find_map(|message| match message {
            PromptMessage::User(text) | PromptMessage::UserWithBlobRefs { content: text, .. } => {
                Some(text.as_str())
            }
            _ => None,
        })
        .unwrap_or("")
}
