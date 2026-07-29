use crate::context::ContextCompactionCheckpoint;
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
                    let summary =
                        serde_json::from_str::<ContextCompactionCheckpoint>(&event.payload)
                            .map(|checkpoint| checkpoint.summary)
                            .unwrap_or(event.payload);
                    messages.clear();
                    messages.push(ConversationFrameMessage::summary(event.id, summary));
                }
                _ => {}
            }
        }
        messages
    }
}
