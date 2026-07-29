use std::sync::Arc;

use crate::llm_contracts::{
    BearerTokenIssuer, EgressDataClassCountDocument, GenerationDisclosureDocument,
    HostCommandEnvelope, HostCommandKind, HostExecutionPhase, HostToolResult, LLMEventEnvelope,
    LLMEventKind, LLMEventSubmissionResult, LogicalRunOutcome, ResourceLifecycle,
    SafeDisplaySummaryDocument,
};
use crate::storage::{
    EventQueueUsage, RuntimeStateError, RuntimeTransition, UnifiedRuntimeStateRepository,
    HOST_EVENT_LOW_WATER_BYTES, HOST_EVENT_LOW_WATER_EVENTS, HOST_EVENT_MAX_BYTES,
    HOST_EVENT_MAX_EVENTS,
};

use super::{ExecutionToolCall, ExecutionToolOutcome};

pub trait HostToolBatchExecutor: Send + Sync + 'static {
    fn execute_tool(
        &self,
        run_id: &str,
        call: &ExecutionToolCall,
    ) -> Result<ExecutionToolOutcome, String>;
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct HostLLMWorkerServiceConfig {
    pub max_events: usize,
    pub max_bytes: usize,
    pub low_water_events: usize,
    pub low_water_bytes: usize,
}

impl Default for HostLLMWorkerServiceConfig {
    fn default() -> Self {
        Self {
            max_events: HOST_EVENT_MAX_EVENTS,
            max_bytes: HOST_EVENT_MAX_BYTES,
            low_water_events: HOST_EVENT_LOW_WATER_EVENTS,
            low_water_bytes: HOST_EVENT_LOW_WATER_BYTES,
        }
    }
}

pub struct HostLLMWorkerService<R: UnifiedRuntimeStateRepository + ?Sized> {
    repository: Arc<R>,
    config: HostLLMWorkerServiceConfig,
    tools: Option<Arc<dyn HostToolBatchExecutor>>,
}

impl<R: UnifiedRuntimeStateRepository + ?Sized> HostLLMWorkerService<R> {
    pub fn new(repository: Arc<R>) -> Self {
        Self {
            repository,
            config: HostLLMWorkerServiceConfig::default(),
            tools: None,
        }
    }

    pub fn with_tools(repository: Arc<R>, tools: Arc<dyn HostToolBatchExecutor>) -> Self {
        Self {
            repository,
            config: HostLLMWorkerServiceConfig::default(),
            tools: Some(tools),
        }
    }

    pub fn submit_event(
        &self,
        event: &LLMEventEnvelope,
    ) -> Result<LLMEventSubmissionResult, RuntimeStateError> {
        if !valid_envelope(event) {
            self.apply_protocol_failure_if_known(event, LLMEventSubmissionResult::InvalidEnvelope)?;
            return Ok(LLMEventSubmissionResult::InvalidEnvelope);
        }

        let Some(session) = self.repository.host_session(event.session_handle())? else {
            return Ok(LLMEventSubmissionResult::StaleSession);
        };
        if session.run_id() != event.run_id()
            || session.host_process_epoch() != event.host_process_epoch()
        {
            return Ok(LLMEventSubmissionResult::StaleSession);
        }

        if let Some(receipt) = self
            .repository
            .event_receipt(event.session_handle(), event.event_sequence())?
        {
            let result = if receipt.event_id() == event.event_id()
                && receipt.event_envelope_digest() == event.event_envelope_digest()
            {
                LLMEventSubmissionResult::Duplicate
            } else {
                LLMEventSubmissionResult::SequenceConflict
            };
            if result == LLMEventSubmissionResult::SequenceConflict {
                self.repository.apply_event_transactionally(event, result)?;
            }
            return Ok(result);
        }

        if matches!(
            session.resource_lifecycle(),
            ResourceLifecycle::Closed { .. }
        ) {
            return Ok(LLMEventSubmissionResult::ClosedSession);
        }

        if let Some(receipt) = self
            .repository
            .event_receipt_by_id(event.session_handle(), event.event_id())?
        {
            if receipt.event_sequence() != event.event_sequence()
                || receipt.event_envelope_digest() != event.event_envelope_digest()
            {
                self.repository.apply_event_transactionally(
                    event,
                    LLMEventSubmissionResult::IdentityConflict,
                )?;
                return Ok(LLMEventSubmissionResult::IdentityConflict);
            }
        }

        let Some(worker) = self.repository.host_worker(event.run_id())? else {
            return Ok(LLMEventSubmissionResult::StaleSession);
        };
        if event.event_sequence() > worker.expected_event_sequence() {
            self.repository
                .apply_event_transactionally(event, LLMEventSubmissionResult::SequenceGap)?;
            return Ok(LLMEventSubmissionResult::SequenceGap);
        }
        if event.event_sequence() < worker.expected_event_sequence() {
            self.repository
                .apply_event_transactionally(event, LLMEventSubmissionResult::SequenceConflict)?;
            return Ok(LLMEventSubmissionResult::SequenceConflict);
        }

        let lifecycle_result = lifecycle_result(event, &worker);
        if lifecycle_result != LLMEventSubmissionResult::Accepted {
            self.repository
                .apply_event_transactionally(event, lifecycle_result)?;
            return Ok(lifecycle_result);
        }

        let event_bytes = serde_json::to_vec(event)
            .map_err(|error| RuntimeStateError::new("llm.event.encode_failed", error.to_string()))?
            .len();
        if event_bytes > self.config.max_bytes {
            self.repository
                .apply_event_transactionally(event, LLMEventSubmissionResult::PayloadTooLarge)?;
            return Ok(LLMEventSubmissionResult::PayloadTooLarge);
        }
        let EventQueueUsage {
            event_count,
            byte_count,
        } = self.repository.event_queue_usage(event.session_handle())?;
        if event_count + 1 > self.config.max_events
            || byte_count + event_bytes > self.config.max_bytes
        {
            self.repository
                .record_event_backpressure(event.session_handle())?;
            return Ok(LLMEventSubmissionResult::Backpressure);
        }

        self.repository
            .apply_event_transactionally(event, LLMEventSubmissionResult::Accepted)?;
        if event.kind() == LLMEventKind::GenerationCompleted
            && event
                .payload
                .completion
                .as_ref()
                .is_some_and(|completion| completion.outcome == "tool_calls_ready")
            && worker
                .generation_payload()
                .is_none_or(|payload| payload.schema_version != "2")
        {
            self.process_tool_batch(event)?;
        }
        Ok(LLMEventSubmissionResult::Accepted)
    }

    pub fn cancel_run(&self, run_id: &str) -> Result<bool, RuntimeStateError> {
        let worker = self
            .repository
            .host_worker(run_id)?
            .ok_or_else(|| RuntimeStateError::new("llm.run.not_found", "host run is missing"))?;
        if !matches!(worker.logical_outcome(), LogicalRunOutcome::Pending)
            || matches!(
                worker.resource_lifecycle(),
                ResourceLifecycle::AwaitingCancelCommandAck
                    | ResourceLifecycle::AwaitingCancelledTerminal
                    | ResourceLifecycle::AwaitingCloseCommandAck
                    | ResourceLifecycle::AwaitingSessionClosed
                    | ResourceLifecycle::Quarantined { .. }
                    | ResourceLifecycle::Closed { .. }
            )
        {
            return Ok(false);
        }
        let command = HostCommandEnvelope::lifecycle(
            BearerTokenIssuer::system()
                .issue("saga-token:v1")
                .map_err(|error| {
                    RuntimeStateError::new("llm.command.id_failed", error.to_string())
                })?
                .raw(),
            worker.run_id(),
            worker.session_handle(),
            worker.host_process_epoch(),
            worker.expected_command_sequence(),
            HostCommandKind::CancelGeneration,
        )
        .map_err(|error| RuntimeStateError::new("llm.command.cancel_invalid", error.to_string()))?;
        let next = worker
            .clone()
            .with_revision(worker.revision() + 1)
            .with_resource_lifecycle(ResourceLifecycle::AwaitingCancelCommandAck)
            .with_watchdog(
                Some(crate::llm_contracts::HostWatchdogKind::CancelCommandAck),
                Some(command.command_id().to_string()),
                Some(
                    crate::storage::runtime_now_millis()
                        + crate::storage::HOST_LIFECYCLE_TIMEOUT_MILLIS,
                ),
            );
        self.repository
            .transition_and_enqueue(RuntimeTransition::new(worker.revision(), next, command))?;
        Ok(true)
    }

    pub fn resume_tool_batch(
        &self,
        run_id: &str,
        external_result: HostToolResult,
    ) -> Result<(), RuntimeStateError> {
        let worker = self
            .repository
            .host_worker(run_id)?
            .ok_or_else(|| RuntimeStateError::new("llm.run.not_found", "host run is missing"))?;
        if worker.execution_phase() != Some(HostExecutionPhase::SuspendedForToolApproval) {
            return Err(RuntimeStateError::new(
                "llm.tool.not_suspended",
                "host tool batch is not suspended",
            ));
        }
        let terminal = self.tool_batch_terminal(&worker)?;
        let mut results = worker.tool_results().to_vec();
        let completion = terminal.payload.completion.as_ref().ok_or_else(|| {
            RuntimeStateError::new("llm.turn.completion_missing", "tool completion is missing")
        })?;
        let expected_call_id = completion
            .ordered_call_ids
            .iter()
            .find(|call_id| {
                !results
                    .iter()
                    .any(|item| item.call_id.as_str() == call_id.as_str())
            })
            .ok_or_else(|| {
                RuntimeStateError::new(
                    "llm.tool.result_unexpected",
                    "tool batch has no pending result",
                )
            })?;
        if external_result.call_id != *expected_call_id {
            return Err(RuntimeStateError::new(
                "llm.tool.result_identity_mismatch",
                "tool result does not match the next ordered call",
            ));
        }
        results.push(external_result);
        let next = worker
            .clone()
            .with_revision(worker.revision() + 1)
            .with_execution_phase(Some(HostExecutionPhase::ExecutingToolBatch))
            .with_tool_results(results)
            .with_watchdog(
                Some(crate::llm_contracts::HostWatchdogKind::ToolBatch),
                None,
                Some(
                    crate::storage::runtime_now_millis()
                        + crate::storage::HOST_LIFECYCLE_TIMEOUT_MILLIS,
                ),
            );
        self.repository
            .update_host_worker(worker.revision(), next)?;
        self.process_tool_batch(&terminal)
    }

    pub fn reject_tool_batch(&self, run_id: &str, message: &str) -> Result<(), RuntimeStateError> {
        let worker = self
            .repository
            .host_worker(run_id)?
            .ok_or_else(|| RuntimeStateError::new("llm.run.not_found", "host run is missing"))?;
        let terminal = self.tool_batch_terminal(&worker)?;
        let completion = terminal.payload.completion.as_ref().ok_or_else(|| {
            RuntimeStateError::new("llm.turn.completion_missing", "tool completion is missing")
        })?;
        let call_id = completion
            .ordered_call_ids
            .iter()
            .find(|call_id| {
                !worker
                    .tool_results()
                    .iter()
                    .any(|item| item.call_id.as_str() == call_id.as_str())
            })
            .ok_or_else(|| {
                RuntimeStateError::new("llm.tool.result_unexpected", "tool batch is complete")
            })?;
        let turn_id = terminal.generation_turn_id.as_deref().ok_or_else(|| {
            RuntimeStateError::new("llm.turn.identity_missing", "tool turn identity is missing")
        })?;
        let call = self
            .repository
            .turn_accumulator_events(worker.session_handle(), turn_id)?
            .into_iter()
            .find(|event| {
                event.kind() == LLMEventKind::ToolCallCompleted
                    && event.payload.call_id.as_deref() == Some(call_id)
            })
            .ok_or_else(|| {
                RuntimeStateError::new(
                    "llm.turn.invalid_tool_batch",
                    "completed tool call is missing",
                )
            })?;
        self.resume_tool_batch(
            run_id,
            HostToolResult {
                call_id: call_id.clone(),
                tool_name: call.payload.name.unwrap_or_else(|| "unknown_tool".into()),
                result: serde_json::json!({ "model_text": message }),
                is_error: true,
                data_classes: vec!["unknown_data".into()],
                highest_sensitivity: "unknown".into(),
            },
        )
    }

    fn tool_batch_terminal(
        &self,
        worker: &crate::llm_contracts::HostWorkerRecord,
    ) -> Result<LLMEventEnvelope, RuntimeStateError> {
        let turn_id = worker.generation_turn_id().ok_or_else(|| {
            RuntimeStateError::new("llm.turn.identity_missing", "tool turn identity is missing")
        })?;
        self.repository
            .turn_accumulator_events(worker.session_handle(), turn_id)?
            .into_iter()
            .find(|event| {
                event.kind() == LLMEventKind::GenerationCompleted
                    && event
                        .payload
                        .completion
                        .as_ref()
                        .is_some_and(|completion| completion.outcome == "tool_calls_ready")
            })
            .ok_or_else(|| {
                RuntimeStateError::new("llm.turn.completion_missing", "tool completion is missing")
            })
    }

    fn apply_protocol_failure_if_known(
        &self,
        event: &LLMEventEnvelope,
        result: LLMEventSubmissionResult,
    ) -> Result<(), RuntimeStateError> {
        if self
            .repository
            .host_session(event.session_handle())?
            .is_some()
        {
            self.repository.apply_event_transactionally(event, result)?;
        }
        Ok(())
    }

    fn process_tool_batch(&self, terminal: &LLMEventEnvelope) -> Result<(), RuntimeStateError> {
        let Some(tools) = &self.tools else {
            return Ok(());
        };
        let mut worker = self
            .repository
            .host_worker(terminal.run_id())?
            .ok_or_else(|| {
                RuntimeStateError::new("llm.turn.worker_missing", "host worker is missing")
            })?;
        if worker.execution_phase() != Some(HostExecutionPhase::ExecutingToolBatch) {
            return Ok(());
        }
        let turn_id = terminal.generation_turn_id.as_deref().ok_or_else(|| {
            RuntimeStateError::new("llm.turn.identity_missing", "tool turn identity is missing")
        })?;
        let events = self
            .repository
            .turn_accumulator_events(terminal.session_handle(), turn_id)?;
        let completion = terminal.payload.completion.as_ref().ok_or_else(|| {
            RuntimeStateError::new("llm.turn.completion_missing", "tool completion is missing")
        })?;
        let mut results = worker.tool_results().to_vec();

        for call_id in &completion.ordered_call_ids {
            if results.iter().any(|result| result.call_id == *call_id) {
                continue;
            }
            let event = events
                .iter()
                .find(|event| {
                    event.kind() == LLMEventKind::ToolCallCompleted
                        && event.payload.call_id.as_deref() == Some(call_id)
                })
                .ok_or_else(|| {
                    RuntimeStateError::new(
                        "llm.turn.invalid_tool_batch",
                        "completed tool call is missing",
                    )
                })?;
            let call = ExecutionToolCall {
                call_id: call_id.clone(),
                name: event.payload.name.clone().ok_or_else(|| {
                    RuntimeStateError::new("llm.turn.invalid_tool_batch", "tool name is missing")
                })?,
                arguments_json: event.payload.arguments_json.clone().ok_or_else(|| {
                    RuntimeStateError::new(
                        "llm.turn.invalid_tool_batch",
                        "tool arguments are missing",
                    )
                })?,
            };
            match tools.execute_tool(terminal.run_id(), &call) {
                Ok(ExecutionToolOutcome::Observation(observation)) => {
                    results.push(HostToolResult {
                        call_id: call.call_id,
                        tool_name: call.name,
                        result: serde_json::json!({
                            "model_text": observation.model_text,
                        }),
                        is_error: false,
                        data_classes: vec!["unknown_data".into()],
                        highest_sensitivity: "unknown".into(),
                    });
                    let next = worker
                        .clone()
                        .with_revision(worker.revision() + 1)
                        .with_tool_results(results.clone());
                    worker = self
                        .repository
                        .update_host_worker(worker.revision(), next)?;
                }
                Ok(ExecutionToolOutcome::PendingHostTool { .. })
                | Ok(ExecutionToolOutcome::ApprovalRequired { .. }) => {
                    let next = worker
                        .clone()
                        .with_revision(worker.revision() + 1)
                        .with_execution_phase(Some(HostExecutionPhase::SuspendedForToolApproval))
                        .with_tool_results(results)
                        .with_watchdog(None, None, None);
                    self.repository
                        .update_host_worker(worker.revision(), next)?;
                    return Ok(());
                }
                Err(_) => {
                    self.fail_tool_batch(worker, "llm.tool.execution_failed")?;
                    return Ok(());
                }
            }
        }
        self.enqueue_resume(worker, results)
    }

    fn enqueue_resume(
        &self,
        worker: crate::llm_contracts::HostWorkerRecord,
        results: Vec<HostToolResult>,
    ) -> Result<(), RuntimeStateError> {
        let mut payload = worker.generation_payload().cloned().ok_or_else(|| {
            RuntimeStateError::new(
                "llm.turn.payload_missing",
                "frozen generation payload is missing",
            )
        })?;
        payload.tool_results = results.clone();
        let content_digest = payload.agent_input_digest().map_err(|error| {
            RuntimeStateError::new("llm.turn.payload_invalid", error.to_string())
        })?;
        let prior_disclosure = worker.generation_disclosure().cloned().ok_or_else(|| {
            RuntimeStateError::new(
                "llm.turn.disclosure_missing",
                "frozen generation disclosure is missing",
            )
        })?;
        let disclosure = GenerationDisclosureDocument {
            schema_version: "1".into(),
            generation_turn_id: format!("generation-turn:{content_digest}"),
            content_digest,
            source_revision_digest: payload.source_revisions_digest.clone(),
            data_classes: vec!["unknown_data".into()],
            highest_sensitivity: "unknown".into(),
            safe_display_summary: SafeDisplaySummaryDocument {
                source_kinds: vec!["tool_result".into()],
                added_item_counts: vec![EgressDataClassCountDocument {
                    data_class: "unknown_data".into(),
                    count: results.len().to_string(),
                }],
                approximate_added_size: prior_disclosure
                    .safe_display_summary
                    .approximate_added_size,
                triggering_tool_display_keys: results
                    .iter()
                    .map(|result| result.tool_name.clone())
                    .collect(),
            },
        };
        let command_id = BearerTokenIssuer::system()
            .issue("saga-token:v1")
            .map_err(|error| RuntimeStateError::new("llm.command.id_failed", error.to_string()))?
            .raw()
            .to_string();
        let command = HostCommandEnvelope::resume_generation(
            command_id,
            worker.run_id(),
            worker.session_handle(),
            worker.host_process_epoch(),
            worker.expected_command_sequence(),
            payload.clone(),
            disclosure.clone(),
        )
        .map_err(|error| RuntimeStateError::new("llm.command.resume_invalid", error.to_string()))?;
        let next = worker
            .clone()
            .with_revision(worker.revision() + 1)
            .with_execution_phase(Some(HostExecutionPhase::AwaitingResumeCommandAck))
            .with_generation_turn_id(Some(disclosure.generation_turn_id.clone()))
            .with_generation_request(payload, disclosure)
            .with_tool_results(results)
            .with_watchdog(
                Some(crate::llm_contracts::HostWatchdogKind::ResumeCommandAck),
                Some(command.command_id().to_string()),
                Some(
                    crate::storage::runtime_now_millis()
                        + crate::storage::HOST_LIFECYCLE_TIMEOUT_MILLIS,
                ),
            );
        self.repository
            .transition_and_enqueue(RuntimeTransition::new(worker.revision(), next, command))?;
        Ok(())
    }

    fn fail_tool_batch(
        &self,
        worker: crate::llm_contracts::HostWorkerRecord,
        code: &str,
    ) -> Result<(), RuntimeStateError> {
        let command_id = BearerTokenIssuer::system()
            .issue("saga-token:v1")
            .map_err(|error| RuntimeStateError::new("llm.command.id_failed", error.to_string()))?
            .raw()
            .to_string();
        let command = HostCommandEnvelope::lifecycle(
            command_id,
            worker.run_id(),
            worker.session_handle(),
            worker.host_process_epoch(),
            worker.expected_command_sequence(),
            HostCommandKind::CloseSession,
        )
        .map_err(|error| RuntimeStateError::new("llm.command.close_invalid", error.to_string()))?;
        let next = worker
            .clone()
            .with_revision(worker.revision() + 1)
            .with_execution_phase(None)
            .with_logical_outcome(LogicalRunOutcome::Failed { code: code.into() })
            .with_resource_lifecycle(ResourceLifecycle::AwaitingCloseCommandAck)
            .with_watchdog(
                Some(crate::llm_contracts::HostWatchdogKind::CloseCommandAck),
                Some(command.command_id().to_string()),
                Some(
                    crate::storage::runtime_now_millis()
                        + crate::storage::HOST_LIFECYCLE_TIMEOUT_MILLIS,
                ),
            );
        self.repository
            .transition_and_enqueue(RuntimeTransition::new(worker.revision(), next, command))?;
        Ok(())
    }
}

fn valid_envelope(event: &LLMEventEnvelope) -> bool {
    if !matches!(event.schema_version, 1 | 2)
        || event.event_id.is_empty()
        || event.run_id.is_empty()
        || event.session_handle.is_empty()
        || event.host_process_epoch.is_empty()
        || event.event_sequence == 0
        || event.expected_digest().ok().as_deref() != Some(event.event_envelope_digest())
        || event
            .payload
            .validate_for(event.kind, &event.run_id, None)
            .is_err()
    {
        return false;
    }
    match event.kind {
        LLMEventKind::SessionClosed => {
            event.generation_turn_id.is_none()
                && event
                    .payload
                    .command_id
                    .as_deref()
                    .is_some_and(|value| !value.is_empty())
                && matches!(
                    event.payload.close_disposition.as_deref(),
                    Some("closed" | "already_closed")
                )
        }
        LLMEventKind::Cancelled => {
            event
                .payload
                .command_id
                .as_deref()
                .is_some_and(|value| !value.is_empty())
                && event
                    .generation_turn_id
                    .as_deref()
                    .is_some_and(|value| !value.is_empty())
        }
        _ => event
            .generation_turn_id
            .as_deref()
            .is_some_and(|value| !value.is_empty()),
    }
}

fn lifecycle_result(
    event: &LLMEventEnvelope,
    worker: &crate::llm_contracts::HostWorkerRecord,
) -> LLMEventSubmissionResult {
    if event.kind == LLMEventKind::SessionClosed {
        if event.payload.command_id.as_deref() != worker.watchdog_command_id() {
            return LLMEventSubmissionResult::IdentityConflict;
        }
        return if matches!(
            worker.resource_lifecycle(),
            ResourceLifecycle::AwaitingSessionClosed
        ) {
            LLMEventSubmissionResult::Accepted
        } else {
            LLMEventSubmissionResult::GenerationTerminal
        };
    }
    if worker.generation_turn_id() != event.generation_turn_id.as_deref() {
        return LLMEventSubmissionResult::IdentityConflict;
    }
    if !matches!(worker.logical_outcome(), LogicalRunOutcome::Pending) {
        return LLMEventSubmissionResult::GenerationTerminal;
    }
    if event.kind == LLMEventKind::Cancelled
        && (!matches!(
            worker.resource_lifecycle(),
            ResourceLifecycle::AwaitingCancelledTerminal
        ) || event.payload.command_id.as_deref() != worker.watchdog_command_id())
    {
        return LLMEventSubmissionResult::IdentityConflict;
    }
    match worker.execution_phase() {
        Some(HostExecutionPhase::AwaitingGenerationStarted)
            if matches!(
                event.kind,
                LLMEventKind::GenerationStarted | LLMEventKind::Failed | LLMEventKind::Cancelled
            ) =>
        {
            LLMEventSubmissionResult::Accepted
        }
        Some(HostExecutionPhase::ConsumingLlmTurn) => LLMEventSubmissionResult::Accepted,
        Some(HostExecutionPhase::ExecutingToolBatch)
            if matches!(
                event.kind,
                LLMEventKind::ToolBatchStarted
                    | LLMEventKind::ToolBatchCompleted
                    | LLMEventKind::ToolBatchFailed
            ) =>
        {
            LLMEventSubmissionResult::Accepted
        }
        _ => LLMEventSubmissionResult::TurnTerminal,
    }
}
