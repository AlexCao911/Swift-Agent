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
}

impl ArchiveRecord {
    pub fn new(run_id: impl Into<String>, kind: impl Into<String>) -> Self {
        Self {
            run_id: run_id.into(),
            kind: kind.into(),
        }
    }

    pub fn run_id(&self) -> &str {
        &self.run_id
    }

    pub fn kind(&self) -> &str {
        &self.kind
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
    pub fn append(&self, record: ArchiveRecord) -> StorageResult<ArchiveId> {
        let mut inner = self.inner.lock().expect("archive store mutex poisoned");
        let id = inner.next_id();
        inner.records.insert(id, record);
        Ok(id)
    }

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

    pub(crate) fn commit(&self, tx: &mut UnitOfWork) -> StorageResult<()> {
        let records = tx.drain_archives();
        if records.is_empty() {
            return Ok(());
        }

        let mut inner = self.inner.lock().expect("archive store mutex poisoned");
        if records
            .iter()
            .any(|pending| inner.records.contains_key(&pending.id))
        {
            return Err(StorageError::new(
                "storage.archive_conflict",
                "archive id already exists",
            ));
        }

        for pending in records {
            inner.records.insert(pending.id, pending.record);
        }

        Ok(())
    }
}

impl ArchiveStore for InMemoryArchiveStore {
    fn append_immutable(
        &self,
        tx: &mut UnitOfWork,
        record: ArchiveRecord,
    ) -> StorageResult<ArchiveId> {
        let mut inner = self.inner.lock().expect("archive store mutex poisoned");
        let id = inner.next_id();
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
    fn next_id(&mut self) -> ArchiveId {
        self.next_id += 1;
        ArchiveId(self.next_id)
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
