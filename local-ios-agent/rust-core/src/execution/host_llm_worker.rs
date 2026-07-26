use std::sync::Arc;

use crate::llm_contracts::{
    HostExecutionPhase, LLMEventEnvelope, LLMEventKind, LLMEventSubmissionResult,
    LogicalRunOutcome, ResourceLifecycle,
};
use crate::storage::{
    EventQueueUsage, RuntimeStateError, UnifiedRuntimeStateRepository, HOST_EVENT_LOW_WATER_BYTES,
    HOST_EVENT_LOW_WATER_EVENTS, HOST_EVENT_MAX_BYTES, HOST_EVENT_MAX_EVENTS,
};

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
}

impl<R: UnifiedRuntimeStateRepository + ?Sized> HostLLMWorkerService<R> {
    pub fn new(repository: Arc<R>) -> Self {
        Self {
            repository,
            config: HostLLMWorkerServiceConfig::default(),
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
            return Ok(LLMEventSubmissionResult::Backpressure);
        }

        self.repository
            .apply_event_transactionally(event, LLMEventSubmissionResult::Accepted)?;
        Ok(LLMEventSubmissionResult::Accepted)
    }

    pub fn drain_inbound_events(
        &self,
        maximum: usize,
    ) -> Result<Vec<LLMEventEnvelope>, RuntimeStateError> {
        self.repository.drain_inbound_events(maximum)
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
}

fn valid_envelope(event: &LLMEventEnvelope) -> bool {
    if event.schema_version != 1
        || event.event_id.is_empty()
        || event.run_id.is_empty()
        || event.session_handle.is_empty()
        || event.host_process_epoch.is_empty()
        || event.event_sequence == 0
        || event.expected_digest().ok().as_deref() != Some(event.event_envelope_digest())
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
        _ => LLMEventSubmissionResult::TurnTerminal,
    }
}
