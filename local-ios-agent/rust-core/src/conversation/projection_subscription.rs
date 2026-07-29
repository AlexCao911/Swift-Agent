use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};

use crate::core::SessionId;
use crate::storage::ConversationEventStore;

use super::TranscriptProjectionEvent;

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ObserveTranscriptProjectionsRequest {
    pub subscription_id: String,
    pub conversation_stream_id: String,
    pub after_sequence: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TranscriptProjectionError {
    code: String,
    message: String,
}

impl TranscriptProjectionError {
    fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }

    pub fn code(&self) -> &str {
        &self.code
    }
}

impl std::fmt::Display for TranscriptProjectionError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for TranscriptProjectionError {}

#[derive(Clone, Default)]
pub struct ProjectionSubscriptionRegistry {
    inner: Arc<Mutex<HashMap<String, Subscription>>>,
}

struct Subscription {
    conversation_stream_id: String,
    sender: Sender<()>,
    cancelled: Arc<AtomicBool>,
}

impl ProjectionSubscriptionRegistry {
    pub fn observe<S: ConversationEventStore + Send + 'static>(
        &self,
        store: Arc<Mutex<S>>,
        request: ObserveTranscriptProjectionsRequest,
    ) -> Result<TranscriptProjectionFeed<S>, TranscriptProjectionError> {
        let (sender, receiver) = mpsc::channel();
        let cancelled = Arc::new(AtomicBool::new(false));
        let mut subscriptions = self
            .inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if subscriptions.contains_key(&request.subscription_id) {
            return Err(TranscriptProjectionError::new(
                "projection.subscription_exists",
                format!(
                    "projection subscription already exists: {}",
                    request.subscription_id
                ),
            ));
        }
        subscriptions.insert(
            request.subscription_id.clone(),
            Subscription {
                conversation_stream_id: request.conversation_stream_id.clone(),
                sender,
                cancelled: cancelled.clone(),
            },
        );
        drop(subscriptions);

        Ok(TranscriptProjectionFeed {
            store,
            registry: self.clone(),
            subscription_id: request.subscription_id,
            conversation_stream_id: request.conversation_stream_id,
            cursor: request.after_sequence,
            pending: VecDeque::new(),
            receiver,
            cancelled,
        })
    }

    pub fn notify(&self, conversation_stream_id: &str) {
        let subscriptions = self
            .inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        for subscription in subscriptions.values() {
            if subscription.conversation_stream_id == conversation_stream_id {
                let _ = subscription.sender.send(());
            }
        }
    }

    pub fn cancel(&self, subscription_id: &str) {
        let subscription = self
            .inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .remove(subscription_id);
        if let Some(subscription) = subscription {
            subscription.cancelled.store(true, Ordering::Release);
            let _ = subscription.sender.send(());
        }
    }

    pub fn listener_count(&self) -> usize {
        self.inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .len()
    }
}

pub struct TranscriptProjectionFeed<S: ConversationEventStore + Send + 'static> {
    store: Arc<Mutex<S>>,
    registry: ProjectionSubscriptionRegistry,
    subscription_id: String,
    conversation_stream_id: String,
    cursor: u64,
    pending: VecDeque<TranscriptProjectionEvent>,
    receiver: Receiver<()>,
    cancelled: Arc<AtomicBool>,
}

impl<S: ConversationEventStore + Send + 'static> TranscriptProjectionFeed<S> {
    pub fn next(&mut self) -> Result<Option<TranscriptProjectionEvent>, TranscriptProjectionError> {
        loop {
            if let Some(event) = self.pending.pop_front() {
                self.cursor = event.sequence;
                return Ok(Some(event));
            }
            if self.cancelled.load(Ordering::Acquire) {
                return Ok(None);
            }

            let events = self
                .store
                .lock()
                .map_err(|_| {
                    TranscriptProjectionError::new(
                        "projection.storage_unavailable",
                        "conversation store lock poisoned",
                    )
                })?
                .events_after(&SessionId(self.conversation_stream_id.clone()), self.cursor)
                .map_err(|error| {
                    TranscriptProjectionError::new("projection.replay_failed", error.to_string())
                })?;
            if let Some(first) = events.first() {
                let expected = self.cursor.saturating_add(1);
                if first.sequence != expected {
                    return Err(TranscriptProjectionError::new(
                        "projection.sequence_gap",
                        format!("expected sequence {expected}, received {}", first.sequence),
                    ));
                }
                self.pending
                    .extend(events.into_iter().map(TranscriptProjectionEvent::from));
                continue;
            }

            if self.receiver.recv().is_err() {
                return Err(TranscriptProjectionError::new(
                    "projection.subscription_closed",
                    "projection wake channel closed",
                ));
            }
        }
    }
}

impl<S: ConversationEventStore + Send + 'static> Drop for TranscriptProjectionFeed<S> {
    fn drop(&mut self) {
        self.registry.cancel(&self.subscription_id);
    }
}
