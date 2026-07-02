use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use crate::conversation::ConversationRunFrameRef;

#[derive(Clone, Debug, Default)]
pub struct CompletedRunRegistry {
    inner: Arc<Mutex<BTreeMap<String, CompletedRunRecord>>>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CompletedRunRecord {
    run_id: String,
    final_message_id: String,
    final_text: String,
    conversation_run_frame_ref: ConversationRunFrameRef,
}

impl CompletedRunRegistry {
    pub fn record_completed(
        &self,
        run_id: &str,
        final_message_id: &str,
        frame_ref: ConversationRunFrameRef,
    ) {
        self.record_completed_with_text(run_id, final_message_id, frame_ref, final_message_id);
    }

    pub fn record_completed_with_text(
        &self,
        run_id: &str,
        final_message_id: &str,
        frame_ref: ConversationRunFrameRef,
        final_text: impl Into<String>,
    ) {
        let record = CompletedRunRecord {
            run_id: run_id.to_string(),
            final_message_id: final_message_id.to_string(),
            final_text: final_text.into(),
            conversation_run_frame_ref: frame_ref,
        };
        self.inner
            .lock()
            .expect("completed run registry poisoned")
            .insert(idempotency_key(run_id, final_message_id), record);
    }

    pub fn get(&self, run_id: &str, final_message_id: &str) -> Option<CompletedRunRecord> {
        self.inner
            .lock()
            .expect("completed run registry poisoned")
            .get(&idempotency_key(run_id, final_message_id))
            .cloned()
    }
}

impl CompletedRunRecord {
    pub fn conversation_run_frame_ref(&self) -> &ConversationRunFrameRef {
        &self.conversation_run_frame_ref
    }

    pub fn run_id(&self) -> &str {
        &self.run_id
    }

    pub fn final_message_id(&self) -> &str {
        &self.final_message_id
    }

    pub fn final_text(&self) -> &str {
        &self.final_text
    }
}

pub fn idempotency_key(run_id: &str, final_message_id: &str) -> String {
    format!("{run_id}:{final_message_id}")
}
