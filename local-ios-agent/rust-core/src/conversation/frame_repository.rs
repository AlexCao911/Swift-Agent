use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use crate::conversation::{ConversationFrameId, ConversationRunFrame, ConversationRunFrameRef};

pub trait ConversationFrameRepository: Clone + Send + Sync + 'static {
    fn put(&self, frame: ConversationRunFrame);
    fn get(&self, frame_ref: &ConversationRunFrameRef) -> Option<ConversationRunFrame>;

    fn contains(&self, frame_ref: &ConversationRunFrameRef) -> bool {
        self.get(frame_ref)
            .map(|frame| frame.frame_ref() == frame_ref)
            .unwrap_or(false)
    }
}

#[derive(Clone, Debug, Default)]
pub struct InMemoryConversationFrameRepository {
    inner: Arc<Mutex<BTreeMap<ConversationFrameId, ConversationRunFrame>>>,
}

impl ConversationFrameRepository for InMemoryConversationFrameRepository {
    fn put(&self, frame: ConversationRunFrame) {
        let Ok(mut frames) = self.inner.lock() else {
            return;
        };
        frames.insert(frame.frame_ref().frame_id().clone(), frame);
    }

    fn get(&self, frame_ref: &ConversationRunFrameRef) -> Option<ConversationRunFrame> {
        let Ok(frames) = self.inner.lock() else {
            return None;
        };
        let frame = frames.get(frame_ref.frame_id()).cloned();
        frame.filter(|frame| frame.frame_ref() == frame_ref)
    }
}
