use std::collections::HashMap;

use serde_json::{json, Value};

use crate::context::{ContextController, PromptDebugSnapshot, PromptFrame, TokenizerAdapter};
use crate::core::{
    AgentError, AgentTurnResult, CancellationToken, EntryId, EventKind, ModelProvider,
    ModelProviderOutput, ProviderCancellationRegistry, ProviderKind, ProviderProfile,
    ProviderRegistry, RunId, RunRecord, RunState, RuntimeEvent, SessionCursor, SessionId,
    StreamBatcher,
};
use crate::memory::{EventStore, InMemoryEventStore, ProviderSetting};
use crate::security::{
    ApprovalDecision, ApprovalProtocolRequest, ApprovalProtocolResponse, AuditPolicy,
    PermissionScope,
};
use crate::tool::{
    RetentionPolicy, Sensitivity, ToolCall, ToolExecutionRequest, ToolRegistry, ToolResult,
    ToolRouteOutcome, ToolRouter, ToolSchema,
};
use crate::utils::id::IdGenerator;

#[derive(Clone, Debug)]
struct RoutedToolCall {
    event_id: EntryId,
    suspension_event_id: Option<EntryId>,
    pending_tool_call_id: String,
    denied_result: Option<ToolResult>,
}

type RuntimeEventSink<'a> = &'a mut dyn FnMut(RuntimeEvent) -> Result<(), AgentError>;

#[derive(Debug)]
enum ProviderOutputAction {
    Completed,
    WaitingTool {
        state: RunState,
        pending_tool_call_id: String,
    },
    AutoSubmitDenied(ToolResult),
}

struct ProviderSlotEmpty;

impl ModelProvider for ProviderSlotEmpty {
    fn id(&self) -> &str {
        "__provider_slot_empty__"
    }

    fn stream_chat(
        &self,
        _frame: &PromptFrame,
        _cancellation: CancellationToken,
        _on_output: &mut dyn FnMut(ModelProviderOutput) -> Result<(), AgentError>,
    ) -> Result<(), AgentError> {
        Err(AgentError::Provider(
            "provider is temporarily unavailable during a streaming call".into(),
        ))
    }
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
    pub blob_refs: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ConversationSummary {
    pub session_id: SessionId,
    pub title: String,
    pub active_leaf_id: Option<EntryId>,
    pub last_event_id: Option<EntryId>,
    pub last_updated_sequence: u64,
}

pub struct AgentRuntime<S: EventStore = InMemoryEventStore> {
    config: AgentRuntimeConfig,
    context_controller: ContextController,
    ids: IdGenerator,
    store: S,
    provider_registry: ProviderRegistry,
    active_provider_profile: ProviderProfile,
    sessions: HashMap<SessionId, SessionCursor>,
    runs: HashMap<RunId, RunRecord>,
    provider_cancellations: ProviderCancellationRegistry,
    latest_prompt_debug_snapshot: Option<PromptDebugSnapshot>,
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
        Self::with_store_and_registry(config, store, ProviderRegistry::with_mock())
    }

    pub fn with_store_and_registry(
        mut config: AgentRuntimeConfig,
        store: S,
        provider_registry: ProviderRegistry,
    ) -> Result<Self, AgentError> {
        let mut sessions = HashMap::new();
        for session_id in store.list_sessions()? {
            let cursor =
                SessionCursor::from_last_event(session_id.clone(), store.last_event(&session_id)?);
            sessions.insert(session_id, cursor);
        }
        let session_ids: Vec<_> = sessions.keys().cloned().collect();
        let next_id = next_replayed_id(&store, &session_ids)?;
        let mut active_provider_profile = active_profile_for_config(&config, &provider_registry);
        if let Some(provider_id) = persisted_provider_id(&store)? {
            let bundle = provider_registry.build(&provider_id)?;
            active_provider_profile = provider_registry.profile(&provider_id).ok_or_else(|| {
                AgentError::Provider(format!("unknown provider profile: {provider_id}"))
            })?;
            config.provider = bundle.provider;
            config.tokenizer = bundle.tokenizer;
        }

        let context_controller = build_context_controller(&config);
        let mut runtime = Self {
            config,
            context_controller,
            ids: IdGenerator::starting_at(next_id),
            store,
            provider_registry,
            active_provider_profile,
            sessions,
            runs: HashMap::new(),
            provider_cancellations: ProviderCancellationRegistry::default(),
            latest_prompt_debug_snapshot: None,
            pending_tool_requests: Vec::new(),
        };
        runtime.replay_waiting_runs()?;
        Ok(runtime)
    }

    pub fn pending_tool_requests(&self) -> &[ToolExecutionRequest] {
        &self.pending_tool_requests
    }

    pub fn provider_profiles(&self) -> Vec<ProviderProfile> {
        self.provider_registry.profiles()
    }

    pub fn active_provider(&self) -> ProviderProfile {
        self.active_provider_profile.clone()
    }

    pub fn latest_prompt_debug_snapshot(&self) -> Option<PromptDebugSnapshot> {
        self.latest_prompt_debug_snapshot.clone()
    }

    pub fn provider_cancellation_registry(&self) -> ProviderCancellationRegistry {
        self.provider_cancellations.clone()
    }

    pub fn set_provider(
        &mut self,
        session_id: SessionId,
        provider_id: &str,
    ) -> Result<RuntimeEvent, AgentError> {
        if !self.sessions.contains_key(&session_id) {
            return Err(AgentError::Storage(format!(
                "missing session: {}",
                session_id.0
            )));
        }
        if let Some(run_id) = self.blocking_provider_switch_run() {
            return Err(AgentError::Provider(format!(
                "provider_switch_blocked({})",
                run_id.0
            )));
        }

        let bundle = self.provider_registry.build(provider_id)?;
        let profile = self
            .provider_registry
            .profile(provider_id)
            .ok_or_else(|| AgentError::Provider(format!("unknown provider: {provider_id}")))?;

        self.config.provider = bundle.provider;
        self.config.tokenizer = bundle.tokenizer;
        self.rebuild_context_controller();
        self.active_provider_profile = profile.clone();
        self.store.save_provider_setting(ProviderSetting {
            key: active_provider_key(),
            value: profile.id.clone(),
        })?;

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
            None,
            EventKind::ProviderChanged,
            json!({ "provider_id": profile.id }).to_string(),
        )?;
        self.store.get(&session_id, &event_id)
    }

    pub fn register_tool(&mut self, schema: ToolSchema) -> Result<(), AgentError> {
        let router = self
            .config
            .tool_router
            .get_or_insert_with(|| ToolRouter::new(ToolRegistry::new()));
        router.register(schema)?;
        self.config.tool_schemas = router.prompt_schemas();
        self.rebuild_context_controller();
        Ok(())
    }

    pub fn set_permission(&mut self, permission: PermissionScope) {
        let router = self
            .config
            .tool_router
            .get_or_insert_with(|| ToolRouter::new(ToolRegistry::new()));
        router.set_permission(permission);
    }

    pub fn pending_approval_requests(&self) -> Vec<ApprovalProtocolRequest> {
        self.config
            .tool_router
            .as_ref()
            .map(ToolRouter::pending_approval_requests)
            .unwrap_or_default()
    }

    pub fn submit_approval_response(
        &mut self,
        response: ApprovalProtocolResponse,
    ) -> Result<AgentTurnResult, AgentError> {
        let (approval, decision, tool_request) = self
            .config
            .tool_router
            .as_mut()
            .ok_or_else(|| AgentError::PolicyDenied("no tool router configured".into()))?
            .resolve_approval(response)?;
        let run_key = approval.run_id.clone();
        let run_id = run_key.0.clone();
        let session_id = {
            let run = self
                .runs
                .get(&run_key)
                .ok_or_else(|| AgentError::Storage(format!("missing run: {}", run_key.0)))?;
            if run.state != RunState::Suspended {
                return Err(AgentError::PolicyDenied(format!(
                    "run is not suspended for approval: {}",
                    run_key.0
                )));
            }
            run.session_id.clone()
        };
        let parent_id = self
            .sessions
            .get(&session_id)
            .and_then(|cursor| cursor.active_leaf.clone())
            .ok_or_else(|| {
                AgentError::Storage(format!("session has no active leaf: {}", session_id.0))
            })?;
        let mut emitted = Vec::new();
        let decision_kind = match decision {
            ApprovalDecision::Approved => EventKind::ToolCallApproved,
            ApprovalDecision::Rejected | ApprovalDecision::Cancelled => EventKind::ToolCallRejected,
        };
        let decision_id = self.append_event(
            &session_id,
            Some(parent_id),
            Some(run_key.clone()),
            decision_kind,
            approval_decision_payload(&approval.approval_id, &decision),
        )?;
        emitted.push(self.store.get(&session_id, &decision_id)?);

        match decision {
            ApprovalDecision::Approved => {
                let request = tool_request.ok_or_else(|| {
                    AgentError::PolicyDenied(format!(
                        "approved tool request missing for approval: {}",
                        approval.approval_id
                    ))
                })?;
                let resumed_id = self.append_event(
                    &session_id,
                    Some(decision_id),
                    Some(run_key.clone()),
                    EventKind::RunResumed,
                    format!("approval {} accepted", approval.approval_id),
                )?;
                emitted.push(self.store.get(&session_id, &resumed_id)?);
                if let Some(run) = self.runs.get_mut(&run_key) {
                    run.mark_waiting_tool()?;
                }
                let pending_tool_call_id = request.tool_call_id.clone();
                self.pending_tool_requests.push(request);

                Ok(AgentTurnResult {
                    run_id,
                    state: RunState::WaitingTool,
                    events: emitted,
                    pending_tool_call_id: Some(pending_tool_call_id),
                })
            }
            ApprovalDecision::Rejected | ApprovalDecision::Cancelled => {
                if let Some(run) = self.runs.get_mut(&run_key) {
                    run.mark_waiting_tool()?;
                }
                let result = ToolResult {
                    display_text: approval.message.clone(),
                    model_text: format!("Tool approval rejected: {}", approval.message),
                    structured_json: "{}".into(),
                    audit_text: format!("approval rejected: {}", approval.approval_id),
                    sensitivity: Sensitivity::Public,
                    retention: RetentionPolicy::RunOnly,
                    is_error: true,
                };
                let resumed = self.submit_tool_result(run_id, result)?;
                emitted.extend(resumed.events);

                Ok(AgentTurnResult {
                    run_id: resumed.run_id,
                    state: resumed.state,
                    events: emitted,
                    pending_tool_call_id: resumed.pending_tool_call_id,
                })
            }
        }
    }

    pub fn session_ids(&self) -> Vec<SessionId> {
        let mut session_ids: Vec<_> = self.sessions.keys().cloned().collect();
        session_ids.sort_by(|left, right| left.0.cmp(&right.0));
        session_ids
    }

    pub fn conversation_summaries(&self) -> Result<Vec<ConversationSummary>, AgentError> {
        let mut summaries = Vec::new();

        for session_id in self.session_ids() {
            let active_leaf_id = self.store.active_leaf(&session_id)?;
            let last_event = self.store.last_event(&session_id)?;
            let title = match &active_leaf_id {
                Some(leaf_id) => self
                    .store
                    .active_branch(&session_id, leaf_id)?
                    .into_iter()
                    .find(|event| event.kind == EventKind::UserMessage)
                    .map(|event| first_line_title(&event.payload))
                    .unwrap_or_else(|| "New chat".to_string()),
                None => "New chat".to_string(),
            };

            summaries.push(ConversationSummary {
                session_id,
                title,
                active_leaf_id,
                last_event_id: last_event.as_ref().map(|event| event.id.clone()),
                last_updated_sequence: last_event.map(|event| event.sequence).unwrap_or(0),
            });
        }

        summaries.sort_by(|left, right| {
            right
                .last_updated_sequence
                .cmp(&left.last_updated_sequence)
                .then_with(|| left.session_id.0.cmp(&right.session_id.0))
        });
        Ok(summaries)
    }

    pub fn active_branch_events(
        &self,
        session_id: &SessionId,
        leaf_id: Option<EntryId>,
    ) -> Result<Vec<RuntimeEvent>, AgentError> {
        let leaf_id = match leaf_id {
            Some(leaf_id) => leaf_id,
            None => self.store.active_leaf(session_id)?.ok_or_else(|| {
                AgentError::Storage(format!("session has no active leaf: {}", session_id.0))
            })?,
        };

        self.store.active_branch(session_id, &leaf_id)
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
        self.send_message_streaming(input, &mut |_| Ok(()))
    }

    pub fn send_message_streaming(
        &mut self,
        input: SendMessageInput,
        on_event: RuntimeEventSink<'_>,
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
        let (parent_id, mut emitted) = self.prepare_context_parent(
            &input.session_id,
            parent_id,
            &run_id,
            EventKind::UserMessage,
            &input.text,
        )?;
        Self::emit_events(&mut emitted, on_event)?;
        let user_id = self.append_event_with_blob_refs(
            &input.session_id,
            parent_id,
            Some(run_id.clone()),
            EventKind::UserMessage,
            input.text,
            input.blob_refs,
        )?;
        self.emit_event_by_id(&input.session_id, &user_id, &mut emitted, on_event)?;
        let branch = self.store.active_branch(&input.session_id, &user_id)?;
        let frame = self.context_controller().build_prompt_frame(branch)?;

        let assistant_start = self.append_event(
            &input.session_id,
            Some(user_id.clone()),
            Some(run_id.clone()),
            EventKind::AssistantMessageStarted,
            format!("run {}", run_id_string),
        )?;
        self.emit_event_by_id(&input.session_id, &assistant_start, &mut emitted, on_event)?;

        let mut batcher = StreamBatcher::new(24);
        let mut parent = assistant_start;
        let mut provider_action = None;
        self.capture_prompt_debug_snapshot(&frame);
        let cancellation = self.start_provider_call(&run_id);
        let provider = std::mem::replace(&mut self.config.provider, Box::new(ProviderSlotEmpty));
        let provider_result = provider.stream_chat(&frame, cancellation, &mut |provider_event| {
            if provider_action.is_some() {
                return Ok(());
            }

            provider_action = self.process_provider_output(
                &input.session_id,
                &run_id,
                &mut parent,
                &mut batcher,
                provider_event,
                &mut emitted,
                on_event,
            )?;
            Ok(())
        });
        self.config.provider = provider;
        self.finish_provider_call(&run_id);
        match provider_result {
            Ok(()) => {}
            Err(error) => {
                let failed_id = self.append_event(
                    &input.session_id,
                    Some(parent),
                    Some(run_id.clone()),
                    EventKind::RunFailed,
                    error.to_string(),
                )?;
                if let Some(run) = self.runs.get_mut(&run_id) {
                    run.mark_failed()?;
                }
                self.emit_event_by_id(&input.session_id, &failed_id, &mut emitted, on_event)?;
                return Err(error);
            }
        }

        self.result_from_provider_action(run_id_string, provider_action, emitted, on_event)
    }

    pub fn submit_tool_result(
        &mut self,
        run_id: String,
        result: ToolResult,
    ) -> Result<AgentTurnResult, AgentError> {
        self.submit_tool_result_streaming(run_id, result, &mut |_| Ok(()))
    }

    pub fn submit_tool_result_streaming(
        &mut self,
        run_id: String,
        result: ToolResult,
        on_event: RuntimeEventSink<'_>,
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

        let tool_result_payload = result.to_event_payload();
        let (parent_id, mut emitted) = self.prepare_context_parent(
            &session_id,
            Some(parent_id),
            &run_key,
            EventKind::ToolResultMessage,
            &tool_result_payload,
        )?;
        Self::emit_events(&mut emitted, on_event)?;

        let tool_result_id = self.append_event(
            &session_id,
            parent_id,
            Some(run_key.clone()),
            EventKind::ToolResultMessage,
            tool_result_payload,
        )?;
        self.emit_event_by_id(&session_id, &tool_result_id, &mut emitted, on_event)?;
        let branch = self.store.active_branch(&session_id, &tool_result_id)?;
        let frame = self.context_controller().build_prompt_frame(branch)?;
        self.capture_prompt_debug_snapshot(&frame);
        let cancellation = self.start_provider_call(&run_key);
        let mut batcher = StreamBatcher::new(24);
        let mut parent = tool_result_id;
        let mut provider_action = None;
        let provider = std::mem::replace(&mut self.config.provider, Box::new(ProviderSlotEmpty));
        let provider_result = provider.stream_chat(&frame, cancellation, &mut |provider_event| {
            if provider_action.is_some() {
                return Ok(());
            }

            provider_action = self.process_provider_output(
                &session_id,
                &run_key,
                &mut parent,
                &mut batcher,
                provider_event,
                &mut emitted,
                on_event,
            )?;
            Ok(())
        });
        self.config.provider = provider;
        self.finish_provider_call(&run_key);
        match provider_result {
            Ok(()) => {}
            Err(error) => {
                let failed_id = self.append_event(
                    &session_id,
                    Some(parent),
                    Some(run_key.clone()),
                    EventKind::RunFailed,
                    error.to_string(),
                )?;
                if let Some(run) = self.runs.get_mut(&run_key) {
                    run.mark_failed()?;
                }
                self.emit_event_by_id(&session_id, &failed_id, &mut emitted, on_event)?;
                return Err(error);
            }
        }

        self.result_from_provider_action(run_id, provider_action, emitted, on_event)
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

        self.provider_cancellations.signal(&run_key);
        self.provider_cancellations.remove(&run_key);

        let event_id = self.append_event(
            &session_id,
            Some(parent_id),
            Some(run_key),
            EventKind::RunCancelled,
            format!("run {run_id} cancelled"),
        )?;
        self.store.get(&session_id, &event_id)
    }

    fn start_provider_call(&mut self, run_id: &RunId) -> CancellationToken {
        let token = CancellationToken::default();
        self.provider_cancellations
            .insert(run_id.clone(), token.clone());
        token
    }

    fn finish_provider_call(&mut self, run_id: &RunId) {
        self.provider_cancellations.remove(run_id);
    }

    fn emit_events(
        emitted: &mut [RuntimeEvent],
        on_event: RuntimeEventSink<'_>,
    ) -> Result<(), AgentError> {
        for event in emitted.iter().cloned() {
            on_event(event)?;
        }
        Ok(())
    }

    fn emit_event_by_id(
        &self,
        session_id: &SessionId,
        event_id: &EntryId,
        emitted: &mut Vec<RuntimeEvent>,
        on_event: RuntimeEventSink<'_>,
    ) -> Result<(), AgentError> {
        let event = self.store.get(session_id, event_id)?;
        on_event(event.clone())?;
        emitted.push(event);
        Ok(())
    }

    fn process_provider_output(
        &mut self,
        session_id: &SessionId,
        run_id: &RunId,
        parent: &mut EntryId,
        batcher: &mut StreamBatcher,
        provider_event: ModelProviderOutput,
        emitted: &mut Vec<RuntimeEvent>,
        on_event: RuntimeEventSink<'_>,
    ) -> Result<Option<ProviderOutputAction>, AgentError> {
        match provider_event {
            ModelProviderOutput::TextDelta(delta) => {
                if let Some(chunk) = batcher.push(&delta) {
                    let delta_id = self.append_event(
                        session_id,
                        Some(parent.clone()),
                        Some(run_id.clone()),
                        EventKind::AssistantTextDelta,
                        chunk,
                    )?;
                    *parent = delta_id.clone();
                    self.emit_event_by_id(session_id, &delta_id, emitted, on_event)?;
                }
                Ok(None)
            }
            ModelProviderOutput::ToolCall(tool_call) => {
                if let Some(chunk) = batcher.flush() {
                    let delta_id = self.append_event(
                        session_id,
                        Some(parent.clone()),
                        Some(run_id.clone()),
                        EventKind::AssistantTextDelta,
                        chunk,
                    )?;
                    *parent = delta_id.clone();
                    self.emit_event_by_id(session_id, &delta_id, emitted, on_event)?;
                }
                let routed_tool_call = self.append_tool_call_requested(
                    session_id,
                    Some(parent.clone()),
                    run_id,
                    tool_call,
                )?;
                let state = if routed_tool_call.suspension_event_id.is_some() {
                    RunState::Suspended
                } else {
                    RunState::WaitingTool
                };
                if let Some(run) = self.runs.get_mut(run_id) {
                    match state {
                        RunState::Suspended => run.mark_suspended()?,
                        RunState::WaitingTool => run.mark_waiting_tool()?,
                        _ => {}
                    }
                }
                self.emit_event_by_id(session_id, &routed_tool_call.event_id, emitted, on_event)?;
                if let Some(suspension_event_id) = &routed_tool_call.suspension_event_id {
                    self.emit_event_by_id(session_id, suspension_event_id, emitted, on_event)?;
                }
                if let Some(result) = routed_tool_call.denied_result {
                    return Ok(Some(ProviderOutputAction::AutoSubmitDenied(result)));
                }

                Ok(Some(ProviderOutputAction::WaitingTool {
                    state,
                    pending_tool_call_id: routed_tool_call.pending_tool_call_id,
                }))
            }
            ModelProviderOutput::Completed(completed) => {
                if let Some(chunk) = batcher.flush() {
                    let delta_id = self.append_event(
                        session_id,
                        Some(parent.clone()),
                        Some(run_id.clone()),
                        EventKind::AssistantTextDelta,
                        chunk,
                    )?;
                    *parent = delta_id.clone();
                    self.emit_event_by_id(session_id, &delta_id, emitted, on_event)?;
                }
                let completed_id = self.append_event(
                    session_id,
                    Some(parent.clone()),
                    Some(run_id.clone()),
                    EventKind::AssistantMessageCompleted,
                    completed,
                )?;
                if let Some(run) = self.runs.get_mut(run_id) {
                    run.mark_completed()?;
                }
                self.emit_event_by_id(session_id, &completed_id, emitted, on_event)?;
                Ok(Some(ProviderOutputAction::Completed))
            }
        }
    }

    fn result_from_provider_action(
        &mut self,
        run_id: String,
        action: Option<ProviderOutputAction>,
        mut emitted: Vec<RuntimeEvent>,
        on_event: RuntimeEventSink<'_>,
    ) -> Result<AgentTurnResult, AgentError> {
        match action {
            Some(ProviderOutputAction::Completed) => Ok(AgentTurnResult {
                run_id,
                state: RunState::Completed,
                events: emitted,
                pending_tool_call_id: None,
            }),
            Some(ProviderOutputAction::WaitingTool {
                state,
                pending_tool_call_id,
            }) => Ok(AgentTurnResult {
                run_id,
                state,
                events: emitted,
                pending_tool_call_id: Some(pending_tool_call_id),
            }),
            Some(ProviderOutputAction::AutoSubmitDenied(result)) => {
                let resumed =
                    self.submit_tool_result_streaming(run_id.clone(), result, on_event)?;
                let state = resumed.state;
                let pending_tool_call_id = resumed.pending_tool_call_id;
                emitted.extend(resumed.events);
                Ok(AgentTurnResult {
                    run_id,
                    state,
                    events: emitted,
                    pending_tool_call_id,
                })
            }
            None => Ok(AgentTurnResult {
                run_id,
                state: RunState::Running,
                events: emitted,
                pending_tool_call_id: None,
            }),
        }
    }

    fn capture_prompt_debug_snapshot(&mut self, frame: &PromptFrame) {
        self.latest_prompt_debug_snapshot = Some(PromptDebugSnapshot::from_frame(frame));
    }

    fn blocking_provider_switch_run(&self) -> Option<RunId> {
        self.runs
            .values()
            .find(|run| {
                matches!(
                    run.state,
                    RunState::Running | RunState::WaitingTool | RunState::Suspended
                )
            })
            .map(|run| run.run_id.clone())
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
            let (tool_call_event, should_suspend) = match last_event.kind {
                EventKind::ToolCallRequested => (last_event.clone(), false),
                EventKind::RunSuspended => {
                    let Some(parent_id) = &last_event.parent_id else {
                        continue;
                    };
                    let parent_event = self.store.get(&session_id, parent_id)?;
                    if parent_event.kind != EventKind::ToolCallRequested {
                        continue;
                    }
                    (parent_event, true)
                }
                _ => continue,
            };
            let Some(run_id) = last_event.run_id.clone() else {
                continue;
            };

            let mut run = RunRecord::new(run_id.clone(), session_id.clone());
            if should_suspend {
                run.mark_suspended()?;
            } else {
                run.mark_waiting_tool()?;
            }
            self.runs.insert(run_id.clone(), run);

            if let Some(router) = &mut self.config.tool_router {
                let tool_call = match tool_call_from_event(&tool_call_event) {
                    Ok(tool_call) => tool_call,
                    Err(error) => {
                        self.fail_replayed_waiting_tool(
                            &session_id,
                            &tool_call_event.id,
                            &run_id,
                            format!("replay failed pending tool call: {error}"),
                        )?;
                        continue;
                    }
                };
                let route_outcome =
                    router.route(&run_id, &session_id, &tool_call_event.id, tool_call);
                match route_outcome {
                    Ok(ToolRouteOutcome::ExecuteInSwift(request)) => {
                        if !should_suspend {
                            self.pending_tool_requests.push(request);
                        }
                    }
                    Ok(ToolRouteOutcome::ApprovalRequired {
                        request: _,
                        approval: _,
                        reason: _,
                    }) => {
                        if let Some(run) = self.runs.get_mut(&run_id) {
                            run.mark_suspended()?;
                        }
                    }
                    Ok(ToolRouteOutcome::Denied(result)) => {
                        self.fail_replayed_waiting_tool(
                            &session_id,
                            &tool_call_event.id,
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
                            &tool_call_event.id,
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

    fn prepare_context_parent(
        &mut self,
        session_id: &SessionId,
        parent_id: Option<EntryId>,
        run_id: &RunId,
        pending_kind: EventKind,
        pending_payload: &str,
    ) -> Result<(Option<EntryId>, Vec<RuntimeEvent>), AgentError> {
        let Some(parent_id) = parent_id else {
            return Ok((None, Vec::new()));
        };

        let context = self.context_controller();
        let mut branch = self.store.active_branch(session_id, &parent_id)?;
        branch.push(RuntimeEvent::new(
            EntryId("__pending_context_leaf__".into()),
            session_id.clone(),
            Some(parent_id.clone()),
            Some(run_id.clone()),
            0,
            0,
            pending_kind,
            pending_payload,
        ));
        let result = context.build_prompt_frame_with_compaction(branch)?;
        let Some(summary) = result.compaction_summary else {
            return Ok((Some(parent_id), Vec::new()));
        };

        let compaction_id = self.append_event(
            session_id,
            Some(parent_id),
            Some(run_id.clone()),
            EventKind::CompactionCreated,
            summary.clone(),
        )?;
        let summary_id = self.append_event(
            session_id,
            Some(compaction_id.clone()),
            Some(run_id.clone()),
            EventKind::BranchSummaryCreated,
            summary,
        )?;
        let events = vec![
            self.store.get(session_id, &compaction_id)?,
            self.store.get(session_id, &summary_id)?,
        ];

        Ok((Some(summary_id), events))
    }

    fn context_controller(&self) -> &ContextController {
        &self.context_controller
    }

    fn rebuild_context_controller(&mut self) {
        self.context_controller = build_context_controller(&self.config);
    }

    fn append_tool_call_requested(
        &mut self,
        session_id: &SessionId,
        parent_id: Option<EntryId>,
        run_id: &RunId,
        tool_call: ToolCall,
    ) -> Result<RoutedToolCall, AgentError> {
        tool_call.validate_shape()?;
        let entry_id = EntryId(self.ids.next_id("entry"));
        let pending_tool_call_id = tool_call.id.clone();
        let mut route_state = "unrouted";
        let mut route_reason = None;
        let mut pending_request = None;
        let mut approval_request = None;
        let mut denied_result = None;

        if let Some(router) = &mut self.config.tool_router {
            match router.route(run_id, session_id, &entry_id, tool_call.clone())? {
                ToolRouteOutcome::ExecuteInSwift(request) => {
                    route_state = "execute_in_swift";
                    pending_request = Some(request);
                }
                ToolRouteOutcome::ApprovalRequired {
                    request: _,
                    approval,
                    reason,
                } => {
                    route_state = "approval_required";
                    route_reason = Some(reason);
                    approval_request = Some(approval);
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
        let suspension_event_id = if let Some(approval) = approval_request {
            Some(self.append_event(
                session_id,
                Some(event_id.clone()),
                Some(run_id.clone()),
                EventKind::RunSuspended,
                approval_payload(&approval, &pending_tool_call_id, &event_id),
            )?)
        } else {
            None
        };

        Ok(RoutedToolCall {
            event_id,
            suspension_event_id,
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
        self.append_event_with_blob_refs(session_id, parent_id, run_id, kind, payload, Vec::new())
    }

    fn append_event_with_blob_refs(
        &mut self,
        session_id: &SessionId,
        parent_id: Option<EntryId>,
        run_id: Option<RunId>,
        kind: EventKind,
        payload: impl Into<String>,
        blob_refs: Vec<String>,
    ) -> Result<EntryId, AgentError> {
        let entry_id = EntryId(self.ids.next_id("entry"));
        self.append_event_with_id_and_blob_refs(
            entry_id, session_id, parent_id, run_id, kind, payload, blob_refs,
        )
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
        self.append_event_with_id_and_blob_refs(
            entry_id,
            session_id,
            parent_id,
            run_id,
            kind,
            payload,
            Vec::new(),
        )
    }

    fn append_event_with_id_and_blob_refs(
        &mut self,
        entry_id: EntryId,
        session_id: &SessionId,
        parent_id: Option<EntryId>,
        run_id: Option<RunId>,
        kind: EventKind,
        payload: impl Into<String>,
        blob_refs: Vec<String>,
    ) -> Result<EntryId, AgentError> {
        let cursor = self.sessions.get_mut(session_id).ok_or_else(|| {
            AgentError::Storage(format!("missing session cursor: {}", session_id.0))
        })?;
        let sequence = cursor.next_sequence;
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
        let event = RuntimeEvent { blob_refs, ..event };
        let audit_event_kind = format!("{:?}", event.kind);
        let audit_summary = format!("{}: {}", audit_event_kind, event.payload);
        self.store.append(event)?;
        if AuditPolicy.should_audit_event(&audit_event_kind) {
            self.store
                .write_audit(session_id, &entry_id, &audit_summary)?;
        }

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

fn approval_payload(
    approval: &ApprovalProtocolRequest,
    tool_call_id: &str,
    tool_call_entry_id: &EntryId,
) -> String {
    json!({
        "approval_id": &approval.approval_id,
        "tool_call_id": tool_call_id,
        "tool_call_entry_id": &tool_call_entry_id.0,
        "message": &approval.message,
        "requires_local_authentication": approval.requires_local_authentication,
    })
    .to_string()
}

fn approval_decision_payload(approval_id: &str, decision: &ApprovalDecision) -> String {
    json!({
        "approval_id": approval_id,
        "decision": match decision {
            ApprovalDecision::Approved => "approved",
            ApprovalDecision::Rejected => "rejected",
            ApprovalDecision::Cancelled => "cancelled",
        },
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

    let tool_call = ToolCall {
        id,
        name,
        arguments_json,
    };
    tool_call.validate_shape()?;
    Ok(tool_call)
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

fn first_line_title(payload: &str) -> String {
    let title = payload.lines().next().unwrap_or("New chat").trim();
    if title.is_empty() {
        "New chat".to_string()
    } else {
        title.chars().take(48).collect()
    }
}

fn active_provider_key() -> String {
    "active_provider".into()
}

fn build_context_controller(config: &AgentRuntimeConfig) -> ContextController {
    ContextController::new(
        config.system_prompt.clone(),
        config.runtime_policy.clone(),
        config.tool_schemas.clone(),
        config.tokenizer.boxed_clone(),
    )
}

fn persisted_provider_id<S: EventStore>(store: &S) -> Result<Option<String>, AgentError> {
    Ok(store
        .load_provider_setting(&active_provider_key())?
        .map(|setting| setting.value))
}

fn active_profile_for_config(
    config: &AgentRuntimeConfig,
    registry: &ProviderRegistry,
) -> ProviderProfile {
    registry
        .profile(config.provider.id())
        .unwrap_or_else(|| ProviderProfile {
            id: config.provider.id().to_string(),
            display_name: config.provider.id().to_string(),
            kind: ProviderKind::Mock,
            max_context_tokens: config.tokenizer.max_context_tokens(),
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::context::MockTokenizer;
    use crate::core::MockStreamingProvider;

    fn config() -> AgentRuntimeConfig {
        AgentRuntimeConfig {
            system_prompt: "system".into(),
            runtime_policy: "policy".into(),
            tool_schemas: Vec::new(),
            tokenizer: Box::new(MockTokenizer::new(100)),
            provider: Box::new(MockStreamingProvider::new()),
            tool_router: None,
        }
    }

    #[test]
    fn append_event_errors_when_session_cursor_is_missing() {
        let mut runtime = AgentRuntime::new(config());
        let session_id = runtime.create_session().unwrap();
        runtime.sessions.remove(&session_id);

        let result = runtime.append_event(
            &session_id,
            None,
            None,
            EventKind::UserMessage,
            "orphaned event",
        );

        assert!(
            matches!(result, Err(AgentError::Storage(message)) if message.contains("missing session cursor"))
        );
    }

    #[test]
    fn cancel_signals_matching_provider_cancellation_token() {
        let mut runtime = AgentRuntime::new(config());
        let session_id = runtime.create_session().unwrap();
        let run_id = RunId("run_active".to_string());
        let token = CancellationToken::default();
        runtime.runs.insert(
            run_id.clone(),
            RunRecord::new(run_id.clone(), session_id.clone()),
        );
        runtime
            .provider_cancellations
            .insert(run_id.clone(), token.clone());

        let event = runtime.cancel(run_id.0.clone()).unwrap();

        assert!(token.is_cancelled());
        assert_eq!(event.kind, EventKind::RunCancelled);
        assert!(!runtime.provider_cancellations.contains(&run_id));
    }

    #[test]
    fn conversation_summary_uses_first_user_message_as_title() {
        let mut runtime = AgentRuntime::new(config());
        let session_id = runtime.create_session().unwrap();
        runtime
            .send_message_turn(SendMessageInput {
                session_id: session_id.clone(),
                parent_event_id: None,
                text: "Hello from the first turn\nwith details".into(),
                blob_refs: Vec::new(),
            })
            .unwrap();

        let summaries = runtime.conversation_summaries().unwrap();

        assert_eq!(summaries.len(), 1);
        assert_eq!(summaries[0].session_id, session_id);
        assert_eq!(summaries[0].title, "Hello from the first turn");
        assert!(summaries[0].active_leaf_id.is_some());
        assert!(summaries[0].last_event_id.is_some());
        assert!(summaries[0].last_updated_sequence > 0);
    }

    #[test]
    fn send_message_persists_user_blob_refs_without_changing_prompt_payload() {
        let mut runtime = AgentRuntime::new(config());
        let session_id = runtime.create_session().unwrap();
        let turn = runtime
            .send_message_turn(SendMessageInput {
                session_id: session_id.clone(),
                parent_event_id: None,
                text: "hello".into(),
                blob_refs: vec!["local-agent-chat:v1:metadata".into()],
            })
            .unwrap();

        let user_event = turn
            .events
            .iter()
            .find(|event| event.kind == EventKind::UserMessage)
            .unwrap();
        assert_eq!(user_event.payload, "hello");
        assert_eq!(
            user_event.blob_refs,
            vec!["local-agent-chat:v1:metadata".to_string()]
        );
        assert!(!runtime
            .latest_prompt_debug_snapshot()
            .unwrap()
            .rendered_text
            .contains("local-agent-chat"));
    }

    #[test]
    fn active_branch_events_can_load_explicit_non_active_leaf() {
        let mut runtime = AgentRuntime::new(config());
        let session_id = runtime.create_session().unwrap();
        let first_turn = runtime
            .send_message_turn(SendMessageInput {
                session_id: session_id.clone(),
                parent_event_id: None,
                text: "root".into(),
                blob_refs: Vec::new(),
            })
            .unwrap();
        let root_user_id = first_turn
            .events
            .iter()
            .find(|event| event.kind == EventKind::UserMessage)
            .unwrap()
            .id
            .clone();
        let first_leaf_id = first_turn.events.last().unwrap().id.clone();

        runtime
            .send_message_turn(SendMessageInput {
                session_id: session_id.clone(),
                parent_event_id: Some(root_user_id),
                text: "fork".into(),
                blob_refs: Vec::new(),
            })
            .unwrap();

        let explicit_branch = runtime
            .active_branch_events(&session_id, Some(first_leaf_id))
            .unwrap();
        let active_branch = runtime.active_branch_events(&session_id, None).unwrap();

        assert!(explicit_branch.iter().any(|event| event.payload == "root"));
        assert!(!explicit_branch.iter().any(|event| event.payload == "fork"));
        assert!(active_branch.iter().any(|event| event.payload == "fork"));
    }
}
