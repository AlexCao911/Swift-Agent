use std::fmt;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use crate::conversation::{
    AttachmentRef, BranchEventReader, ConversationFrameId, ConversationFrameMessage,
    ConversationFrameProjector, ConversationFrameRepository, ConversationLineage,
    ConversationRunFrame, ConversationRunFrameRef,
};
use crate::core::{EntryId, SessionId};

#[derive(Clone)]
pub struct ConversationService<R: ConversationFrameRepository, B: BranchEventReader> {
    frames: R,
    branch_reader: B,
    projector: ConversationFrameProjector,
    next_user_turn: Arc<AtomicU64>,
    next_frame: Arc<AtomicU64>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PrepareUserTurnRequest {
    session_id: Option<SessionId>,
    parent_event_id: Option<EntryId>,
    fork_origin_id: Option<EntryId>,
    edit_origin_id: Option<EntryId>,
    text: String,
    blob_refs: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PreparedUserTurn {
    session_id: SessionId,
    user_message_id: EntryId,
    conversation_run_frame_ref: ConversationRunFrameRef,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ConversationServiceError {
    code: String,
    message: String,
}

impl<R: ConversationFrameRepository, B: BranchEventReader> ConversationService<R, B> {
    pub fn new(frames: R, branch_reader: B) -> Self {
        Self {
            frames,
            branch_reader,
            projector: ConversationFrameProjector::new(),
            next_user_turn: Arc::new(AtomicU64::new(1)),
            next_frame: Arc::new(AtomicU64::new(1)),
        }
    }

    pub fn prepare_user_turn(
        &self,
        request: PrepareUserTurnRequest,
    ) -> Result<PreparedUserTurn, ConversationServiceError> {
        let session_id = request
            .session_id
            .clone()
            .unwrap_or_else(|| SessionId("session_1".into()));
        let user_turn_id = EntryId(format!(
            "user_turn_{}",
            self.next_user_turn.fetch_add(1, Ordering::SeqCst)
        ));
        let frame_id = ConversationFrameId::new(format!(
            "frame_{}",
            self.next_frame.fetch_add(1, Ordering::SeqCst)
        ));
        let branch_head_id = request
            .parent_event_id
            .clone()
            .unwrap_or_else(|| user_turn_id.clone());
        let mut messages = if request.parent_event_id.is_some() {
            self.projector.project(
                self.branch_reader
                    .active_branch(&session_id, &branch_head_id),
            )
        } else {
            Vec::new()
        };
        messages.push(
            ConversationFrameMessage::user(user_turn_id.clone(), request.text)
                .with_blob_refs(request.blob_refs),
        );
        let frame_ref = ConversationRunFrameRef::new(
            frame_id,
            session_id.clone(),
            branch_head_id.clone(),
            user_turn_id.clone(),
        );
        let frame = ConversationRunFrame::new(
            frame_ref.clone(),
            request.parent_event_id.clone(),
            messages,
            Vec::<AttachmentRef>::new(),
            ConversationLineage::new(
                branch_head_id,
                request.fork_origin_id.clone(),
                request.edit_origin_id.clone(),
            ),
        );
        self.frames.put(frame);
        Ok(PreparedUserTurn {
            session_id,
            user_message_id: user_turn_id,
            conversation_run_frame_ref: frame_ref,
        })
    }
}

impl PrepareUserTurnRequest {
    pub fn new(
        session_id: Option<SessionId>,
        parent_event_id: Option<EntryId>,
        text: impl Into<String>,
        blob_refs: Vec<String>,
    ) -> Self {
        Self {
            session_id,
            parent_event_id,
            fork_origin_id: None,
            edit_origin_id: None,
            text: text.into(),
            blob_refs,
        }
    }

    pub fn with_fork_origin(mut self, fork_origin_id: EntryId) -> Self {
        self.fork_origin_id = Some(fork_origin_id);
        self
    }

    pub fn with_edit_origin(mut self, edit_origin_id: EntryId) -> Self {
        self.edit_origin_id = Some(edit_origin_id);
        self
    }
}

impl PreparedUserTurn {
    pub fn session_id(&self) -> &SessionId {
        &self.session_id
    }

    pub fn user_message_id(&self) -> &EntryId {
        &self.user_message_id
    }

    pub fn conversation_run_frame_ref(&self) -> &ConversationRunFrameRef {
        &self.conversation_run_frame_ref
    }
}

impl ConversationServiceError {
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

impl fmt::Display for ConversationServiceError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for ConversationServiceError {}
