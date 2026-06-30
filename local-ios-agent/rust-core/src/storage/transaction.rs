use std::fmt;

use super::archive_store::PendingArchiveRecord;
use super::{EventRecord, InMemoryArchiveStore, InMemoryEventStore};

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
}

impl UnitOfWork {
    pub(crate) fn drain_events(&mut self) -> Vec<EventRecord> {
        self.events.drain(..).collect()
    }
}

#[derive(Default)]
pub struct InMemoryTransactionRunner {
    archive_store: InMemoryArchiveStore,
    event_store: InMemoryEventStore,
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
        let mut tx = UnitOfWork::default();
        operation.execute(&mut tx)?;
        self.archive_store.commit(&mut tx)?;
        self.event_store.commit(&mut tx)
    }
}
