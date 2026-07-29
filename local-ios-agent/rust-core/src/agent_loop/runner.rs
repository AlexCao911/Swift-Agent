use std::collections::{BTreeSet, HashMap};
use std::sync::{Arc, Mutex};

use serde_json::{json, Value};

use crate::agent_input::{AgentInputAssembler, ToolDefinitionSnapshot};
use crate::context::{
    approximate_token_count, compact_tool_results_for_context, AgentTurnInput, BranchProjector,
    CompactionCandidate, ContextCompactionCheckpoint, ContextWindowPolicy, ModelInputRole,
    PromptMessage,
};
use crate::conversation::{ActiveRunRegistry, ProjectionSubscriptionRegistry, TranscriptCommand};
use crate::core::{EntryId, EventKind, RunId, RuntimeEvent, SessionId};
use crate::memory::{CompletedTurnMemoryInput, MemoryProvider};
use crate::storage::ConversationEventStore;
use crate::tool::{AgentToolCall, ToolBatch, ToolBatchResult};

use super::{
    AgentLoopError, AgentLoopOutcome, AgentRunRequest, AssistantTurn, ModelEventSink, ModelMessage,
    ModelRequest, ModelRequestPurpose, ModelRuntime, RunCancellationRecord, ToolRuntime,
};

pub const MAX_MODEL_TURNS: usize = 200;

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
        let cancellation = self.begin_run(&request)?;
        self.run_registered(request, cancellation, sink)
    }

    pub fn spawn(&self, request: AgentRunRequest) -> Result<(), AgentLoopError> {
        let cancellation = self.begin_run(&request)?;
        let service = self.clone();
        std::thread::spawn(move || {
            let mut sink = DiscardingModelEventSink;
            let _ = service.run_registered(request, cancellation, &mut sink);
        });
        Ok(())
    }

    fn begin_run(
        &self,
        request: &AgentRunRequest,
    ) -> Result<Arc<RunCancellationRecord>, AgentLoopError> {
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
        Ok(cancellation)
    }

    fn run_registered(
        &self,
        request: AgentRunRequest,
        cancellation: Arc<RunCancellationRecord>,
        sink: &mut dyn ModelEventSink,
    ) -> Result<AgentLoopOutcome, AgentLoopError> {
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
        let mut input_assembler = AgentInputAssembler::for_run(request.run_start_snapshot.clone())
            .map_err(input_error)?;
        if let Some(provider) = &self.memory_provider {
            input_assembler = input_assembler.with_memory_provider(provider.clone());
        }
        let context_policy =
            ContextWindowPolicy::for_model(request.run_start_snapshot.model_context_window)
                .map_err(input_error)?;
        let mut completed_tool_results = Vec::new();
        let mut pending_tool_results = Vec::new();

        for model_turn in 0..MAX_MODEL_TURNS {
            cancellation.check()?;
            let mut branch = self.current_branch(&request.conversation_stream_id)?;
            let mut input = input_assembler
                .assemble_turn(&request.conversation_stream_id, branch.clone())
                .map_err(input_error)?;
            let mut generation_request =
                model_request(request, &input, pending_tool_results.clone());
            if estimated_model_request_tokens(&generation_request)
                >= context_policy.auto_compact_threshold_tokens()
            {
                branch = self.current_branch(&request.conversation_stream_id)?;
                if let Some(checkpoint) = compaction_checkpoint(&branch) {
                    cancellation.check()?;
                    let summary_turn = self.model.generate(
                        compaction_model_request(
                            request,
                            &branch,
                            &context_policy,
                            pending_tool_results.clone(),
                        ),
                        &mut DiscardingModelEventSink,
                    )?;
                    pending_tool_results.clear();
                    cancellation.check()?;
                    if summary_turn.text.trim().is_empty() || !summary_turn.tool_calls.is_empty() {
                        return Err(AgentLoopError::new(
                            "agent_loop.context_compaction_invalid",
                            "context compaction must return summary text without tool calls",
                        ));
                    }
                    cancellation.commit_if_active(|| {
                        self.commit_context_summary(
                            request,
                            ContextCompactionCheckpoint {
                                summary: summary_turn.text,
                                ..checkpoint
                            },
                        )
                    })?;
                    branch = self.current_branch(&request.conversation_stream_id)?;
                    input = input_assembler
                        .assemble_turn(&request.conversation_stream_id, branch)
                        .map_err(input_error)?;
                    generation_request = model_request(request, &input, Vec::new());
                }
            }
            let turn = self.model.generate(generation_request, sink)?;
            pending_tool_results.clear();
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
            pending_tool_results = result.ordered_results.clone();
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

    fn commit_context_summary(
        &self,
        request: &AgentRunRequest,
        checkpoint: ContextCompactionCheckpoint,
    ) -> Result<(), AgentLoopError> {
        self.commit_status_event(
            request,
            format!(
                "agent-{}-context-summary-{}",
                request.run_id, checkpoint.covered_through_sequence
            ),
            EventKind::BranchSummaryCreated,
            &serde_json::to_string(&checkpoint).map_err(serialization_error)?,
        )
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
    agent_run_request(
        &command,
        event
            .run_id
            .as_ref()
            .map(|run_id| run_id.0.clone())
            .ok_or_else(|| {
                AgentLoopError::new(
                    "agent_loop.recovery_payload_invalid",
                    "run command has no run identifier",
                )
            })?,
    )
}

pub(crate) fn agent_run_request(
    command: &TranscriptCommand,
    run_id: String,
) -> Result<AgentRunRequest, AgentLoopError> {
    let run_start_snapshot = command.run_start_snapshot().cloned().ok_or_else(|| {
        AgentLoopError::new(
            "agent_loop.recovery_payload_invalid",
            "run-start snapshot is missing",
        )
    })?;
    run_start_snapshot.validate().map_err(input_error)?;
    let attachment_references = match command {
        TranscriptCommand::Send { attachments, .. } => attachments.clone(),
        TranscriptCommand::EditMessage {
            replacement_attachments,
            ..
        } => replacement_attachments.clone(),
        TranscriptCommand::RetryFrom { .. } => Vec::new(),
        _ => {
            return Err(AgentLoopError::new(
                "agent_loop.recovery_payload_invalid",
                "event does not contain a run-producing command",
            ));
        }
    };
    Ok(AgentRunRequest {
        run_id,
        conversation_stream_id: command.conversation_stream_id().to_string(),
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

fn model_request(
    request: &AgentRunRequest,
    input: &AgentTurnInput,
    ordered_tool_results: Vec<crate::tool::ToolCallResult>,
) -> ModelRequest {
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
        ordered_tool_results,
        purpose: ModelRequestPurpose::Generation,
    }
}

fn estimated_model_request_tokens(request: &ModelRequest) -> usize {
    let messages = request
        .ordered_messages
        .iter()
        .map(|message| approximate_token_count(&message.content.to_string()))
        .sum::<usize>();
    let tools = request
        .ordered_tool_definitions
        .iter()
        .map(|tool| {
            approximate_token_count(&tool.name)
                + approximate_token_count(&tool.description)
                + approximate_token_count(&tool.input_schema.to_string())
        })
        .sum::<usize>();
    approximate_token_count(&request.system_prompt)
        .saturating_add(messages)
        .saturating_add(tools)
}

fn compaction_checkpoint(branch: &[RuntimeEvent]) -> Option<ContextCompactionCheckpoint> {
    let covered_through_sequence = branch.last()?.sequence;
    let latest_model_content_sequence = branch
        .iter()
        .filter(|event| {
            is_model_visible_event(event) && event.kind != EventKind::BranchSummaryCreated
        })
        .map(|event| event.sequence)
        .max()
        .unwrap_or(0);
    if branch
        .iter()
        .rev()
        .find_map(|event| {
            (event.kind == EventKind::BranchSummaryCreated)
                .then(|| serde_json::from_str::<ContextCompactionCheckpoint>(&event.payload).ok())
                .flatten()
        })
        .is_some_and(|checkpoint| {
            checkpoint.covered_through_sequence >= latest_model_content_sequence
        })
    {
        return None;
    }
    let preserved_event_ids = preserved_context_event_ids(branch);
    let compressible_count = branch
        .iter()
        .filter(|event| {
            is_model_visible_event(event) && !preserved_event_ids.iter().any(|id| id == &event.id.0)
        })
        .count();
    (compressible_count > 0).then(|| ContextCompactionCheckpoint {
        summary: String::new(),
        covered_through_sequence,
        preserved_event_ids,
    })
}

fn compaction_model_request(
    request: &AgentRunRequest,
    branch: &[RuntimeEvent],
    policy: &ContextWindowPolicy,
    ordered_tool_results: Vec<crate::tool::ToolCallResult>,
) -> ModelRequest {
    let system_prompt = concat!(
        "Compact the conversation for continued agent work. Preserve user intent, ",
        "decisions, constraints, unresolved work, important file paths, and tool findings. ",
        "Return only the compact summary."
    );
    let messages = compact_tool_results_for_context(
        BranchProjector::new().project(branch.to_vec()),
        policy.model_input_limit_tokens(),
    )
    .into_iter()
    .map(|message| format!("{}: {}", prompt_message_role(&message), message.content()))
    .collect::<Vec<_>>();
    let content_budget = policy
        .model_input_limit_tokens()
        .saturating_sub(approximate_token_count(system_prompt));
    ModelRequest {
        run_id: request.run_id.clone(),
        conversation_stream_id: request.conversation_stream_id.clone(),
        system_prompt: system_prompt.into(),
        ordered_messages: vec![ModelMessage {
            role: "user".into(),
            content: Value::String(
                CompactionCandidate::new(messages).bounded_summary_text(content_budget),
            ),
        }],
        attachment_references: Vec::new(),
        ordered_tool_definitions: Vec::new(),
        ordered_tool_results,
        purpose: ModelRequestPurpose::Compaction,
    }
}

fn preserved_context_event_ids(branch: &[RuntimeEvent]) -> Vec<String> {
    let mut preserved = BTreeSet::new();
    if let Some(event) = branch
        .iter()
        .rev()
        .find(|event| event.kind == EventKind::UserMessage)
    {
        preserved.insert(event.id.0.clone());
    }

    if let Some(last_result_index) = branch
        .iter()
        .rposition(|event| event.kind == EventKind::ToolResultMessage)
    {
        let mut first_result_index = last_result_index;
        while first_result_index > 0
            && branch[first_result_index - 1].kind == EventKind::ToolResultMessage
        {
            first_result_index -= 1;
        }
        let mut first_call_index = first_result_index;
        while first_call_index > 0
            && branch[first_call_index - 1].kind == EventKind::ToolCallRequested
        {
            first_call_index -= 1;
        }
        for event in &branch[first_call_index..=last_result_index] {
            preserved.insert(event.id.0.clone());
        }
    }
    preserved.into_iter().collect()
}

fn is_model_visible_event(event: &RuntimeEvent) -> bool {
    matches!(
        event.kind,
        EventKind::UserMessage
            | EventKind::AssistantMessageCompleted
            | EventKind::ToolCallRequested
            | EventKind::ToolResultMessage
            | EventKind::BranchSummaryCreated
    )
}

fn prompt_message_role(message: &PromptMessage) -> &'static str {
    match message {
        PromptMessage::User(_) | PromptMessage::UserWithBlobRefs { .. } => "user",
        PromptMessage::Assistant(_) => "assistant",
        PromptMessage::ToolResult(_) => "tool",
        PromptMessage::Summary(_) => "summary",
    }
}

struct DiscardingModelEventSink;

impl ModelEventSink for DiscardingModelEventSink {
    fn emit(&mut self, _event: super::ModelEvent) -> Result<(), AgentLoopError> {
        Ok(())
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
