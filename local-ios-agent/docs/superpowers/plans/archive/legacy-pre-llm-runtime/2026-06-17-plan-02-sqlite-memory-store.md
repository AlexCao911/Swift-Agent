# Plan 2: SQLite Memory Store Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a SQLite-backed event store for the Rust runtime memory layer while preserving the existing in-memory tests and runtime behavior.

**Architecture:** Introduce an `EventStore` trait in `memory`, make `SessionTree` generic over that trait, then implement `SqliteEventStore` with the same closure-table semantics as `InMemoryEventStore`. Keep `AgentRuntime` on the in-memory default for now; SQLite is added as a tested persistence backend without forcing Swift/UniFFI decisions yet.

**Tech Stack:** Rust 2021, `rusqlite` with bundled SQLite, `tempfile` for tests, `cargo test`, TDD.

---

## Scope

This is Plan 2 of the MVP. It implements the SQLite persistence boundary under:

```text
/Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
```

It does not implement:

- SwiftUI integration.
- UniFFI bindings.
- SQLCipher encryption.
- Blob file storage.
- Provider settings UI.
- Runtime process restart recovery.

## File Structure

Create:

```text
local-ios-agent/rust-core/src/memory/event_store.rs
local-ios-agent/rust-core/src/memory/sqlite.rs
local-ios-agent/rust-core/tests/sqlite_store.rs
```

Modify:

```text
local-ios-agent/rust-core/Cargo.toml
local-ios-agent/rust-core/src/core/runtime.rs
local-ios-agent/rust-core/src/core/session_tree.rs
local-ios-agent/rust-core/src/memory/in_memory.rs
local-ios-agent/rust-core/src/memory/mod.rs
local-ios-agent/rust-core/tests/session_tree.rs
```

## Task 1: Extract EventStore Trait

**Files:**
- Create: `local-ios-agent/rust-core/src/memory/event_store.rs`
- Modify: `local-ios-agent/rust-core/src/memory/in_memory.rs`
- Modify: `local-ios-agent/rust-core/src/memory/mod.rs`

- [ ] **Step 1: Add EventStore trait**

Create `local-ios-agent/rust-core/src/memory/event_store.rs`:

```rust
use crate::core::{AgentError, EntryId, RuntimeEvent, SessionId};

pub trait EventStore {
    fn append(&mut self, event: RuntimeEvent) -> Result<(), AgentError>;
    fn get(&self, session_id: &SessionId, entry_id: &EntryId) -> Result<RuntimeEvent, AgentError>;
    fn active_branch(
        &self,
        session_id: &SessionId,
        leaf_id: &EntryId,
    ) -> Result<Vec<RuntimeEvent>, AgentError>;
}
```

- [ ] **Step 2: Implement trait for InMemoryEventStore**

In `local-ios-agent/rust-core/src/memory/in_memory.rs`, add this import:

```rust
use crate::memory::EventStore;
```

Then change the existing `impl InMemoryEventStore` so it contains `new()`, API-compatible forwarding methods, and `insert_paths()`:

```rust
impl InMemoryEventStore {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn append(&mut self, event: RuntimeEvent) -> Result<(), AgentError> {
        <Self as EventStore>::append(self, event)
    }

    pub fn get(
        &self,
        session_id: &SessionId,
        entry_id: &EntryId,
    ) -> Result<RuntimeEvent, AgentError> {
        <Self as EventStore>::get(self, session_id, entry_id)
    }

    pub fn active_branch(
        &self,
        session_id: &SessionId,
        leaf_id: &EntryId,
    ) -> Result<Vec<RuntimeEvent>, AgentError> {
        <Self as EventStore>::active_branch(self, session_id, leaf_id)
    }

    fn insert_paths(&mut self, event: &RuntimeEvent) {
        self.paths.push(PathRow {
            key: PathKey {
                session_id: event.session_id.clone(),
                ancestor_id: event.id.clone(),
                descendant_id: event.id.clone(),
            },
            depth_delta: 0,
        });

        if let Some(parent_id) = &event.parent_id {
            let parent_rows: Vec<_> = self
                .paths
                .iter()
                .filter(|row| {
                    row.key.session_id == event.session_id && row.key.descendant_id == *parent_id
                })
                .cloned()
                .collect();

            for row in parent_rows {
                self.paths.push(PathRow {
                    key: PathKey {
                        session_id: event.session_id.clone(),
                        ancestor_id: row.key.ancestor_id,
                        descendant_id: event.id.clone(),
                    },
                    depth_delta: row.depth_delta + 1,
                });
            }
        }
    }
}
```

Add this trait implementation below it:

```rust
impl EventStore for InMemoryEventStore {
    fn append(&mut self, event: RuntimeEvent) -> Result<(), AgentError> {
        let key = (event.session_id.clone(), event.id.clone());
        if self.events.contains_key(&key) {
            return Err(AgentError::Storage(format!(
                "event already exists: {}",
                event.id.0
            )));
        }

        if let Some(parent_id) = &event.parent_id {
            let parent_key = (event.session_id.clone(), parent_id.clone());
            if !self.events.contains_key(&parent_key) {
                return Err(AgentError::Storage(format!(
                    "missing parent event: {}",
                    parent_id.0
                )));
            }
        }

        self.insert_paths(&event);

        if let Some(parent_id) = &event.parent_id {
            self.children
                .entry((event.session_id.clone(), parent_id.clone()))
                .or_default()
                .insert(event.id.clone());
        }

        self.events.insert(key, event);
        Ok(())
    }

    fn get(
        &self,
        session_id: &SessionId,
        entry_id: &EntryId,
    ) -> Result<RuntimeEvent, AgentError> {
        self.events
            .get(&(session_id.clone(), entry_id.clone()))
            .cloned()
            .ok_or_else(|| AgentError::Storage(format!("event not found: {}", entry_id.0)))
    }

    fn active_branch(
        &self,
        session_id: &SessionId,
        leaf_id: &EntryId,
    ) -> Result<Vec<RuntimeEvent>, AgentError> {
        let mut rows: Vec<_> = self
            .paths
            .iter()
            .filter(|row| row.key.session_id == *session_id && row.key.descendant_id == *leaf_id)
            .collect();

        if rows.is_empty() {
            return Err(AgentError::Storage(format!(
                "leaf has no path rows: {}",
                leaf_id.0
            )));
        }

        rows.sort_by_key(|row| row.depth_delta);
        rows.reverse();

        let mut events = Vec::with_capacity(rows.len());
        for row in rows {
            events.push(self.get(session_id, &row.key.ancestor_id)?);
        }
        events.sort_by_key(|event| (event.depth, event.sequence));
        Ok(events)
    }
}
```

- [ ] **Step 3: Export EventStore**

Replace `local-ios-agent/rust-core/src/memory/mod.rs` with:

```rust
pub mod event_store;
pub mod in_memory;

pub use event_store::EventStore;
pub use in_memory::InMemoryEventStore;
```

- [ ] **Step 4: Run tests**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo fmt
cargo test
```

Expected:

```text
test result: ok
```

- [ ] **Step 5: Commit**

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/rust-core/src/memory/event_store.rs local-ios-agent/rust-core/src/memory/in_memory.rs local-ios-agent/rust-core/src/memory/mod.rs
git commit -m "feat: add event store trait"
```

## Task 2: Make SessionTree Generic Over EventStore

**Files:**
- Modify: `local-ios-agent/rust-core/src/core/session_tree.rs`
- Modify: `local-ios-agent/rust-core/src/core/runtime.rs`
- Modify: `local-ios-agent/rust-core/tests/session_tree.rs`

- [ ] **Step 1: Write failing custom-store test**

Append this test to `local-ios-agent/rust-core/tests/session_tree.rs`:

```rust
#[test]
fn session_tree_can_be_constructed_with_explicit_store() {
    let mut tree = SessionTree::with_store(
        SessionId("session_3".to_string()),
        InMemoryEventStore::new(),
    );
    let root = tree
        .append(None, EventKind::SessionCreated, "created")
        .unwrap();

    assert_eq!(tree.active_leaf(), Some(&root));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo test --test session_tree session_tree_can_be_constructed_with_explicit_store
```

Expected:

```text
error[E0599]: no function or associated item named `with_store`
```

- [ ] **Step 3: Update SessionTree**

Replace `local-ios-agent/rust-core/src/core/session_tree.rs` with:

```rust
use crate::core::{AgentError, EntryId, EventKind, RuntimeEvent, SessionId};
use crate::memory::{EventStore, InMemoryEventStore};
use crate::utils::id::IdGenerator;

#[derive(Debug)]
pub struct SessionTree<S: EventStore = InMemoryEventStore> {
    session_id: SessionId,
    store: S,
    ids: IdGenerator,
    active_leaf: Option<EntryId>,
    sequence: u64,
}

impl SessionTree<InMemoryEventStore> {
    pub fn new(session_id: SessionId) -> Self {
        Self::with_store(session_id, InMemoryEventStore::new())
    }
}

impl<S: EventStore> SessionTree<S> {
    pub fn with_store(session_id: SessionId, store: S) -> Self {
        Self {
            session_id,
            store,
            ids: IdGenerator::new(),
            active_leaf: None,
            sequence: 1,
        }
    }

    pub fn active_leaf(&self) -> Option<&EntryId> {
        self.active_leaf.as_ref()
    }

    pub fn append(
        &mut self,
        parent_id: Option<EntryId>,
        kind: EventKind,
        payload: impl Into<String>,
    ) -> Result<EntryId, AgentError> {
        let depth = match &parent_id {
            Some(parent) => self.store.get(&self.session_id, parent)?.depth + 1,
            None => 0,
        };
        let id = EntryId(self.ids.next_id("entry"));
        let event = RuntimeEvent::new(
            id.clone(),
            self.session_id.clone(),
            parent_id,
            None,
            self.sequence,
            depth,
            kind,
            payload,
        );
        self.sequence += 1;
        self.store.append(event)?;
        self.active_leaf = Some(id.clone());
        Ok(id)
    }

    pub fn active_branch(&self, leaf_id: &EntryId) -> Result<Vec<RuntimeEvent>, AgentError> {
        self.store.active_branch(&self.session_id, leaf_id)
    }
}
```

- [ ] **Step 4: Update AgentRuntime session map type**

In `local-ios-agent/rust-core/src/core/runtime.rs`, update the `sessions` field type:

```rust
sessions: HashMap<SessionId, SessionTree>,
```

This line may already be correct because `SessionTree` has a default store type. If `cargo test` compiles without change, leave it unchanged.

- [ ] **Step 5: Run tests**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo fmt
cargo test --test session_tree
cargo test
```

Expected:

```text
test result: ok
```

- [ ] **Step 6: Commit**

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/rust-core/src/core/session_tree.rs local-ios-agent/rust-core/src/core/runtime.rs local-ios-agent/rust-core/tests/session_tree.rs
git commit -m "feat: make session tree store generic"
```

## Task 3: Add SQLite Dependencies and Store Skeleton

**Files:**
- Modify: `local-ios-agent/rust-core/Cargo.toml`
- Create: `local-ios-agent/rust-core/src/memory/sqlite.rs`
- Modify: `local-ios-agent/rust-core/src/memory/mod.rs`
- Test: `local-ios-agent/rust-core/tests/sqlite_store.rs`

- [ ] **Step 1: Add dependencies**

Modify `local-ios-agent/rust-core/Cargo.toml`:

```toml
[dependencies]
rusqlite = { version = "0.32", features = ["bundled"] }

[dev-dependencies]
tempfile = "3.10"
```

- [ ] **Step 2: Write failing open-and-migrate test**

Create `local-ios-agent/rust-core/tests/sqlite_store.rs`:

```rust
use local_ios_agent_runtime::memory::SqliteEventStore;

#[test]
fn sqlite_store_opens_and_creates_schema() {
    let tempdir = tempfile::tempdir().unwrap();
    let db_path = tempdir.path().join("agent.sqlite");

    let store = SqliteEventStore::open(&db_path).unwrap();

    assert_eq!(store.schema_version().unwrap(), 1);
}
```

- [ ] **Step 3: Run test to verify it fails**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo test --test sqlite_store sqlite_store_opens_and_creates_schema
```

Expected:

```text
unresolved import `local_ios_agent_runtime::memory::SqliteEventStore`
```

- [ ] **Step 4: Implement SQLite store skeleton**

Create `local-ios-agent/rust-core/src/memory/sqlite.rs`:

```rust
use std::path::Path;

use rusqlite::{params, Connection};

use crate::core::AgentError;

pub struct SqliteEventStore {
    conn: Connection,
}

impl SqliteEventStore {
    pub fn open(path: impl AsRef<Path>) -> Result<Self, AgentError> {
        let conn = Connection::open(path).map_err(storage_error)?;
        let store = Self { conn };
        store.migrate()?;
        Ok(store)
    }

    pub fn schema_version(&self) -> Result<i64, AgentError> {
        self.conn
            .query_row("select version from schema_meta", [], |row| row.get(0))
            .map_err(storage_error)
    }

    fn migrate(&self) -> Result<(), AgentError> {
        self.conn
            .execute_batch(
                "
                create table if not exists schema_meta (
                  version integer not null
                );

                insert into schema_meta(version)
                select 1
                where not exists (select 1 from schema_meta);
                ",
            )
            .map_err(storage_error)?;

        let version = self.schema_version()?;
        if version != 1 {
            return Err(AgentError::Storage(format!(
                "unsupported sqlite schema version: {version}"
            )));
        }
        Ok(())
    }
}

fn storage_error(error: rusqlite::Error) -> AgentError {
    AgentError::Storage(error.to_string())
}
```

- [ ] **Step 5: Export SQLite store**

Replace `local-ios-agent/rust-core/src/memory/mod.rs` with:

```rust
pub mod event_store;
pub mod in_memory;
pub mod sqlite;

pub use event_store::EventStore;
pub use in_memory::InMemoryEventStore;
pub use sqlite::SqliteEventStore;
```

- [ ] **Step 6: Run test**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo fmt
cargo test --test sqlite_store sqlite_store_opens_and_creates_schema
```

Expected:

```text
test sqlite_store_opens_and_creates_schema ... ok
```

- [ ] **Step 7: Commit**

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/rust-core/Cargo.toml local-ios-agent/rust-core/Cargo.lock local-ios-agent/rust-core/src/memory/mod.rs local-ios-agent/rust-core/src/memory/sqlite.rs local-ios-agent/rust-core/tests/sqlite_store.rs
git commit -m "feat: add sqlite event store skeleton"
```

## Task 4: Create SQLite Event Tables

**Files:**
- Modify: `local-ios-agent/rust-core/src/memory/sqlite.rs`
- Modify: `local-ios-agent/rust-core/tests/sqlite_store.rs`

- [ ] **Step 1: Add failing table existence test**

Append to `local-ios-agent/rust-core/tests/sqlite_store.rs`:

```rust
#[test]
fn sqlite_store_creates_event_tables() {
    let tempdir = tempfile::tempdir().unwrap();
    let db_path = tempdir.path().join("agent.sqlite");
    let store = SqliteEventStore::open(&db_path).unwrap();

    let tables = store.table_names().unwrap();

    assert!(tables.contains(&"sessions".to_string()));
    assert!(tables.contains(&"events".to_string()));
    assert!(tables.contains(&"event_paths".to_string()));
    assert!(tables.contains(&"audit_log".to_string()));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo test --test sqlite_store sqlite_store_creates_event_tables
```

Expected:

```text
no method named `table_names`
```

- [ ] **Step 3: Expand migration**

In `local-ios-agent/rust-core/src/memory/sqlite.rs`, replace `migrate()` with:

```rust
    fn migrate(&self) -> Result<(), AgentError> {
        self.conn
            .execute_batch(
                "
                create table if not exists schema_meta (
                  version integer not null
                );

                insert into schema_meta(version)
                select 1
                where not exists (select 1 from schema_meta);

                create table if not exists sessions (
                  id text primary key,
                  active_leaf_id text
                );

                create table if not exists events (
                  id text not null,
                  session_id text not null,
                  parent_id text,
                  run_id text,
                  sequence integer not null,
                  depth integer not null,
                  kind text not null,
                  payload text not null,
                  blob_refs text not null default '',
                  primary key (session_id, id)
                );

                create table if not exists event_paths (
                  session_id text not null,
                  ancestor_id text not null,
                  descendant_id text not null,
                  depth_delta integer not null,
                  primary key (session_id, ancestor_id, descendant_id)
                );

                create index if not exists idx_event_paths_descendant
                on event_paths(session_id, descendant_id, depth_delta);

                create table if not exists audit_log (
                  id integer primary key autoincrement,
                  session_id text not null,
                  event_id text not null,
                  summary text not null
                );
                ",
            )
            .map_err(storage_error)?;

        let version = self.schema_version()?;
        if version != 1 {
            return Err(AgentError::Storage(format!(
                "unsupported sqlite schema version: {version}"
            )));
        }
        Ok(())
    }
```

Add this method to `impl SqliteEventStore`:

```rust
    pub fn table_names(&self) -> Result<Vec<String>, AgentError> {
        let mut statement = self
            .conn
            .prepare("select name from sqlite_master where type = 'table' order by name")
            .map_err(storage_error)?;
        let rows = statement
            .query_map([], |row| row.get::<_, String>(0))
            .map_err(storage_error)?;

        let mut names = Vec::new();
        for row in rows {
            names.push(row.map_err(storage_error)?);
        }
        Ok(names)
    }
```

- [ ] **Step 4: Run test**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo fmt
cargo test --test sqlite_store sqlite_store_creates_event_tables
```

Expected:

```text
test sqlite_store_creates_event_tables ... ok
```

- [ ] **Step 5: Commit**

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/rust-core/src/memory/sqlite.rs local-ios-agent/rust-core/tests/sqlite_store.rs
git commit -m "feat: add sqlite event schema"
```

## Task 5: Implement SQLite EventStore Append and Read

**Files:**
- Modify: `local-ios-agent/rust-core/src/memory/sqlite.rs`
- Modify: `local-ios-agent/rust-core/tests/sqlite_store.rs`

- [ ] **Step 1: Add failing append/get test**

Append to `local-ios-agent/rust-core/tests/sqlite_store.rs`:

```rust
use local_ios_agent_runtime::core::{EntryId, EventKind, RuntimeEvent, SessionId};
use local_ios_agent_runtime::memory::EventStore;

fn sqlite_event(
    id: &str,
    parent: Option<&str>,
    sequence: u64,
    depth: u32,
    payload: &str,
) -> RuntimeEvent {
    RuntimeEvent::new(
        EntryId(id.to_string()),
        SessionId("session_sqlite".to_string()),
        parent.map(|value| EntryId(value.to_string())),
        None,
        sequence,
        depth,
        EventKind::UserMessage,
        payload,
    )
}

#[test]
fn sqlite_store_appends_and_reads_event() {
    let tempdir = tempfile::tempdir().unwrap();
    let db_path = tempdir.path().join("agent.sqlite");
    let mut store = SqliteEventStore::open(&db_path).unwrap();

    store
        .append(sqlite_event("root", None, 1, 0, "root"))
        .unwrap();

    let event = store
        .get(
            &SessionId("session_sqlite".to_string()),
            &EntryId("root".to_string()),
        )
        .unwrap();

    assert_eq!(event.payload, "root");
    assert_eq!(event.kind, EventKind::UserMessage);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo test --test sqlite_store sqlite_store_appends_and_reads_event
```

Expected:

```text
the method `append` exists for struct `SqliteEventStore`, but its trait bounds were not satisfied
```

- [ ] **Step 3: Add event kind serialization helpers**

In `local-ios-agent/rust-core/src/memory/sqlite.rs`, add these imports:

```rust
use crate::core::{AgentError, EntryId, EventKind, RuntimeEvent, SessionId};
use crate::memory::EventStore;
```

Then add helper functions at the bottom:

```rust
fn event_kind_to_str(kind: &EventKind) -> &'static str {
    match kind {
        EventKind::SessionCreated => "SessionCreated",
        EventKind::ProviderChanged => "ProviderChanged",
        EventKind::ToolRegistered => "ToolRegistered",
        EventKind::UserMessage => "UserMessage",
        EventKind::AssistantMessageStarted => "AssistantMessageStarted",
        EventKind::AssistantTextDelta => "AssistantTextDelta",
        EventKind::AssistantMessageCompleted => "AssistantMessageCompleted",
        EventKind::ToolCallRequested => "ToolCallRequested",
        EventKind::ToolCallApproved => "ToolCallApproved",
        EventKind::ToolCallRejected => "ToolCallRejected",
        EventKind::ToolExecutionStarted => "ToolExecutionStarted",
        EventKind::ToolExecutionUpdate => "ToolExecutionUpdate",
        EventKind::ToolExecutionCompleted => "ToolExecutionCompleted",
        EventKind::ToolExecutionFailed => "ToolExecutionFailed",
        EventKind::ToolResultMessage => "ToolResultMessage",
        EventKind::RunSuspended => "RunSuspended",
        EventKind::RunResumed => "RunResumed",
        EventKind::CompactionCreated => "CompactionCreated",
        EventKind::BranchSummaryCreated => "BranchSummaryCreated",
        EventKind::RunCancelled => "RunCancelled",
        EventKind::RunFailed => "RunFailed",
    }
}

fn event_kind_from_str(value: &str) -> Result<EventKind, AgentError> {
    match value {
        "SessionCreated" => Ok(EventKind::SessionCreated),
        "ProviderChanged" => Ok(EventKind::ProviderChanged),
        "ToolRegistered" => Ok(EventKind::ToolRegistered),
        "UserMessage" => Ok(EventKind::UserMessage),
        "AssistantMessageStarted" => Ok(EventKind::AssistantMessageStarted),
        "AssistantTextDelta" => Ok(EventKind::AssistantTextDelta),
        "AssistantMessageCompleted" => Ok(EventKind::AssistantMessageCompleted),
        "ToolCallRequested" => Ok(EventKind::ToolCallRequested),
        "ToolCallApproved" => Ok(EventKind::ToolCallApproved),
        "ToolCallRejected" => Ok(EventKind::ToolCallRejected),
        "ToolExecutionStarted" => Ok(EventKind::ToolExecutionStarted),
        "ToolExecutionUpdate" => Ok(EventKind::ToolExecutionUpdate),
        "ToolExecutionCompleted" => Ok(EventKind::ToolExecutionCompleted),
        "ToolExecutionFailed" => Ok(EventKind::ToolExecutionFailed),
        "ToolResultMessage" => Ok(EventKind::ToolResultMessage),
        "RunSuspended" => Ok(EventKind::RunSuspended),
        "RunResumed" => Ok(EventKind::RunResumed),
        "CompactionCreated" => Ok(EventKind::CompactionCreated),
        "BranchSummaryCreated" => Ok(EventKind::BranchSummaryCreated),
        "RunCancelled" => Ok(EventKind::RunCancelled),
        "RunFailed" => Ok(EventKind::RunFailed),
        _ => Err(AgentError::Storage(format!("unknown event kind: {value}"))),
    }
}
```

- [ ] **Step 4: Implement append/get**

Add this implementation to `local-ios-agent/rust-core/src/memory/sqlite.rs`:

```rust
impl EventStore for SqliteEventStore {
    fn append(&mut self, event: RuntimeEvent) -> Result<(), AgentError> {
        if let Some(parent_id) = &event.parent_id {
            self.get(&event.session_id, parent_id)?;
        }

        let tx = self.conn.transaction().map_err(storage_error)?;
        tx.execute(
            "
            insert into sessions(id, active_leaf_id)
            values (?1, ?2)
            on conflict(id) do update set active_leaf_id = excluded.active_leaf_id
            ",
            params![event.session_id.0, event.id.0],
        )
        .map_err(storage_error)?;

        tx.execute(
            "
            insert into events(
              id, session_id, parent_id, run_id, sequence, depth, kind, payload, blob_refs
            )
            values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
            ",
            params![
                event.id.0,
                event.session_id.0,
                event.parent_id.as_ref().map(|id| id.0.as_str()),
                event.run_id.as_ref().map(|id| id.0.as_str()),
                event.sequence as i64,
                event.depth as i64,
                event_kind_to_str(&event.kind),
                event.payload,
                event.blob_refs.join("\n"),
            ],
        )
        .map_err(storage_error)?;

        tx.execute(
            "
            insert into event_paths(session_id, ancestor_id, descendant_id, depth_delta)
            values (?1, ?2, ?3, 0)
            ",
            params![event.session_id.0, event.id.0, event.id.0],
        )
        .map_err(storage_error)?;

        if let Some(parent_id) = &event.parent_id {
            tx.execute(
                "
                insert into event_paths(session_id, ancestor_id, descendant_id, depth_delta)
                select session_id, ancestor_id, ?1, depth_delta + 1
                from event_paths
                where session_id = ?2 and descendant_id = ?3
                ",
                params![event.id.0, event.session_id.0, parent_id.0],
            )
            .map_err(storage_error)?;
        }

        tx.commit().map_err(storage_error)?;
        Ok(())
    }

    fn get(
        &self,
        session_id: &SessionId,
        entry_id: &EntryId,
    ) -> Result<RuntimeEvent, AgentError> {
        self.conn
            .query_row(
                "
                select id, session_id, parent_id, run_id, sequence, depth, kind, payload, blob_refs
                from events
                where session_id = ?1 and id = ?2
                ",
                params![session_id.0, entry_id.0],
                |row| {
                    let id: String = row.get(0)?;
                    let session_id: String = row.get(1)?;
                    let parent_id: Option<String> = row.get(2)?;
                    let run_id: Option<String> = row.get(3)?;
                    let sequence: i64 = row.get(4)?;
                    let depth: i64 = row.get(5)?;
                    let kind: String = row.get(6)?;
                    let payload: String = row.get(7)?;
                    let blob_refs: String = row.get(8)?;
                    Ok((
                        id,
                        session_id,
                        parent_id,
                        run_id,
                        sequence,
                        depth,
                        kind,
                        payload,
                        blob_refs,
                    ))
                },
            )
            .map_err(storage_error)
            .and_then(
                |(id, session_id, parent_id, run_id, sequence, depth, kind, payload, blob_refs)| {
                    Ok(RuntimeEvent {
                        id: EntryId(id),
                        session_id: SessionId(session_id),
                        parent_id: parent_id.map(EntryId),
                        run_id: run_id.map(crate::core::RunId),
                        sequence: sequence as u64,
                        depth: depth as u32,
                        kind: event_kind_from_str(&kind)?,
                        payload,
                        blob_refs: if blob_refs.is_empty() {
                            Vec::new()
                        } else {
                            blob_refs.split('\n').map(ToString::to_string).collect()
                        },
                    })
                },
            )
    }

    fn active_branch(
        &self,
        _session_id: &SessionId,
        _leaf_id: &EntryId,
    ) -> Result<Vec<RuntimeEvent>, AgentError> {
        Err(AgentError::Storage(
            "sqlite active_branch is not implemented yet".to_string(),
        ))
    }
}
```

- [ ] **Step 5: Run append/get test**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo fmt
cargo test --test sqlite_store sqlite_store_appends_and_reads_event
```

Expected:

```text
test sqlite_store_appends_and_reads_event ... ok
```

- [ ] **Step 6: Commit**

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/rust-core/src/memory/sqlite.rs local-ios-agent/rust-core/tests/sqlite_store.rs
git commit -m "feat: persist sqlite events"
```

## Task 6: Implement SQLite Active Branch Reconstruction

**Files:**
- Modify: `local-ios-agent/rust-core/src/memory/sqlite.rs`
- Modify: `local-ios-agent/rust-core/tests/sqlite_store.rs`

- [ ] **Step 1: Add failing active branch test**

Append to `local-ios-agent/rust-core/tests/sqlite_store.rs`:

```rust
#[test]
fn sqlite_store_reconstructs_active_branch_from_closure_table() {
    let tempdir = tempfile::tempdir().unwrap();
    let db_path = tempdir.path().join("agent.sqlite");
    let mut store = SqliteEventStore::open(&db_path).unwrap();

    store
        .append(sqlite_event("root", None, 1, 0, "root"))
        .unwrap();
    store
        .append(sqlite_event("a", Some("root"), 2, 1, "a"))
        .unwrap();
    store
        .append(sqlite_event("b", Some("a"), 3, 2, "b"))
        .unwrap();
    store
        .append(sqlite_event("side", Some("root"), 4, 1, "side"))
        .unwrap();

    let branch = store
        .active_branch(
            &SessionId("session_sqlite".to_string()),
            &EntryId("b".to_string()),
        )
        .unwrap();

    let payloads: Vec<_> = branch.iter().map(|event| event.payload.as_str()).collect();
    assert_eq!(payloads, vec!["root", "a", "b"]);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo test --test sqlite_store sqlite_store_reconstructs_active_branch_from_closure_table
```

Expected:

```text
sqlite active_branch is not implemented yet
```

- [ ] **Step 3: Implement active_branch**

Replace the `active_branch` method in `local-ios-agent/rust-core/src/memory/sqlite.rs` with:

```rust
    fn active_branch(
        &self,
        session_id: &SessionId,
        leaf_id: &EntryId,
    ) -> Result<Vec<RuntimeEvent>, AgentError> {
        let mut statement = self
            .conn
            .prepare(
                "
                select e.id
                from event_paths p
                join events e on e.session_id = p.session_id and e.id = p.ancestor_id
                where p.session_id = ?1 and p.descendant_id = ?2
                order by e.depth asc, e.sequence asc
                ",
            )
            .map_err(storage_error)?;

        let rows = statement
            .query_map(params![session_id.0, leaf_id.0], |row| row.get::<_, String>(0))
            .map_err(storage_error)?;

        let mut events = Vec::new();
        for row in rows {
            let id = EntryId(row.map_err(storage_error)?);
            events.push(self.get(session_id, &id)?);
        }

        if events.is_empty() {
            return Err(AgentError::Storage(format!(
                "leaf has no path rows: {}",
                leaf_id.0
            )));
        }

        Ok(events)
    }
```

- [ ] **Step 4: Run sqlite tests**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo fmt
cargo test --test sqlite_store
```

Expected:

```text
test result: ok
```

- [ ] **Step 5: Commit**

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/rust-core/src/memory/sqlite.rs local-ios-agent/rust-core/tests/sqlite_store.rs
git commit -m "feat: reconstruct sqlite active branches"
```

## Task 7: Verify SessionTree Works With SQLite Store

**Files:**
- Modify: `local-ios-agent/rust-core/tests/sqlite_store.rs`

- [ ] **Step 1: Add SessionTree SQLite test**

Append to `local-ios-agent/rust-core/tests/sqlite_store.rs`:

```rust
use local_ios_agent_runtime::core::SessionTree;

#[test]
fn session_tree_can_use_sqlite_event_store() {
    let tempdir = tempfile::tempdir().unwrap();
    let db_path = tempdir.path().join("agent.sqlite");
    let store = SqliteEventStore::open(&db_path).unwrap();
    let mut tree = SessionTree::with_store(SessionId("session_tree_sqlite".to_string()), store);

    let root = tree
        .append(None, EventKind::SessionCreated, "created")
        .unwrap();
    let user = tree
        .append(Some(root.clone()), EventKind::UserMessage, "hello")
        .unwrap();

    let branch = tree.active_branch(&user).unwrap();
    let payloads: Vec<_> = branch.iter().map(|event| event.payload.as_str()).collect();
    assert_eq!(payloads, vec!["created", "hello"]);
}
```

- [ ] **Step 2: Run test**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo fmt
cargo test --test sqlite_store session_tree_can_use_sqlite_event_store
```

Expected:

```text
test session_tree_can_use_sqlite_event_store ... ok
```

- [ ] **Step 3: Run full test suite**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo test
```

Expected:

```text
test result: ok
```

- [ ] **Step 4: Commit**

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/rust-core/tests/sqlite_store.rs
git commit -m "test: verify sqlite session tree store"
```

## Task 8: Document SQLite Memory Store

**Files:**
- Modify: `local-ios-agent/rust-core/README.md`

- [ ] **Step 1: Update README**

Append to `local-ios-agent/rust-core/README.md`:

```markdown

## Memory Stores

The runtime has two event-store implementations:

- `InMemoryEventStore`: deterministic test and mock-runtime backend.
- `SqliteEventStore`: persistent backend with `events` and `event_paths` tables.

`event_paths` is a closure table. It lets the context layer reconstruct the
active branch from a leaf event without recursively walking parent pointers.
`parent_id` remains the canonical relationship for each event.
```

- [ ] **Step 2: Run final verification**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo fmt
cargo test
```

Expected:

```text
test result: ok
```

- [ ] **Step 3: Commit**

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/rust-core/README.md
git commit -m "docs: document sqlite memory store"
```

## Completion Checklist

- [ ] `cargo test` passes in `local-ios-agent/rust-core`.
- [ ] `InMemoryEventStore` implements `EventStore`.
- [ ] `SqliteEventStore` opens and migrates schema version 1.
- [ ] SQLite schema includes `sessions`, `events`, `event_paths`, and `audit_log`.
- [ ] SQLite append/get works.
- [ ] SQLite active branch reconstruction works through `event_paths`.
- [ ] `SessionTree::with_store` works with SQLite.
- [ ] No files under `pi/` are modified or staged.

## Follow-up Plans

After this plan passes, create separate detailed plans for:

1. UniFFI bridge between Rust runtime and Swift.
2. SwiftUI shell with chat view, provider selector, and PromptFrame debug view.
3. Swift Native Toolkit with calendar/reminders/shortcuts tools.
4. Desktop MiniCPM provider and local serving runbook.
5. MVP hardening: cancellation, persisted suspended runs, error recovery, and docs.
