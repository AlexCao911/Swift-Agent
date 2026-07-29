use std::collections::{BTreeSet, HashMap};
use std::sync::{Arc, Mutex};

use serde_json::{json, Value};

use crate::agent_input::{AgentInputAssembler, ToolDefinitionSnapshot};
use crate::context::{AgentTurnInput, ModelInputRole};
use crate::conversation::{ActiveRunRegistry, ProjectionSubscriptionRegistry, TranscriptCommand};
use crate::core::{EntryId, EventKind, RunId, RuntimeEvent, SessionId};
use crate::memory::{CompletedTurnMemoryInput, MemoryProvider};
use crate::storage::ConversationEventStore;
use crate::tool::{AgentToolCall, ToolBatch, ToolBatchResult};

use super::{
    AgentLoopError, AgentLoopOutcome, AgentRunRequest, AssistantTurn, ModelEventSink, ModelMessage,
    ModelRequest, ModelRuntime, RunCancellationRecord, ToolRuntime,
};

pub const MAX_MODEL_TURNS: usize = 200;
const DEFAULT_CONTEXT_BUDGET_TOKENS: usize = 32_000;

pub struct AgentLoopService<S: ConversationEventStore> {
    store: Arc<Mutex<S>>,
    model: Arc<dyn ModelRuntime>,
    tools: Arc<dyn ToolRuntime>,
    active_runs: ActiveRunRegistry,
    projections: ProjectionSubscriptionRegistry,
    cancellations: Arc<Mutex<HashMap<String, Arc<RunCancellationRecord>>>>,
    memory_provider: Option<Arc<dyn MemoryProvider>>,
}

impl<S: ConversationEventStore> Clone for AgentLoopService<S> {
    fn clone(&self) -> Self {
        Self {
            store: self.store.clone(),
            model: self.model.clone(),
            tools: self.tools.clone(),
            active_runs: self.active_runs.clone(),
            projections: self.projections.clone(),
            cancellations: self.cancellations.clone(),
            memory_provider: self.memory_provider.clone(),
        }
    }
}

impl<S> AgentLoopService<S>
where
    S: ConversationEventStore + Send + 'static,
{
    pub fn new(
        store: Arc<Mutex<S>>,
        model: Arc<dyn ModelRuntime>,
        tools: Arc<dyn ToolRuntime>,
        active_runs: ActiveRunRegistry,
        projections: ProjectionSubscriptionRegistry,
    ) -> Self {
        Self {
            store,
            model,
            tools,
            active_runs,
            projections,
            cancellations: Arc::new(Mutex::new(HashMap::new())),
            memory_provider: None,
        }
    }

    pub fn with_memory_provider(mut self, provider: Arc<dyn MemoryProvider>) -> Self {
        self.memory_provider = Some(provider);
        self
    }

    pub fn run(
        &self,
        request: AgentRunRequest,
        sink: &mut dyn ModelEventSink,
    ) -> Result<AgentLoopOutcome, AgentLoopError> {
        if self
            .active_runs
            .active_run(&request.conversation_stream_id)
            .as_deref()
            != Some(request.run_id.as_str())
        {
            return Err(AgentLoopError::new(
                "agent_loop.run_not_active",
                "run does not own the conversation lease",
            ));
        }

        let cancellation = Arc::new(RunCancellationRecord::new(&request.run_id));
        {
            let mut records = self
                .cancellations
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            if records.contains_key(&request.run_id) {
                return Err(AgentLoopError::new(
                    "agent_loop.run_already_started",
                    "run already has an Agent loop",
                ));
            }
            records.insert(request.run_id.clone(), cancellation.clone());
        }

        let result = cancellation
            .commit_if_active(|| self.commit_run_started(&request))
            .and_then(|_| self.run_inner(&request, &cancellation, sink));
        if let Err(error) = &result {
            let kind = if error.code() == "agent_loop.cancelled" {
                EventKind::RunCancelled
            } else {
                EventKind::RunFailed
            };
            let _ = self.commit_run_terminal(&request, kind, error.code());
        }
        let close = self.model.close(&request.run_id);
        self.cancellations
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .remove(&request.run_id);
        let release = self
            .active_runs
            .complete(&request.conversation_stream_id, &request.run_id)
            .map_err(|error| AgentLoopError::new(error.code(), error.to_string()));

        match result {
            Err(error) => Err(error),
            Ok(outcome) => {
                close?;
                release?;
                Ok(outcome)
            }
        }
    }

    pub fn recover_after_process_loss(&self) -> Result<Vec<AgentRunRequest>, AgentLoopError> {
        let session_ids = self
            .store
            .lock()
            .map_err(|_| storage_lock_error())?
            .list_all_sessions()
            .map_err(storage_error)?;
        let mut recovered = Vec::new();

        for session_id in session_ids {
            let events = self
                .store
                .lock()
                .map_err(|_| storage_lock_error())?
                .events_after(&session_id, 0)
                .map_err(storage_error)?;
            let Some(command) = events.iter().rev().find(|event| {
                event.run_id.is_some()
                    && matches!(
                        event.kind,
                        EventKind::UserMessage
                            | EventKind::TranscriptRetryRequested
                            | EventKind::MessageEdited
                    )
            }) else {
                continue;
            };
            let Some(run_id) = command.run_id.as_ref().map(|run_id| run_id.0.clone()) else {
                continue;
            };
            let run_events = events
                .iter()
                .filter(|event| event.run_id.as_ref().map(|id| id.0.as_str()) == Some(&run_id))
                .collect::<Vec<_>>();
            let started = run_events
                .iter()
                .any(|event| event.kind == EventKind::AssistantMessageStarted);
            let terminal = run_events.last().is_some_and(|event| {
                matches!(
                    event.kind,
                    EventKind::AssistantMessageCompleted
                        | EventKind::RunCancelled
                        | EventKind::RunFailed
                )
            });

            if started && !terminal {
                let request = recovered_request(command)?;
                self.commit_run_terminal(
                    &request,
                    EventKind::RunFailed,
                    "agent_loop.process_interrupted",
                )?;
                continue;
            }
            if started || terminal {
                continue;
            }

            let request = recovered_request(command)?;
            if self
                .active_runs
                .start(&request.conversation_stream_id, &request.run_id)
                .is_ok()
            {
                recovered.push(request);
            }
        }
        Ok(recovered)
    }

    pub fn cancel_run(&self, run_id: &str) -> Result<(), AgentLoopError> {
        let record = self
            .cancellations
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .get(run_id)
            .cloned()
            .ok_or_else(|| {
                AgentLoopError::new(
                    "agent_loop.run_not_active",
                    "run has no cancellation record",
                )
            })?;
        let active_batch_id = record.request_cancel();

        match active_batch_id {
            Some(batch_id) => self.tools.cancel_batch(&batch_id),
            None => self.model.cancel(run_id),
        }
    }

    fn run_inner(
        &self,
        request: &AgentRunRequest,
        cancellation: &RunCancellationRecord,
        sink: &mut dyn ModelEventSink,
    ) -> Result<AgentLoopOutcome, AgentLoopError> {
        let mut input_assembler = AgentInputAssembler::new(
            request.run_start_snapshot.clone(),
            DEFAULT_CONTEXT_BUDGET_TOKENS,
        )
        .map_err(input_error)?;
        if let Some(provider) = &self.memory_provider {
            input_assembler = input_assembler.with_memory_provider(provider.clone());
        }
        let mut completed_tool_results = Vec::new();

        for model_turn in 0..MAX_MODEL_TURNS {
            cancellation.check()?;
            let branch = self.current_branch(&request.conversation_stream_id)?;
            let input = input_assembler
                .assemble_turn(&request.conversation_stream_id, branch)
                .map_err(input_error)?;
            let model_request = model_request(request, &input);
            let turn = self.model.generate(model_request, sink)?;
            cancellation.check()?;

            if turn.tool_calls.is_empty() {
                cancellation
                    .commit_if_active(|| self.commit_final_turn(request, model_turn, &turn))?;
                self.remember_completed_turn(request, &turn, completed_tool_results);
                return Ok(AgentLoopOutcome::Completed);
            }

            validate_tool_calls(
                &turn.tool_calls,
                &request.run_start_snapshot.ordered_tool_definitions,
            )?;
            let batch = ToolBatch {
                batch_id: format!("batch-{}-{model_turn}", request.run_id),
                run_id: request.run_id.clone(),
                ordered_calls: turn.tool_calls.clone(),
            };
            cancellation.begin_batch(&batch.batch_id)?;
            if let Err(error) = cancellation.check() {
                cancellation.finish_batch(&batch.batch_id);
                return Err(error);
            }
            let result = self.tools.execute_batch(batch.clone());
            cancellation.finish_batch(&batch.batch_id);
            let result = result?;
            cancellation.check()?;
            validate_batch_result(&batch, &result)?;
            cancellation
                .commit_if_active(|| self.commit_tool_round(request, model_turn, &turn, &result))?;
            completed_tool_results.extend(
                result
                    .ordered_results
                    .iter()
                    .map(|result| result.result.clone()),
            );
        }

        Err(AgentLoopError::max_model_turns(MAX_MODEL_TURNS))
    }

    fn current_branch(
        &self,
        conversation_stream_id: &str,
    ) -> Result<Vec<RuntimeEvent>, AgentLoopError> {
        self.store
            .lock()
            .map_err(|_| storage_lock_error())?
            .events_after(&SessionId(conversation_stream_id.to_string()), 0)
            .map_err(storage_error)
    }

    fn commit_final_turn(
        &self,
        request: &AgentRunRequest,
        model_turn: usize,
        turn: &AssistantTurn,
    ) -> Result<(), AgentLoopError> {
        let mut store = self.store.lock().map_err(|_| storage_lock_error())?;
        let (next_sequence, parent_id, depth) =
            transaction_head(&*store, &request.conversation_stream_id)?;
        let event = RuntimeEvent::new(
            EntryId(format!("agent-{}-turn-{model_turn}-final", request.run_id)),
            SessionId(request.conversation_stream_id.clone()),
            parent_id,
            Some(RunId(request.run_id.clone())),
            0,
            depth,
            EventKind::AssistantMessageCompleted,
            turn.text.clone(),
        );
        store
            .append_transaction(&request.conversation_stream_id, next_sequence, vec![event])
            .map_err(storage_error)?;
        drop(store);
        self.projections.notify(&request.conversation_stream_id);
        Ok(())
    }

    fn commit_run_started(&self, request: &AgentRunRequest) -> Result<(), AgentLoopError> {
        self.commit_status_event(
            request,
            format!("agent-{}-started", request.run_id),
            EventKind::AssistantMessageStarted,
            "",
        )
    }

    fn commit_run_terminal(
        &self,
        request: &AgentRunRequest,
        kind: EventKind,
        code: &str,
    ) -> Result<(), AgentLoopError> {
        self.commit_status_event(
            request,
            format!(
                "agent-{}-{}",
                request.run_id,
                match kind {
                    EventKind::RunCancelled => "cancelled",
                    _ => "failed",
                }
            ),
            kind,
            &json!({ "code": code }).to_string(),
        )
    }

    fn commit_status_event(
        &self,
        request: &AgentRunRequest,
        id: String,
        kind: EventKind,
        payload: &str,
    ) -> Result<(), AgentLoopError> {
        let mut store = self.store.lock().map_err(|_| storage_lock_error())?;
        let (next_sequence, parent_id, depth) =
            transaction_head(&*store, &request.conversation_stream_id)?;
        store
            .append_transaction(
                &request.conversation_stream_id,
                next_sequence,
                vec![RuntimeEvent::new(
                    EntryId(id),
                    SessionId(request.conversation_stream_id.clone()),
                    parent_id,
                    Some(RunId(request.run_id.clone())),
                    0,
                    depth,
                    kind,
                    payload,
                )],
            )
            .map_err(storage_error)?;
        drop(store);
        self.projections.notify(&request.conversation_stream_id);
        Ok(())
    }

    fn commit_tool_round(
        &self,
        request: &AgentRunRequest,
        model_turn: usize,
        turn: &AssistantTurn,
        result: &ToolBatchResult,
    ) -> Result<(), AgentLoopError> {
        let mut store = self.store.lock().map_err(|_| storage_lock_error())?;
        let (next_sequence, mut parent_id, mut depth) =
            transaction_head(&*store, &request.conversation_stream_id)?;
        let mut events = Vec::new();

        if !turn.text.is_empty() {
            push_event(
                &mut events,
                &mut parent_id,
                &mut depth,
                request,
                format!("agent-{}-turn-{model_turn}-text", request.run_id),
                EventKind::AssistantMessageCompleted,
                turn.text.clone(),
            );
        }
        for (index, call) in turn.tool_calls.iter().enumerate() {
            push_event(
                &mut events,
                &mut parent_id,
                &mut depth,
                request,
                format!("agent-{}-turn-{model_turn}-call-{index}", request.run_id),
                EventKind::ToolCallRequested,
                serde_json::to_string(call).map_err(serialization_error)?,
            );
        }
        for (index, tool_result) in result.ordered_results.iter().enumerate() {
            push_event(
                &mut events,
                &mut parent_id,
                &mut depth,
                request,
                format!("agent-{}-turn-{model_turn}-result-{index}", request.run_id),
                EventKind::ToolResultMessage,
                serde_json::to_string(tool_result).map_err(serialization_error)?,
            );
        }

        store
            .append_transaction(&request.conversation_stream_id, next_sequence, events)
            .map_err(storage_error)?;
        drop(store);
        self.projections.notify(&request.conversation_stream_id);
        Ok(())
    }

    fn remember_completed_turn(
        &self,
        request: &AgentRunRequest,
        turn: &AssistantTurn,
        tool_results: Vec<Value>,
    ) {
        let Some(provider) = &self.memory_provider else {
            return;
        };
        let user_text = self
            .current_branch(&request.conversation_stream_id)
            .ok()
            .and_then(|events| {
                events.into_iter().rev().find_map(|event| {
                    (event.kind == EventKind::UserMessage)
                        .then(|| user_text_from_command_payload(&event.payload))
                })
            })
            .unwrap_or_default();
        let _ = provider.remember_completed_turn(&CompletedTurnMemoryInput {
            conversation_stream_id: request.conversation_stream_id.clone(),
            user_text,
            assistant_text: turn.text.clone(),
            tool_results,
        });
    }
}

fn recovered_request(event: &RuntimeEvent) -> Result<AgentRunRequest, AgentLoopError> {
    let payload: Value = serde_json::from_str(&event.payload).map_err(serialization_error)?;
    let command: TranscriptCommand =
        serde_json::from_value(payload.get("command").cloned().ok_or_else(|| {
            AgentLoopError::new(
                "agent_loop.recovery_payload_invalid",
                "run command payload is missing",
            )
        })?)
        .map_err(serialization_error)?;
    if command.conversation_stream_id() != event.session_id.0 {
        return Err(AgentLoopError::new(
            "agent_loop.recovery_payload_invalid",
            "run command stream does not match its event",
        ));
    }
    let run_start_snapshot = command.run_start_snapshot().cloned().ok_or_else(|| {
        AgentLoopError::new(
            "agent_loop.recovery_payload_invalid",
            "run-start snapshot is missing",
        )
    })?;
    run_start_snapshot.validate().map_err(input_error)?;
    let attachment_references = match command {
        TranscriptCommand::Send { attachments, .. } => attachments,
        TranscriptCommand::EditMessage {
            replacement_attachments,
            ..
        } => replacement_attachments,
        TranscriptCommand::RetryFrom { .. } => Vec::new(),
        _ => {
            return Err(AgentLoopError::new(
                "agent_loop.recovery_payload_invalid",
                "event does not contain a run-producing command",
            ));
        }
    };
    Ok(AgentRunRequest {
        run_id: event
            .run_id
            .as_ref()
            .map(|run_id| run_id.0.clone())
            .ok_or_else(|| {
                AgentLoopError::new(
                    "agent_loop.recovery_payload_invalid",
                    "run command has no run identifier",
                )
            })?,
        conversation_stream_id: event.session_id.0.clone(),
        run_start_snapshot,
        attachment_references,
    })
}

fn user_text_from_command_payload(payload: &str) -> String {
    serde_json::from_str::<Value>(payload)
        .ok()
        .and_then(|value| value.get("command").cloned())
        .and_then(|value| serde_json::from_value::<TranscriptCommand>(value).ok())
        .and_then(|command| match command {
            TranscriptCommand::Send { text, .. } => Some(text),
            TranscriptCommand::EditMessage {
                replacement_text, ..
            } => Some(replacement_text),
            _ => None,
        })
        .unwrap_or_else(|| payload.to_string())
}

pub fn validate_tool_calls(
    calls: &[AgentToolCall],
    definitions: &[ToolDefinitionSnapshot],
) -> Result<(), AgentLoopError> {
    let known_tools = definitions
        .iter()
        .map(|definition| definition.name.as_str())
        .collect::<BTreeSet<_>>();
    let mut call_ids = BTreeSet::new();
    for call in calls {
        if call.call_id.trim().is_empty()
            || call.tool_name.trim().is_empty()
            || !call_ids.insert(call.call_id.as_str())
            || !known_tools.contains(call.tool_name.as_str())
            || !serde_json::from_str::<Value>(&call.arguments_json)
                .map(|value| value.is_object())
                .unwrap_or(false)
        {
            return Err(AgentLoopError::new(
                "agent_loop.invalid_tool_call",
                format!("invalid tool call {}", call.call_id),
            ));
        }
    }
    Ok(())
}

pub fn validate_batch_result(
    batch: &ToolBatch,
    result: &ToolBatchResult,
) -> Result<(), AgentLoopError> {
    if result.batch_id != batch.batch_id
        || result.run_id != batch.run_id
        || result.ordered_results.len() != batch.ordered_calls.len()
        || result
            .ordered_results
            .iter()
            .zip(&batch.ordered_calls)
            .any(|(result, call)| {
                result.call_id != call.call_id || result.tool_name != call.tool_name
            })
    {
        return Err(AgentLoopError::new(
            "agent_loop.tool_batch_identity_mismatch",
            "tool batch result did not match the ordered request",
        ));
    }
    Ok(())
}

fn model_request(request: &AgentRunRequest, input: &AgentTurnInput) -> ModelRequest {
    ModelRequest {
        run_id: request.run_id.clone(),
        conversation_stream_id: request.conversation_stream_id.clone(),
        system_prompt: input.system_prompt().to_string(),
        ordered_messages: input
            .ordered_messages()
            .messages()
            .iter()
            .map(|message| ModelMessage {
                role: role_name(message.role()).to_string(),
                content: Value::String(message.content().to_string()),
            })
            .collect(),
        attachment_references: request.attachment_references.clone(),
        ordered_tool_definitions: input.ordered_tool_definitions().to_vec(),
    }
}

fn role_name(role: ModelInputRole) -> &'static str {
    match role {
        ModelInputRole::System => "system",
        ModelInputRole::User => "user",
        ModelInputRole::Assistant => "assistant",
        ModelInputRole::Tool => "tool",
        ModelInputRole::Summary => "summary",
    }
}

fn transaction_head(
    store: &impl ConversationEventStore,
    conversation_stream_id: &str,
) -> Result<(u64, Option<EntryId>, u32), AgentLoopError> {
    let last = store
        .last_event(&SessionId(conversation_stream_id.to_string()))
        .map_err(storage_error)?;
    Ok((
        last.as_ref().map(|event| event.sequence + 1).unwrap_or(1),
        last.as_ref().map(|event| event.id.clone()),
        last.as_ref()
            .map(|event| event.depth.saturating_add(1))
            .unwrap_or(0),
    ))
}

fn push_event(
    events: &mut Vec<RuntimeEvent>,
    parent_id: &mut Option<EntryId>,
    depth: &mut u32,
    request: &AgentRunRequest,
    id: String,
    kind: EventKind,
    payload: String,
) {
    let event_id = EntryId(id);
    events.push(RuntimeEvent::new(
        event_id.clone(),
        SessionId(request.conversation_stream_id.clone()),
        parent_id.clone(),
        Some(RunId(request.run_id.clone())),
        0,
        *depth,
        kind,
        payload,
    ));
    *parent_id = Some(event_id);
    *depth = depth.saturating_add(1);
}

fn input_error(error: impl std::fmt::Display) -> AgentLoopError {
    AgentLoopError::new("agent_loop.input_failed", error.to_string())
}

fn storage_lock_error() -> AgentLoopError {
    AgentLoopError::new(
        "agent_loop.storage_unavailable",
        "conversation store lock poisoned",
    )
}

fn storage_error(error: impl std::fmt::Display) -> AgentLoopError {
    AgentLoopError::new("agent_loop.storage_failed", error.to_string())
}

fn serialization_error(error: serde_json::Error) -> AgentLoopError {
    AgentLoopError::new("agent_loop.serialization_failed", error.to_string())
}
