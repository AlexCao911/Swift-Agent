use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use super::{StorageError, StorageResult, UnitOfWork};

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct ArchiveId(u64);

impl ArchiveId {
    pub const fn new(value: u64) -> Self {
        Self(value)
    }

    pub const fn as_u64(self) -> u64 {
        self.0
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ArchiveRecord {
    run_id: String,
    kind: String,
    payload: String,
}

impl ArchiveRecord {
    pub fn new(run_id: impl Into<String>, kind: impl Into<String>) -> Self {
        Self {
            run_id: run_id.into(),
            kind: kind.into(),
            payload: String::new(),
        }
    }

    pub fn with_payload(
        run_id: impl Into<String>,
        kind: impl Into<String>,
        payload: impl Into<String>,
    ) -> Self {
        Self {
            run_id: run_id.into(),
            kind: kind.into(),
            payload: payload.into(),
        }
    }

    pub fn run_id(&self) -> &str {
        &self.run_id
    }

    pub fn kind(&self) -> &str {
        &self.kind
    }

    pub fn payload(&self) -> &str {
        &self.payload
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct PendingArchiveRecord {
    id: ArchiveId,
    record: ArchiveRecord,
}

impl PendingArchiveRecord {
    fn new(id: ArchiveId, record: ArchiveRecord) -> Self {
        Self { id, record }
    }
}

pub trait ArchiveStore: Send + Sync {
    fn append_immutable(
        &self,
        tx: &mut UnitOfWork,
        record: ArchiveRecord,
    ) -> StorageResult<ArchiveId>;
    fn get(&self, id: ArchiveId) -> StorageResult<ArchiveRecord>;
    fn replace(&self, id: ArchiveId, record: ArchiveRecord) -> StorageResult<()>;
}

#[derive(Clone, Debug, Default)]
pub struct InMemoryArchiveStore {
    inner: Arc<Mutex<InMemoryArchiveStoreInner>>,
}

#[derive(Debug, Default)]
struct InMemoryArchiveStoreInner {
    next_id: u64,
    records: BTreeMap<ArchiveId, ArchiveRecord>,
}

impl InMemoryArchiveStore {
    pub fn get(&self, id: ArchiveId) -> StorageResult<ArchiveRecord> {
        let inner = self.inner.lock().expect("archive store mutex poisoned");
        inner
            .records
            .get(&id)
            .cloned()
            .ok_or_else(|| StorageError::new("storage.archive_not_found", "archive not found"))
    }

    pub fn replace(&self, _id: ArchiveId, _record: ArchiveRecord) -> StorageResult<()> {
        Err(StorageError::new(
            "storage.archive_append_only",
            "archive records are append-only",
        ))
    }

    pub fn records(&self) -> Vec<ArchiveRecord> {
        let inner = self.inner.lock().expect("archive store mutex poisoned");
        inner.records.values().cloned().collect()
    }

    pub(crate) fn validate_pending(&self, records: &[PendingArchiveRecord]) -> StorageResult<()> {
        if records.is_empty() {
            return Ok(());
        }

        let inner = self.inner.lock().expect("archive store mutex poisoned");
        let mut next_id = inner.next_id_value();

        for pending in records {
            if pending.id.as_u64() != next_id || inner.records.contains_key(&pending.id) {
                return Err(StorageError::new(
                    "storage.archive_conflict",
                    "archive id already exists or is out of order",
                ));
            }
            next_id += 1;
        }

        Ok(())
    }

    pub(crate) fn apply_pending(&self, records: Vec<PendingArchiveRecord>) {
        let mut inner = self.inner.lock().expect("archive store mutex poisoned");
        for pending in records {
            inner.advance_next_id(pending.id);
            inner.records.insert(pending.id, pending.record);
        }
    }
}

impl ArchiveStore for InMemoryArchiveStore {
    fn append_immutable(
        &self,
        tx: &mut UnitOfWork,
        record: ArchiveRecord,
    ) -> StorageResult<ArchiveId> {
        let inner = self.inner.lock().expect("archive store mutex poisoned");
        let id = tx.reserve_archive_id(inner.next_id_value());
        tx.push_archive(PendingArchiveRecord::new(id, record));
        Ok(id)
    }

    fn get(&self, id: ArchiveId) -> StorageResult<ArchiveRecord> {
        InMemoryArchiveStore::get(self, id)
    }

    fn replace(&self, id: ArchiveId, record: ArchiveRecord) -> StorageResult<()> {
        InMemoryArchiveStore::replace(self, id, record)
    }
}

impl InMemoryArchiveStoreInner {
    fn next_id_value(&self) -> u64 {
        self.next_id + 1
    }

    fn advance_next_id(&mut self, id: ArchiveId) {
        self.next_id = self.next_id.max(id.as_u64());
    }
}

impl UnitOfWork {
    pub(crate) fn push_archive(&mut self, record: PendingArchiveRecord) {
        self.archives.push(record);
    }

    pub(crate) fn drain_archives(&mut self) -> Vec<PendingArchiveRecord> {
        self.archives.drain(..).collect()
    }
}
