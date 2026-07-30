use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};

use serde::{Deserialize, Serialize};

use crate::core::SessionId;
use crate::storage::ConversationEventStore;

use super::TranscriptProjectionEvent;

const PROJECTION_MAILBOX_CAPACITY: usize = 64;
const MAX_COALESCED_TEXT_BYTES: usize = 16 * 1024;

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
    mailbox: ProjectionMailbox,
    cancelled: Arc<AtomicBool>,
}

enum ProjectionSignal {
    Wake,
    Live(TranscriptProjectionEvent),
}

#[derive(Clone)]
struct ProjectionMailbox {
    inner: Arc<ProjectionMailboxInner>,
}

struct ProjectionMailboxInner {
    state: Mutex<ProjectionMailboxState>,
    available: Condvar,
    space: Condvar,
}

struct ProjectionMailboxState {
    queue: VecDeque<ProjectionSignal>,
    closed: bool,
}

enum ProjectionMailboxRead {
    Signal(ProjectionSignal),
    Empty,
    Closed,
}

impl ProjectionMailbox {
    fn new() -> Self {
        Self {
            inner: Arc::new(ProjectionMailboxInner {
                state: Mutex::new(ProjectionMailboxState {
                    queue: VecDeque::new(),
                    closed: false,
                }),
                available: Condvar::new(),
                space: Condvar::new(),
            }),
        }
    }

    fn wake(&self) {
        let mut state = self
            .inner
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if state.closed
            || state
                .queue
                .iter()
                .any(|signal| matches!(signal, ProjectionSignal::Wake))
            || state.queue.len() >= PROJECTION_MAILBOX_CAPACITY
        {
            return;
        }
        state.queue.push_back(ProjectionSignal::Wake);
        self.inner.available.notify_one();
    }

    fn publish_live(&self, event: TranscriptProjectionEvent) {
        let Some(text) = event.payload.as_str() else {
            let _ = self.push(ProjectionSignal::Live(event));
            return;
        };
        if event.kind != super::TranscriptProjectionKind::AssistantTextDelta
            || text.len() <= MAX_COALESCED_TEXT_BYTES
        {
            let _ = self.push(ProjectionSignal::Live(event));
            return;
        }

        let mut start = 0;
        let mut part = 0;
        while start < text.len() {
            let mut end = (start + MAX_COALESCED_TEXT_BYTES).min(text.len());
            while end > start && !text.is_char_boundary(end) {
                end -= 1;
            }
            let mut chunk = event.clone();
            chunk.event_id = format!("{}-part-{part}", event.event_id);
            chunk.payload = serde_json::Value::String(text[start..end].to_string());
            if !self.push(ProjectionSignal::Live(chunk)) {
                return;
            }
            start = end;
            part += 1;
        }
    }

    fn push(&self, signal: ProjectionSignal) -> bool {
        let mut state = self
            .inner
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        loop {
            if state.closed {
                return false;
            }
            if let ProjectionSignal::Live(event) = &signal {
                if coalesce_adjacent_text_delta(&mut state.queue, event) {
                    return true;
                }
            }
            if state.queue.len() < PROJECTION_MAILBOX_CAPACITY {
                state.queue.push_back(signal);
                self.inner.available.notify_one();
                return true;
            }
            state = self
                .inner
                .space
                .wait(state)
                .unwrap_or_else(|poisoned| poisoned.into_inner());
        }
    }

    fn try_recv(&self) -> ProjectionMailboxRead {
        let mut state = self
            .inner
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some(signal) = state.queue.pop_front() {
            self.inner.space.notify_one();
            ProjectionMailboxRead::Signal(signal)
        } else if state.closed {
            ProjectionMailboxRead::Closed
        } else {
            ProjectionMailboxRead::Empty
        }
    }

    fn recv(&self) -> Option<ProjectionSignal> {
        let mut state = self
            .inner
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        loop {
            if let Some(signal) = state.queue.pop_front() {
                self.inner.space.notify_one();
                return Some(signal);
            }
            if state.closed {
                return None;
            }
            state = self
                .inner
                .available
                .wait(state)
                .unwrap_or_else(|poisoned| poisoned.into_inner());
        }
    }

    fn close(&self) {
        let mut state = self
            .inner
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        state.closed = true;
        self.inner.available.notify_all();
        self.inner.space.notify_all();
    }
}

fn coalesce_adjacent_text_delta(
    queue: &mut VecDeque<ProjectionSignal>,
    event: &TranscriptProjectionEvent,
) -> bool {
    if event.kind != super::TranscriptProjectionKind::AssistantTextDelta {
        return false;
    }
    let Some(ProjectionSignal::Live(previous)) = queue.back_mut() else {
        return false;
    };
    if previous.kind != event.kind
        || previous.conversation_stream_id != event.conversation_stream_id
        || previous.run_id != event.run_id
    {
        return false;
    }
    let (Some(previous_text), Some(next_text)) =
        (previous.payload.as_str(), event.payload.as_str())
    else {
        return false;
    };
    if previous_text.len() + next_text.len() > MAX_COALESCED_TEXT_BYTES {
        return false;
    }
    let mut merged = String::with_capacity(previous_text.len() + next_text.len());
    merged.push_str(previous_text);
    merged.push_str(next_text);
    previous.payload = serde_json::Value::String(merged);
    previous.event_id.clone_from(&event.event_id);
    true
}

impl ProjectionSubscriptionRegistry {
    pub fn observe<S: ConversationEventStore + Send + 'static>(
        &self,
        store: Arc<Mutex<S>>,
        request: ObserveTranscriptProjectionsRequest,
    ) -> Result<TranscriptProjectionFeed<S>, TranscriptProjectionError> {
        let mailbox = ProjectionMailbox::new();
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
                mailbox: mailbox.clone(),
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
            mailbox,
            cancelled,
        })
    }

    pub fn notify(&self, conversation_stream_id: &str) {
        let mailboxes = self.mailboxes_for(conversation_stream_id);
        for mailbox in mailboxes {
            mailbox.wake();
        }
    }

    pub fn publish_live(&self, event: TranscriptProjectionEvent) {
        let mailboxes = self.mailboxes_for(&event.conversation_stream_id);
        for mailbox in mailboxes {
            mailbox.publish_live(event.clone());
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
            subscription.mailbox.close();
        }
    }

    pub fn listener_count(&self) -> usize {
        self.inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .len()
    }

    fn mailboxes_for(&self, conversation_stream_id: &str) -> Vec<ProjectionMailbox> {
        self.inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .values()
            .filter(|subscription| subscription.conversation_stream_id == conversation_stream_id)
            .map(|subscription| subscription.mailbox.clone())
            .collect()
    }
}

pub struct TranscriptProjectionFeed<S: ConversationEventStore + Send + 'static> {
    store: Arc<Mutex<S>>,
    registry: ProjectionSubscriptionRegistry,
    subscription_id: String,
    conversation_stream_id: String,
    cursor: u64,
    pending: VecDeque<TranscriptProjectionEvent>,
    mailbox: ProjectionMailbox,
    cancelled: Arc<AtomicBool>,
}

impl<S: ConversationEventStore + Send + 'static> TranscriptProjectionFeed<S> {
    // This is a blocking, fallible feed operation rather than Iterator::next.
    #[allow(clippy::should_implement_trait)]
    pub fn next(&mut self) -> Result<Option<TranscriptProjectionEvent>, TranscriptProjectionError> {
        loop {
            if let Some(event) = self.pending.pop_front() {
                self.cursor = event.sequence;
                return Ok(Some(event));
            }
            if self.cancelled.load(Ordering::Acquire) {
                return Ok(None);
            }
            match self.mailbox.try_recv() {
                ProjectionMailboxRead::Signal(ProjectionSignal::Live(event)) => {
                    return Ok(Some(event));
                }
                ProjectionMailboxRead::Signal(ProjectionSignal::Wake)
                | ProjectionMailboxRead::Empty => {}
                ProjectionMailboxRead::Closed => {
                    if self.cancelled.load(Ordering::Acquire) {
                        return Ok(None);
                    }
                    return Err(TranscriptProjectionError::new(
                        "projection.subscription_closed",
                        "projection mailbox closed",
                    ));
                }
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

            match self.mailbox.recv() {
                Some(ProjectionSignal::Live(event)) => return Ok(Some(event)),
                Some(ProjectionSignal::Wake) => {}
                None => {
                    if self.cancelled.load(Ordering::Acquire) {
                        return Ok(None);
                    }
                    return Err(TranscriptProjectionError::new(
                        "projection.subscription_closed",
                        "projection mailbox closed",
                    ));
                }
            }
        }
    }
}

impl<S: ConversationEventStore + Send + 'static> Drop for TranscriptProjectionFeed<S> {
    fn drop(&mut self) {
        self.registry.cancel(&self.subscription_id);
    }
}
