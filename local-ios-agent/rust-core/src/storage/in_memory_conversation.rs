use std::collections::{HashMap, HashSet};

use crate::core::{AgentError, EntryId, RuntimeEvent, SessionId};
use crate::storage::conversation_event_store::{
    ConversationEventStore, StoredTranscriptCommandReceipt,
};

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
struct PathKey {
    session_id: SessionId,
    ancestor_id: EntryId,
    descendant_id: EntryId,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct PathRow {
    key: PathKey,
    depth_delta: u32,
}

#[derive(Clone, Debug, Default)]
pub struct InMemoryConversationStore {
    events: HashMap<(SessionId, EntryId), RuntimeEvent>,
    paths: Vec<PathRow>,
    children: HashMap<(SessionId, EntryId), HashSet<EntryId>>,
    archived_sessions: HashSet<SessionId>,
    session_title_overrides: HashMap<SessionId, String>,
    command_receipts: HashMap<(SessionId, String), StoredTranscriptCommandReceipt>,
}

impl InMemoryConversationStore {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn append(&mut self, event: RuntimeEvent) -> Result<(), AgentError> {
        <Self as ConversationEventStore>::append(self, event)
    }

    pub fn get(
        &self,
        session_id: &SessionId,
        entry_id: &EntryId,
    ) -> Result<RuntimeEvent, AgentError> {
        <Self as ConversationEventStore>::get(self, session_id, entry_id)
    }

    pub fn active_branch(
        &self,
        session_id: &SessionId,
        leaf_id: &EntryId,
    ) -> Result<Vec<RuntimeEvent>, AgentError> {
        <Self as ConversationEventStore>::active_branch(self, session_id, leaf_id)
    }

    pub fn list_sessions(&self) -> Result<Vec<SessionId>, AgentError> {
        <Self as ConversationEventStore>::list_sessions(self)
    }

    pub fn active_leaf(&self, session_id: &SessionId) -> Result<Option<EntryId>, AgentError> {
        <Self as ConversationEventStore>::active_leaf(self, session_id)
    }

    pub fn last_event(&self, session_id: &SessionId) -> Result<Option<RuntimeEvent>, AgentError> {
        <Self as ConversationEventStore>::last_event(self, session_id)
    }

    pub fn rename_session(
        &mut self,
        session_id: &SessionId,
        title: String,
    ) -> Result<(), AgentError> {
        <Self as ConversationEventStore>::rename_session(self, session_id, title)
    }

    pub fn session_title_override(
        &self,
        session_id: &SessionId,
    ) -> Result<Option<String>, AgentError> {
        <Self as ConversationEventStore>::session_title_override(self, session_id)
    }

    fn insert_paths(&mut self, event: &RuntimeEvent) {
        self.paths.push(PathRow {
            key: PathKey {
                session_id: event.session_id.clone(),
                ancestor_id: event.id.clone(),
                descendant_id: event.id.clone(),
            },
            depth_delta: 0,
        });

        if let Some(parent_id) = &event.parent_id {
            let parent_rows: Vec<_> = self
                .paths
                .iter()
                .filter(|row| {
                    row.key.session_id == event.session_id && row.key.descendant_id == *parent_id
                })
                .cloned()
                .collect();

            for row in parent_rows {
                self.paths.push(PathRow {
                    key: PathKey {
                        session_id: event.session_id.clone(),
                        ancestor_id: row.key.ancestor_id,
                        descendant_id: event.id.clone(),
                    },
                    depth_delta: row.depth_delta + 1,
                });
            }
        }
    }
}

impl ConversationEventStore for InMemoryConversationStore {
    fn append(&mut self, event: RuntimeEvent) -> Result<(), AgentError> {
        let key = (event.session_id.clone(), event.id.clone());
        if self.events.contains_key(&key) {
            return Err(AgentError::Storage(format!(
                "event already exists: {}",
                event.id.0
            )));
        }

        if let Some(parent_id) = &event.parent_id {
            let parent_key = (event.session_id.clone(), parent_id.clone());
            if !self.events.contains_key(&parent_key) {
                return Err(AgentError::Storage(format!(
                    "missing parent event: {}",
                    parent_id.0
                )));
            }
        }

        self.insert_paths(&event);

        if let Some(parent_id) = &event.parent_id {
            self.children
                .entry((event.session_id.clone(), parent_id.clone()))
                .or_default()
                .insert(event.id.clone());
        }

        self.events.insert(key, event);
        Ok(())
    }

    fn append_transaction(
        &mut self,
        conversation_stream_id: &str,
        expected_next_sequence: u64,
        events: Vec<RuntimeEvent>,
    ) -> Result<Vec<RuntimeEvent>, AgentError> {
        let session_id = SessionId(conversation_stream_id.to_string());
        let actual_next_sequence = self
            .last_event(&session_id)?
            .map(|event| event.sequence + 1)
            .unwrap_or(1);
        if actual_next_sequence != expected_next_sequence {
            return Err(AgentError::Storage(format!(
                "conversation sequence conflict: expected {expected_next_sequence}, actual {actual_next_sequence}"
            )));
        }

        let backup = self.clone();
        let mut committed = Vec::with_capacity(events.len());
        for (offset, mut event) in events.into_iter().enumerate() {
            if event.session_id != session_id {
                *self = backup;
                return Err(AgentError::Storage(
                    "conversation transaction mixed stream identifiers".into(),
                ));
            }
            event.sequence = expected_next_sequence + offset as u64;
            if let Err(error) = self.append(event.clone()) {
                *self = backup;
                return Err(error);
            }
            committed.push(event);
        }
        Ok(committed)
    }

    fn events_after(
        &self,
        session_id: &SessionId,
        after_sequence: u64,
    ) -> Result<Vec<RuntimeEvent>, AgentError> {
        let mut events = self
            .events
            .values()
            .filter(|event| event.session_id == *session_id && event.sequence > after_sequence)
            .cloned()
            .collect::<Vec<_>>();
        events.sort_by_key(|event| event.sequence);
        Ok(events)
    }

    fn command_receipt(
        &self,
        conversation_stream_id: &str,
        request_id: &str,
    ) -> Result<Option<StoredTranscriptCommandReceipt>, AgentError> {
        Ok(self
            .command_receipts
            .get(&(
                SessionId(conversation_stream_id.to_string()),
                request_id.to_string(),
            ))
            .cloned())
    }

    fn commit_command(
        &mut self,
        conversation_stream_id: &str,
        expected_next_sequence: u64,
        events: Vec<RuntimeEvent>,
        receipt: StoredTranscriptCommandReceipt,
    ) -> Result<Vec<RuntimeEvent>, AgentError> {
        let key = (
            SessionId(conversation_stream_id.to_string()),
            receipt.request_id.clone(),
        );
        if self.command_receipts.contains_key(&key) {
            return Err(AgentError::Storage(
                "conversation command receipt already exists".into(),
            ));
        }
        let backup = self.clone();
        match self.append_transaction(conversation_stream_id, expected_next_sequence, events) {
            Ok(committed) => {
                self.command_receipts.insert(key, receipt);
                Ok(committed)
            }
            Err(error) => {
                *self = backup;
                Err(error)
            }
        }
    }

    fn get(&self, session_id: &SessionId, entry_id: &EntryId) -> Result<RuntimeEvent, AgentError> {
        self.events
            .get(&(session_id.clone(), entry_id.clone()))
            .cloned()
            .ok_or_else(|| AgentError::Storage(format!("event not found: {}", entry_id.0)))
    }

    fn active_branch(
        &self,
        session_id: &SessionId,
        leaf_id: &EntryId,
    ) -> Result<Vec<RuntimeEvent>, AgentError> {
        let mut rows: Vec<_> = self
            .paths
            .iter()
            .filter(|row| row.key.session_id == *session_id && row.key.descendant_id == *leaf_id)
            .collect();

        if rows.is_empty() {
            return Err(AgentError::Storage(format!(
                "leaf has no path rows: {}",
                leaf_id.0
            )));
        }

        rows.sort_by_key(|row| row.depth_delta);
        rows.reverse();

        let mut events = Vec::with_capacity(rows.len());
        for row in rows {
            events.push(self.get(session_id, &row.key.ancestor_id)?);
        }
        events.sort_by_key(|event| (event.depth, event.sequence));
        Ok(events)
    }

    fn list_sessions(&self) -> Result<Vec<SessionId>, AgentError> {
        let mut sessions: Vec<_> = self
            .events
            .keys()
            .map(|(session_id, _)| session_id.clone())
            .collect::<HashSet<_>>()
            .into_iter()
            .filter(|session_id| !self.archived_sessions.contains(session_id))
            .collect();
        sessions.sort_by(|left, right| left.0.cmp(&right.0));
        Ok(sessions)
    }

    fn active_leaf(&self, session_id: &SessionId) -> Result<Option<EntryId>, AgentError> {
        Ok(self.last_event(session_id)?.map(|event| event.id))
    }

    fn last_event(&self, session_id: &SessionId) -> Result<Option<RuntimeEvent>, AgentError> {
        Ok(self
            .events
            .values()
            .filter(|event| event.session_id == *session_id)
            .max_by_key(|event| event.sequence)
            .cloned())
    }

    fn rename_session(&mut self, session_id: &SessionId, title: String) -> Result<(), AgentError> {
        if !self
            .events
            .keys()
            .any(|(event_session_id, _)| event_session_id == session_id)
        {
            return Err(AgentError::Storage(format!(
                "session not found: {}",
                session_id.0
            )));
        }
        self.session_title_overrides
            .insert(session_id.clone(), title);
        Ok(())
    }

    fn session_title_override(&self, session_id: &SessionId) -> Result<Option<String>, AgentError> {
        Ok(self.session_title_overrides.get(session_id).cloned())
    }

    fn archive_session(&mut self, session_id: &SessionId) -> Result<(), AgentError> {
        if !self
            .events
            .keys()
            .any(|(event_session_id, _)| event_session_id == session_id)
        {
            return Err(AgentError::Storage(format!(
                "session not found: {}",
                session_id.0
            )));
        }
        self.archived_sessions.insert(session_id.clone());
        Ok(())
    }

    fn delete_session(&mut self, session_id: &SessionId) -> Result<(), AgentError> {
        self.events
            .retain(|(event_session_id, _), _| event_session_id != session_id);
        self.paths.retain(|row| row.key.session_id != *session_id);
        self.children
            .retain(|(child_session_id, _), _| child_session_id != session_id);
        self.archived_sessions.remove(session_id);
        self.session_title_overrides.remove(session_id);
        Ok(())
    }
}
