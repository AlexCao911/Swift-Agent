use std::fmt;

use crate::context::{ContextAssembler, ContextSegment, ModelInputMessages, PromptMessage};
use crate::conversation::{ConversationFrameMessage, ConversationRunFrame};
use crate::execution::RuntimeOptions;

#[derive(Clone, Debug)]
pub struct ExecutionContextInputAssembler {
    runtime_options: Option<RuntimeOptions>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ExecutionContextInputError {
    code: String,
    message: String,
}

impl ExecutionContextInputAssembler {
    pub fn new(runtime_options: Option<RuntimeOptions>) -> Self {
        Self { runtime_options }
    }

    pub fn assemble_initial(
        &self,
        frame: &ConversationRunFrame,
    ) -> Result<ModelInputMessages, ExecutionContextInputError> {
        let mut assembler = ContextAssembler::new();

        if let Some(options) = &self.runtime_options {
            let system = system_segment_text(options);
            if !system.trim().is_empty() {
                assembler = assembler.with_segment(
                    ContextSegment::prompt("execution.prompt.runtime_options", system)
                        .with_provenance("execution.runtime_options"),
                );
            }
        }

        assembler = assembler.with_conversation_messages(
            frame
                .messages()
                .iter()
                .map(prompt_message_from_conversation)
                .collect(),
        );

        Ok(assembler
            .assemble_default()
            .map_err(|error| {
                ExecutionContextInputError::new(
                    "execution_context.assembly_failed",
                    error.to_string(),
                )
            })?
            .model_input_messages())
    }
}

impl ExecutionContextInputError {
    fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }

    pub fn code(&self) -> &str {
        &self.code
    }
}

impl fmt::Display for ExecutionContextInputError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for ExecutionContextInputError {}

fn system_segment_text(options: &RuntimeOptions) -> String {
    [options.system_prompt.trim(), options.runtime_policy.trim()]
        .into_iter()
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>()
        .join("\n\n")
}

fn prompt_message_from_conversation(message: &ConversationFrameMessage) -> PromptMessage {
    match message.role() {
        "user" => {
            if message.blob_refs().is_empty() {
                PromptMessage::User(message.content().to_string())
            } else {
                PromptMessage::UserWithBlobRefs {
                    content: message.content().to_string(),
                    blob_refs: message.blob_refs().to_vec(),
                }
            }
        }
        "assistant" => PromptMessage::Assistant(message.content().to_string()),
        "summary" => PromptMessage::Summary(message.content().to_string()),
        other => PromptMessage::Summary(format!("unknown conversation role {other}")),
    }
}
