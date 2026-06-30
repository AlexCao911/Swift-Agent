use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use super::{StorageResult, UnitOfWork};

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct EventSequence(u64);

impl EventSequence {
    pub const fn new(value: u64) -> Self {
        Self(value)
    }

    pub const fn as_u64(self) -> u64 {
        self.0
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct EventRecord {
    stream_id: String,
    event_type: String,
    pub sequence: EventSequence,
}

impl EventRecord {
    pub fn new(stream_id: impl Into<String>, event_type: impl Into<String>) -> Self {
        Self {
            stream_id: stream_id.into(),
            event_type: event_type.into(),
            sequence: EventSequence::new(0),
        }
    }

    pub fn stream_id(&self) -> &str {
        &self.stream_id
    }

    pub fn event_type(&self) -> &str {
        &self.event_type
    }
}

pub struct UnitOfWorkEvents<'a> {
    records: &'a mut Vec<EventRecord>,
}

impl UnitOfWorkEvents<'_> {
    pub fn append(&mut self, record: EventRecord) -> StorageResult<()> {
        self.records.push(record);
        Ok(())
    }
}

pub trait EventStore: Send + Sync {
    fn append(&self, tx: &mut UnitOfWork, record: EventRecord) -> StorageResult<EventSequence>;
    fn stream(&self, stream_id: &str) -> StorageResult<Vec<EventRecord>>;
}

#[derive(Clone, Debug, Default)]
pub struct InMemoryEventStore {
    inner: Arc<Mutex<InMemoryEventStoreInner>>,
}

#[derive(Debug, Default)]
struct InMemoryEventStoreInner {
    next_sequences: BTreeMap<String, u64>,
    streams: BTreeMap<String, Vec<EventRecord>>,
}

impl InMemoryEventStore {
    pub fn append_immediate(&self, record: EventRecord) -> StorageResult<EventSequence> {
        let mut inner = self.inner.lock().expect("event store mutex poisoned");
        let sequence = inner.next_sequence(record.stream_id());

        let mut stored = record;
        stored.sequence = sequence;
        inner
            .streams
            .entry(stored.stream_id().to_string())
            .or_default()
            .push(stored);

        Ok(sequence)
    }

    pub fn stream(&self, stream_id: &str) -> StorageResult<Vec<EventRecord>> {
        let inner = self.inner.lock().expect("event store mutex poisoned");
        Ok(inner.streams.get(stream_id).cloned().unwrap_or_default())
    }

    pub(crate) fn commit(&self, tx: &mut UnitOfWork) -> StorageResult<()> {
        let mut records = tx.drain_events();
        if records.is_empty() {
            return Ok(());
        }

        let mut inner = self.inner.lock().expect("event store mutex poisoned");
        for record in &mut records {
            if record.sequence.as_u64() == 0 {
                record.sequence = inner.next_sequence(record.stream_id());
            } else {
                inner.advance_next_sequence(record.stream_id(), record.sequence);
            }
        }

        for record in records {
            inner
                .streams
                .entry(record.stream_id().to_string())
                .or_default()
                .push(record);
        }
        Ok(())
    }
}

impl EventStore for InMemoryEventStore {
    fn append(&self, tx: &mut UnitOfWork, mut record: EventRecord) -> StorageResult<EventSequence> {
        let mut inner = self.inner.lock().expect("event store mutex poisoned");
        let sequence = inner.next_sequence(record.stream_id());
        record.sequence = sequence;
        tx.push_event(record);
        Ok(sequence)
    }

    fn stream(&self, stream_id: &str) -> StorageResult<Vec<EventRecord>> {
        InMemoryEventStore::stream(self, stream_id)
    }
}

impl InMemoryEventStoreInner {
    fn next_sequence(&mut self, stream_id: &str) -> EventSequence {
        let default_next = self
            .streams
            .get(stream_id)
            .and_then(|stream| stream.last())
            .map(|record| record.sequence.as_u64() + 1)
            .unwrap_or(1);
        let next = self
            .next_sequences
            .entry(stream_id.to_string())
            .or_insert(default_next);
        let sequence = EventSequence::new(*next);
        *next += 1;
        sequence
    }

    fn advance_next_sequence(&mut self, stream_id: &str, used_sequence: EventSequence) {
        let next = self
            .next_sequences
            .entry(stream_id.to_string())
            .or_insert(used_sequence.as_u64() + 1);
        *next = (*next).max(used_sequence.as_u64() + 1);
    }
}

impl UnitOfWork {
    pub(crate) fn push_event(&mut self, record: EventRecord) {
        self.events.push(record);
    }

    pub fn events(&mut self) -> UnitOfWorkEvents<'_> {
        UnitOfWorkEvents {
            records: &mut self.events,
        }
    }
}
