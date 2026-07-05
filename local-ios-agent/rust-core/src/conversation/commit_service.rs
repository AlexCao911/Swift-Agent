use std::collections::BTreeMap;
use std::fmt;
use std::sync::{Arc, Mutex};

use crate::conversation::ConversationRunFrameRef;
use crate::execution::{idempotency_key, CompletedRunRecord, CompletedRunRegistry};

#[derive(Clone, Debug)]
pub struct ConversationCommitService {
    completed_runs: CompletedRunRegistry,
    commits: Arc<Mutex<BTreeMap<String, AssistantCommitRecord>>>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AssistantCommitRecord {
    assistant_message_id: String,
    already_committed: bool,
    conversation_run_frame_ref: ConversationRunFrameRef,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ConversationCommitError {
    code: String,
    message: String,
}

impl ConversationCommitService {
    pub fn new(completed_runs: CompletedRunRegistry) -> Self {
        Self {
            completed_runs,
            commits: Arc::new(Mutex::new(BTreeMap::new())),
        }
    }

    pub fn commit_assistant_result(
        &self,
        run_id: &str,
        final_message_id: &str,
        expected_frame_ref: &ConversationRunFrameRef,
    ) -> Result<AssistantCommitRecord, ConversationCommitError> {
        self.commit_assistant_result_with_persist(
            run_id,
            final_message_id,
            expected_frame_ref,
            |completed| {
                Ok(format!(
                    "assistant.{}.{}",
                    completed.run_id(),
                    completed.final_message_id()
                ))
            },
        )
    }

    pub fn commit_assistant_result_with_persist(
        &self,
        run_id: &str,
        final_message_id: &str,
        expected_frame_ref: &ConversationRunFrameRef,
        persist: impl FnOnce(&CompletedRunRecord) -> Result<String, ConversationCommitError>,
    ) -> Result<AssistantCommitRecord, ConversationCommitError> {
        let key = idempotency_key(run_id, final_message_id);
        let mut commits = self.commits.lock().map_err(|_| {
            ConversationCommitError::new(
                "conversation_commit.lock_poisoned",
                "conversation commit state lock poisoned",
            )
        })?;
        if let Some(existing) = commits.get(&key) {
            if existing.conversation_run_frame_ref() != expected_frame_ref {
                return Err(ConversationCommitError::new(
                    "conversation_commit.frame_ref_mismatch",
                    format!("commit frame ref did not match existing commit for {key}"),
                ));
            }

            let mut record = existing.clone();
            record.already_committed = true;
            return Ok(record);
        }

        let completed = self
            .completed_runs
            .get(run_id, final_message_id)
            .ok_or_else(|| {
                ConversationCommitError::new(
                    "conversation_commit.completed_run_missing",
                    format!("completed run not found for {key}"),
                )
            })?;
        if completed.conversation_run_frame_ref() != expected_frame_ref {
            return Err(ConversationCommitError::new(
                "conversation_commit.frame_ref_mismatch",
                format!("completed run frame ref did not match commit request for {key}"),
            ));
        }

        let assistant_message_id = persist(&completed)?;
        let record = AssistantCommitRecord {
            assistant_message_id,
            already_committed: false,
            conversation_run_frame_ref: completed.conversation_run_frame_ref().clone(),
        };
        commits.insert(key, record.clone());
        Ok(record)
    }

    pub fn commit_count(&self) -> usize {
        let Ok(commits) = self.commits.lock() else {
            return 0;
        };
        commits.len()
    }
}

impl AssistantCommitRecord {
    pub fn assistant_message_id(&self) -> &str {
        &self.assistant_message_id
    }

    pub fn already_committed(&self) -> bool {
        self.already_committed
    }

    pub fn conversation_run_frame_ref(&self) -> &ConversationRunFrameRef {
        &self.conversation_run_frame_ref
    }
}

impl ConversationCommitError {
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }

    pub fn code(&self) -> &str {
        &self.code
    }
}

impl fmt::Display for ConversationCommitError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for ConversationCommitError {}
