# Plan 6: Memory Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the durable MVP memory layer: long-term memory records, memory extraction candidates, keyword search, branch summaries, blob references, audit rows, and provider settings.

**Architecture:** `memory` owns persistence and retrieval. It does not decide runtime policy, execute tools, or build prompts. SQLite stores MVP memory data with exact keyword search backed by a normalized keyword table; vector search, SQLCipher, and iOS Data Protection are explicitly later hardening work.

**Tech Stack:** Rust 2021, existing `SqliteEventStore`, SQLite tables, `cargo test`, TDD.

---

## Current Code Audit

Checked current code with:

```bash
rg -n "long.?term|memory|blob|audit|provider_settings|BranchSummary|CompactionCreated" local-ios-agent/rust-core/src local-ios-agent/rust-core/tests
sed -n '1,260p' local-ios-agent/rust-core/src/memory/sqlite.rs
```

Observed:

- SQLite stores `sessions`, `events`, `event_paths`, and has an `audit_log`
  table but no API for it.
- `RuntimeEvent` has `blob_refs`, but there is no blob table/API.
- No long-term memory table, memory candidate, keyword index, branch summary
  table/API, provider settings API, or audit API exists.

Assigned to this plan:

- Long-term memory table.
- Memory extraction candidates.
- Keyword index.
- Branch summary persistence.
- Blob/image reference metadata.
- Audit/provider settings APIs.

Deferred:

- Semantic/vector index: post-MVP.
- SQLCipher and iOS Data Protection: after iOS storage location is final.

## File Structure

Create:

```text
local-ios-agent/rust-core/src/memory/long_term.rs
local-ios-agent/rust-core/src/memory/memory_candidate.rs
local-ios-agent/rust-core/src/memory/blob.rs
local-ios-agent/rust-core/src/memory/branch_summary.rs
local-ios-agent/rust-core/src/memory/audit.rs
local-ios-agent/rust-core/src/memory/provider_settings.rs
local-ios-agent/rust-core/tests/memory_foundation.rs
```

Modify:

```text
local-ios-agent/rust-core/src/memory/mod.rs
local-ios-agent/rust-core/src/memory/sqlite.rs
```

## Task 1: Add Long-Term Memory and Keyword Search

**Files:**
- Create: `local-ios-agent/rust-core/src/memory/long_term.rs`
- Modify: `local-ios-agent/rust-core/src/memory/mod.rs`
- Modify: `local-ios-agent/rust-core/src/memory/sqlite.rs`
- Test: `local-ios-agent/rust-core/tests/memory_foundation.rs`

- [ ] **Step 1: Write failing memory test**

Create `tests/memory_foundation.rs`:

```rust
use local_ios_agent_runtime::memory::{LongTermMemoryRecord, SqliteEventStore};

#[test]
fn sqlite_stores_and_searches_confirmed_memory() {
    let tempdir = tempfile::tempdir().unwrap();
    let store = SqliteEventStore::open(tempdir.path().join("agent.sqlite")).unwrap();

    store.upsert_memory(LongTermMemoryRecord {
        id: "mem_1".into(),
        text: "Alex prefers local-first private agents".into(),
        keywords: vec!["local-first".into(), "privacy".into()],
        confirmed: true,
    }).unwrap();

    assert_eq!(store.search_memory("privacy").unwrap()[0].id, "mem_1");
}
```

- [ ] **Step 2: Implement record and SQLite methods**

Create `src/memory/long_term.rs`:

```rust
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LongTermMemoryRecord {
    pub id: String,
    pub text: String,
    pub keywords: Vec<String>,
    pub confirmed: bool,
}
```

Add SQLite table:

```sql
create table if not exists long_term_memory (
  id text primary key,
  text text not null,
  keywords text not null,
  confirmed integer not null
);

create table if not exists long_term_memory_keywords (
  keyword text not null,
  memory_id text not null,
  primary key (keyword, memory_id)
);

create index if not exists idx_long_term_memory_keywords_keyword
on long_term_memory_keywords(keyword);
```

Add methods:

```rust
pub fn upsert_memory(&self, record: LongTermMemoryRecord) -> Result<(), AgentError>
pub fn search_memory(&self, keyword: &str) -> Result<Vec<LongTermMemoryRecord>, AgentError>
```

`upsert_memory` must keep `long_term_memory_keywords` in sync by deleting old keyword rows for the memory id and inserting the current keywords. `search_memory` must query through `long_term_memory_keywords` instead of scanning every confirmed memory row.

- [ ] **Step 3: Verify and commit**

Run:

```bash
cargo fmt
cargo test --test memory_foundation sqlite_stores_and_searches_confirmed_memory
cargo test --test memory_foundation sqlite_uses_keyword_index_for_memory_search
cargo test
```

Commit:

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/rust-core/src/memory/long_term.rs local-ios-agent/rust-core/src/memory/mod.rs local-ios-agent/rust-core/src/memory/sqlite.rs local-ios-agent/rust-core/tests/memory_foundation.rs
git commit -m "feat: add long term memory store"
```

## Task 2: Add Memory Extraction Candidate

**Files:**
- Create: `local-ios-agent/rust-core/src/memory/memory_candidate.rs`
- Modify: `local-ios-agent/rust-core/src/memory/mod.rs`
- Modify: `local-ios-agent/rust-core/src/memory/sqlite.rs`
- Modify: `local-ios-agent/rust-core/tests/memory_foundation.rs`

- [ ] **Step 1: Add candidate tests**

Append:

```rust
use local_ios_agent_runtime::memory::MemoryCandidate;

#[test]
fn memory_candidate_requires_confirmation() {
    let candidate = MemoryCandidate::new("likes local agents");

    assert!(!candidate.confirmed);
    assert_eq!(candidate.text, "likes local agents");
}

#[test]
fn sqlite_persists_confirmed_memory_candidate() {
    let tempdir = tempfile::tempdir().unwrap();
    let db_path = tempdir.path().join("agent.sqlite");
    let store = SqliteEventStore::open(&db_path).unwrap();

    store
        .save_memory_candidate(MemoryCandidate::new("likes local agents").confirm())
        .unwrap();
    drop(store);

    let reopened = SqliteEventStore::open(&db_path).unwrap();

    assert_eq!(
        reopened.memory_candidates().unwrap(),
        vec![MemoryCandidate {
            text: "likes local agents".into(),
            confirmed: true,
        }]
    );
}
```

- [ ] **Step 2: Implement candidate and SQLite APIs**

Create `src/memory/memory_candidate.rs`:

```rust
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MemoryCandidate {
    pub text: String,
    pub confirmed: bool,
}

impl MemoryCandidate {
    pub fn new(text: impl Into<String>) -> Self {
        Self { text: text.into(), confirmed: false }
    }

    pub fn confirm(mut self) -> Self {
        self.confirmed = true;
        self
    }
}
```

Add SQLite table:

```sql
create table if not exists memory_candidates (
  text text primary key,
  confirmed integer not null
);
```

Add methods:

```rust
pub fn save_memory_candidate(&self, candidate: MemoryCandidate) -> Result<(), AgentError>
pub fn memory_candidates(&self) -> Result<Vec<MemoryCandidate>, AgentError>
```

- [ ] **Step 3: Verify and commit**

Run:

```bash
cargo fmt
cargo test --test memory_foundation memory_candidate_requires_confirmation
cargo test --test memory_foundation sqlite_persists_confirmed_memory_candidate
cargo test
```

Commit:

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/rust-core/src/memory/memory_candidate.rs local-ios-agent/rust-core/src/memory/mod.rs local-ios-agent/rust-core/src/memory/sqlite.rs local-ios-agent/rust-core/tests/memory_foundation.rs
git commit -m "feat: add memory candidate"
```

## Task 3: Add Branch Summary and Blob Stores

**Files:**
- Create: `local-ios-agent/rust-core/src/memory/blob.rs`
- Create: `local-ios-agent/rust-core/src/memory/branch_summary.rs`
- Modify: `local-ios-agent/rust-core/src/memory/mod.rs`
- Modify: `local-ios-agent/rust-core/src/memory/sqlite.rs`
- Modify: `local-ios-agent/rust-core/tests/memory_foundation.rs`

- [ ] **Step 1: Add failing tests**

Append:

```rust
use local_ios_agent_runtime::memory::{BlobRecord, BranchSummaryRecord};

#[test]
fn sqlite_stores_blob_and_branch_summary() {
    let tempdir = tempfile::tempdir().unwrap();
    let store = SqliteEventStore::open(tempdir.path().join("agent.sqlite")).unwrap();

    store.put_blob(BlobRecord {
        id: "blob_1".into(),
        path: "/tmp/image.png".into(),
        mime_type: "image/png".into(),
        byte_count: 42,
    }).unwrap();
    store.put_branch_summary(BranchSummaryRecord {
        session_id: "session_1".into(),
        leaf_id: "entry_9".into(),
        summary: "summary".into(),
    }).unwrap();

    assert_eq!(store.get_blob("blob_1").unwrap().unwrap().mime_type, "image/png");
    assert_eq!(store.branch_summary("session_1", "entry_9").unwrap().unwrap().summary, "summary");
}

#[test]
fn sqlite_rejects_blob_byte_count_above_sqlite_integer_range() {
    let tempdir = tempfile::tempdir().unwrap();
    let store = SqliteEventStore::open(tempdir.path().join("agent.sqlite")).unwrap();

    let result = store.put_blob(BlobRecord {
        id: "blob_large".into(),
        path: "/tmp/large.bin".into(),
        mime_type: "application/octet-stream".into(),
        byte_count: i64::MAX as u64 + 1,
    });

    assert!(result.is_err());
}

#[test]
fn sqlite_rejects_negative_blob_byte_count_from_storage() {
    let tempdir = tempfile::tempdir().unwrap();
    let db_path = tempdir.path().join("agent.sqlite");
    let store = SqliteEventStore::open(&db_path).unwrap();
    drop(store);

    let conn = rusqlite::Connection::open(&db_path).unwrap();
    conn.execute(
        "
        insert into blobs(id, path, mime_type, byte_count)
        values (?1, ?2, ?3, ?4)
        ",
        rusqlite::params!["blob_negative", "/tmp/bad.bin", "application/octet-stream", -1],
    )
    .unwrap();
    drop(conn);

    let reopened = SqliteEventStore::open(&db_path).unwrap();

    assert!(reopened.get_blob("blob_negative").is_err());
}
```

- [ ] **Step 2: Implement records and SQLite APIs**

Create `blob.rs`:

```rust
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BlobRecord {
    pub id: String,
    pub path: String,
    pub mime_type: String,
    pub byte_count: u64,
}
```

Create `branch_summary.rs`:

```rust
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BranchSummaryRecord {
    pub session_id: String,
    pub leaf_id: String,
    pub summary: String,
}
```

Add SQLite tables `blobs` and `branch_summaries`, plus methods:

```rust
pub fn put_blob(&self, record: BlobRecord) -> Result<(), AgentError>
pub fn get_blob(&self, id: &str) -> Result<Option<BlobRecord>, AgentError>
pub fn put_branch_summary(&self, record: BranchSummaryRecord) -> Result<(), AgentError>
pub fn branch_summary(&self, session_id: &str, leaf_id: &str) -> Result<Option<BranchSummaryRecord>, AgentError>
```

`put_blob` must reject `byte_count` values that do not fit SQLite's signed integer range. `get_blob` must reject negative stored `byte_count` values instead of casting them to `u64`.

- [ ] **Step 3: Verify and commit**

Run:

```bash
cargo fmt
cargo test --test memory_foundation sqlite_stores_blob_and_branch_summary
cargo test --test memory_foundation blob_byte_count
cargo test
```

Commit:

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/rust-core/src/memory/blob.rs local-ios-agent/rust-core/src/memory/branch_summary.rs local-ios-agent/rust-core/src/memory/mod.rs local-ios-agent/rust-core/src/memory/sqlite.rs local-ios-agent/rust-core/tests/memory_foundation.rs
git commit -m "feat: add blob and branch summary stores"
```

## Task 4: Add Audit and Provider Settings APIs

**Files:**
- Create: `local-ios-agent/rust-core/src/memory/audit.rs`
- Create: `local-ios-agent/rust-core/src/memory/provider_settings.rs`
- Modify: `local-ios-agent/rust-core/src/memory/mod.rs`
- Modify: `local-ios-agent/rust-core/src/memory/sqlite.rs`
- Modify: `local-ios-agent/rust-core/tests/memory_foundation.rs`

- [ ] **Step 1: Add failing audit/settings test**

Append:

```rust
#[test]
fn sqlite_persists_audit_rows_and_provider_settings() {
    let tempdir = tempfile::tempdir().unwrap();
    let store = SqliteEventStore::open(tempdir.path().join("agent.sqlite")).unwrap();

    store.write_audit("session_1", "entry_1", "tool executed").unwrap();
    store.save_provider_setting("active_provider", "mock").unwrap();

    assert_eq!(store.audit_rows("session_1").unwrap()[0].summary, "tool executed");
    assert_eq!(store.provider_setting("active_provider").unwrap(), Some("mock".into()));
}
```

- [ ] **Step 2: Implement records and APIs**

Create `audit.rs`:

```rust
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AuditRow {
    pub session_id: String,
    pub event_id: String,
    pub summary: String,
}
```

Create `provider_settings.rs`:

```rust
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProviderSetting {
    pub key: String,
    pub value: String,
}
```

Add SQLite table:

```sql
create table if not exists provider_settings (
  key text primary key,
  value text not null
);
```

Add methods:

```rust
pub fn write_audit(&self, session_id: &str, event_id: &str, summary: &str) -> Result<(), AgentError>
pub fn audit_rows(&self, session_id: &str) -> Result<Vec<AuditRow>, AgentError>
pub fn save_provider_setting(&self, key: &str, value: &str) -> Result<(), AgentError>
pub fn provider_setting(&self, key: &str) -> Result<Option<String>, AgentError>
```

- [ ] **Step 3: Verify and commit**

Run:

```bash
cargo fmt
cargo test --test memory_foundation sqlite_persists_audit_rows_and_provider_settings
cargo test
```

Commit:

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/rust-core/src/memory/audit.rs local-ios-agent/rust-core/src/memory/provider_settings.rs local-ios-agent/rust-core/src/memory/mod.rs local-ios-agent/rust-core/src/memory/sqlite.rs local-ios-agent/rust-core/tests/memory_foundation.rs
git commit -m "feat: add audit and provider settings"
```

## Exit Criteria

- Confirmed long-term memory can be stored and keyword searched.
- Keyword search is backed by `long_term_memory_keywords` and stale keyword rows are removed on update.
- Memory candidates require confirmation before promotion and are persisted before restart.
- Branch summaries are persisted.
- Blob/image metadata is persisted separately from event payloads, with checked `byte_count` conversion at the SQLite integer boundary.
- Audit rows can be written and listed.
- Provider settings are persisted.
- `cargo test` passes.
