use std::collections::{HashMap, HashSet};

use crate::core::{AgentError, EntryId, RuntimeEvent, SessionId};
use crate::memory::{EventStore, ProviderSetting};

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

#[derive(Debug, Default)]
pub struct InMemoryEventStore {
    events: HashMap<(SessionId, EntryId), RuntimeEvent>,
    paths: Vec<PathRow>,
    children: HashMap<(SessionId, EntryId), HashSet<EntryId>>,
    provider_settings: HashMap<String, ProviderSetting>,
}

impl InMemoryEventStore {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn append(&mut self, event: RuntimeEvent) -> Result<(), AgentError> {
        <Self as EventStore>::append(self, event)
    }

    pub fn get(
        &self,
        session_id: &SessionId,
        entry_id: &EntryId,
    ) -> Result<RuntimeEvent, AgentError> {
        <Self as EventStore>::get(self, session_id, entry_id)
    }

    pub fn active_branch(
        &self,
        session_id: &SessionId,
        leaf_id: &EntryId,
    ) -> Result<Vec<RuntimeEvent>, AgentError> {
        <Self as EventStore>::active_branch(self, session_id, leaf_id)
    }

    pub fn list_sessions(&self) -> Result<Vec<SessionId>, AgentError> {
        <Self as EventStore>::list_sessions(self)
    }

    pub fn active_leaf(&self, session_id: &SessionId) -> Result<Option<EntryId>, AgentError> {
        <Self as EventStore>::active_leaf(self, session_id)
    }

    pub fn last_event(&self, session_id: &SessionId) -> Result<Option<RuntimeEvent>, AgentError> {
        <Self as EventStore>::last_event(self, session_id)
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

impl EventStore for InMemoryEventStore {
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

    fn save_provider_setting(&mut self, setting: ProviderSetting) -> Result<(), AgentError> {
        self.provider_settings.insert(setting.key.clone(), setting);
        Ok(())
    }

    fn load_provider_setting(&self, key: &str) -> Result<Option<ProviderSetting>, AgentError> {
        Ok(self.provider_settings.get(key).cloned())
    }
}
