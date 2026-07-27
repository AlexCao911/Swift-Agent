use std::collections::HashMap;

use crate::conversation::ConversationRunFrameRef;
use crate::core::{AgentError, EntryId, EventKind, RunId, RuntimeEvent, SessionCursor, SessionId};
use crate::execution::{ExecutionToolObservation, ExecutionToolOutcome};
use crate::memory::{EventStore, InMemoryEventStore};
use crate::security::{
    ApprovalDecision, ApprovalProtocolRequest, ApprovalProtocolResponse, AuditPolicy,
    PermissionScope,
};
use crate::tool::{
    ToolCall, ToolExecutionRequest, ToolRegistry, ToolRouteOutcome, ToolRouter, ToolSchema,
};
use crate::utils::id::IdGenerator;

pub struct AgentRuntimeConfig {
    pub tool_router: Option<ToolRouter>,
}

impl Default for AgentRuntimeConfig {
    fn default() -> Self {
        Self { tool_router: None }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PreparedConversationUserTurn {
    pub session_id: SessionId,
    pub parent_event_id: Option<EntryId>,
    pub user_turn_id: EntryId,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ExecutionApprovalResolution {
    pub run_id: RunId,
    pub approved_tool_call_id: Option<String>,
    pub approved: bool,
    pub message: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ConversationSummary {
    pub session_id: SessionId,
    pub title: String,
    pub search_text: String,
    pub active_leaf_id: Option<EntryId>,
    pub last_event_id: Option<EntryId>,
    pub last_updated_sequence: u64,
    pub last_updated_at_millis: u64,
}

const ROOT_PARENT_EVENT_ID: &str = "__local_agent_root__";

pub struct AgentRuntime<S: EventStore = InMemoryEventStore> {
    ids: IdGenerator,
    store: S,
    sessions: HashMap<SessionId, SessionCursor>,
    tool_router: Option<ToolRouter>,
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
        Self::open_without_replay(config, store)
    }

    pub(crate) fn open_without_replay(
        config: AgentRuntimeConfig,
        store: S,
    ) -> Result<Self, AgentError> {
        let mut sessions = HashMap::new();
        for session_id in store.list_all_sessions()? {
            let cursor =
                SessionCursor::from_last_event(session_id.clone(), store.last_event(&session_id)?);
            sessions.insert(session_id, cursor);
        }
        let session_ids: Vec<_> = sessions.keys().cloned().collect();
        let next_id = next_replayed_id(&store, &session_ids)?;
        Ok(Self {
            ids: IdGenerator::starting_at(next_id),
            store,
            sessions,
            tool_router: config.tool_router,
            pending_tool_requests: Vec::new(),
        })
    }

    pub(crate) fn replay_provider_independent_state(&mut self) -> Result<(), AgentError> {
        Ok(())
    }

    pub fn pending_tool_requests(&self) -> &[ToolExecutionRequest] {
        &self.pending_tool_requests
    }

    pub fn consume_execution_pending_tool_request(
        &mut self,
        run_id: &RunId,
    ) -> Result<ToolExecutionRequest, AgentError> {
        let index = self
            .pending_tool_requests
            .iter()
            .position(|request| request.run_id() == run_id)
            .ok_or_else(|| {
                AgentError::ToolExecution(format!(
                    "missing pending execution tool request for run: {}",
                    run_id.0
                ))
            })?;
        Ok(self.pending_tool_requests.remove(index))
    }

    pub fn route_execution_tool_call(
        &mut self,
        run_id: &RunId,
        session_id: &SessionId,
        call: ToolCall,
    ) -> Result<ExecutionToolOutcome, AgentError> {
        let call_id = call.id.clone();
        let entry_id = EntryId(format!("execution_tool_call_{call_id}"));
        let router = self
            .tool_router
            .as_mut()
            .ok_or_else(|| AgentError::ToolValidation("no tool router configured".into()))?;
        match router.route(run_id, session_id, &entry_id, call)? {
            ToolRouteOutcome::ExecuteInSwift(request) => {
                let call_id = request.tool_call_id().to_string();
                self.pending_tool_requests.push(request);
                Ok(ExecutionToolOutcome::PendingHostTool { call_id })
            }
            ToolRouteOutcome::ApprovalRequired {
                request,
                approval: _,
                reason,
            } => Ok(ExecutionToolOutcome::ApprovalRequired {
                call_id: request.tool_call_id().to_string(),
                reason,
            }),
            ToolRouteOutcome::Denied(result) => Ok(ExecutionToolOutcome::Observation(
                ExecutionToolObservation {
                    call_id,
                    model_text: result.model_text,
                },
            )),
        }
    }

    pub fn register_tool(&mut self, schema: ToolSchema) -> Result<(), AgentError> {
        let router = self
            .tool_router
            .get_or_insert_with(|| ToolRouter::new(ToolRegistry::new()));
        router.register(schema)
    }

    pub fn set_permission(&mut self, permission: PermissionScope) {
        self.tool_router
            .get_or_insert_with(|| ToolRouter::new(ToolRegistry::new()))
            .set_permission(permission);
    }

    pub fn pending_approval_requests(&self) -> Vec<ApprovalProtocolRequest> {
        self.tool_router
            .as_ref()
            .map(ToolRouter::pending_approval_requests)
            .unwrap_or_default()
    }

    pub fn approve_execution_tool_request(
        &mut self,
        response: ApprovalProtocolResponse,
    ) -> Result<ExecutionApprovalResolution, AgentError> {
        let (approval, decision, tool_request) = self
            .tool_router
            .as_mut()
            .ok_or_else(|| AgentError::PolicyDenied("no tool router configured".into()))?
            .resolve_approval(response)?;
        match decision {
            ApprovalDecision::Approved => {
                let request = tool_request.ok_or_else(|| {
                    AgentError::PolicyDenied(format!(
                        "approved tool request missing for approval: {}",
                        approval.approval_id
                    ))
                })?;
                let run_id = request.run_id().clone();
                let call_id = request.tool_call_id().to_string();
                self.pending_tool_requests.push(request);
                Ok(ExecutionApprovalResolution {
                    run_id,
                    approved_tool_call_id: Some(call_id),
                    approved: true,
                    message: approval.message,
                })
            }
            ApprovalDecision::Rejected | ApprovalDecision::Cancelled => {
                Ok(ExecutionApprovalResolution {
                    run_id: approval.run_id,
                    approved_tool_call_id: None,
                    approved: false,
                    message: approval.message,
                })
            }
        }
    }

    pub fn session_ids(&self) -> Result<Vec<SessionId>, AgentError> {
        self.store.list_sessions()
    }

    pub fn conversation_summaries(&self) -> Result<Vec<ConversationSummary>, AgentError> {
        let mut summaries = Vec::new();
        for session_id in self.session_ids()? {
            let active_leaf_id = self.store.active_leaf(&session_id)?;
            let last_event = self.store.last_event(&session_id)?;
            let Some(leaf_id) = &active_leaf_id else {
                continue;
            };
            let branch = self.store.active_branch(&session_id, leaf_id)?;
            let search_text = conversation_search_text(&branch);
            let Some(first_user_event) = branch
                .iter()
                .find(|event| event.kind == EventKind::UserMessage)
            else {
                continue;
            };
            let title = self
                .store
                .session_title_override(&session_id)?
                .filter(|title| !title.trim().is_empty())
                .unwrap_or_else(|| first_line_title(&first_user_event.payload));
            let last_updated_sequence = last_event
                .as_ref()
                .and_then(|event| numeric_suffix(&event.id.0))
                .unwrap_or_else(|| last_event.as_ref().map(|event| event.sequence).unwrap_or(0));
            let last_updated_at_millis = last_event
                .as_ref()
                .map(|event| event.created_at_millis)
                .unwrap_or(0);
            summaries.push(ConversationSummary {
                session_id,
                title,
                search_text,
                active_leaf_id,
                last_event_id: last_event.as_ref().map(|event| event.id.clone()),
                last_updated_sequence,
                last_updated_at_millis,
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

    pub fn archive_session(&mut self, session_id: &SessionId) -> Result<(), AgentError> {
        self.store.archive_session(session_id)?;
        self.sessions.remove(session_id);
        Ok(())
    }

    pub fn rename_session(
        &mut self,
        session_id: &SessionId,
        title: String,
    ) -> Result<(), AgentError> {
        let title = title.trim();
        if title.is_empty() {
            return Err(AgentError::Storage(
                "conversation title cannot be empty".into(),
            ));
        }
        self.store.rename_session(session_id, title.to_string())
    }

    pub fn delete_session(&mut self, session_id: &SessionId) -> Result<(), AgentError> {
        self.store.delete_session(session_id)?;
        self.sessions.remove(session_id);
        self.pending_tool_requests
            .retain(|request| request.session_id() != session_id);
        Ok(())
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

    pub fn prepare_conversation_user_turn(
        &mut self,
        session_id: Option<SessionId>,
        parent_event_id: Option<EntryId>,
        text: impl Into<String>,
        blob_refs: Vec<String>,
    ) -> Result<PreparedConversationUserTurn, AgentError> {
        let session_id = match session_id {
            Some(session_id) if self.sessions.contains_key(&session_id) => session_id,
            Some(session_id) => {
                return Err(AgentError::Storage(format!(
                    "missing session: {}",
                    session_id.0
                )))
            }
            None => self.create_session()?,
        };
        let parent_event_id = match parent_event_id {
            Some(parent_event_id) if parent_event_id.0 == ROOT_PARENT_EVENT_ID => None,
            Some(parent_event_id) => Some(parent_event_id),
            None => self.store.active_leaf(&session_id)?,
        };
        let user_turn_id = self.append_event_with_blob_refs(
            &session_id,
            parent_event_id.clone(),
            None,
            EventKind::UserMessage,
            text,
            blob_refs,
        )?;
        Ok(PreparedConversationUserTurn {
            session_id,
            parent_event_id,
            user_turn_id,
        })
    }

    pub fn commit_conversation_assistant_result(
        &mut self,
        frame_ref: &ConversationRunFrameRef,
        run_id: &str,
        content: impl Into<String>,
    ) -> Result<EntryId, AgentError> {
        self.append_event(
            frame_ref.session_id(),
            Some(frame_ref.user_turn_id().clone()),
            Some(RunId(run_id.to_string())),
            EventKind::AssistantMessageCompleted,
            content,
        )
    }

    pub fn fork_session(
        &mut self,
        source_session_id: &SessionId,
        leaf_id: &EntryId,
    ) -> Result<SessionId, AgentError> {
        let source_branch = self.store.active_branch(source_session_id, leaf_id)?;
        let target_session_id = self.create_session()?;
        let target_root_id = self.store.active_leaf(&target_session_id)?.ok_or_else(|| {
            AgentError::Storage(format!(
                "new fork session has no root event: {}",
                target_session_id.0
            ))
        })?;
        let mut copied_ids = HashMap::new();
        for event in source_branch {
            if event.kind == EventKind::SessionCreated {
                copied_ids.insert(event.id, target_root_id.clone());
                continue;
            }
            let target_id = EntryId(self.ids.next_id("entry"));
            let parent_id = event
                .parent_id
                .as_ref()
                .and_then(|parent_id| copied_ids.get(parent_id).cloned());
            self.append_event_with_id_and_blob_refs(
                target_id.clone(),
                &target_session_id,
                parent_id,
                None,
                event.kind,
                event.payload,
                event.blob_refs,
            )?;
            copied_ids.insert(event.id, target_id);
        }
        Ok(target_session_id)
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
        let event = RuntimeEvent {
            blob_refs,
            ..RuntimeEvent::new(
                entry_id.clone(),
                session_id.clone(),
                parent_id,
                run_id,
                sequence,
                depth,
                kind,
                payload,
            )
        };
        let audit_kind = format!("{:?}", event.kind);
        let audit_summary = format!("{audit_kind}: {}", event.payload);
        self.store.append(event)?;
        if AuditPolicy.should_audit_event(&audit_kind) {
            self.store
                .write_audit(session_id, &entry_id, &audit_summary)?;
        }
        cursor.active_leaf = Some(entry_id.clone());
        cursor.next_sequence = sequence + 1;
        Ok(entry_id)
    }
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
        for event in store.active_branch(session_id, &active_leaf_id)? {
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

fn conversation_search_text(events: &[RuntimeEvent]) -> String {
    events
        .iter()
        .filter(|event| {
            matches!(
                event.kind,
                EventKind::UserMessage
                    | EventKind::AssistantTextDelta
                    | EventKind::AssistantMessageCompleted
                    | EventKind::ToolResultMessage
                    | EventKind::CompactionCreated
                    | EventKind::BranchSummaryCreated
            )
        })
        .map(|event| event.payload.as_str())
        .collect::<Vec<_>>()
        .join("\n")
}
