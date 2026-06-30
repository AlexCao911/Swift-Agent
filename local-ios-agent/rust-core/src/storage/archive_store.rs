use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use super::{StorageError, StorageResult};

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct ArchiveId(u64);

impl ArchiveId {
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
        inner.next_id += 1;
        let id = ArchiveId(inner.next_id);
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
}
