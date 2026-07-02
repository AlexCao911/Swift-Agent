use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use crate::core::{EntryId, RuntimeEvent, SessionId};

pub trait BranchEventReader: Clone + Send + Sync + 'static {
    fn active_branch(&self, session_id: &SessionId, branch_head_id: &EntryId) -> Vec<RuntimeEvent>;
}

#[derive(Clone, Debug, Default)]
pub struct InMemoryBranchEventReader {
    branches: Arc<Mutex<HashMap<(SessionId, EntryId), Vec<RuntimeEvent>>>>,
}

impl InMemoryBranchEventReader {
    pub fn with_branch(
        self,
        session_id: SessionId,
        branch_head_id: EntryId,
        events: Vec<RuntimeEvent>,
    ) -> Self {
        self.branches
            .lock()
            .expect("branch reader poisoned")
            .insert((session_id, branch_head_id), events);
        self
    }
}

impl BranchEventReader for InMemoryBranchEventReader {
    fn active_branch(&self, session_id: &SessionId, branch_head_id: &EntryId) -> Vec<RuntimeEvent> {
        self.branches
            .lock()
            .expect("branch reader poisoned")
            .get(&(session_id.clone(), branch_head_id.clone()))
            .cloned()
            .unwrap_or_default()
    }
}
