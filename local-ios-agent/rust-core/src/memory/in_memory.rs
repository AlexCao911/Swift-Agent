use std::collections::{HashMap, HashSet};

use crate::core::{AgentError, EntryId, RuntimeEvent, SessionId};

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
}

impl InMemoryEventStore {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn append(&mut self, event: RuntimeEvent) -> Result<(), AgentError> {
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

    pub fn get(
        &self,
        session_id: &SessionId,
        entry_id: &EntryId,
    ) -> Result<RuntimeEvent, AgentError> {
        self.events
            .get(&(session_id.clone(), entry_id.clone()))
            .cloned()
            .ok_or_else(|| AgentError::Storage(format!("event not found: {}", entry_id.0)))
    }

    pub fn active_branch(
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
