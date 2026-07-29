use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use super::TranscriptCommandError;

#[derive(Clone, Debug, Default)]
pub struct ActiveRunRegistry {
    inner: Arc<Mutex<HashMap<String, String>>>,
}

impl ActiveRunRegistry {
    pub fn active_run(&self, conversation_stream_id: &str) -> Option<String> {
        self.inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .get(conversation_stream_id)
            .cloned()
    }

    pub fn start(
        &self,
        conversation_stream_id: &str,
        run_id: &str,
    ) -> Result<(), TranscriptCommandError> {
        let mut active = self
            .inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if active.contains_key(conversation_stream_id) {
            return Err(TranscriptCommandError::conversation_busy(
                conversation_stream_id,
            ));
        }
        active.insert(conversation_stream_id.to_string(), run_id.to_string());
        Ok(())
    }

    pub fn complete(
        &self,
        conversation_stream_id: &str,
        run_id: &str,
    ) -> Result<(), TranscriptCommandError> {
        let mut active = self
            .inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        match active.get(conversation_stream_id) {
            Some(active_run_id) if active_run_id == run_id => {
                active.remove(conversation_stream_id);
                Ok(())
            }
            _ => Err(TranscriptCommandError::new(
                "conversation.run_not_active",
                format!("run {run_id} is not active for conversation {conversation_stream_id}"),
            )),
        }
    }
}
