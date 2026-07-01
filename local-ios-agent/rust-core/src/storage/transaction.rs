use std::fmt;
use std::sync::{Arc, Mutex};

use super::archive_store::PendingArchiveRecord;
use super::{ArchiveId, EventRecord, EventSequence, InMemoryArchiveStore, InMemoryEventStore};

pub type StorageResult<T> = Result<T, StorageError>;

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct StorageError {
    code: String,
    message: String,
}

impl StorageError {
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }

    pub fn forced(message: impl Into<String>) -> Self {
        Self::new("storage.forced", message)
    }

    pub fn code(&self) -> &str {
        &self.code
    }
}

impl fmt::Display for StorageError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for StorageError {}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TransactionName(String);

impl TransactionName {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

pub trait TransactionRunner: Send + Sync {
    fn run(
        &self,
        name: TransactionName,
        operation: &mut dyn TransactionOperation,
    ) -> StorageResult<()>;
}

pub trait TransactionOperation {
    fn execute(&mut self, tx: &mut UnitOfWork) -> StorageResult<()>;
}

#[derive(Default)]
pub struct UnitOfWork {
    pub(crate) archives: Vec<PendingArchiveRecord>,
    pub(crate) events: Vec<EventRecord>,
    store_writes: Vec<Box<dyn PendingStoreWrite>>,
    event_sequence_cursors: std::collections::BTreeMap<String, u64>,
    next_archive_id: Option<u64>,
}

impl UnitOfWork {
    pub fn push_store_write(&mut self, write: Box<dyn PendingStoreWrite>) {
        self.store_writes.push(write);
    }

    pub(crate) fn drain_store_writes(&mut self) -> Vec<Box<dyn PendingStoreWrite>> {
        self.store_writes.drain(..).collect()
    }

    pub(crate) fn drain_events(&mut self) -> Vec<EventRecord> {
        self.events.drain(..).collect()
    }

    pub(crate) fn reserve_event_sequence(
        &mut self,
        stream_id: &str,
        committed_next: u64,
    ) -> EventSequence {
        let next = self
            .event_sequence_cursors
            .get(stream_id)
            .copied()
            .unwrap_or_else(|| self.next_event_sequence_from_pending(stream_id, committed_next));
        self.event_sequence_cursors
            .insert(stream_id.to_string(), next + 1);
        EventSequence::new(next)
    }

    fn next_event_sequence_from_pending(&self, stream_id: &str, committed_next: u64) -> u64 {
        self.events
            .iter()
            .filter(|record| record.stream_id() == stream_id)
            .fold(committed_next, |next, record| {
                if record.sequence.as_u64() == 0 {
                    next + 1
                } else {
                    next.max(record.sequence.as_u64() + 1)
                }
            })
    }

    pub(crate) fn reserve_archive_id(&mut self, committed_next: u64) -> ArchiveId {
        let id = self.next_archive_id.unwrap_or(committed_next);
        self.next_archive_id = Some(id + 1);
        ArchiveId::new(id)
    }
}

pub trait PendingStoreWrite: Send {
    /// Performs every fallible pre-commit check for this staged in-memory write.
    ///
    /// `commit` is intentionally infallible so `InMemoryTransactionRunner` cannot model a
    /// partially applied transaction by returning an error after earlier staged writes have
    /// mutated state. Real SQLite/file-backed stores should perform durable writes inside their
    /// concrete database transaction runner rather than using this in-memory staging hook.
    fn validate(&self) -> StorageResult<()>;
    fn commit(self: Box<Self>);
}

#[derive(Default)]
pub struct InMemoryTransactionRunner {
    archive_store: InMemoryArchiveStore,
    event_store: InMemoryEventStore,
    transaction_lock: Arc<Mutex<()>>,
}

impl InMemoryTransactionRunner {
    pub fn archive_store(&self) -> InMemoryArchiveStore {
        self.archive_store.clone()
    }

    pub fn event_store(&self) -> InMemoryEventStore {
        self.event_store.clone()
    }
}

impl TransactionRunner for InMemoryTransactionRunner {
    fn run(
        &self,
        _name: TransactionName,
        operation: &mut dyn TransactionOperation,
    ) -> StorageResult<()> {
        let _guard = self
            .transaction_lock
            .lock()
            .expect("transaction runner mutex poisoned");
        let mut tx = UnitOfWork::default();
        operation.execute(&mut tx)?;
        let archives = tx.drain_archives();
        let mut events = tx.drain_events();
        let store_writes = tx.drain_store_writes();

        self.archive_store.validate_pending(&archives)?;
        self.event_store.validate_pending(&mut events)?;
        for write in &store_writes {
            write.validate()?;
        }

        for write in store_writes {
            write.commit();
        }
        self.archive_store.apply_pending(archives);
        self.event_store.apply_pending(events);

        Ok(())
    }
}
