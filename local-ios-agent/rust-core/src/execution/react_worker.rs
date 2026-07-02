use serde_json::json;

use crate::context::ModelInputMessages;
use crate::conversation::{ConversationRunFrame, ConversationRunFrameRef};
use crate::execution::{CompletedRunRegistry, ExecutionContextInputAssembler, ExecutionEventLog};

pub trait ExecutionModelClient: Clone + Send + Sync + 'static {
    fn next_turn(&self, input: &ModelInputMessages) -> Result<ExecutionModelTurn, String>;
}

pub trait ExecutionToolExecutor: Clone + Send + Sync + 'static {
    fn execute_tool(&self, call: &ExecutionToolCall) -> Result<ExecutionToolObservation, String>;
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ExecutionModelTurn {
    Final {
        message_id: String,
        text: String,
    },
    ToolCall {
        call_id: String,
        name: String,
        arguments_json: String,
    },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ExecutionToolCall {
    pub call_id: String,
    pub name: String,
    pub arguments_json: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ExecutionToolObservation {
    pub call_id: String,
    pub model_text: String,
}

#[derive(Clone, Debug, Default)]
pub struct NoopExecutionToolExecutor;

impl ExecutionToolExecutor for NoopExecutionToolExecutor {
    fn execute_tool(&self, call: &ExecutionToolCall) -> Result<ExecutionToolObservation, String> {
        Err(format!(
            "no execution tool executor installed for {}",
            call.name
        ))
    }
}

#[derive(Clone, Debug)]
pub struct ExecutionReactWorker<M, T> {
    model: M,
    tools: T,
    context: ExecutionContextInputAssembler,
    event_log: ExecutionEventLog,
    completed_runs: CompletedRunRegistry,
}

impl<M, T> ExecutionReactWorker<M, T>
where
    M: ExecutionModelClient,
    T: ExecutionToolExecutor,
{
    pub fn new(
        model: M,
        tools: T,
        context: ExecutionContextInputAssembler,
        event_log: ExecutionEventLog,
        completed_runs: CompletedRunRegistry,
    ) -> Self {
        Self {
            model,
            tools,
            context,
            event_log,
            completed_runs,
        }
    }

    pub fn run(
        &self,
        run_id: &str,
        frame: &ConversationRunFrame,
        frame_ref: &ConversationRunFrameRef,
    ) -> Result<(), String> {
        let input = self
            .context
            .assemble_initial(frame)
            .map_err(|error| format!("{}: {error}", error.code()))?;
        match self.model.next_turn(&input)? {
            ExecutionModelTurn::Final { message_id, text } => {
                self.record_final(run_id, frame_ref, message_id, text);
                Ok(())
            }
            ExecutionModelTurn::ToolCall {
                call_id,
                name,
                arguments_json,
            } => {
                let _ = self.tools.execute_tool(&ExecutionToolCall {
                    call_id,
                    name,
                    arguments_json,
                })?;
                Err("tool continuation not implemented in Task 2".to_string())
            }
        }
    }

    fn record_final(
        &self,
        run_id: &str,
        frame_ref: &ConversationRunFrameRef,
        message_id: String,
        text: String,
    ) {
        self.event_log.append_with_payload(
            run_id,
            "assistant_message_completed",
            json!({
                "message_id": message_id,
                "text": text
            })
            .to_string(),
        );
        self.event_log.append(run_id, "run.completed");
        self.completed_runs.record_completed_with_text(
            run_id,
            &message_id,
            frame_ref.clone(),
            text,
        );
    }
}
