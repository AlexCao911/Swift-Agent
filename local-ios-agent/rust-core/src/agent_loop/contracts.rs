use std::fmt;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::agent_input::{RunStartSnapshot, ToolDefinitionSnapshot};
use crate::conversation::TranscriptAttachmentReference;
use crate::tool::{AgentToolCall, ToolBatch, ToolBatchResult, ToolCallResult};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgentRunRequest {
    pub run_id: String,
    pub conversation_stream_id: String,
    pub run_start_snapshot: RunStartSnapshot,
    pub attachment_references: Vec<TranscriptAttachmentReference>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ModelMessage {
    pub role: String,
    pub content: Value,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ModelRequestPurpose {
    #[default]
    Generation,
    Compaction,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ModelRequest {
    pub run_id: String,
    pub conversation_stream_id: String,
    pub system_prompt: String,
    pub ordered_messages: Vec<ModelMessage>,
    pub attachment_references: Vec<TranscriptAttachmentReference>,
    pub ordered_tool_definitions: Vec<ToolDefinitionSnapshot>,
    pub ordered_tool_results: Vec<ToolCallResult>,
    pub purpose: ModelRequestPurpose,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ModelEvent {
    TextDelta {
        text: String,
    },
    ReasoningDelta {
        text: String,
    },
    ToolCallDelta {
        call_id: String,
        tool_name: String,
        arguments_fragment: String,
    },
    Usage {
        payload: Value,
    },
}

pub trait ModelEventSink {
    fn emit(&mut self, event: ModelEvent) -> Result<(), AgentLoopError>;
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AssistantTurn {
    pub text: String,
    pub reasoning: String,
    pub tool_calls: Vec<AgentToolCall>,
    pub usage: Option<Value>,
}

pub trait ModelRuntime: Send + Sync {
    fn generate(
        &self,
        request: ModelRequest,
        sink: &mut dyn ModelEventSink,
    ) -> Result<AssistantTurn, AgentLoopError>;

    fn cancel(&self, run_id: &str) -> Result<(), AgentLoopError>;
    fn close(&self, run_id: &str) -> Result<(), AgentLoopError>;
}

pub trait ToolRuntime: Send + Sync {
    fn execute_batch(&self, batch: ToolBatch) -> Result<ToolBatchResult, AgentLoopError>;
    fn cancel_batch(&self, batch_id: &str) -> Result<(), AgentLoopError>;
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AgentLoopOutcome {
    Completed,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgentLoopError {
    code: String,
    message: String,
}

impl AgentLoopError {
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }

    pub fn cancelled() -> Self {
        Self::new("agent_loop.cancelled", "Agent run was cancelled")
    }

    pub fn max_model_turns(limit: usize) -> Self {
        Self::new(
            "agent_loop.max_model_turns",
            format!("Agent run reached the fixed limit of {limit} model turns"),
        )
    }

    pub fn code(&self) -> &str {
        &self.code
    }
}

impl fmt::Display for AgentLoopError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for AgentLoopError {}
