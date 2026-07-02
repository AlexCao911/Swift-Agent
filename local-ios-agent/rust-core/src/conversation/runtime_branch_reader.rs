use std::sync::{Arc, Mutex};

use crate::conversation::BranchEventReader;
use crate::core::{AgentRuntime, EntryId, RuntimeEvent, SessionId};
use crate::memory::EventStore;

pub struct RuntimeBranchEventReader<S: EventStore> {
    runtime: Arc<Mutex<AgentRuntime<S>>>,
}

impl<S: EventStore> Clone for RuntimeBranchEventReader<S> {
    fn clone(&self) -> Self {
        Self {
            runtime: self.runtime.clone(),
        }
    }
}

impl<S: EventStore> RuntimeBranchEventReader<S> {
    pub fn new(runtime: Arc<Mutex<AgentRuntime<S>>>) -> Self {
        Self { runtime }
    }
}

impl<S> BranchEventReader for RuntimeBranchEventReader<S>
where
    S: EventStore + Send + 'static,
{
    fn active_branch(&self, session_id: &SessionId, branch_head_id: &EntryId) -> Vec<RuntimeEvent> {
        self.runtime
            .lock()
            .expect("runtime branch reader poisoned")
            .active_branch_events(session_id, Some(branch_head_id.clone()))
            .expect("failed to load active conversation branch")
    }
}
