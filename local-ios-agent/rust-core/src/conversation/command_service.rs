use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};
use serde_json::json;

use crate::canonical_digest::CanonicalDigestV1;
use crate::context::branch_projector::effective_transcript_branch;
use crate::core::{AgentError, EntryId, EventKind, RunId, RuntimeEvent, SessionId};
use crate::storage::{ConversationEventStore, StoredTranscriptCommandReceipt};

use super::{ActiveRunRegistry, ProjectionSubscriptionRegistry, TranscriptCommand};

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct TranscriptCommandResult {
    pub conversation_stream_id: String,
    pub accepted_sequence: u64,
    pub run_id: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct TranscriptCommandError {
    code: String,
    message: String,
}

impl TranscriptCommandError {
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }

    pub fn code(&self) -> &str {
        &self.code
    }

    pub fn idempotency_conflict(conversation_stream_id: &str, request_id: &str) -> Self {
        Self::new(
            "conversation.idempotency_conflict",
            format!(
                "request {request_id} was already used for conversation {conversation_stream_id}"
            ),
        )
    }

    pub fn conversation_busy(conversation_stream_id: &str) -> Self {
        Self::new(
            "conversation_busy",
            format!("conversation {conversation_stream_id} already has an active run"),
        )
    }
}

impl std::fmt::Display for TranscriptCommandError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for TranscriptCommandError {}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "status", content = "value", rename_all = "snake_case")]
enum StoredTranscriptCommandOutcome {
    Accepted(TranscriptCommandResult),
    Rejected(TranscriptCommandError),
}

pub struct ConversationCommandService<S: ConversationEventStore> {
    store: Arc<Mutex<S>>,
    active_runs: ActiveRunRegistry,
    projection_subscriptions: ProjectionSubscriptionRegistry,
}

impl<S: ConversationEventStore> ConversationCommandService<S> {
    pub fn new(store: Arc<Mutex<S>>) -> Self {
        Self::with_registries(
            store,
            ActiveRunRegistry::default(),
            ProjectionSubscriptionRegistry::default(),
        )
    }

    pub fn with_registries(
        store: Arc<Mutex<S>>,
        active_runs: ActiveRunRegistry,
        projection_subscriptions: ProjectionSubscriptionRegistry,
    ) -> Self {
        Self {
            store,
            active_runs,
            projection_subscriptions,
        }
    }

    pub fn submit(
        &self,
        command: TranscriptCommand,
    ) -> Result<TranscriptCommandResult, TranscriptCommandError> {
        let stream_id = command.conversation_stream_id().to_string();
        let request_id = command.request_id().to_string();
        let command_digest = CanonicalDigestV1::digest("transcript-command:v1", &command)
            .map_err(|error| TranscriptCommandError::new(error.code(), error.to_string()))?
            .as_str()
            .to_string();
        let mut store = self.store.lock().map_err(|_| {
            TranscriptCommandError::new(
                "conversation.storage_unavailable",
                "conversation store lock poisoned",
            )
        })?;

        if let Some(receipt) = store
            .command_receipt(&stream_id, &request_id)
            .map_err(storage_error)?
        {
            if receipt.command_digest != command_digest {
                return Err(TranscriptCommandError::idempotency_conflict(
                    &stream_id,
                    &request_id,
                ));
            }
            return decode_outcome(&receipt.outcome_json);
        }

        if let Some(snapshot) = command.run_start_snapshot() {
            snapshot
                .validate()
                .map_err(|error| TranscriptCommandError::new(error.code(), error.to_string()))?;
        }
        let branch_target = validate_command_target(&*store, &command)?;

        let next_sequence = store
            .last_event(&SessionId(stream_id.clone()))
            .map_err(storage_error)?
            .map(|event| event.sequence + 1)
            .unwrap_or(1);

        if self.active_runs.active_run(&stream_id).is_some() {
            let error = TranscriptCommandError::conversation_busy(&stream_id);
            let receipt = stored_receipt(
                &stream_id,
                &request_id,
                &command_digest,
                &StoredTranscriptCommandOutcome::Rejected(error.clone()),
            )?;
            store
                .commit_command(&stream_id, next_sequence, Vec::new(), receipt)
                .map_err(storage_error)?;
            return Err(error);
        }

        let run_id = command
            .starts_run()
            .then(|| format!("run-{}", &command_digest[..24]));
        if let Some(run_id) = &run_id {
            self.active_runs.start(&stream_id, run_id)?;
        }

        let last_event = store
            .last_event(&SessionId(stream_id.clone()))
            .map_err(storage_error)?;
        let event = RuntimeEvent::new(
            EntryId(format!("command-event-{}", &command_digest[..24])),
            SessionId(stream_id.clone()),
            last_event.as_ref().map(|event| event.id.clone()),
            run_id.clone().map(RunId),
            0,
            last_event
                .as_ref()
                .map(|event| event.depth.saturating_add(1))
                .unwrap_or(0),
            event_kind(&command),
            event_payload(&command)?,
        );
        let result = TranscriptCommandResult {
            conversation_stream_id: stream_id.clone(),
            accepted_sequence: next_sequence,
            run_id: run_id.clone(),
        };
        let receipt = stored_receipt(
            &stream_id,
            &request_id,
            &command_digest,
            &StoredTranscriptCommandOutcome::Accepted(result.clone()),
        )?;

        let commit = if let Some((target_stream_id, target_events)) = branch_target {
            store.commit_branch_command(
                &stream_id,
                next_sequence,
                vec![event],
                receipt,
                &target_stream_id,
                1,
                target_events,
            )
        } else {
            store.commit_command(&stream_id, next_sequence, vec![event], receipt)
        };
        match commit {
            Ok(_) => {
                self.projection_subscriptions.notify(&stream_id);
                if let TranscriptCommand::CreateBranch {
                    new_conversation_stream_id,
                    ..
                } = &command
                {
                    self.projection_subscriptions
                        .notify(new_conversation_stream_id);
                }
                Ok(result)
            }
            Err(error) => {
                if let Some(run_id) = run_id {
                    let _ = self.active_runs.complete(&stream_id, &run_id);
                }
                Err(storage_error(error))
            }
        }
    }

    pub fn complete_run(
        &self,
        conversation_stream_id: &str,
        run_id: &str,
    ) -> Result<(), TranscriptCommandError> {
        self.active_runs.complete(conversation_stream_id, run_id)
    }

    pub fn projection_registry(&self) -> ProjectionSubscriptionRegistry {
        self.projection_subscriptions.clone()
    }

    pub fn active_run_registry(&self) -> ActiveRunRegistry {
        self.active_runs.clone()
    }

    pub(crate) fn store_handle(&self) -> Arc<Mutex<S>> {
        self.store.clone()
    }
}

fn validate_command_target(
    store: &impl ConversationEventStore,
    command: &TranscriptCommand,
) -> Result<Option<(String, Vec<RuntimeEvent>)>, TranscriptCommandError> {
    let stream_id = SessionId(command.conversation_stream_id().to_string());
    let target_id = match command {
        TranscriptCommand::RetryFrom {
            anchor_event_id, ..
        }
        | TranscriptCommand::CreateBranch {
            anchor_event_id, ..
        } => Some(anchor_event_id.as_str()),
        TranscriptCommand::EditMessage {
            target_event_id, ..
        }
        | TranscriptCommand::DeleteMessage {
            target_event_id, ..
        } => Some(target_event_id.as_str()),
        _ => None,
    };

    let Some(target_id) = target_id else {
        return Ok(None);
    };
    let target_id = EntryId(target_id.to_string());
    store.get(&stream_id, &target_id).map_err(|_| {
        TranscriptCommandError::new(
            "conversation.target_not_found",
            format!(
                "event {} does not exist in conversation {}",
                target_id.0, stream_id.0
            ),
        )
    })?;
    if matches!(command, TranscriptCommand::RetryFrom { .. }) {
        let last_event = store
            .last_event(&stream_id)
            .map_err(storage_error)?
            .ok_or_else(|| {
                TranscriptCommandError::new(
                    "conversation.target_not_found",
                    "retry conversation is empty",
                )
            })?;
        let effective = effective_transcript_branch(
            store
                .active_branch(&stream_id, &last_event.id)
                .map_err(storage_error)?,
        );
        if !effective
            .iter()
            .any(|event| event.id == target_id && event.kind == EventKind::UserMessage)
        {
            return Err(TranscriptCommandError::new(
                "conversation.retry_anchor_not_user",
                "retry must anchor an effective user message whose answer is being regenerated",
            ));
        }
    }

    let TranscriptCommand::CreateBranch {
        new_conversation_stream_id,
        ..
    } = command
    else {
        return Ok(None);
    };
    if new_conversation_stream_id == &stream_id.0 {
        return Err(TranscriptCommandError::new(
            "conversation.branch_target_invalid",
            "branch target must differ from source conversation",
        ));
    }
    if store
        .last_event(&SessionId(new_conversation_stream_id.clone()))
        .map_err(storage_error)?
        .is_some()
    {
        return Err(TranscriptCommandError::new(
            "conversation.branch_target_exists",
            format!("conversation {new_conversation_stream_id} already exists"),
        ));
    }

    let target_stream_id = SessionId(new_conversation_stream_id.clone());
    let target_events = store
        .active_branch(&stream_id, &target_id)
        .map_err(storage_error)?
        .into_iter()
        .map(|mut event| {
            event.session_id = target_stream_id.clone();
            event.run_id = None;
            event.sequence = 0;
            event
        })
        .collect();
    Ok(Some((new_conversation_stream_id.clone(), target_events)))
}

fn event_kind(command: &TranscriptCommand) -> EventKind {
    match command {
        TranscriptCommand::Send { .. } => EventKind::UserMessage,
        TranscriptCommand::RetryFrom { .. } => EventKind::TranscriptRetryRequested,
        TranscriptCommand::EditMessage { .. } => EventKind::MessageEdited,
        TranscriptCommand::DeleteMessage { .. } => EventKind::MessageDeleted,
        TranscriptCommand::ClearConversation { .. } => EventKind::ConversationCleared,
        TranscriptCommand::CreateBranch { .. } => EventKind::BranchCreated,
        TranscriptCommand::ArchiveConversation { .. } => EventKind::ConversationArchived,
        TranscriptCommand::DeleteConversation { .. } => EventKind::ConversationDeleted,
    }
}

fn event_payload(command: &TranscriptCommand) -> Result<String, TranscriptCommandError> {
    serde_json::to_string(&json!({ "command": command })).map_err(|error| {
        TranscriptCommandError::new(
            "conversation.command_serialization_failed",
            error.to_string(),
        )
    })
}

fn stored_receipt(
    stream_id: &str,
    request_id: &str,
    command_digest: &str,
    outcome: &StoredTranscriptCommandOutcome,
) -> Result<StoredTranscriptCommandReceipt, TranscriptCommandError> {
    Ok(StoredTranscriptCommandReceipt {
        conversation_stream_id: stream_id.to_string(),
        request_id: request_id.to_string(),
        command_digest: command_digest.to_string(),
        outcome_json: serde_json::to_string(outcome).map_err(|error| {
            TranscriptCommandError::new(
                "conversation.receipt_serialization_failed",
                error.to_string(),
            )
        })?,
    })
}

fn decode_outcome(outcome_json: &str) -> Result<TranscriptCommandResult, TranscriptCommandError> {
    match serde_json::from_str(outcome_json).map_err(|error| {
        TranscriptCommandError::new(
            "conversation.receipt_deserialization_failed",
            error.to_string(),
        )
    })? {
        StoredTranscriptCommandOutcome::Accepted(result) => Ok(result),
        StoredTranscriptCommandOutcome::Rejected(error) => Err(error),
    }
}

fn storage_error(error: AgentError) -> TranscriptCommandError {
    TranscriptCommandError::new("conversation.storage_failed", error.to_string())
}
