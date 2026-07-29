use crate::core::{AgentError, EntryId, RuntimeEvent, SessionId};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StoredTranscriptCommandReceipt {
    pub conversation_stream_id: String,
    pub request_id: String,
    pub command_digest: String,
    pub outcome_json: String,
}

pub trait ConversationEventStore {
    fn append(&mut self, event: RuntimeEvent) -> Result<(), AgentError>;
    fn append_transaction(
        &mut self,
        conversation_stream_id: &str,
        expected_next_sequence: u64,
        events: Vec<RuntimeEvent>,
    ) -> Result<Vec<RuntimeEvent>, AgentError>;
    fn events_after(
        &self,
        session_id: &SessionId,
        after_sequence: u64,
    ) -> Result<Vec<RuntimeEvent>, AgentError>;
    fn command_receipt(
        &self,
        conversation_stream_id: &str,
        request_id: &str,
    ) -> Result<Option<StoredTranscriptCommandReceipt>, AgentError>;
    fn commit_command(
        &mut self,
        conversation_stream_id: &str,
        expected_next_sequence: u64,
        events: Vec<RuntimeEvent>,
        receipt: StoredTranscriptCommandReceipt,
    ) -> Result<Vec<RuntimeEvent>, AgentError>;
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
}
