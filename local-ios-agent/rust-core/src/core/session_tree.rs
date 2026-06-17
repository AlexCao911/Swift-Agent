use crate::core::{AgentError, EntryId, EventKind, RuntimeEvent, SessionId};
use crate::memory::InMemoryEventStore;
use crate::utils::id::IdGenerator;

#[derive(Debug)]
pub struct SessionTree {
    session_id: SessionId,
    store: InMemoryEventStore,
    ids: IdGenerator,
    active_leaf: Option<EntryId>,
    sequence: u64,
}

impl SessionTree {
    pub fn new(session_id: SessionId) -> Self {
        Self {
            session_id,
            store: InMemoryEventStore::new(),
            ids: IdGenerator::new(),
            active_leaf: None,
            sequence: 1,
        }
    }

    pub fn active_leaf(&self) -> Option<&EntryId> {
        self.active_leaf.as_ref()
    }

    pub fn append(
        &mut self,
        parent_id: Option<EntryId>,
        kind: EventKind,
        payload: impl Into<String>,
    ) -> Result<EntryId, AgentError> {
        let depth = match &parent_id {
            Some(parent) => self.store.get(&self.session_id, parent)?.depth + 1,
            None => 0,
        };
        let id = EntryId(self.ids.next_id("entry"));
        let event = RuntimeEvent::new(
            id.clone(),
            self.session_id.clone(),
            parent_id,
            None,
            self.sequence,
            depth,
            kind,
            payload,
        );
        self.sequence += 1;
        self.store.append(event)?;
        self.active_leaf = Some(id.clone());
        Ok(id)
    }

    pub fn active_branch(&self, leaf_id: &EntryId) -> Result<Vec<RuntimeEvent>, AgentError> {
        self.store.active_branch(&self.session_id, leaf_id)
    }
}
