use crate::core::{AgentError, EntryId, RuntimeEvent, SessionId};

pub trait EventStore {
    fn append(&mut self, event: RuntimeEvent) -> Result<(), AgentError>;
    fn get(&self, session_id: &SessionId, entry_id: &EntryId) -> Result<RuntimeEvent, AgentError>;
    fn active_branch(
        &self,
        session_id: &SessionId,
        leaf_id: &EntryId,
    ) -> Result<Vec<RuntimeEvent>, AgentError>;
}
