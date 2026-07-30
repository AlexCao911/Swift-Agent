use std::sync::{Arc, Mutex, MutexGuard};

use crate::core::{AgentError, AgentRuntime, EntryId, RuntimeEvent, SessionId};
use crate::storage::{ConversationEventStore, StoredTranscriptCommandReceipt};

pub struct RuntimeConversationStore<S: ConversationEventStore> {
    runtime: Arc<Mutex<AgentRuntime<S>>>,
}

impl<S: ConversationEventStore> RuntimeConversationStore<S> {
    pub fn new(runtime: Arc<Mutex<AgentRuntime<S>>>) -> Self {
        Self { runtime }
    }

    fn runtime(&self) -> Result<MutexGuard<'_, AgentRuntime<S>>, AgentError> {
        self.runtime
            .lock()
            .map_err(|_| AgentError::Storage("runtime conversation store lock poisoned".into()))
    }
}

impl<S: ConversationEventStore> ConversationEventStore for RuntimeConversationStore<S> {
    fn append(&mut self, event: RuntimeEvent) -> Result<(), AgentError> {
        self.runtime()?.conversation_store_mut().append(event)
    }

    fn append_transaction(
        &mut self,
        conversation_stream_id: &str,
        expected_next_sequence: u64,
        events: Vec<RuntimeEvent>,
    ) -> Result<Vec<RuntimeEvent>, AgentError> {
        self.runtime()?.conversation_store_mut().append_transaction(
            conversation_stream_id,
            expected_next_sequence,
            events,
        )
    }

    fn events_after(
        &self,
        session_id: &SessionId,
        after_sequence: u64,
    ) -> Result<Vec<RuntimeEvent>, AgentError> {
        self.runtime()?
            .conversation_store()
            .events_after(session_id, after_sequence)
    }

    fn command_receipt(
        &self,
        conversation_stream_id: &str,
        request_id: &str,
    ) -> Result<Option<StoredTranscriptCommandReceipt>, AgentError> {
        self.runtime()?
            .conversation_store()
            .command_receipt(conversation_stream_id, request_id)
    }

    fn commit_command(
        &mut self,
        conversation_stream_id: &str,
        expected_next_sequence: u64,
        events: Vec<RuntimeEvent>,
        receipt: StoredTranscriptCommandReceipt,
    ) -> Result<Vec<RuntimeEvent>, AgentError> {
        self.runtime()?.conversation_store_mut().commit_command(
            conversation_stream_id,
            expected_next_sequence,
            events,
            receipt,
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn commit_branch_command(
        &mut self,
        source_stream_id: &str,
        source_expected_next_sequence: u64,
        source_events: Vec<RuntimeEvent>,
        receipt: StoredTranscriptCommandReceipt,
        target_stream_id: &str,
        target_expected_next_sequence: u64,
        target_events: Vec<RuntimeEvent>,
    ) -> Result<Vec<RuntimeEvent>, AgentError> {
        self.runtime()?
            .conversation_store_mut()
            .commit_branch_command(
                source_stream_id,
                source_expected_next_sequence,
                source_events,
                receipt,
                target_stream_id,
                target_expected_next_sequence,
                target_events,
            )
    }

    fn write_audit(
        &self,
        session_id: &SessionId,
        entry_id: &EntryId,
        summary: &str,
    ) -> Result<(), AgentError> {
        self.runtime()?
            .conversation_store()
            .write_audit(session_id, entry_id, summary)
    }

    fn get(&self, session_id: &SessionId, entry_id: &EntryId) -> Result<RuntimeEvent, AgentError> {
        self.runtime()?
            .conversation_store()
            .get(session_id, entry_id)
    }

    fn active_branch(
        &self,
        session_id: &SessionId,
        leaf_id: &EntryId,
    ) -> Result<Vec<RuntimeEvent>, AgentError> {
        self.runtime()?
            .conversation_store()
            .active_branch(session_id, leaf_id)
    }

    fn list_sessions(&self) -> Result<Vec<SessionId>, AgentError> {
        self.runtime()?.conversation_store().list_sessions()
    }

    fn list_all_sessions(&self) -> Result<Vec<SessionId>, AgentError> {
        self.runtime()?.conversation_store().list_all_sessions()
    }

    fn active_leaf(&self, session_id: &SessionId) -> Result<Option<EntryId>, AgentError> {
        self.runtime()?.conversation_store().active_leaf(session_id)
    }

    fn last_event(&self, session_id: &SessionId) -> Result<Option<RuntimeEvent>, AgentError> {
        self.runtime()?.conversation_store().last_event(session_id)
    }

    fn rename_session(&mut self, session_id: &SessionId, title: String) -> Result<(), AgentError> {
        self.runtime()?
            .conversation_store_mut()
            .rename_session(session_id, title)
    }

    fn session_title_override(&self, session_id: &SessionId) -> Result<Option<String>, AgentError> {
        self.runtime()?
            .conversation_store()
            .session_title_override(session_id)
    }

    fn archive_session(&mut self, session_id: &SessionId) -> Result<(), AgentError> {
        self.runtime()?
            .conversation_store_mut()
            .archive_session(session_id)
    }

    fn delete_session(&mut self, session_id: &SessionId) -> Result<(), AgentError> {
        self.runtime()?
            .conversation_store_mut()
            .delete_session(session_id)
    }
}
