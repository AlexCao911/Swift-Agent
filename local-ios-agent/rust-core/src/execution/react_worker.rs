use std::sync::Arc;

use serde_json::json;

use crate::context::ModelInputMessages;
use crate::conversation::{ConversationRunFrame, ConversationRunFrameRef};
use crate::execution::{
    CompletedRunRegistry, ExecutionContextInputAssembler, ExecutionEventLog, ExecutionPlan,
};
use crate::run_snapshot::RunSnapshotId;

pub trait ExecutionModelClient: Send + Sync + 'static {
    fn next_turn(
        &self,
        run_id: &str,
        input: &ModelInputMessages,
    ) -> Result<ExecutionModelTurn, String>;
}

pub trait ExecutionToolExecutor: Send + Sync + 'static {
    fn execute_tool(
        &self,
        run_id: &str,
        frame_ref: &ConversationRunFrameRef,
        call: &ExecutionToolCall,
    ) -> Result<ExecutionToolOutcome, String>;
}

impl<T> ExecutionModelClient for Arc<T>
where
    T: ExecutionModelClient + ?Sized,
{
    fn next_turn(
        &self,
        run_id: &str,
        input: &ModelInputMessages,
    ) -> Result<ExecutionModelTurn, String> {
        (**self).next_turn(run_id, input)
    }
}

impl<T> ExecutionToolExecutor for Arc<T>
where
    T: ExecutionToolExecutor + ?Sized,
{
    fn execute_tool(
        &self,
        run_id: &str,
        frame_ref: &ConversationRunFrameRef,
        call: &ExecutionToolCall,
    ) -> Result<ExecutionToolOutcome, String> {
        (**self).execute_tool(run_id, frame_ref, call)
    }
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

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ExecutionToolOutcome {
    Observation(ExecutionToolObservation),
    PendingHostTool { call_id: String },
    ApprovalRequired { call_id: String, reason: String },
}

#[derive(Clone, Debug, Default)]
pub struct NoopExecutionToolExecutor;

impl ExecutionToolExecutor for NoopExecutionToolExecutor {
    fn execute_tool(
        &self,
        _run_id: &str,
        _frame_ref: &ConversationRunFrameRef,
        call: &ExecutionToolCall,
    ) -> Result<ExecutionToolOutcome, String> {
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
        let default_plan = ExecutionPlan::for_snapshot(RunSnapshotId::new(0));
        self.run_with_plan(run_id, frame, frame_ref, &default_plan)
    }

    pub fn run_with_plan(
        &self,
        run_id: &str,
        frame: &ConversationRunFrame,
        frame_ref: &ConversationRunFrameRef,
        plan: &ExecutionPlan,
    ) -> Result<(), String> {
        self.run_with_plan_and_observations(run_id, frame, frame_ref, plan, Vec::new())
    }

    pub fn run_with_plan_and_observations(
        &self,
        run_id: &str,
        frame: &ConversationRunFrame,
        frame_ref: &ConversationRunFrameRef,
        plan: &ExecutionPlan,
        mut observations: Vec<ExecutionToolObservation>,
    ) -> Result<(), String> {
        self.require_plan_step(run_id, plan, "context.assemble")?;
        self.require_plan_step(run_id, plan, "inference.generate")?;

        for _ in 0..8 {
            let input = self
                .context
                .assemble_with_observations_and_budget(
                    frame,
                    &observations,
                    Some(plan.budgets().max_model_input_tokens()),
                )
                .map_err(|error| format!("{}: {error}", error.code()))?;
            let input_token_count = model_input_token_count(&input);
            if plan.trace_config().capture_context_archive() {
                self.event_log.append_with_payload(
                    run_id,
                    "context.assembled",
                    json!({
                        "snapshot_id": plan.snapshot_id().as_u64(),
                        "message_count": input.messages().len(),
                        "input_token_count": input_token_count,
                        "max_model_input_tokens": plan.budgets().max_model_input_tokens()
                    })
                    .to_string(),
                );
            }
            if plan.trace_config().capture_prompt_archive() {
                self.event_log.append_with_payload(
                    run_id,
                    "inference.generate",
                    json!({
                        "snapshot_id": plan.snapshot_id().as_u64(),
                        "input_token_count": input_token_count
                    })
                    .to_string(),
                );
            }
            match self.model.next_turn(run_id, &input)? {
                ExecutionModelTurn::Final { message_id, text } => {
                    self.record_final(run_id, frame_ref, message_id, text);
                    return Ok(());
                }
                ExecutionModelTurn::ToolCall {
                    call_id,
                    name,
                    arguments_json,
                } => {
                    self.event_log.append_with_payload(
                        run_id,
                        "tool_call_requested",
                        json!({
                            "call_id": &call_id,
                            "name": &name,
                            "arguments_json": &arguments_json
                        })
                        .to_string(),
                    );
                    let outcome = self.tools.execute_tool(
                        run_id,
                        frame_ref,
                        &ExecutionToolCall {
                            call_id,
                            name,
                            arguments_json,
                        },
                    )?;
                    match outcome {
                        ExecutionToolOutcome::Observation(observation) => {
                            self.event_log.append_with_payload(
                                run_id,
                                "tool_result_message",
                                json!({
                                    "call_id": &observation.call_id,
                                    "model_text": &observation.model_text
                                })
                                .to_string(),
                            );
                            observations.push(observation);
                        }
                        ExecutionToolOutcome::PendingHostTool { call_id } => {
                            self.event_log.append_with_payload(
                                run_id,
                                "run.waiting_tool",
                                json!({ "call_id": call_id }).to_string(),
                            );
                            return Ok(());
                        }
                        ExecutionToolOutcome::ApprovalRequired { call_id, reason } => {
                            self.event_log.append_with_payload(
                                run_id,
                                "run.suspended",
                                json!({
                                    "call_id": call_id,
                                    "reason": reason
                                })
                                .to_string(),
                            );
                            return Ok(());
                        }
                    }
                }
            }
        }

        self.event_log.append(run_id, "run.failed");
        Err("execution tool loop exceeded 8 model calls".to_string())
    }

    fn require_plan_step(
        &self,
        run_id: &str,
        plan: &ExecutionPlan,
        required_step: &str,
    ) -> Result<(), String> {
        let has_step = plan
            .steps()
            .iter()
            .any(|step| step.kind().as_str() == required_step);
        if has_step {
            return Ok(());
        }

        self.event_log.append_with_payload(
            run_id,
            "run.failed",
            json!({
                "reason": "execution.plan_missing_required_step",
                "missing_step": required_step
            })
            .to_string(),
        );
        Err(format!(
            "execution plan missing required step: {required_step}"
        ))
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

fn model_input_token_count(input: &ModelInputMessages) -> usize {
    input
        .messages()
        .iter()
        .map(|message| message.content().split_whitespace().count())
        .sum()
}
