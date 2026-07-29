use std::collections::{BTreeSet, HashMap};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use serde_json::{json, Value};

use crate::agent_loop::{
    AgentLoopError, AssistantTurn, ModelEvent, ModelEventSink, ModelMessage, ModelRequest,
    ModelRuntime,
};
use crate::llm_contracts::{
    BearerTokenIssuer, EgressDataClassCountDocument, GenerationDisclosureDocument,
    HostAttachmentReference, HostCommandEnvelope, HostCommandKind, HostExecutionPhase,
    HostModelMessage, HostModelRequest, HostToolDefinition, HostWatchdogKind, LLMEventEnvelope,
    LLMEventKind, LogicalRunOutcome, ModelRequestPurpose as HostModelRequestPurpose,
    ResourceLifecycle, SafeDisplaySummaryDocument,
};
use crate::storage::{
    runtime_now_millis, HostCommandOutboxStatus, RuntimeStateError, RuntimeTransition,
    UnifiedRuntimeStateRepository, HOST_LIFECYCLE_TIMEOUT_MILLIS,
};
use crate::tool::AgentToolCall;

const DEFAULT_POLL_INTERVAL: Duration = Duration::from_millis(10);
const EMPTY_SHA256: &str = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

pub struct HostModelRuntime<R: UnifiedRuntimeStateRepository + ?Sized> {
    repository: Arc<R>,
    poll_interval: Duration,
    active_commands: Arc<Mutex<HashMap<String, String>>>,
}

impl<R: UnifiedRuntimeStateRepository + ?Sized> HostModelRuntime<R> {
    pub fn new(repository: Arc<R>) -> Self {
        Self {
            repository,
            poll_interval: DEFAULT_POLL_INTERVAL,
            active_commands: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    pub fn with_poll_interval(mut self, interval: Duration) -> Self {
        self.poll_interval = interval;
        self
    }

    fn generate_inner(
        &self,
        request: ModelRequest,
        sink: &mut dyn ModelEventSink,
    ) -> Result<AssistantTurn, AgentLoopError> {
        let worker = required_worker(self.repository.as_ref(), &request.run_id)?;
        ensure_pending(&worker)?;
        let payload =
            crate::llm_contracts::HostCommandPayload::generation_v2(host_model_request(request));
        let payload_digest = payload
            .expected_digest()
            .map_err(|error| adapter_error(error.code(), error.to_string()))?;
        let turn_id = format!(
            "generation-turn:{}:{}",
            worker.run_id(),
            worker.expected_command_sequence()
        );
        let disclosure = disclosure(turn_id.clone(), payload_digest);
        let command_id = command_id()?;
        let command =
            if worker.expected_command_sequence() == 1 && worker.generation_turn_id().is_none() {
                HostCommandEnvelope::start_generation(
                    &command_id,
                    worker.run_id(),
                    worker.session_handle(),
                    worker.host_process_epoch(),
                    payload.clone(),
                    disclosure.clone(),
                )
            } else {
                HostCommandEnvelope::resume_generation(
                    &command_id,
                    worker.run_id(),
                    worker.session_handle(),
                    worker.host_process_epoch(),
                    worker.expected_command_sequence(),
                    payload.clone(),
                    disclosure.clone(),
                )
            }
            .map_err(|error| adapter_error(error.code(), error.to_string()))?;
        let phase = if command.kind() == HostCommandKind::StartGeneration {
            HostExecutionPhase::AwaitingStartCommandAck
        } else {
            HostExecutionPhase::AwaitingResumeCommandAck
        };
        let watchdog = if command.kind() == HostCommandKind::StartGeneration {
            HostWatchdogKind::StartCommandAck
        } else {
            HostWatchdogKind::ResumeCommandAck
        };
        let next = worker
            .clone()
            .with_revision(worker.revision() + 1)
            .with_execution_phase(Some(phase))
            .with_generation_turn_id(Some(turn_id.clone()))
            .with_generation_request(payload, disclosure)
            .with_tool_results(Vec::new())
            .with_watchdog(
                Some(watchdog),
                Some(command_id.clone()),
                Some(runtime_now_millis() + HOST_LIFECYCLE_TIMEOUT_MILLIS),
            );
        self.repository
            .transition_and_enqueue(RuntimeTransition::new(worker.revision(), next, command))
            .map_err(runtime_error)?;
        self.active_commands
            .lock()
            .map_err(|_| lock_error())?
            .insert(worker.run_id().to_string(), command_id);

        let result = self.wait_for_turn(&worker, &turn_id, sink);
        self.active_commands
            .lock()
            .map_err(|_| lock_error())?
            .remove(worker.run_id());
        result
    }

    fn wait_for_turn(
        &self,
        worker: &crate::llm_contracts::HostWorkerRecord,
        turn_id: &str,
        sink: &mut dyn ModelEventSink,
    ) -> Result<AssistantTurn, AgentLoopError> {
        let mut seen = BTreeSet::new();
        let mut text = String::new();
        let mut reasoning = String::new();
        let mut tool_calls = Vec::new();
        let mut usage = None;

        loop {
            let mut events = self
                .repository
                .turn_accumulator_events(worker.session_handle(), turn_id)
                .map_err(runtime_error)?;
            events.sort_by_key(|event| event.event_sequence());
            for event in events {
                if !seen.insert(event.event_sequence()) {
                    continue;
                }
                let terminal = match event.kind() {
                    LLMEventKind::TextDelta => {
                        let value = event.payload.text.clone().unwrap_or_default();
                        text.push_str(&value);
                        sink.emit(ModelEvent::TextDelta { text: value })?;
                        None
                    }
                    LLMEventKind::ReasoningSummaryDelta => {
                        let value = event.payload.text.clone().unwrap_or_default();
                        reasoning.push_str(&value);
                        sink.emit(ModelEvent::ReasoningDelta { text: value })?;
                        None
                    }
                    LLMEventKind::ToolCallArgumentsDelta => {
                        sink.emit(ModelEvent::ToolCallDelta {
                            call_id: event.payload.call_id.clone().unwrap_or_default(),
                            tool_name: event.payload.name.clone().unwrap_or_default(),
                            arguments_fragment: event
                                .payload
                                .arguments_json
                                .clone()
                                .unwrap_or_default(),
                        })?;
                        None
                    }
                    LLMEventKind::ToolCallCompleted => {
                        tool_calls.push(AgentToolCall {
                            call_id: required(&event.payload.call_id, "call_id")?,
                            tool_name: required(&event.payload.name, "tool_name")?,
                            arguments_json: required(
                                &event.payload.arguments_json,
                                "arguments_json",
                            )?,
                        });
                        None
                    }
                    LLMEventKind::UsageUpdated => {
                        let value = usage_value(&event);
                        sink.emit(ModelEvent::Usage {
                            payload: value.clone(),
                        })?;
                        usage = Some(value);
                        None
                    }
                    LLMEventKind::GenerationCompleted => Some(Ok(AssistantTurn {
                        text: text.clone(),
                        reasoning: reasoning.clone(),
                        tool_calls: tool_calls.clone(),
                        usage: usage.clone(),
                    })),
                    LLMEventKind::Failed => Some(Err(adapter_error(
                        event
                            .payload
                            .failure_code
                            .as_deref()
                            .unwrap_or("llm.generation_failed"),
                        "model generation failed",
                    ))),
                    LLMEventKind::Cancelled => Some(Err(AgentLoopError::cancelled())),
                    _ => None,
                };
                self.repository
                    .acknowledge_inbound_event_projection(&event)
                    .map_err(runtime_error)?;
                if let Some(result) = terminal {
                    return result;
                }
            }
            if let Some(current) = self
                .repository
                .host_worker(worker.run_id())
                .map_err(runtime_error)?
            {
                match current.logical_outcome() {
                    LogicalRunOutcome::Failed { code }
                    | LogicalRunOutcome::Interrupted { code } => {
                        return Err(adapter_error(code, "host model runtime failed"))
                    }
                    LogicalRunOutcome::Cancelled => return Err(AgentLoopError::cancelled()),
                    _ => {}
                }
            }
            thread::sleep(self.poll_interval);
        }
    }

    fn enqueue_lifecycle(&self, run_id: &str, kind: HostCommandKind) -> Result<(), AgentLoopError> {
        let worker = required_worker(self.repository.as_ref(), run_id)?;
        if kind == HostCommandKind::CloseSession
            && matches!(
                worker.resource_lifecycle(),
                ResourceLifecycle::AwaitingCloseCommandAck
                    | ResourceLifecycle::AwaitingSessionClosed
                    | ResourceLifecycle::Closed { .. }
                    | ResourceLifecycle::Quarantined { .. }
            )
        {
            return Ok(());
        }
        if let Some(active) = self
            .active_commands
            .lock()
            .map_err(|_| lock_error())?
            .get(run_id)
            .cloned()
        {
            wait_for_ack(self.repository.as_ref(), &active, self.poll_interval)?;
        }
        let command_id = command_id()?;
        let command = HostCommandEnvelope::command_v2(
            &command_id,
            worker.run_id(),
            worker.session_handle(),
            worker.host_process_epoch(),
            worker.expected_command_sequence(),
            kind,
            crate::llm_contracts::HostCommandPayload::lifecycle_v2(),
        )
        .map_err(|error| adapter_error(error.code(), error.to_string()))?;
        let (lifecycle, watchdog) = if kind == HostCommandKind::CancelGeneration {
            (
                ResourceLifecycle::AwaitingCancelCommandAck,
                HostWatchdogKind::CancelCommandAck,
            )
        } else {
            (
                ResourceLifecycle::AwaitingCloseCommandAck,
                HostWatchdogKind::CloseCommandAck,
            )
        };
        let next = worker
            .clone()
            .with_revision(worker.revision() + 1)
            .with_resource_lifecycle(lifecycle)
            .with_watchdog(
                Some(watchdog),
                Some(command_id),
                Some(runtime_now_millis() + HOST_LIFECYCLE_TIMEOUT_MILLIS),
            );
        self.repository
            .transition_and_enqueue(RuntimeTransition::new(worker.revision(), next, command))
            .map_err(runtime_error)?;
        Ok(())
    }
}

impl<R: UnifiedRuntimeStateRepository + ?Sized> ModelRuntime for HostModelRuntime<R> {
    fn generate(
        &self,
        request: ModelRequest,
        sink: &mut dyn ModelEventSink,
    ) -> Result<AssistantTurn, AgentLoopError> {
        self.generate_inner(request, sink)
    }

    fn cancel(&self, run_id: &str) -> Result<(), AgentLoopError> {
        self.enqueue_lifecycle(run_id, HostCommandKind::CancelGeneration)
    }

    fn close(&self, run_id: &str) -> Result<(), AgentLoopError> {
        self.enqueue_lifecycle(run_id, HostCommandKind::CloseSession)
    }
}

pub(crate) fn wait_for_ack<R: UnifiedRuntimeStateRepository + ?Sized>(
    repository: &R,
    command_id: &str,
    poll_interval: Duration,
) -> Result<(), AgentLoopError> {
    loop {
        let row = repository
            .host_command(command_id)
            .map_err(runtime_error)?
            .ok_or_else(|| adapter_error("host_adapter.command_missing", "command is missing"))?;
        match row.status() {
            HostCommandOutboxStatus::Accepted => return Ok(()),
            HostCommandOutboxStatus::Rejected
            | HostCommandOutboxStatus::Cancelled
            | HostCommandOutboxStatus::TimedOut => {
                return Err(adapter_error(
                    row.acknowledgement()
                        .and_then(|value| value.rejection_code())
                        .unwrap_or("host_adapter.command_rejected"),
                    "host rejected command",
                ))
            }
            HostCommandOutboxStatus::PendingCopy | HostCommandOutboxStatus::Copied => {
                thread::sleep(poll_interval)
            }
        }
    }
}

pub(crate) fn required_worker<R: UnifiedRuntimeStateRepository + ?Sized>(
    repository: &R,
    run_id: &str,
) -> Result<crate::llm_contracts::HostWorkerRecord, AgentLoopError> {
    repository
        .host_worker(run_id)
        .map_err(runtime_error)?
        .ok_or_else(|| adapter_error("host_adapter.run_missing", "host worker is missing"))
}

pub(crate) fn command_id() -> Result<String, AgentLoopError> {
    BearerTokenIssuer::system()
        .issue("saga-token:v1")
        .map(|value| value.raw().to_string())
        .map_err(|error| adapter_error(error.code(), error.to_string()))
}

pub(crate) fn runtime_error(error: RuntimeStateError) -> AgentLoopError {
    adapter_error(error.code(), error.to_string())
}

pub(crate) fn adapter_error(code: impl Into<String>, message: impl Into<String>) -> AgentLoopError {
    AgentLoopError::new(code, message)
}

fn lock_error() -> AgentLoopError {
    adapter_error(
        "host_adapter.lock_poisoned",
        "host adapter lock was poisoned",
    )
}

fn ensure_pending(worker: &crate::llm_contracts::HostWorkerRecord) -> Result<(), AgentLoopError> {
    if matches!(worker.logical_outcome(), LogicalRunOutcome::Pending) {
        Ok(())
    } else {
        Err(adapter_error(
            "host_adapter.run_terminal",
            "host worker is already terminal",
        ))
    }
}

fn host_model_request(request: ModelRequest) -> HostModelRequest {
    HostModelRequest {
        run_id: request.run_id,
        conversation_stream_id: request.conversation_stream_id,
        system_prompt: request.system_prompt,
        ordered_messages: request
            .ordered_messages
            .into_iter()
            .map(|ModelMessage { role, content }| HostModelMessage { role, content })
            .collect(),
        attachment_references: request
            .attachment_references
            .into_iter()
            .map(|value| HostAttachmentReference {
                attachment_id: value.attachment_id,
                display_name: value.display_name,
                media_type: value.media_type,
                modality: value.modality,
                content_digest: value.content_digest,
            })
            .collect(),
        ordered_tool_definitions: request
            .ordered_tool_definitions
            .into_iter()
            .map(|value| HostToolDefinition {
                name: value.name,
                description: value.description,
                input_schema: value.input_schema,
            })
            .collect(),
        ordered_tool_results: request
            .ordered_tool_results
            .into_iter()
            .map(|value| crate::llm_contracts::HostToolResult {
                call_id: value.call_id,
                tool_name: value.tool_name,
                result: value.result,
                is_error: value.is_error,
                data_classes: value.data_classes,
                highest_sensitivity: value.highest_sensitivity,
            })
            .collect(),
        purpose: match request.purpose {
            crate::agent_loop::ModelRequestPurpose::Generation => {
                HostModelRequestPurpose::Generation
            }
            crate::agent_loop::ModelRequestPurpose::Compaction => {
                HostModelRequestPurpose::Compaction
            }
        },
    }
}

fn disclosure(generation_turn_id: String, content_digest: String) -> GenerationDisclosureDocument {
    GenerationDisclosureDocument {
        schema_version: "1".into(),
        generation_turn_id,
        content_digest,
        source_revision_digest: EMPTY_SHA256.into(),
        data_classes: vec!["text".into()],
        highest_sensitivity: "private".into(),
        safe_display_summary: SafeDisplaySummaryDocument {
            source_kinds: vec!["agent_configuration".into(), "conversation".into()],
            added_item_counts: vec![EgressDataClassCountDocument {
                data_class: "text".into(),
                count: "1".into(),
            }],
            approximate_added_size: "1_to_100_kib".into(),
            triggering_tool_display_keys: Vec::new(),
        },
    }
}

fn required(value: &Option<String>, field: &str) -> Result<String, AgentLoopError> {
    value.clone().ok_or_else(|| {
        adapter_error(
            "host_adapter.event_payload_invalid",
            format!("model event is missing {field}"),
        )
    })
}

fn usage_value(event: &LLMEventEnvelope) -> Value {
    json!({
        "input_tokens": event.payload.input_tokens,
        "output_tokens": event.payload.output_tokens,
    })
}
