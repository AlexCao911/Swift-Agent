# Rust Runtime Mock Provider Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first working Rust runtime slice: project skeleton, event-sourced session tree, context builder, security approval suspension, stream batching, and a mock streaming provider.

**Architecture:** This plan implements the Rust `core / memory / context / security / tool / utils` boundary from the approved MVP design. It intentionally avoids SwiftUI, UniFFI, SQLite, C++, and Desktop MiniCPM until the runtime kernel is testable in isolation.

**Tech Stack:** Rust 2021, standard library only for Plan 1, `cargo test`, in-memory event store with closure-table semantics, deterministic mock provider.

---

## Scope

This is Plan 1 of the MVP. It produces a testable Rust crate under:

```text
/Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
```

It does not implement:

- SwiftUI frontend.
- Swift Native Toolkit.
- UniFFI bindings.
- SQLite persistence.
- Desktop MiniCPM provider.
- C++ on-device inference.

Those are separate implementation plans after this foundation passes.

## File Structure

Create:

```text
local-ios-agent/rust-core/Cargo.toml
local-ios-agent/rust-core/src/lib.rs
local-ios-agent/rust-core/src/core/mod.rs
local-ios-agent/rust-core/src/core/event.rs
local-ios-agent/rust-core/src/core/provider.rs
local-ios-agent/rust-core/src/core/runtime.rs
local-ios-agent/rust-core/src/core/session_tree.rs
local-ios-agent/rust-core/src/core/stream_batcher.rs
local-ios-agent/rust-core/src/core/types.rs
local-ios-agent/rust-core/src/context/mod.rs
local-ios-agent/rust-core/src/context/prompt_frame.rs
local-ios-agent/rust-core/src/context/tokenizer.rs
local-ios-agent/rust-core/src/memory/mod.rs
local-ios-agent/rust-core/src/memory/in_memory.rs
local-ios-agent/rust-core/src/security/mod.rs
local-ios-agent/rust-core/src/security/approval.rs
local-ios-agent/rust-core/src/security/policy.rs
local-ios-agent/rust-core/src/tool/mod.rs
local-ios-agent/rust-core/src/tool/result.rs
local-ios-agent/rust-core/src/tool/schema.rs
local-ios-agent/rust-core/src/utils/mod.rs
local-ios-agent/rust-core/src/utils/id.rs
local-ios-agent/rust-core/tests/approval.rs
local-ios-agent/rust-core/tests/context_prompt.rs
local-ios-agent/rust-core/tests/runtime_mock.rs
local-ios-agent/rust-core/tests/session_tree.rs
local-ios-agent/rust-core/tests/stream_batcher.rs
```

Do not modify the reference `pi/` repository.

## Task 1: Create Rust Crate Skeleton

**Files:**
- Create: `local-ios-agent/rust-core/Cargo.toml`
- Create: `local-ios-agent/rust-core/src/lib.rs`
- Create: module `mod.rs` files listed below

- [ ] **Step 1: Write crate manifest**

Create `local-ios-agent/rust-core/Cargo.toml`:

```toml
[package]
name = "local_ios_agent_runtime"
version = "0.1.0"
edition = "2021"
publish = false

[lib]
name = "local_ios_agent_runtime"
path = "src/lib.rs"

[dependencies]
```

- [ ] **Step 2: Write top-level library module**

Create `local-ios-agent/rust-core/src/lib.rs`:

```rust
pub mod core;
pub mod context;
pub mod memory;
pub mod security;
pub mod tool;
pub mod utils;
```

- [ ] **Step 3: Write module declarations**

Create `local-ios-agent/rust-core/src/core/mod.rs`:

```rust
//! Core runtime module.
```

Create `local-ios-agent/rust-core/src/context/mod.rs`:

```rust
//! Prompt and context construction module.
```

Create `local-ios-agent/rust-core/src/memory/mod.rs`:

```rust
//! Persistence and memory module.
```

Create `local-ios-agent/rust-core/src/security/mod.rs`:

```rust
//! Runtime policy and approval module.
```

Create `local-ios-agent/rust-core/src/tool/mod.rs`:

```rust
//! Tool schema and result module.
```

Create `local-ios-agent/rust-core/src/utils/mod.rs`:

```rust
//! Shared utility module.
```

- [ ] **Step 4: Run format and tests**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo fmt
cargo test
```

Expected:

```text
test result: ok. 0 passed
```

- [ ] **Step 5: Commit**

The git repository root is `/Users/alexandercou/Projects/Alex-agent`. Commit only
files under `local-ios-agent/` and never stage the reference `pi/` directory.

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent
git add rust-core/Cargo.toml rust-core/src
git commit -m "feat: add rust runtime crate skeleton"
```

Expected:

```text
[main ...] feat: add rust runtime crate skeleton
```

## Task 2: Add IDs, Errors, and Runtime Events

**Files:**
- Create: `local-ios-agent/rust-core/src/utils/id.rs`
- Create: `local-ios-agent/rust-core/src/core/types.rs`
- Create: `local-ios-agent/rust-core/src/core/event.rs`
- Modify: `local-ios-agent/rust-core/src/core/mod.rs`
- Modify: `local-ios-agent/rust-core/src/utils/mod.rs`

- [ ] **Step 1: Write ID generator**

Create `local-ios-agent/rust-core/src/utils/id.rs`:

```rust
use std::sync::atomic::{AtomicU64, Ordering};

#[derive(Debug, Default)]
pub struct IdGenerator {
    next: AtomicU64,
}

impl IdGenerator {
    pub fn new() -> Self {
        Self {
            next: AtomicU64::new(1),
        }
    }

    pub fn next_id(&self, prefix: &str) -> String {
        let value = self.next.fetch_add(1, Ordering::Relaxed);
        format!("{prefix}_{value}")
    }
}
```

- [ ] **Step 2: Write core types and error**

Create `local-ios-agent/rust-core/src/core/types.rs`:

```rust
use std::fmt;

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub struct SessionId(pub String);

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub struct EntryId(pub String);

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub struct RunId(pub String);

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum AgentError {
    Storage(String),
    Provider(String),
    ToolParse(String),
    ToolValidation(String),
    ToolPermission(String),
    ToolExecution(String),
    PolicyDenied(String),
    Cancelled(String),
    Ffi(String),
    Unknown(String),
}

impl fmt::Display for AgentError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Storage(message) => write!(f, "storage error: {message}"),
            Self::Provider(message) => write!(f, "provider error: {message}"),
            Self::ToolParse(message) => write!(f, "tool parse error: {message}"),
            Self::ToolValidation(message) => write!(f, "tool validation error: {message}"),
            Self::ToolPermission(message) => write!(f, "tool permission error: {message}"),
            Self::ToolExecution(message) => write!(f, "tool execution error: {message}"),
            Self::PolicyDenied(message) => write!(f, "policy denied: {message}"),
            Self::Cancelled(message) => write!(f, "cancelled: {message}"),
            Self::Ffi(message) => write!(f, "ffi error: {message}"),
            Self::Unknown(message) => write!(f, "unknown error: {message}"),
        }
    }
}

impl std::error::Error for AgentError {}
```

- [ ] **Step 3: Write runtime event model**

Create `local-ios-agent/rust-core/src/core/event.rs`:

```rust
use crate::core::types::{EntryId, RunId, SessionId};

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum EventKind {
    SessionCreated,
    ProviderChanged,
    ToolRegistered,
    UserMessage,
    AssistantMessageStarted,
    AssistantTextDelta,
    AssistantMessageCompleted,
    ToolCallRequested,
    ToolCallApproved,
    ToolCallRejected,
    ToolExecutionStarted,
    ToolExecutionUpdate,
    ToolExecutionCompleted,
    ToolExecutionFailed,
    ToolResultMessage,
    RunSuspended,
    RunResumed,
    CompactionCreated,
    BranchSummaryCreated,
    RunCancelled,
    RunFailed,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RuntimeEvent {
    pub id: EntryId,
    pub session_id: SessionId,
    pub parent_id: Option<EntryId>,
    pub run_id: Option<RunId>,
    pub sequence: u64,
    pub depth: u32,
    pub kind: EventKind,
    pub payload: String,
    pub blob_refs: Vec<String>,
}

impl RuntimeEvent {
    pub fn new(
        id: EntryId,
        session_id: SessionId,
        parent_id: Option<EntryId>,
        run_id: Option<RunId>,
        sequence: u64,
        depth: u32,
        kind: EventKind,
        payload: impl Into<String>,
    ) -> Self {
        Self {
            id,
            session_id,
            parent_id,
            run_id,
            sequence,
            depth,
            kind,
            payload: payload.into(),
            blob_refs: Vec::new(),
        }
    }
}
```

- [ ] **Step 4: Export new modules**

Replace `local-ios-agent/rust-core/src/core/mod.rs` with:

```rust
pub mod event;
pub mod types;

pub use event::{EventKind, RuntimeEvent};
pub use types::{AgentError, EntryId, RunId, SessionId};
```

Replace `local-ios-agent/rust-core/src/utils/mod.rs` with:

```rust
pub mod id;
```

- [ ] **Step 5: Run format and tests**

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

- [ ] **Step 6: Commit**

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent
git add rust-core/src/core/event.rs rust-core/src/core/types.rs rust-core/src/core/mod.rs rust-core/src/utils/id.rs rust-core/src/utils/mod.rs
git commit -m "feat: add runtime ids and events"
```

## Task 3: Implement In-Memory Event Store with Closure Paths

**Files:**
- Create: `local-ios-agent/rust-core/src/memory/in_memory.rs`
- Modify: `local-ios-agent/rust-core/src/memory/mod.rs`
- Test: `local-ios-agent/rust-core/tests/session_tree.rs`

- [ ] **Step 1: Write failing closure-path test**

Create `local-ios-agent/rust-core/tests/session_tree.rs`:

```rust
use local_ios_agent_runtime::core::{EntryId, EventKind, RuntimeEvent, SessionId};
use local_ios_agent_runtime::memory::InMemoryEventStore;

fn event(id: &str, parent: Option<&str>, sequence: u64, depth: u32, payload: &str) -> RuntimeEvent {
    RuntimeEvent::new(
        EntryId(id.to_string()),
        SessionId("session_1".to_string()),
        parent.map(|value| EntryId(value.to_string())),
        None,
        sequence,
        depth,
        EventKind::UserMessage,
        payload,
    )
}

#[test]
fn active_branch_returns_ancestors_in_order() {
    let mut store = InMemoryEventStore::new();
    store.append(event("root", None, 1, 0, "root")).unwrap();
    store.append(event("a", Some("root"), 2, 1, "a")).unwrap();
    store.append(event("b", Some("a"), 3, 2, "b")).unwrap();
    store.append(event("side", Some("root"), 4, 1, "side")).unwrap();

    let branch = store
        .active_branch(&SessionId("session_1".to_string()), &EntryId("b".to_string()))
        .unwrap();

    let payloads: Vec<_> = branch.iter().map(|event| event.payload.as_str()).collect();
    assert_eq!(payloads, vec!["root", "a", "b"]);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo test --test session_tree active_branch_returns_ancestors_in_order
```

Expected:

```text
error[E0432]: unresolved import `local_ios_agent_runtime::memory::InMemoryEventStore`
```

- [ ] **Step 3: Implement in-memory store**

Create `local-ios-agent/rust-core/src/memory/in_memory.rs`:

```rust
use std::collections::{HashMap, HashSet};

use crate::core::{AgentError, EntryId, RuntimeEvent, SessionId};

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
struct PathKey {
    session_id: SessionId,
    ancestor_id: EntryId,
    descendant_id: EntryId,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct PathRow {
    key: PathKey,
    depth_delta: u32,
}

#[derive(Debug, Default)]
pub struct InMemoryEventStore {
    events: HashMap<(SessionId, EntryId), RuntimeEvent>,
    paths: Vec<PathRow>,
    children: HashMap<(SessionId, EntryId), HashSet<EntryId>>,
}

impl InMemoryEventStore {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn append(&mut self, event: RuntimeEvent) -> Result<(), AgentError> {
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

    pub fn get(
        &self,
        session_id: &SessionId,
        entry_id: &EntryId,
    ) -> Result<RuntimeEvent, AgentError> {
        self.events
            .get(&(session_id.clone(), entry_id.clone()))
            .cloned()
            .ok_or_else(|| AgentError::Storage(format!("event not found: {}", entry_id.0)))
    }

    pub fn active_branch(
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

- [ ] **Step 4: Export in-memory store**

Replace `local-ios-agent/rust-core/src/memory/mod.rs` with:

```rust
pub mod in_memory;

pub use in_memory::InMemoryEventStore;
```

- [ ] **Step 5: Run test to verify it passes**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo test --test session_tree
```

Expected:

```text
test active_branch_returns_ancestors_in_order ... ok
```

- [ ] **Step 6: Commit**

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent
git add rust-core/src/memory/in_memory.rs rust-core/src/memory/mod.rs rust-core/tests/session_tree.rs
git commit -m "feat: add in-memory event store"
```

## Task 4: Implement SessionTree Wrapper

**Files:**
- Create: `local-ios-agent/rust-core/src/core/session_tree.rs`
- Modify: `local-ios-agent/rust-core/src/core/mod.rs`
- Modify: `local-ios-agent/rust-core/tests/session_tree.rs`

- [ ] **Step 1: Add failing SessionTree test**

Append to `local-ios-agent/rust-core/tests/session_tree.rs`:

```rust
use local_ios_agent_runtime::core::SessionTree;

#[test]
fn session_tree_tracks_active_leaf() {
    let mut tree = SessionTree::new(SessionId("session_2".to_string()));
    let root = tree
        .append(None, EventKind::SessionCreated, "created")
        .unwrap();
    let user = tree
        .append(Some(root.clone()), EventKind::UserMessage, "hello")
        .unwrap();

    assert_eq!(tree.active_leaf(), Some(&user));
    let branch = tree.active_branch(&user).unwrap();
    let payloads: Vec<_> = branch.iter().map(|event| event.payload.as_str()).collect();
    assert_eq!(payloads, vec!["created", "hello"]);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo test --test session_tree session_tree_tracks_active_leaf
```

Expected:

```text
error[E0432]: unresolved import `local_ios_agent_runtime::core::SessionTree`
```

- [ ] **Step 3: Implement SessionTree**

Create `local-ios-agent/rust-core/src/core/session_tree.rs`:

```rust
use crate::core::{AgentError, EntryId, EventKind, RuntimeEvent, SessionId};
use crate::memory::InMemoryEventStore;
use crate::utils::id::IdGenerator;

#[derive(Debug)]
pub struct SessionTree {
    session_id: SessionId,
    store: InMemoryEventStore,
    ids: IdGenerator,
    active_leaf: Option<EntryId>,
    sequence: u64,
}

impl SessionTree {
    pub fn new(session_id: SessionId) -> Self {
        Self {
            session_id,
            store: InMemoryEventStore::new(),
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

- [ ] **Step 4: Export SessionTree**

Replace `local-ios-agent/rust-core/src/core/mod.rs` with:

```rust
pub mod event;
pub mod session_tree;
pub mod types;

pub use event::{EventKind, RuntimeEvent};
pub use session_tree::SessionTree;
pub use types::{AgentError, EntryId, RunId, SessionId};
```

- [ ] **Step 5: Run session tree tests**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo test --test session_tree
```

Expected:

```text
test result: ok. 2 passed
```

- [ ] **Step 6: Commit**

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent
git add rust-core/src/core/session_tree.rs rust-core/src/core/mod.rs rust-core/tests/session_tree.rs
git commit -m "feat: add session tree wrapper"
```

## Task 5: Add PromptFrame and Tokenizer Contract

**Files:**
- Create: `local-ios-agent/rust-core/src/context/prompt_frame.rs`
- Create: `local-ios-agent/rust-core/src/context/tokenizer.rs`
- Modify: `local-ios-agent/rust-core/src/context/mod.rs`
- Test: `local-ios-agent/rust-core/tests/context_prompt.rs`

- [ ] **Step 1: Write failing context test**

Create `local-ios-agent/rust-core/tests/context_prompt.rs`:

```rust
use local_ios_agent_runtime::context::{ContextController, MockTokenizer, PromptMessage};
use local_ios_agent_runtime::core::{EntryId, EventKind, RuntimeEvent, SessionId};

fn message(kind: EventKind, payload: &str) -> RuntimeEvent {
    RuntimeEvent::new(
        EntryId(format!("entry_{payload}")),
        SessionId("session_1".to_string()),
        None,
        None,
        1,
        0,
        kind,
        payload,
    )
}

#[test]
fn prompt_frame_injects_policy_tools_and_recent_messages() {
    let controller = ContextController::new(
        "system prompt",
        "runtime policy",
        vec!["calendar.search_events".to_string()],
        Box::new(MockTokenizer::new(100)),
    );

    let frame = controller
        .build_prompt_frame(vec![
            message(EventKind::UserMessage, "hello"),
            message(EventKind::AssistantMessageCompleted, "hi"),
        ])
        .unwrap();

    assert_eq!(frame.system_prompt, "system prompt");
    assert_eq!(frame.runtime_policy, "runtime policy");
    assert_eq!(frame.tool_schemas, vec!["calendar.search_events"]);
    assert_eq!(
        frame.messages,
        vec![
            PromptMessage::User("hello".to_string()),
            PromptMessage::Assistant("hi".to_string())
        ]
    );
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo test --test context_prompt
```

Expected:

```text
error[E0432]: unresolved imports `ContextController`, `MockTokenizer`, `PromptMessage`
```

- [ ] **Step 3: Implement tokenizer contract**

Create `local-ios-agent/rust-core/src/context/tokenizer.rs`:

```rust
use crate::context::PromptFrame;

pub trait TokenizerAdapter: Send + Sync {
    fn provider_id(&self) -> &str;
    fn max_context_tokens(&self) -> usize;
    fn safety_margin_tokens(&self) -> usize;
    fn count_prompt_frame(&self, frame: &PromptFrame) -> usize;
    fn boxed_clone(&self) -> Box<dyn TokenizerAdapter>;
}

#[derive(Clone, Debug)]
pub struct MockTokenizer {
    max_context_tokens: usize,
}

impl MockTokenizer {
    pub fn new(max_context_tokens: usize) -> Self {
        Self { max_context_tokens }
    }
}

impl TokenizerAdapter for MockTokenizer {
    fn provider_id(&self) -> &str {
        "mock"
    }

    fn max_context_tokens(&self) -> usize {
        self.max_context_tokens
    }

    fn safety_margin_tokens(&self) -> usize {
        8
    }

    fn count_prompt_frame(&self, frame: &PromptFrame) -> usize {
        let mut count = frame.system_prompt.split_whitespace().count();
        count += frame.runtime_policy.split_whitespace().count();
        count += frame.tool_schemas.iter().map(|tool| tool.split_whitespace().count()).sum::<usize>();
        count += frame
            .messages
            .iter()
            .map(|message| message.content().split_whitespace().count())
            .sum::<usize>();
        count
    }

    fn boxed_clone(&self) -> Box<dyn TokenizerAdapter> {
        Box::new(self.clone())
    }
}
```

- [ ] **Step 4: Implement PromptFrame builder**

Create `local-ios-agent/rust-core/src/context/prompt_frame.rs`:

```rust
use crate::context::TokenizerAdapter;
use crate::core::{AgentError, EventKind, RuntimeEvent};

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PromptMessage {
    User(String),
    Assistant(String),
    ToolResult(String),
}

impl PromptMessage {
    pub fn content(&self) -> &str {
        match self {
            Self::User(content) | Self::Assistant(content) | Self::ToolResult(content) => content,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PromptFrame {
    pub system_prompt: String,
    pub runtime_policy: String,
    pub tool_schemas: Vec<String>,
    pub messages: Vec<PromptMessage>,
}

pub struct ContextController {
    system_prompt: String,
    runtime_policy: String,
    tool_schemas: Vec<String>,
    tokenizer: Box<dyn TokenizerAdapter>,
}

impl ContextController {
    pub fn new(
        system_prompt: impl Into<String>,
        runtime_policy: impl Into<String>,
        tool_schemas: Vec<String>,
        tokenizer: Box<dyn TokenizerAdapter>,
    ) -> Self {
        Self {
            system_prompt: system_prompt.into(),
            runtime_policy: runtime_policy.into(),
            tool_schemas,
            tokenizer,
        }
    }

    pub fn build_prompt_frame(
        &self,
        branch: Vec<RuntimeEvent>,
    ) -> Result<PromptFrame, AgentError> {
        let mut messages = Vec::new();
        for event in branch {
            match event.kind {
                EventKind::UserMessage => messages.push(PromptMessage::User(event.payload)),
                EventKind::AssistantMessageCompleted => {
                    messages.push(PromptMessage::Assistant(event.payload));
                }
                EventKind::ToolResultMessage => {
                    messages.push(PromptMessage::ToolResult(event.payload));
                }
                _ => {}
            }
        }

        let frame = PromptFrame {
            system_prompt: self.system_prompt.clone(),
            runtime_policy: self.runtime_policy.clone(),
            tool_schemas: self.tool_schemas.clone(),
            messages,
        };

        let count = self.tokenizer.count_prompt_frame(&frame);
        let usable = self
            .tokenizer
            .max_context_tokens()
            .saturating_sub(self.tokenizer.safety_margin_tokens());
        if count > usable {
            return Err(AgentError::Provider(format!(
                "prompt frame exceeds mock context budget: {count} > {usable}"
            )));
        }

        Ok(frame)
    }
}
```

- [ ] **Step 5: Export context modules**

Replace `local-ios-agent/rust-core/src/context/mod.rs` with:

```rust
pub mod prompt_frame;
pub mod tokenizer;

pub use prompt_frame::{ContextController, PromptFrame, PromptMessage};
pub use tokenizer::{MockTokenizer, TokenizerAdapter};
```

- [ ] **Step 6: Run context tests**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo test --test context_prompt
```

Expected:

```text
test prompt_frame_injects_policy_tools_and_recent_messages ... ok
```

- [ ] **Step 7: Commit**

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent
git add rust-core/src/context rust-core/tests/context_prompt.rs
git commit -m "feat: add prompt frame builder"
```

## Task 6: Add Tool Result and Security Approval Types

**Files:**
- Create: `local-ios-agent/rust-core/src/tool/result.rs`
- Create: `local-ios-agent/rust-core/src/tool/schema.rs`
- Create: `local-ios-agent/rust-core/src/security/policy.rs`
- Create: `local-ios-agent/rust-core/src/security/approval.rs`
- Modify: `local-ios-agent/rust-core/src/security/mod.rs`
- Modify: `local-ios-agent/rust-core/src/tool/mod.rs`
- Test: `local-ios-agent/rust-core/tests/approval.rs`

- [ ] **Step 1: Write failing approval test**

Create `local-ios-agent/rust-core/tests/approval.rs`:

```rust
use local_ios_agent_runtime::core::{RunId, EntryId};
use local_ios_agent_runtime::security::{ApprovalDecision, ApprovalRequest, SuspendedRun};

#[test]
fn suspended_run_resumes_with_matching_approval_id() {
    let request = ApprovalRequest {
        approval_id: "approval_1".to_string(),
        run_id: RunId("run_1".to_string()),
        tool_call_id: EntryId("tool_1".to_string()),
        message: "Allow reminder creation?".to_string(),
    };
    let mut suspended = SuspendedRun::new(request);

    let decision = suspended
        .submit_decision("approval_1", ApprovalDecision::Approved)
        .unwrap();

    assert_eq!(decision, ApprovalDecision::Approved);
    assert!(suspended.is_resolved());
}

#[test]
fn suspended_run_rejects_wrong_approval_id() {
    let request = ApprovalRequest {
        approval_id: "approval_1".to_string(),
        run_id: RunId("run_1".to_string()),
        tool_call_id: EntryId("tool_1".to_string()),
        message: "Allow reminder creation?".to_string(),
    };
    let mut suspended = SuspendedRun::new(request);

    let error = suspended
        .submit_decision("approval_2", ApprovalDecision::Approved)
        .unwrap_err();

    assert!(error.to_string().contains("approval id mismatch"));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo test --test approval
```

Expected:

```text
error[E0432]: unresolved imports `ApprovalDecision`, `ApprovalRequest`, `SuspendedRun`
```

- [ ] **Step 3: Implement tool DTOs**

Create `local-ios-agent/rust-core/src/tool/result.rs`:

```rust
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Sensitivity {
    Public,
    Private,
    Secret,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum RetentionPolicy {
    RunOnly,
    Session,
    MemoryCandidate,
    AuditOnly,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ToolResult {
    pub display_text: String,
    pub model_text: String,
    pub structured_json: String,
    pub audit_text: String,
    pub sensitivity: Sensitivity,
    pub retention: RetentionPolicy,
    pub is_error: bool,
}
```

Create `local-ios-agent/rust-core/src/tool/schema.rs`:

```rust
use crate::security::RiskLevel;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ToolSchema {
    pub name: String,
    pub description: String,
    pub parameters_json_schema: String,
    pub risk_level: RiskLevel,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ToolCall {
    pub id: String,
    pub name: String,
    pub arguments_json: String,
}
```

- [ ] **Step 4: Implement policy and approval**

Create `local-ios-agent/rust-core/src/security/policy.rs`:

```rust
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum RiskLevel {
    ReadOnly,
    Confirm,
    Destructive,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PolicyDecision {
    Allow,
    RequireApproval(String),
    Deny(String),
}

#[derive(Clone, Debug, Default)]
pub struct PolicyEngine;

impl PolicyEngine {
    pub fn decide(&self, risk_level: &RiskLevel, tool_name: &str) -> PolicyDecision {
        match risk_level {
            RiskLevel::ReadOnly => PolicyDecision::Allow,
            RiskLevel::Confirm => PolicyDecision::RequireApproval(format!(
                "Allow tool `{tool_name}` to run?"
            )),
            RiskLevel::Destructive => PolicyDecision::Deny(format!(
                "Tool `{tool_name}` is destructive and disabled in MVP"
            )),
        }
    }
}
```

Create `local-ios-agent/rust-core/src/security/approval.rs`:

```rust
use crate::core::{AgentError, EntryId, RunId};

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ApprovalDecision {
    Approved,
    Rejected,
    Cancelled,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ApprovalRequest {
    pub approval_id: String,
    pub run_id: RunId,
    pub tool_call_id: EntryId,
    pub message: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SuspendedRun {
    request: ApprovalRequest,
    decision: Option<ApprovalDecision>,
}

impl SuspendedRun {
    pub fn new(request: ApprovalRequest) -> Self {
        Self {
            request,
            decision: None,
        }
    }

    pub fn submit_decision(
        &mut self,
        approval_id: &str,
        decision: ApprovalDecision,
    ) -> Result<ApprovalDecision, AgentError> {
        if self.request.approval_id != approval_id {
            return Err(AgentError::PolicyDenied(format!(
                "approval id mismatch: expected {}, got {approval_id}",
                self.request.approval_id
            )));
        }
        if self.decision.is_some() {
            return Err(AgentError::PolicyDenied(format!(
                "approval already resolved: {approval_id}"
            )));
        }
        self.decision = Some(decision.clone());
        Ok(decision)
    }

    pub fn is_resolved(&self) -> bool {
        self.decision.is_some()
    }
}
```

- [ ] **Step 5: Export security and tool modules**

Replace `local-ios-agent/rust-core/src/security/mod.rs` with:

```rust
pub mod approval;
pub mod policy;

pub use approval::{ApprovalDecision, ApprovalRequest, SuspendedRun};
pub use policy::{PolicyDecision, PolicyEngine, RiskLevel};
```

Replace `local-ios-agent/rust-core/src/tool/mod.rs` with:

```rust
pub mod result;
pub mod schema;

pub use result::{RetentionPolicy, Sensitivity, ToolResult};
pub use schema::{ToolCall, ToolSchema};
```

- [ ] **Step 6: Run approval tests**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo test --test approval
```

Expected:

```text
test result: ok. 2 passed
```

- [ ] **Step 7: Commit**

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent
git add rust-core/src/security rust-core/src/tool rust-core/tests/approval.rs
git commit -m "feat: add tool and approval types"
```

## Task 7: Add StreamBatcher

**Files:**
- Create: `local-ios-agent/rust-core/src/core/stream_batcher.rs`
- Modify: `local-ios-agent/rust-core/src/core/mod.rs`
- Test: `local-ios-agent/rust-core/tests/stream_batcher.rs`

- [ ] **Step 1: Write failing stream batching test**

Create `local-ios-agent/rust-core/tests/stream_batcher.rs`:

```rust
use local_ios_agent_runtime::core::StreamBatcher;

#[test]
fn stream_batcher_flushes_after_byte_threshold() {
    let mut batcher = StreamBatcher::new(5);

    assert_eq!(batcher.push("he"), None);
    assert_eq!(batcher.push("llo"), Some("hello".to_string()));
    assert_eq!(batcher.push("!"), None);
    assert_eq!(batcher.flush(), Some("!".to_string()));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo test --test stream_batcher
```

Expected:

```text
error[E0432]: unresolved import `local_ios_agent_runtime::core::StreamBatcher`
```

- [ ] **Step 3: Implement StreamBatcher**

Create `local-ios-agent/rust-core/src/core/stream_batcher.rs`:

```rust
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StreamBatcher {
    byte_threshold: usize,
    buffer: String,
}

impl StreamBatcher {
    pub fn new(byte_threshold: usize) -> Self {
        Self {
            byte_threshold,
            buffer: String::new(),
        }
    }

    pub fn push(&mut self, delta: &str) -> Option<String> {
        self.buffer.push_str(delta);
        if self.buffer.len() >= self.byte_threshold {
            return self.flush();
        }
        None
    }

    pub fn flush(&mut self) -> Option<String> {
        if self.buffer.is_empty() {
            return None;
        }
        Some(std::mem::take(&mut self.buffer))
    }
}
```

- [ ] **Step 4: Export StreamBatcher**

Replace `local-ios-agent/rust-core/src/core/mod.rs` with:

```rust
pub mod event;
pub mod session_tree;
pub mod stream_batcher;
pub mod types;

pub use event::{EventKind, RuntimeEvent};
pub use session_tree::SessionTree;
pub use stream_batcher::StreamBatcher;
pub use types::{AgentError, EntryId, RunId, SessionId};
```

- [ ] **Step 5: Run stream batching test**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo test --test stream_batcher
```

Expected:

```text
test stream_batcher_flushes_after_byte_threshold ... ok
```

- [ ] **Step 6: Commit**

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent
git add rust-core/src/core/stream_batcher.rs rust-core/src/core/mod.rs rust-core/tests/stream_batcher.rs
git commit -m "feat: add stream batching"
```

## Task 8: Add Mock Provider

**Files:**
- Create: `local-ios-agent/rust-core/src/core/provider.rs`
- Modify: `local-ios-agent/rust-core/src/core/mod.rs`

- [ ] **Step 1: Implement provider trait and mock provider**

Create `local-ios-agent/rust-core/src/core/provider.rs`:

```rust
use crate::context::PromptFrame;
use crate::core::AgentError;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ModelProviderOutput {
    TextDelta(String),
    Completed(String),
}

pub trait ModelProvider: Send + Sync {
    fn id(&self) -> &str;
    fn stream_chat(
        &self,
        frame: &PromptFrame,
    ) -> Result<Vec<ModelProviderOutput>, AgentError>;
}

#[derive(Clone, Debug, Default)]
pub struct MockStreamingProvider;

impl MockStreamingProvider {
    pub fn new() -> Self {
        Self
    }
}

impl ModelProvider for MockStreamingProvider {
    fn id(&self) -> &str {
        "mock"
    }

    fn stream_chat(
        &self,
        frame: &PromptFrame,
    ) -> Result<Vec<ModelProviderOutput>, AgentError> {
        let last_user = frame
            .messages
            .iter()
            .rev()
            .find_map(|message| match message {
                crate::context::PromptMessage::User(content) => Some(content.as_str()),
                _ => None,
            })
            .unwrap_or("");

        let response = format!("Mock response to: {last_user}");
        Ok(vec![
            ModelProviderOutput::TextDelta("Mock ".to_string()),
            ModelProviderOutput::TextDelta(format!("response to: {last_user}")),
            ModelProviderOutput::Completed(response),
        ])
    }
}
```

- [ ] **Step 2: Export provider types**

Replace `local-ios-agent/rust-core/src/core/mod.rs` with:

```rust
pub mod event;
pub mod provider;
pub mod session_tree;
pub mod stream_batcher;
pub mod types;

pub use event::{EventKind, RuntimeEvent};
pub use provider::{MockStreamingProvider, ModelProvider, ModelProviderOutput};
pub use session_tree::SessionTree;
pub use stream_batcher::StreamBatcher;
pub use types::{AgentError, EntryId, RunId, SessionId};
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
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent
git add rust-core/src/core/provider.rs rust-core/src/core/mod.rs
git commit -m "feat: add mock model provider"
```

## Task 9: Implement AgentRuntime send_message with Mock Provider

**Files:**
- Create: `local-ios-agent/rust-core/src/core/runtime.rs`
- Modify: `local-ios-agent/rust-core/src/core/mod.rs`
- Test: `local-ios-agent/rust-core/tests/runtime_mock.rs`

- [ ] **Step 1: Write failing runtime test**

Create `local-ios-agent/rust-core/tests/runtime_mock.rs`:

```rust
use local_ios_agent_runtime::context::MockTokenizer;
use local_ios_agent_runtime::core::{
    AgentRuntime, AgentRuntimeConfig, EventKind, MockStreamingProvider, SendMessageInput,
};

#[test]
fn runtime_streams_mock_response_and_persists_events() {
    let mut runtime = AgentRuntime::new(AgentRuntimeConfig {
        system_prompt: "system".to_string(),
        runtime_policy: "policy".to_string(),
        tool_schemas: Vec::new(),
        tokenizer: Box::new(MockTokenizer::new(100)),
        provider: Box::new(MockStreamingProvider::new()),
    });

    let session_id = runtime.create_session().unwrap();
    let events = runtime
        .send_message(SendMessageInput {
            session_id,
            parent_event_id: None,
            text: "hello".to_string(),
        })
        .unwrap();

    assert!(events.iter().any(|event| event.kind == EventKind::UserMessage));
    assert!(events
        .iter()
        .any(|event| event.kind == EventKind::AssistantTextDelta));
    assert!(events
        .iter()
        .any(|event| event.kind == EventKind::AssistantMessageCompleted));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo test --test runtime_mock
```

Expected:

```text
error[E0432]: unresolved imports `AgentRuntime`, `AgentRuntimeConfig`, `SendMessageInput`
```

- [ ] **Step 3: Implement AgentRuntime**

Create `local-ios-agent/rust-core/src/core/runtime.rs`:

```rust
use std::collections::HashMap;

use crate::context::{ContextController, TokenizerAdapter};
use crate::core::{
    AgentError, EntryId, EventKind, ModelProvider, ModelProviderOutput, RunId, RuntimeEvent,
    SessionId, SessionTree, StreamBatcher,
};
use crate::utils::id::IdGenerator;

pub struct AgentRuntimeConfig {
    pub system_prompt: String,
    pub runtime_policy: String,
    pub tool_schemas: Vec<String>,
    pub tokenizer: Box<dyn TokenizerAdapter>,
    pub provider: Box<dyn ModelProvider>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SendMessageInput {
    pub session_id: SessionId,
    pub parent_event_id: Option<EntryId>,
    pub text: String,
}

pub struct AgentRuntime {
    config: AgentRuntimeConfig,
    ids: IdGenerator,
    sessions: HashMap<SessionId, SessionTree>,
}

impl AgentRuntime {
    pub fn new(config: AgentRuntimeConfig) -> Self {
        Self {
            config,
            ids: IdGenerator::new(),
            sessions: HashMap::new(),
        }
    }

    pub fn create_session(&mut self) -> Result<SessionId, AgentError> {
        let session_id = SessionId(self.ids.next_id("session"));
        let mut tree = SessionTree::new(session_id.clone());
        tree.append(None, EventKind::SessionCreated, "session created")?;
        self.sessions.insert(session_id.clone(), tree);
        Ok(session_id)
    }

    pub fn send_message(
        &mut self,
        input: SendMessageInput,
    ) -> Result<Vec<RuntimeEvent>, AgentError> {
        let run_id = RunId(self.ids.next_id("run"));
        let tree = self
            .sessions
            .get_mut(&input.session_id)
            .ok_or_else(|| AgentError::Storage(format!("missing session: {}", input.session_id.0)))?;

        let parent_id = input
            .parent_event_id
            .clone()
            .or_else(|| tree.active_leaf().cloned());
        let user_id = tree.append(parent_id, EventKind::UserMessage, input.text)?;
        let branch = tree.active_branch(&user_id)?;

        let context = ContextController::new(
            self.config.system_prompt.clone(),
            self.config.runtime_policy.clone(),
            self.config.tool_schemas.clone(),
            self.config.tokenizer.boxed_clone(),
        );
        let frame = context.build_prompt_frame(branch)?;

        let mut emitted = Vec::new();
        emitted.push(tree.active_branch(&user_id)?.last().cloned().ok_or_else(|| {
            AgentError::Storage("missing just-appended user event".to_string())
        })?);

        let assistant_start = tree.append(
            Some(user_id.clone()),
            EventKind::AssistantMessageStarted,
            format!("run {}", run_id.0),
        )?;
        emitted.push(tree.active_branch(&assistant_start)?.last().cloned().unwrap());

        let mut batcher = StreamBatcher::new(24);
        let provider_events = self.config.provider.stream_chat(&frame)?;
        let mut parent = assistant_start;

        for provider_event in provider_events {
            match provider_event {
                ModelProviderOutput::TextDelta(delta) => {
                    if let Some(chunk) = batcher.push(&delta) {
                        let delta_id =
                            tree.append(Some(parent.clone()), EventKind::AssistantTextDelta, chunk)?;
                        parent = delta_id.clone();
                        emitted.push(tree.active_branch(&delta_id)?.last().cloned().unwrap());
                    }
                }
                ModelProviderOutput::Completed(completed) => {
                    if let Some(chunk) = batcher.flush() {
                        let delta_id =
                            tree.append(Some(parent.clone()), EventKind::AssistantTextDelta, chunk)?;
                        parent = delta_id.clone();
                        emitted.push(tree.active_branch(&delta_id)?.last().cloned().unwrap());
                    }
                    let completed_id = tree.append(
                        Some(parent),
                        EventKind::AssistantMessageCompleted,
                        completed,
                    )?;
                    emitted.push(tree.active_branch(&completed_id)?.last().cloned().unwrap());
                }
            }
        }

        Ok(emitted)
    }
}
```

- [ ] **Step 4: Export runtime types**

Replace `local-ios-agent/rust-core/src/core/mod.rs` with:

```rust
pub mod event;
pub mod provider;
pub mod runtime;
pub mod session_tree;
pub mod stream_batcher;
pub mod types;

pub use event::{EventKind, RuntimeEvent};
pub use provider::{MockStreamingProvider, ModelProvider, ModelProviderOutput};
pub use runtime::{AgentRuntime, AgentRuntimeConfig, SendMessageInput};
pub use session_tree::SessionTree;
pub use stream_batcher::StreamBatcher;
pub use types::{AgentError, EntryId, RunId, SessionId};
```

- [ ] **Step 5: Run runtime test**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo test --test runtime_mock
```

Expected:

```text
test runtime_streams_mock_response_and_persists_events ... ok
```

- [ ] **Step 6: Run full Rust test suite**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo test
```

Expected:

```text
test result: ok
```

- [ ] **Step 7: Commit**

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent
git add rust-core/src/core/runtime.rs rust-core/src/core/mod.rs rust-core/tests/runtime_mock.rs
git commit -m "feat: add mock runtime loop"
```

## Task 10: Add Runtime Foundation README

**Files:**
- Create: `local-ios-agent/rust-core/README.md`

- [ ] **Step 1: Write runtime README**

Create `local-ios-agent/rust-core/README.md`:

```markdown
# Rust Core Runtime

This crate contains the local iOS agent runtime foundation.

## Boundaries

- `core`: agent loop, event stream, session tree, stream batching, run lifecycle
- `memory`: persistence boundary and current in-memory event store
- `context`: PromptFrame construction and tokenizer contract
- `security`: policy and approval suspension types
- `tool`: tool schema and result DTOs
- `utils`: small shared helpers

Swift owns native iOS tools and UI. C++ owns future on-device inference. This
crate owns agent semantics.

## Test

```bash
cargo test
```
```

- [ ] **Step 2: Run final format and tests**

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
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent
git add rust-core/README.md rust-core
git commit -m "docs: document rust runtime foundation"
```

## Plan 1 Completion Checklist

- [ ] `cargo test` passes in `local-ios-agent/rust-core`.
- [ ] The runtime crate has the six approved modules.
- [ ] Session tree active branch reconstruction is tested.
- [ ] PromptFrame construction is tested.
- [ ] Approval suspension type behavior is tested.
- [ ] Stream batching is tested.
- [ ] Mock provider runtime loop is tested.
- [ ] No code is added under `pi/`.

## Follow-up Plans

After this plan passes, create separate detailed plans for:

1. SQLite-backed `memory` implementation and migration from in-memory store.
2. UniFFI bridge between Rust runtime and Swift.
3. SwiftUI shell with chat view, provider selector, and PromptFrame debug view.
4. Swift Native Toolkit with calendar/reminders/shortcuts tools.
5. Desktop MiniCPM provider and local serving runbook.
6. MVP hardening: cancellation, persisted suspended runs, error recovery, and docs.
