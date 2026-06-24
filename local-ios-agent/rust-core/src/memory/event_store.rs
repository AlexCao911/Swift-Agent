use crate::core::{AgentError, EntryId, RuntimeEvent, SessionId};
use crate::memory::ProviderSetting;

pub trait EventStore {
    fn append(&mut self, event: RuntimeEvent) -> Result<(), AgentError>;
    fn write_audit(
        &self,
        _session_id: &SessionId,
        _entry_id: &EntryId,
        _summary: &str,
    ) -> Result<(), AgentError> {
        Ok(())
    }
    fn get(&self, session_id: &SessionId, entry_id: &EntryId) -> Result<RuntimeEvent, AgentError>;
    fn active_branch(
        &self,
        session_id: &SessionId,
        leaf_id: &EntryId,
    ) -> Result<Vec<RuntimeEvent>, AgentError>;
    fn list_sessions(&self) -> Result<Vec<SessionId>, AgentError>;
    fn list_all_sessions(&self) -> Result<Vec<SessionId>, AgentError> {
        self.list_sessions()
    }
    fn active_leaf(&self, session_id: &SessionId) -> Result<Option<EntryId>, AgentError>;
    fn last_event(&self, session_id: &SessionId) -> Result<Option<RuntimeEvent>, AgentError>;
    fn rename_session(&mut self, session_id: &SessionId, title: String) -> Result<(), AgentError>;
    fn session_title_override(&self, session_id: &SessionId) -> Result<Option<String>, AgentError>;
    fn archive_session(&mut self, session_id: &SessionId) -> Result<(), AgentError>;
    fn delete_session(&mut self, session_id: &SessionId) -> Result<(), AgentError>;
    fn save_provider_setting(&mut self, setting: ProviderSetting) -> Result<(), AgentError>;
    fn load_provider_setting(&self, key: &str) -> Result<Option<ProviderSetting>, AgentError>;
}
