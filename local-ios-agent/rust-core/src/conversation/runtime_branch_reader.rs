use std::sync::{Arc, Mutex};

use crate::conversation::BranchEventReader;
use crate::core::{AgentError, AgentRuntime, EntryId, RuntimeEvent, SessionId};
use crate::storage::ConversationEventStore;

pub struct RuntimeBranchEventReader<S: ConversationEventStore> {
    runtime: Arc<Mutex<AgentRuntime<S>>>,
}

impl<S: ConversationEventStore> Clone for RuntimeBranchEventReader<S> {
    fn clone(&self) -> Self {
        Self {
            runtime: self.runtime.clone(),
        }
    }
}

impl<S: ConversationEventStore> RuntimeBranchEventReader<S> {
    pub fn new(runtime: Arc<Mutex<AgentRuntime<S>>>) -> Self {
        Self { runtime }
    }
}

impl<S> BranchEventReader for RuntimeBranchEventReader<S>
where
    S: ConversationEventStore + Send + 'static,
{
    fn active_branch(
        &self,
        session_id: &SessionId,
        branch_head_id: Option<&EntryId>,
    ) -> Result<(Option<EntryId>, Vec<RuntimeEvent>), AgentError> {
        let events = self
            .runtime
            .lock()
            .map_err(|_| AgentError::Ffi("runtime branch reader lock poisoned".into()))?
            .active_branch_events(session_id, branch_head_id.cloned())?;
        let resolved_head = events.last().map(|event| event.id.clone());
        Ok((resolved_head, events))
    }
}
