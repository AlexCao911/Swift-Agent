use std::collections::HashMap;

use serde_json::{json, Value};

use crate::context::{ContextController, TokenizerAdapter};
use crate::core::{
    AgentError, AgentTurnResult, EntryId, EventKind, ModelProvider, ModelProviderOutput, RunId,
    RunRecord, RunState, RuntimeEvent, SessionCursor, SessionId, StreamBatcher,
};
use crate::memory::{EventStore, InMemoryEventStore};
use crate::tool::{ToolCall, ToolExecutionRequest, ToolResult, ToolRouteOutcome, ToolRouter};
use crate::utils::id::IdGenerator;

#[derive(Clone, Debug)]
struct RoutedToolCall {
    event_id: EntryId,
    pending_tool_call_id: String,
    denied_result: Option<ToolResult>,
}

pub struct AgentRuntimeConfig {
    pub system_prompt: String,
    pub runtime_policy: String,
    pub tool_schemas: Vec<String>,
    pub tokenizer: Box<dyn TokenizerAdapter>,
    pub provider: Box<dyn ModelProvider>,
    pub tool_router: Option<ToolRouter>,
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
    pending_tool_requests: Vec<ToolExecutionRequest>,
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
        let session_ids: Vec<_> = sessions.keys().cloned().collect();
        let next_id = next_replayed_id(&store, &session_ids)?;

        let mut runtime = Self {
            config,
            ids: IdGenerator::starting_at(next_id),
            store,
            sessions,
            runs: HashMap::new(),
            pending_tool_requests: Vec::new(),
        };
        runtime.replay_waiting_runs()?;
        Ok(runtime)
    }

    pub fn pending_tool_requests(&self) -> &[ToolExecutionRequest] {
        &self.pending_tool_requests
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
                    let routed_tool_call = self.append_tool_call_requested(
                        &input.session_id,
                        Some(parent.clone()),
                        &run_id,
                        tool_call,
                    )?;
                    if let Some(run) = self.runs.get_mut(&run_id) {
                        run.mark_waiting_tool()?;
                    }
                    emitted.push(
                        self.store
                            .get(&input.session_id, &routed_tool_call.event_id)?,
                    );
                    if let Some(result) = routed_tool_call.denied_result {
                        let resumed = self.submit_tool_result(run_id_string.clone(), result)?;
                        let state = resumed.state;
                        let pending_tool_call_id = resumed.pending_tool_call_id;
                        emitted.extend(resumed.events);
                        return Ok(AgentTurnResult {
                            run_id: run_id_string,
                            state,
                            events: emitted,
                            pending_tool_call_id,
                        });
                    }
                    return Ok(AgentTurnResult {
                        run_id: run_id_string,
                        state: RunState::WaitingTool,
                        events: emitted,
                        pending_tool_call_id: Some(routed_tool_call.pending_tool_call_id),
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
        self.consume_pending_tool_requests(&run_key);

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
                    let routed_tool_call = self.append_tool_call_requested(
                        &session_id,
                        Some(parent.clone()),
                        &run_key,
                        tool_call,
                    )?;
                    if let Some(run) = self.runs.get_mut(&run_key) {
                        run.mark_waiting_tool()?;
                    }
                    emitted.push(self.store.get(&session_id, &routed_tool_call.event_id)?);
                    if let Some(result) = routed_tool_call.denied_result {
                        let resumed = self.submit_tool_result(run_id.clone(), result)?;
                        let state = resumed.state;
                        let pending_tool_call_id = resumed.pending_tool_call_id;
                        emitted.extend(resumed.events);
                        return Ok(AgentTurnResult {
                            run_id,
                            state,
                            events: emitted,
                            pending_tool_call_id,
                        });
                    }
                    return Ok(AgentTurnResult {
                        run_id,
                        state: RunState::WaitingTool,
                        events: emitted,
                        pending_tool_call_id: Some(routed_tool_call.pending_tool_call_id),
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

    pub fn cancel(&mut self, run_id: String) -> Result<RuntimeEvent, AgentError> {
        let run_key = RunId(run_id.clone());
        let session_id = {
            let run = self
                .runs
                .get_mut(&run_key)
                .ok_or_else(|| AgentError::Storage(format!("missing run: {run_id}")))?;
            run.cancel()?;
            run.session_id.clone()
        };
        let parent_id = self
            .sessions
            .get(&session_id)
            .and_then(|cursor| cursor.active_leaf.clone())
            .ok_or_else(|| {
                AgentError::Storage(format!("session has no active leaf: {}", session_id.0))
            })?;

        let event_id = self.append_event(
            &session_id,
            Some(parent_id),
            Some(run_key),
            EventKind::RunCancelled,
            format!("run {run_id} cancelled"),
        )?;
        self.store.get(&session_id, &event_id)
    }

    fn replay_waiting_runs(&mut self) -> Result<(), AgentError> {
        let session_ids: Vec<_> = self.sessions.keys().cloned().collect();
        for session_id in session_ids {
            let Some(active_leaf_id) = self.store.active_leaf(&session_id)? else {
                continue;
            };
            let branch = self.store.active_branch(&session_id, &active_leaf_id)?;
            let Some(last_event) = branch.last() else {
                continue;
            };
            if last_event.kind != EventKind::ToolCallRequested {
                continue;
            }
            let Some(run_id) = last_event.run_id.clone() else {
                continue;
            };

            let mut run = RunRecord::new(run_id.clone(), session_id.clone());
            run.mark_waiting_tool()?;
            self.runs.insert(run_id.clone(), run);

            if let Some(router) = &self.config.tool_router {
                let tool_call = match tool_call_from_event(last_event) {
                    Ok(tool_call) => tool_call,
                    Err(error) => {
                        self.fail_replayed_waiting_tool(
                            &session_id,
                            &last_event.id,
                            &run_id,
                            format!("replay failed pending tool call: {error}"),
                        )?;
                        continue;
                    }
                };
                let route_outcome = router.route(&run_id, &session_id, &last_event.id, tool_call);
                match route_outcome {
                    Ok(ToolRouteOutcome::ExecuteInSwift(request)) => {
                        self.pending_tool_requests.push(request);
                    }
                    Ok(ToolRouteOutcome::ApprovalRequired { request, reason: _ }) => {
                        // Plan 7 will turn this route into a suspended approval lifecycle.
                        self.pending_tool_requests.push(request);
                    }
                    Ok(ToolRouteOutcome::Denied(result)) => {
                        self.fail_replayed_waiting_tool(
                            &session_id,
                            &last_event.id,
                            &run_id,
                            format!(
                                "replay denied pending tool call `{}`: {}",
                                result.audit_text, result.model_text
                            ),
                        )?;
                    }
                    Err(error) => {
                        self.fail_replayed_waiting_tool(
                            &session_id,
                            &last_event.id,
                            &run_id,
                            format!("replay failed pending tool call: {error}"),
                        )?;
                    }
                }
            }
        }

        Ok(())
    }

    fn fail_replayed_waiting_tool(
        &mut self,
        session_id: &SessionId,
        parent_id: &EntryId,
        run_id: &RunId,
        message: String,
    ) -> Result<(), AgentError> {
        self.append_event(
            session_id,
            Some(parent_id.clone()),
            Some(run_id.clone()),
            EventKind::RunFailed,
            message,
        )?;
        if let Some(run) = self.runs.get_mut(run_id) {
            run.mark_failed()?;
        }

        Ok(())
    }

    fn append_tool_call_requested(
        &mut self,
        session_id: &SessionId,
        parent_id: Option<EntryId>,
        run_id: &RunId,
        tool_call: ToolCall,
    ) -> Result<RoutedToolCall, AgentError> {
        let entry_id = EntryId(self.ids.next_id("entry"));
        let pending_tool_call_id = tool_call.id.clone();
        let mut route_state = "unrouted";
        let mut route_reason = None;
        let mut pending_request = None;
        let mut denied_result = None;

        if let Some(router) = &self.config.tool_router {
            match router.route(run_id, session_id, &entry_id, tool_call.clone())? {
                ToolRouteOutcome::ExecuteInSwift(request) => {
                    route_state = "execute_in_swift";
                    pending_request = Some(request);
                }
                ToolRouteOutcome::ApprovalRequired { request, reason } => {
                    route_state = "approval_required";
                    route_reason = Some(reason);
                    // Plan 7 will turn this route into a suspended approval lifecycle.
                    pending_request = Some(request);
                }
                ToolRouteOutcome::Denied(result) => {
                    route_state = "denied";
                    route_reason = Some(result.audit_text.clone());
                    denied_result = Some(result);
                }
            }
        }

        let payload = tool_call_payload(&tool_call, route_state, route_reason.as_deref());
        let event_id = self.append_event_with_id(
            entry_id,
            session_id,
            parent_id,
            Some(run_id.clone()),
            EventKind::ToolCallRequested,
            payload,
        )?;
        if let Some(request) = pending_request {
            self.pending_tool_requests.push(request);
        }

        Ok(RoutedToolCall {
            event_id,
            pending_tool_call_id,
            denied_result,
        })
    }

    fn consume_pending_tool_requests(&mut self, run_id: &RunId) {
        self.pending_tool_requests
            .retain(|request| &request.run_id != run_id);
    }

    fn append_event(
        &mut self,
        session_id: &SessionId,
        parent_id: Option<EntryId>,
        run_id: Option<RunId>,
        kind: EventKind,
        payload: impl Into<String>,
    ) -> Result<EntryId, AgentError> {
        let entry_id = EntryId(self.ids.next_id("entry"));
        self.append_event_with_id(entry_id, session_id, parent_id, run_id, kind, payload)
    }

    fn append_event_with_id(
        &mut self,
        entry_id: EntryId,
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

fn tool_call_payload(call: &ToolCall, route_state: &str, route_reason: Option<&str>) -> String {
    json!({
        "call_id": call.id,
        "name": call.name,
        "arguments_json": call.arguments_json,
        "route_state": route_state,
        "route_reason": route_reason,
    })
    .to_string()
}

fn tool_call_from_event(event: &RuntimeEvent) -> Result<ToolCall, AgentError> {
    let value: Value = serde_json::from_str(&event.payload).map_err(|error| {
        AgentError::ToolParse(format!("invalid persisted tool call payload: {error}"))
    })?;
    let id = value
        .get("call_id")
        .and_then(Value::as_str)
        .ok_or_else(|| AgentError::ToolParse("persisted tool call missing call_id".to_string()))?
        .to_string();
    let name = value
        .get("name")
        .and_then(Value::as_str)
        .ok_or_else(|| AgentError::ToolParse("persisted tool call missing name".to_string()))?
        .to_string();
    let arguments_json = value
        .get("arguments_json")
        .and_then(Value::as_str)
        .ok_or_else(|| {
            AgentError::ToolParse("persisted tool call missing arguments_json".to_string())
        })?
        .to_string();
    let arguments: Value = serde_json::from_str(&arguments_json).map_err(|error| {
        AgentError::ToolParse(format!("invalid persisted tool arguments JSON: {error}"))
    })?;
    if !arguments.is_object() {
        return Err(AgentError::ToolParse(
            "persisted tool arguments must be a JSON object".to_string(),
        ));
    }

    Ok(ToolCall {
        id,
        name,
        arguments_json,
    })
}

fn next_replayed_id<S: EventStore>(
    store: &S,
    session_ids: &[SessionId],
) -> Result<u64, AgentError> {
    let mut max_id = 0;

    for session_id in session_ids {
        max_id = max_id.max(numeric_suffix(&session_id.0).unwrap_or(0));

        let Some(active_leaf_id) = store.active_leaf(session_id)? else {
            continue;
        };
        let branch = store.active_branch(session_id, &active_leaf_id)?;
        for event in branch {
            max_id = max_id.max(numeric_suffix(&event.id.0).unwrap_or(0));
            if let Some(run_id) = event.run_id {
                max_id = max_id.max(numeric_suffix(&run_id.0).unwrap_or(0));
            }
        }
    }

    Ok(max_id + 1)
}

fn numeric_suffix(id: &str) -> Option<u64> {
    id.rsplit_once('_')?.1.parse().ok()
}
