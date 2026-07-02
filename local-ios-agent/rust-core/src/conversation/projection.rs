use crate::conversation::ConversationFrameMessage;
use crate::core::{EventKind, RuntimeEvent};

#[derive(Clone, Debug, Default)]
pub struct ConversationFrameProjector;

impl ConversationFrameProjector {
    pub fn new() -> Self {
        Self
    }

    pub fn project(&self, branch: Vec<RuntimeEvent>) -> Vec<ConversationFrameMessage> {
        let mut messages = Vec::new();
        for event in branch {
            match event.kind {
                EventKind::UserMessage => {
                    messages.push(
                        ConversationFrameMessage::user(event.id, event.payload)
                            .with_blob_refs(event.blob_refs),
                    );
                }
                EventKind::AssistantMessageCompleted => {
                    messages.push(ConversationFrameMessage::assistant(event.id, event.payload));
                }
                EventKind::BranchSummaryCreated => {
                    messages.clear();
                    messages.push(ConversationFrameMessage::summary(event.id, event.payload));
                }
                _ => {}
            }
        }
        messages
    }
}
