use serde::{Deserialize, Serialize};

use crate::agent_input::RunStartSnapshot;

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct TranscriptAttachmentReference {
    pub attachment_id: String,
    pub display_name: String,
    pub media_type: String,
    pub modality: String,
    pub content_digest: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum TranscriptCommand {
    Send {
        request_id: String,
        conversation_stream_id: String,
        client_message_id: String,
        text: String,
        attachments: Vec<TranscriptAttachmentReference>,
        run_start_snapshot: RunStartSnapshot,
    },
    RetryFrom {
        request_id: String,
        conversation_stream_id: String,
        anchor_event_id: String,
        run_start_snapshot: RunStartSnapshot,
    },
    EditMessage {
        request_id: String,
        conversation_stream_id: String,
        target_event_id: String,
        replacement_text: String,
        replacement_attachments: Vec<TranscriptAttachmentReference>,
        run_start_snapshot: RunStartSnapshot,
    },
    DeleteMessage {
        request_id: String,
        conversation_stream_id: String,
        target_event_id: String,
    },
    ClearConversation {
        request_id: String,
        conversation_stream_id: String,
    },
    CreateBranch {
        request_id: String,
        conversation_stream_id: String,
        anchor_event_id: String,
        new_conversation_stream_id: String,
    },
    ArchiveConversation {
        request_id: String,
        conversation_stream_id: String,
    },
    DeleteConversation {
        request_id: String,
        conversation_stream_id: String,
    },
}

impl TranscriptCommand {
    pub fn request_id(&self) -> &str {
        match self {
            Self::Send { request_id, .. }
            | Self::RetryFrom { request_id, .. }
            | Self::EditMessage { request_id, .. }
            | Self::DeleteMessage { request_id, .. }
            | Self::ClearConversation { request_id, .. }
            | Self::CreateBranch { request_id, .. }
            | Self::ArchiveConversation { request_id, .. }
            | Self::DeleteConversation { request_id, .. } => request_id,
        }
    }

    pub fn conversation_stream_id(&self) -> &str {
        match self {
            Self::Send {
                conversation_stream_id,
                ..
            }
            | Self::RetryFrom {
                conversation_stream_id,
                ..
            }
            | Self::EditMessage {
                conversation_stream_id,
                ..
            }
            | Self::DeleteMessage {
                conversation_stream_id,
                ..
            }
            | Self::ClearConversation {
                conversation_stream_id,
                ..
            }
            | Self::CreateBranch {
                conversation_stream_id,
                ..
            }
            | Self::ArchiveConversation {
                conversation_stream_id,
                ..
            }
            | Self::DeleteConversation {
                conversation_stream_id,
                ..
            } => conversation_stream_id,
        }
    }

    pub fn starts_run(&self) -> bool {
        matches!(
            self,
            Self::Send { .. } | Self::RetryFrom { .. } | Self::EditMessage { .. }
        )
    }

    pub fn run_start_snapshot(&self) -> Option<&RunStartSnapshot> {
        match self {
            Self::Send {
                run_start_snapshot, ..
            }
            | Self::RetryFrom {
                run_start_snapshot, ..
            }
            | Self::EditMessage {
                run_start_snapshot, ..
            } => Some(run_start_snapshot),
            _ => None,
        }
    }
}
