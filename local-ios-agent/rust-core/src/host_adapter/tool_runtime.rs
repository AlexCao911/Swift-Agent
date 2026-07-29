use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use crate::agent_loop::{AgentLoopError, ToolRuntime};
use crate::llm_contracts::{
    HostCommandEnvelope, HostCommandKind, HostExecutionPhase, HostToolBatch, HostToolCall,
    HostWatchdogKind, LLMEventKind,
};
use crate::storage::{
    runtime_now_millis, RuntimeTransition, UnifiedRuntimeStateRepository,
    HOST_LIFECYCLE_TIMEOUT_MILLIS,
};
use crate::tool::{ToolBatch, ToolBatchResult, ToolCallResult};

use super::model_runtime::{
    adapter_error, command_id, required_worker, runtime_error, wait_for_ack,
};

const DEFAULT_POLL_INTERVAL: Duration = Duration::from_millis(10);

pub struct HostToolRuntime<R: UnifiedRuntimeStateRepository + ?Sized> {
    repository: Arc<R>,
    poll_interval: Duration,
    active_batches: Arc<Mutex<HashMap<String, ActiveBatch>>>,
}

#[derive(Clone)]
struct ActiveBatch {
    run_id: String,
    command_id: String,
}

impl<R: UnifiedRuntimeStateRepository + ?Sized> HostToolRuntime<R> {
    pub fn new(repository: Arc<R>) -> Self {
        Self {
            repository,
            poll_interval: DEFAULT_POLL_INTERVAL,
            active_batches: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    pub fn with_poll_interval(mut self, interval: Duration) -> Self {
        self.poll_interval = interval;
        self
    }

    fn execute_inner(&self, batch: ToolBatch) -> Result<ToolBatchResult, AgentLoopError> {
        {
            let mut active = self.active_batches.lock().map_err(|_| lock_error())?;
            if active.contains_key(&batch.batch_id) {
                return Err(adapter_error(
                    "host_adapter.batch_already_active",
                    "tool batch is already active",
                ));
            }
            active.insert(
                batch.batch_id.clone(),
                ActiveBatch {
                    run_id: batch.run_id.clone(),
                    command_id: String::new(),
                },
            );
        }
        let result = self.execute_registered_batch(&batch);
        self.active_batches
            .lock()
            .map_err(|_| lock_error())?
            .remove(&batch.batch_id);
        result
    }

    fn execute_registered_batch(
        &self,
        batch: &ToolBatch,
    ) -> Result<ToolBatchResult, AgentLoopError> {
        let worker = required_worker(self.repository.as_ref(), &batch.run_id)?;
        if worker.execution_phase() != Some(HostExecutionPhase::ExecutingToolBatch) {
            return Err(adapter_error(
                "host_adapter.tool_phase_invalid",
                "host worker is not waiting for a tool batch",
            ));
        }
        let turn_id = worker
            .generation_turn_id()
            .ok_or_else(|| {
                adapter_error(
                    "host_adapter.generation_turn_missing",
                    "tool batch has no generation turn",
                )
            })?
            .to_string();
        let host_batch = HostToolBatch {
            batch_id: batch.batch_id.clone(),
            run_id: batch.run_id.clone(),
            ordered_calls: batch
                .ordered_calls
                .iter()
                .map(|call| HostToolCall {
                    call_id: call.call_id.clone(),
                    tool_name: call.tool_name.clone(),
                    arguments_json: call.arguments_json.clone(),
                })
                .collect(),
        };
        let command_id = command_id()?;
        let command = HostCommandEnvelope::command_v2(
            &command_id,
            worker.run_id(),
            worker.session_handle(),
            worker.host_process_epoch(),
            worker.expected_command_sequence(),
            HostCommandKind::ExecuteToolBatch,
            crate::llm_contracts::HostCommandPayload::tool_batch_v2(host_batch),
        )
        .map_err(|error| adapter_error(error.code(), error.to_string()))?;
        let next = worker
            .clone()
            .with_revision(worker.revision() + 1)
            .with_watchdog(
                Some(HostWatchdogKind::ToolBatch),
                Some(command_id.clone()),
                Some(runtime_now_millis() + HOST_LIFECYCLE_TIMEOUT_MILLIS),
            );
        self.repository
            .transition_and_enqueue(RuntimeTransition::new(worker.revision(), next, command))
            .map_err(runtime_error)?;
        if let Some(active) = self
            .active_batches
            .lock()
            .map_err(|_| lock_error())?
            .get_mut(&batch.batch_id)
        {
            active.command_id = command_id;
        }

        loop {
            let mut events = self
                .repository
                .turn_accumulator_events(worker.session_handle(), &turn_id)
                .map_err(runtime_error)?;
            events.sort_by_key(|event| event.event_sequence());
            for event in events {
                if event.kind() == LLMEventKind::ToolBatchCompleted {
                    let completion =
                        event
                            .payload
                            .tool_batch_completion
                            .as_ref()
                            .ok_or_else(|| {
                                adapter_error(
                                    "host_adapter.tool_completion_missing",
                                    "tool batch completion is missing",
                                )
                            })?;
                    event
                        .payload
                        .validate_for(
                            LLMEventKind::ToolBatchCompleted,
                            &batch.run_id,
                            Some(&batch.batch_id),
                        )
                        .map_err(|error| adapter_error(error.code(), error.to_string()))?;
                    self.repository
                        .acknowledge_inbound_event_projection(&event)
                        .map_err(runtime_error)?;
                    return Ok(ToolBatchResult {
                        batch_id: completion.batch_id.clone(),
                        run_id: completion.run_id.clone(),
                        ordered_results: completion
                            .ordered_results
                            .iter()
                            .map(|result| ToolCallResult {
                                call_id: result.call_id.clone(),
                                tool_name: result.tool_name.clone(),
                                result: result.result.clone(),
                                is_error: result.is_error,
                                data_classes: result.data_classes.clone(),
                                highest_sensitivity: result.highest_sensitivity.clone(),
                            })
                            .collect(),
                    });
                }
                if event.kind() == LLMEventKind::ToolBatchFailed {
                    self.repository
                        .acknowledge_inbound_event_projection(&event)
                        .map_err(runtime_error)?;
                    return Err(adapter_error(
                        event
                            .payload
                            .failure_code
                            .as_deref()
                            .unwrap_or("host_adapter.tool_batch_failed"),
                        "Swift tool batch failed",
                    ));
                }
            }
            thread::sleep(self.poll_interval);
        }
    }
}

impl<R: UnifiedRuntimeStateRepository + ?Sized> ToolRuntime for HostToolRuntime<R> {
    fn execute_batch(&self, batch: ToolBatch) -> Result<ToolBatchResult, AgentLoopError> {
        self.execute_inner(batch)
    }

    fn cancel_batch(&self, batch_id: &str) -> Result<(), AgentLoopError> {
        let active = self
            .active_batches
            .lock()
            .map_err(|_| lock_error())?
            .get(batch_id)
            .cloned()
            .ok_or_else(|| {
                adapter_error("host_adapter.batch_not_active", "tool batch is not active")
            })?;
        if !active.command_id.is_empty() {
            wait_for_ack(
                self.repository.as_ref(),
                &active.command_id,
                self.poll_interval,
            )?;
        }
        let worker = required_worker(self.repository.as_ref(), &active.run_id)?;
        let command_id = command_id()?;
        let command = HostCommandEnvelope::command_v2(
            command_id,
            worker.run_id(),
            worker.session_handle(),
            worker.host_process_epoch(),
            worker.expected_command_sequence(),
            HostCommandKind::CancelToolBatch,
            crate::llm_contracts::HostCommandPayload::cancel_tool_batch_v2(batch_id),
        )
        .map_err(|error| adapter_error(error.code(), error.to_string()))?;
        let next = worker.clone().with_revision(worker.revision() + 1);
        self.repository
            .transition_and_enqueue(RuntimeTransition::new(worker.revision(), next, command))
            .map_err(runtime_error)?;
        Ok(())
    }
}

fn lock_error() -> AgentLoopError {
    adapter_error(
        "host_adapter.lock_poisoned",
        "host adapter lock was poisoned",
    )
}
