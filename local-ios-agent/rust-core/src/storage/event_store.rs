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

#[derive(Clone, Debug, Default)]
pub struct InMemoryEventStore {
    inner: Arc<Mutex<InMemoryEventStoreInner>>,
}

#[derive(Debug, Default)]
struct InMemoryEventStoreInner {
    streams: BTreeMap<String, Vec<EventRecord>>,
}

impl InMemoryEventStore {
    pub fn append(&self, record: EventRecord) -> StorageResult<EventSequence> {
        let mut inner = self.inner.lock().expect("event store mutex poisoned");
        let stream = inner
            .streams
            .entry(record.stream_id().to_string())
            .or_default();
        let sequence = EventSequence::new(stream.len() as u64 + 1);

        let mut stored = record;
        stored.sequence = sequence;
        stream.push(stored);

        Ok(sequence)
    }

    pub fn stream(&self, stream_id: &str) -> StorageResult<Vec<EventRecord>> {
        let inner = self.inner.lock().expect("event store mutex poisoned");
        Ok(inner.streams.get(stream_id).cloned().unwrap_or_default())
    }

    pub(crate) fn commit(&self, tx: &mut UnitOfWork) -> StorageResult<()> {
        for record in tx.drain_events() {
            self.append(record)?;
        }
        Ok(())
    }
}

impl UnitOfWork {
    pub fn events(&mut self) -> UnitOfWorkEvents<'_> {
        UnitOfWorkEvents {
            records: &mut self.events,
        }
    }
}
