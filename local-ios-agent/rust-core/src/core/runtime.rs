use std::collections::HashMap;

use crate::context::{ContextController, TokenizerAdapter};
use crate::core::{
    AgentError, AgentTurnResult, EntryId, EventKind, ModelProvider, ModelProviderOutput, RunId,
    RunRecord, RunState, RuntimeEvent, SessionCursor, SessionId, StreamBatcher,
};
use crate::memory::{EventStore, InMemoryEventStore};
use crate::tool::ToolResult;
use crate::utils::id::IdGenerator;

pub struct AgentRuntimeConfig {
    pub system_prompt: String,
    pub runtime_policy: String,
    pub tool_schemas: Vec<String>,
    pub tokenizer: Box<dyn TokenizerAdapter>,
    pub provider: Box<dyn ModelProvider>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SendMessageInput {
    pub session_id: SessionId,
    pub parent_event_id: Option<EntryId>,
    pub text: String,
}

pub struct AgentRuntime<S: EventStore = InMemoryEventStore> {
    config: AgentRuntimeConfig,
    ids: IdGenerator,
    store: S,
    sessions: HashMap<SessionId, SessionCursor>,
    runs: HashMap<RunId, RunRecord>,
}

impl AgentRuntime<InMemoryEventStore> {
    pub fn new(config: AgentRuntimeConfig) -> Self {
        Self::with_store(config, InMemoryEventStore::new())
            .expect("new in-memory runtime should initialize")
    }
}

impl<S: EventStore> AgentRuntime<S> {
    pub fn with_store(config: AgentRuntimeConfig, store: S) -> Result<Self, AgentError> {
        let mut sessions = HashMap::new();
        for session_id in store.list_sessions()? {
            let cursor =
                SessionCursor::from_last_event(session_id.clone(), store.last_event(&session_id)?);
            sessions.insert(session_id, cursor);
        }

        Ok(Self {
            config,
            ids: IdGenerator::new(),
            store,
            sessions,
            runs: HashMap::new(),
        })
    }

    pub fn session_ids(&self) -> Vec<SessionId> {
        let mut session_ids: Vec<_> = self.sessions.keys().cloned().collect();
        session_ids.sort_by(|left, right| left.0.cmp(&right.0));
        session_ids
    }

    pub fn create_session(&mut self) -> Result<SessionId, AgentError> {
        let session_id = SessionId(self.ids.next_id("session"));
        self.sessions
            .insert(session_id.clone(), SessionCursor::new(session_id.clone()));
        self.append_event(
            &session_id,
            None,
            None,
            EventKind::SessionCreated,
            "session created",
        )?;
        Ok(session_id)
    }

    pub fn send_message(
        &mut self,
        input: SendMessageInput,
    ) -> Result<Vec<RuntimeEvent>, AgentError> {
        self.send_message_turn(input).map(|turn| turn.events)
    }

    pub fn send_message_turn(
        &mut self,
        input: SendMessageInput,
    ) -> Result<AgentTurnResult, AgentError> {
        let run_id = RunId(self.ids.next_id("run"));
        let run_id_string = run_id.0.clone();
        self.runs.insert(
            run_id.clone(),
            RunRecord::new(run_id.clone(), input.session_id.clone()),
        );
        let cursor = self.sessions.get(&input.session_id).ok_or_else(|| {
            AgentError::Storage(format!("missing session: {}", input.session_id.0))
        })?;

        let parent_id = input
            .parent_event_id
            .clone()
            .or_else(|| cursor.active_leaf.clone());
        let user_id = self.append_event(
            &input.session_id,
            parent_id,
            Some(run_id.clone()),
            EventKind::UserMessage,
            input.text,
        )?;
        let branch = self.store.active_branch(&input.session_id, &user_id)?;

        let context = ContextController::new(
            self.config.system_prompt.clone(),
            self.config.runtime_policy.clone(),
            self.config.tool_schemas.clone(),
            self.config.tokenizer.boxed_clone(),
        );
        let frame = context.build_prompt_frame(branch)?;

        let mut emitted = Vec::new();
        emitted.push(self.store.get(&input.session_id, &user_id)?);

        let assistant_start = self.append_event(
            &input.session_id,
            Some(user_id.clone()),
            Some(run_id.clone()),
            EventKind::AssistantMessageStarted,
            format!("run {}", run_id_string),
        )?;
        emitted.push(self.store.get(&input.session_id, &assistant_start)?);

        let mut batcher = StreamBatcher::new(24);
        let provider_events = match self.config.provider.stream_chat(&frame) {
            Ok(events) => events,
            Err(error) => {
                let failed_id = self.append_event(
                    &input.session_id,
                    Some(assistant_start.clone()),
                    Some(run_id.clone()),
                    EventKind::RunFailed,
                    error.to_string(),
                )?;
                if let Some(run) = self.runs.get_mut(&run_id) {
                    run.mark_failed()?;
                }
                emitted.push(self.store.get(&input.session_id, &failed_id)?);
                return Err(error);
            }
        };
        let mut parent = assistant_start;

        for provider_event in provider_events {
            match provider_event {
                ModelProviderOutput::TextDelta(delta) => {
                    if let Some(chunk) = batcher.push(&delta) {
                        let delta_id = self.append_event(
                            &input.session_id,
                            Some(parent.clone()),
                            Some(run_id.clone()),
                            EventKind::AssistantTextDelta,
                            chunk,
                        )?;
                        parent = delta_id.clone();
                        emitted.push(self.store.get(&input.session_id, &delta_id)?);
                    }
                }
                ModelProviderOutput::ToolCall(tool_call) => {
                    if let Some(chunk) = batcher.flush() {
                        let delta_id = self.append_event(
                            &input.session_id,
                            Some(parent.clone()),
                            Some(run_id.clone()),
                            EventKind::AssistantTextDelta,
                            chunk,
                        )?;
                        parent = delta_id.clone();
                        emitted.push(self.store.get(&input.session_id, &delta_id)?);
                    }
                    let pending_tool_call_id = tool_call.id.clone();
                    let tool_call_id = self.append_event(
                        &input.session_id,
                        Some(parent.clone()),
                        Some(run_id.clone()),
                        EventKind::ToolCallRequested,
                        format!("{} {}", tool_call.name, tool_call.arguments_json),
                    )?;
                    if let Some(run) = self.runs.get_mut(&run_id) {
                        run.mark_waiting_tool()?;
                    }
                    emitted.push(self.store.get(&input.session_id, &tool_call_id)?);
                    return Ok(AgentTurnResult {
                        run_id: run_id_string,
                        state: RunState::WaitingTool,
                        events: emitted,
                        pending_tool_call_id: Some(pending_tool_call_id),
                    });
                }
                ModelProviderOutput::Completed(completed) => {
                    if let Some(chunk) = batcher.flush() {
                        let delta_id = self.append_event(
                            &input.session_id,
                            Some(parent.clone()),
                            Some(run_id.clone()),
                            EventKind::AssistantTextDelta,
                            chunk,
                        )?;
                        parent = delta_id.clone();
                        emitted.push(self.store.get(&input.session_id, &delta_id)?);
                    }
                    let completed_id = self.append_event(
                        &input.session_id,
                        Some(parent.clone()),
                        Some(run_id.clone()),
                        EventKind::AssistantMessageCompleted,
                        completed,
                    )?;
                    if let Some(run) = self.runs.get_mut(&run_id) {
                        run.mark_completed()?;
                    }
                    emitted.push(self.store.get(&input.session_id, &completed_id)?);
                    return Ok(AgentTurnResult {
                        run_id: run_id_string,
                        state: RunState::Completed,
                        events: emitted,
                        pending_tool_call_id: None,
                    });
                }
            }
        }

        Ok(AgentTurnResult {
            run_id: run_id_string,
            state: RunState::Running,
            events: emitted,
            pending_tool_call_id: None,
        })
    }

    pub fn submit_tool_result(
        &mut self,
        run_id: String,
        result: ToolResult,
    ) -> Result<AgentTurnResult, AgentError> {
        let run_key = RunId(run_id.clone());
        let session_id = {
            let run = self
                .runs
                .get(&run_key)
                .ok_or_else(|| AgentError::Storage(format!("missing run: {run_id}")))?;
            if run.state != RunState::WaitingTool {
                return Err(AgentError::ToolExecution(format!(
                    "run is not waiting for a tool result: {run_id}"
                )));
            }
            run.session_id.clone()
        };
        if let Some(run) = self.runs.get_mut(&run_key) {
            run.mark_running()?;
        }

        let parent_id = self
            .sessions
            .get(&session_id)
            .and_then(|cursor| cursor.active_leaf.clone())
            .ok_or_else(|| {
                AgentError::Storage(format!("session has no active leaf: {}", session_id.0))
            })?;

        let tool_result_id = self.append_event(
            &session_id,
            Some(parent_id),
            Some(run_key.clone()),
            EventKind::ToolResultMessage,
            result.model_text,
        )?;
        let mut emitted = vec![self.store.get(&session_id, &tool_result_id)?];
        let branch = self.store.active_branch(&session_id, &tool_result_id)?;

        let context = ContextController::new(
            self.config.system_prompt.clone(),
            self.config.runtime_policy.clone(),
            self.config.tool_schemas.clone(),
            self.config.tokenizer.boxed_clone(),
        );
        let frame = context.build_prompt_frame(branch)?;
        let provider_events = match self.config.provider.stream_chat(&frame) {
            Ok(events) => events,
            Err(error) => {
                let failed_id = self.append_event(
                    &session_id,
                    Some(tool_result_id.clone()),
                    Some(run_key.clone()),
                    EventKind::RunFailed,
                    error.to_string(),
                )?;
                if let Some(run) = self.runs.get_mut(&run_key) {
                    run.mark_failed()?;
                }
                emitted.push(self.store.get(&session_id, &failed_id)?);
                return Err(error);
            }
        };

        let mut batcher = StreamBatcher::new(24);
        let mut parent = tool_result_id;

        for provider_event in provider_events {
            match provider_event {
                ModelProviderOutput::TextDelta(delta) => {
                    if let Some(chunk) = batcher.push(&delta) {
                        let delta_id = self.append_event(
                            &session_id,
                            Some(parent.clone()),
                            Some(run_key.clone()),
                            EventKind::AssistantTextDelta,
                            chunk,
                        )?;
                        parent = delta_id.clone();
                        emitted.push(self.store.get(&session_id, &delta_id)?);
                    }
                }
                ModelProviderOutput::ToolCall(tool_call) => {
                    if let Some(chunk) = batcher.flush() {
                        let delta_id = self.append_event(
                            &session_id,
                            Some(parent.clone()),
                            Some(run_key.clone()),
                            EventKind::AssistantTextDelta,
                            chunk,
                        )?;
                        parent = delta_id.clone();
                        emitted.push(self.store.get(&session_id, &delta_id)?);
                    }
                    let pending_tool_call_id = tool_call.id.clone();
                    let tool_call_id = self.append_event(
                        &session_id,
                        Some(parent.clone()),
                        Some(run_key.clone()),
                        EventKind::ToolCallRequested,
                        format!("{} {}", tool_call.name, tool_call.arguments_json),
                    )?;
                    if let Some(run) = self.runs.get_mut(&run_key) {
                        run.mark_waiting_tool()?;
                    }
                    emitted.push(self.store.get(&session_id, &tool_call_id)?);
                    return Ok(AgentTurnResult {
                        run_id,
                        state: RunState::WaitingTool,
                        events: emitted,
                        pending_tool_call_id: Some(pending_tool_call_id),
                    });
                }
                ModelProviderOutput::Completed(completed) => {
                    if let Some(chunk) = batcher.flush() {
                        let delta_id = self.append_event(
                            &session_id,
                            Some(parent.clone()),
                            Some(run_key.clone()),
                            EventKind::AssistantTextDelta,
                            chunk,
                        )?;
                        parent = delta_id.clone();
                        emitted.push(self.store.get(&session_id, &delta_id)?);
                    }
                    let completed_id = self.append_event(
                        &session_id,
                        Some(parent.clone()),
                        Some(run_key.clone()),
                        EventKind::AssistantMessageCompleted,
                        completed,
                    )?;
                    if let Some(run) = self.runs.get_mut(&run_key) {
                        run.mark_completed()?;
                    }
                    emitted.push(self.store.get(&session_id, &completed_id)?);
                    return Ok(AgentTurnResult {
                        run_id,
                        state: RunState::Completed,
                        events: emitted,
                        pending_tool_call_id: None,
                    });
                }
            }
        }

        Ok(AgentTurnResult {
            run_id,
            state: RunState::Running,
            events: emitted,
            pending_tool_call_id: None,
        })
    }

    fn append_event(
        &mut self,
        session_id: &SessionId,
        parent_id: Option<EntryId>,
        run_id: Option<RunId>,
        kind: EventKind,
        payload: impl Into<String>,
    ) -> Result<EntryId, AgentError> {
        let sequence = self
            .sessions
            .get(session_id)
            .map(|cursor| cursor.next_sequence)
            .unwrap_or(1);
        let depth = match &parent_id {
            Some(parent_id) => self.store.get(session_id, parent_id)?.depth + 1,
            None => 0,
        };
        let entry_id = EntryId(self.ids.next_id("entry"));
        let event = RuntimeEvent::new(
            entry_id.clone(),
            session_id.clone(),
            parent_id,
            run_id,
            sequence,
            depth,
            kind,
            payload,
        );
        self.store.append(event)?;

        let cursor = self
            .sessions
            .entry(session_id.clone())
            .or_insert_with(|| SessionCursor::new(session_id.clone()));
        cursor.active_leaf = Some(entry_id.clone());
        cursor.next_sequence = sequence + 1;

        Ok(entry_id)
    }
}
