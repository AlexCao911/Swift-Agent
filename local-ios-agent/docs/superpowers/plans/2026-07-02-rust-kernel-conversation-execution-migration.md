# Rust Kernel Conversation Execution Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the Rust kernel from the mixed `core::AgentRuntime` path toward a real `conversation -> execution` boundary without breaking the existing app.

**Architecture:** Introduce the new path beside the legacy path first: `conversation/` prepares and persists `ConversationRunFrameRef`; `run_snapshot/` pins that ref; `execution/` starts runs through small focused services and exposes replayable events. The legacy `send_message_streaming` path remains available but is marked as compatibility until Swift adopts the new contract.

**Tech Stack:** Rust crate `local-ios-agent/rust-core`, existing `cargo test` contract/integration/golden suites, JSON over C ABI in `ffi_bridge.rs`.

## Global Constraints

- `ExecutionService` must stay a thin facade over focused services; it must not become the new `AgentRuntime`.
- Execution trusted input is `ConversationRunFrameRef`, not a full frame DTO.
- `ResolvedRunSnapshot` must pin `ConversationRunFrameRef`.
- `observe_events(run_id, from_sequence)` must replay persisted events before tailing live events.
- Final assistant commit must be idempotent by `run_id + final_message_id`.
- Legacy `core::AgentRuntime::send_message_streaming` remains a compatibility path during this plan.

---

## Migration Shape

The migration is deliberately staged:

```text
Stage 1: Add target modules and contracts
  conversation/frame.rs
  conversation/projection.rs
  execution/event_log.rs
  execution/run_lifecycle.rs
  execution/final_commit.rs

Stage 2: Pin frame ref in snapshot
  StartRunRequest + ResolvedRunSnapshot include ConversationRunFrameRef

Stage 3: Add new execution application path
  ExecutionService delegates to RunLifecycleService, ExecutionEventLog,
  FinalAssistantCommitService, ToolLoopService, RunDebugStore,
  InferenceSettingsService

Stage 4: Bridge exposes new contract
  start_run_json requires conversation_frame_ref
  RunHandle includes replay_from_sequence
  observe_events can replay by sequence

Stage 5: Legacy remains classified
  core::AgentRuntime streaming APIs are marked compatibility and tested as
  bypassing snapshot/planner until Swift moves off them
```

## File Structure

Create:

- `rust-core/src/conversation/mod.rs`
- `rust-core/src/conversation/frame.rs`
- `rust-core/src/conversation/projection.rs`
- `rust-core/src/execution/event_log.rs`
- `rust-core/src/execution/run_lifecycle.rs`
- `rust-core/src/execution/final_commit.rs`
- `rust-core/src/execution/execution_service.rs`
- `rust-core/src/execution/tool_loop.rs`
- `rust-core/src/execution/debug_store.rs`
- `rust-core/src/execution/inference_settings.rs`
- `rust-core/tests/contract/conversation_execution_boundary.rs`

Modify:

- `rust-core/src/lib.rs`
- `rust-core/src/run_snapshot/snapshot.rs`
- `rust-core/src/run_snapshot/resolver.rs`
- `rust-core/src/run_snapshot/mod.rs`
- `rust-core/src/app_service.rs`
- `rust-core/src/ffi_bridge.rs`
- `rust-core/src/execution/mod.rs`
- `rust-core/src/core/runtime.rs`
- `rust-core/tests/contract.rs`
- `rust-core/tests/contract/run_snapshot_resolution_agent_os.rs`
- `rust-core/tests/contract/runtime_execution_agent_os.rs`
- `rust-core/tests/integration/ffi_bridge.rs`
- `rust-core/tests/lint/architecture_agent_os.rs`

---

### Task 1: Classify Legacy Runtime And Add Boundary Failing Tests

**Files:**
- Create: `local-ios-agent/rust-core/tests/contract/conversation_execution_boundary.rs`
- Modify: `local-ios-agent/rust-core/tests/contract.rs`
- Modify: `local-ios-agent/rust-core/tests/lint/architecture_agent_os.rs`

**Interfaces:**
- Produces failing tests for `ConversationRunFrameRef`, snapshot pinning, event replay, final commit idempotency, and legacy marker.
- Consumes no new source yet.

- [ ] **Step 1: Register the new contract module**

Modify `local-ios-agent/rust-core/tests/contract.rs`:

```rust
#[path = "contract/conversation_execution_boundary.rs"]
mod conversation_execution_boundary;
```

- [ ] **Step 2: Create failing boundary tests**

Create `local-ios-agent/rust-core/tests/contract/conversation_execution_boundary.rs`:

```rust
use local_ios_agent_runtime::conversation::{
    AttachmentRef, ConversationFrameId, ConversationFrameMessage, ConversationLineage,
    ConversationRunFrame, ConversationRunFrameRef,
};
use local_ios_agent_runtime::core::{EntryId, SessionId};

#[test]
fn conversation_frame_ref_pins_branch_and_user_turn() {
    let frame_ref = ConversationRunFrameRef::new(
        ConversationFrameId::new("frame_1"),
        SessionId("session_1".into()),
        EntryId("branch_head_1".into()),
        EntryId("user_turn_1".into()),
    );

    assert_eq!(frame_ref.frame_id().as_str(), "frame_1");
    assert_eq!(frame_ref.session_id().0, "session_1");
    assert_eq!(frame_ref.branch_head_id().0, "branch_head_1");
    assert_eq!(frame_ref.user_turn_id().0, "user_turn_1");
}

#[test]
fn conversation_frame_is_projection_not_execution_input() {
    let frame_ref = ConversationRunFrameRef::new(
        ConversationFrameId::new("frame_2"),
        SessionId("session_1".into()),
        EntryId("user_turn_1".into()),
        EntryId("user_turn_1".into()),
    );
    let frame = ConversationRunFrame::new(
        frame_ref.clone(),
        None,
        vec![ConversationFrameMessage::user(
            EntryId("user_turn_1".into()),
            "hello",
        )],
        vec![AttachmentRef::new("attachment_1")],
        ConversationLineage::root(),
    );

    assert_eq!(frame.frame_ref(), &frame_ref);
    assert_eq!(frame.messages()[0].role(), "user");
    assert_eq!(frame.system_prompt(), None);
}
```

- [ ] **Step 3: Add failing legacy marker lint**

Add to `local-ios-agent/rust-core/tests/lint/architecture_agent_os.rs`:

```rust
#[test]
fn legacy_streaming_path_is_marked_as_compatibility() {
    let source = include_str!("../../src/core/runtime.rs");

    assert!(
        source.contains("LEGACY_COMPATIBILITY_STREAMING_PATH"),
        "legacy send_message_streaming path must be explicitly marked while it bypasses snapshot/execution planning"
    );
}
```

- [ ] **Step 4: Run tests and confirm failure**

Run:

```bash
cd local-ios-agent/rust-core
cargo test --test contract conversation_frame_ref_pins_branch_and_user_turn -- --exact
cargo test --test lint legacy_streaming_path_is_marked_as_compatibility -- --exact
```

Expected:

```text
FAIL unresolved import local_ios_agent_runtime::conversation
FAIL legacy marker missing
```

- [ ] **Step 5: Commit failing tests**

```bash
git add local-ios-agent/rust-core/tests/contract.rs \
  local-ios-agent/rust-core/tests/contract/conversation_execution_boundary.rs \
  local-ios-agent/rust-core/tests/lint/architecture_agent_os.rs
git commit -m "test: define rust conversation execution boundary contracts"
```

---

### Task 2: Add Conversation Frame Module

**Files:**
- Create: `local-ios-agent/rust-core/src/conversation/mod.rs`
- Create: `local-ios-agent/rust-core/src/conversation/frame.rs`
- Modify: `local-ios-agent/rust-core/src/lib.rs`

**Interfaces:**
- Produces: `ConversationFrameId`
- Produces: `ConversationRunFrameRef`
- Produces: `ConversationRunFrame`
- Produces: `ConversationFrameMessage`
- Produces: `AttachmentRef`
- Produces: `ConversationLineage`

- [ ] **Step 1: Export conversation module**

Modify `local-ios-agent/rust-core/src/lib.rs`:

```rust
pub mod conversation;
```

- [ ] **Step 2: Create module exports**

Create `local-ios-agent/rust-core/src/conversation/mod.rs`:

```rust
mod frame;

pub use frame::{
    AttachmentRef, ConversationFrameId, ConversationFrameMessage, ConversationLineage,
    ConversationRunFrame, ConversationRunFrameRef,
};
```

- [ ] **Step 3: Implement frame types**

Create `local-ios-agent/rust-core/src/conversation/frame.rs`:

```rust
use crate::core::{EntryId, SessionId};

#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct ConversationFrameId(String);

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ConversationRunFrameRef {
    frame_id: ConversationFrameId,
    session_id: SessionId,
    branch_head_id: EntryId,
    user_turn_id: EntryId,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ConversationRunFrame {
    frame_ref: ConversationRunFrameRef,
    parent_event_id: Option<EntryId>,
    messages: Vec<ConversationFrameMessage>,
    attachment_refs: Vec<AttachmentRef>,
    lineage: ConversationLineage,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ConversationFrameMessage {
    event_id: EntryId,
    role: ConversationFrameRole,
    content: String,
    blob_refs: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum ConversationFrameRole {
    User,
    Assistant,
    Summary,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AttachmentRef(String);

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ConversationLineage {
    root: bool,
}

impl ConversationFrameId {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl ConversationRunFrameRef {
    pub fn new(
        frame_id: ConversationFrameId,
        session_id: SessionId,
        branch_head_id: EntryId,
        user_turn_id: EntryId,
    ) -> Self {
        Self {
            frame_id,
            session_id,
            branch_head_id,
            user_turn_id,
        }
    }

    pub fn frame_id(&self) -> &ConversationFrameId {
        &self.frame_id
    }

    pub fn session_id(&self) -> &SessionId {
        &self.session_id
    }

    pub fn branch_head_id(&self) -> &EntryId {
        &self.branch_head_id
    }

    pub fn user_turn_id(&self) -> &EntryId {
        &self.user_turn_id
    }
}

impl ConversationRunFrame {
    pub fn new(
        frame_ref: ConversationRunFrameRef,
        parent_event_id: Option<EntryId>,
        messages: Vec<ConversationFrameMessage>,
        attachment_refs: Vec<AttachmentRef>,
        lineage: ConversationLineage,
    ) -> Self {
        Self {
            frame_ref,
            parent_event_id,
            messages,
            attachment_refs,
            lineage,
        }
    }

    pub fn frame_ref(&self) -> &ConversationRunFrameRef {
        &self.frame_ref
    }

    pub fn parent_event_id(&self) -> Option<&EntryId> {
        self.parent_event_id.as_ref()
    }

    pub fn messages(&self) -> &[ConversationFrameMessage] {
        &self.messages
    }

    pub fn attachment_refs(&self) -> &[AttachmentRef] {
        &self.attachment_refs
    }

    pub fn lineage(&self) -> &ConversationLineage {
        &self.lineage
    }

    pub fn system_prompt(&self) -> Option<&str> {
        None
    }
}

impl ConversationFrameMessage {
    pub fn user(event_id: EntryId, content: impl Into<String>) -> Self {
        Self::new(event_id, ConversationFrameRole::User, content)
    }

    pub fn assistant(event_id: EntryId, content: impl Into<String>) -> Self {
        Self::new(event_id, ConversationFrameRole::Assistant, content)
    }

    pub fn summary(event_id: EntryId, content: impl Into<String>) -> Self {
        Self::new(event_id, ConversationFrameRole::Summary, content)
    }

    fn new(
        event_id: EntryId,
        role: ConversationFrameRole,
        content: impl Into<String>,
    ) -> Self {
        Self {
            event_id,
            role,
            content: content.into(),
            blob_refs: Vec::new(),
        }
    }

    pub fn with_blob_refs(mut self, blob_refs: Vec<String>) -> Self {
        self.blob_refs = blob_refs;
        self
    }

    pub fn event_id(&self) -> &EntryId {
        &self.event_id
    }

    pub fn role(&self) -> &'static str {
        match self.role {
            ConversationFrameRole::User => "user",
            ConversationFrameRole::Assistant => "assistant",
            ConversationFrameRole::Summary => "summary",
        }
    }

    pub fn content(&self) -> &str {
        &self.content
    }

    pub fn blob_refs(&self) -> &[String] {
        &self.blob_refs
    }
}

impl AttachmentRef {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl ConversationLineage {
    pub fn root() -> Self {
        Self { root: true }
    }

    pub fn is_root(&self) -> bool {
        self.root
    }
}
```

- [ ] **Step 4: Run conversation frame tests**

Run:

```bash
cd local-ios-agent/rust-core
cargo test --test contract conversation_frame -- --nocapture
```

Expected: PASS for the two frame tests.

- [ ] **Step 5: Commit**

```bash
git add local-ios-agent/rust-core/src/lib.rs \
  local-ios-agent/rust-core/src/conversation/mod.rs \
  local-ios-agent/rust-core/src/conversation/frame.rs
git commit -m "feat: add conversation frame boundary types"
```

---

### Task 3: Pin Frame Ref In Run Snapshot

**Files:**
- Modify: `local-ios-agent/rust-core/src/run_snapshot/snapshot.rs`
- Modify: `local-ios-agent/rust-core/src/run_snapshot/resolver.rs`
- Modify: `local-ios-agent/rust-core/src/run_snapshot/mod.rs`
- Modify: `local-ios-agent/rust-core/tests/contract/run_snapshot_resolution_agent_os.rs`
- Modify: `local-ios-agent/rust-core/tests/contract/runtime_execution_agent_os.rs`
- Modify: `local-ios-agent/rust-core/tests/integration/runtime_execution_lifecycle.rs`
- Modify: `local-ios-agent/rust-core/tests/golden/runtime_execution_trace.rs`

**Interfaces:**
- Consumes: `ConversationRunFrameRef`
- Produces: `StartRunRequest::new(agent_profile_id, user_intent, conversation_frame_ref)`
- Produces: `StartRunRequest::conversation_frame_ref()`
- Produces: `ResolvedRunSnapshot::conversation_frame_ref()`

- [ ] **Step 1: Update snapshot contract test**

In `local-ios-agent/rust-core/tests/contract/run_snapshot_resolution_agent_os.rs`, replace the request-shape test with:

```rust
use local_ios_agent_runtime::conversation::{ConversationFrameId, ConversationRunFrameRef};
use local_ios_agent_runtime::core::{EntryId, SessionId};

fn frame_ref_fixture() -> ConversationRunFrameRef {
    ConversationRunFrameRef::new(
        ConversationFrameId::new("frame_1"),
        SessionId("session_1".into()),
        EntryId("branch_head_1".into()),
        EntryId("user_turn_1".into()),
    )
}

#[test]
fn start_run_request_requires_conversation_frame_ref() {
    let request = StartRunRequest::new(
        "profile_1",
        "user asked a question",
        frame_ref_fixture(),
    );

    assert_eq!(request.agent_profile_id().as_str(), "profile_1");
    assert_eq!(request.user_intent().as_str(), "user asked a question");
    assert_eq!(request.conversation_frame_ref().frame_id().as_str(), "frame_1");
}

#[test]
fn resolved_snapshot_pins_conversation_frame_ref() {
    let service = RunSnapshotService::fixture();
    let snapshot = service
        .resolve_and_persist(StartRunRequest::new(
            "profile_1",
            "hello",
            frame_ref_fixture(),
        ))
        .unwrap();

    assert_eq!(snapshot.conversation_frame_ref().frame_id().as_str(), "frame_1");
    assert_eq!(
        snapshot.conversation_frame_ref().branch_head_id().0,
        "branch_head_1"
    );
}
```

- [ ] **Step 2: Run request-shape test and confirm failure**

Run:

```bash
cd local-ios-agent/rust-core
cargo test --test contract start_run_request_requires_conversation_frame_ref -- --exact
```

Expected: FAIL because `StartRunRequest::new` still has two arguments.

- [ ] **Step 3: Update snapshot domain structs**

Modify `local-ios-agent/rust-core/src/run_snapshot/snapshot.rs`:

```rust
use crate::conversation::ConversationRunFrameRef;
```

Change `StartRunRequest`:

```rust
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StartRunRequest {
    agent_profile_id: AgentProfileId,
    user_intent: RunUserIntent,
    conversation_frame_ref: ConversationRunFrameRef,
}
```

Change `ResolvedRunSnapshot`:

```rust
conversation_frame_ref: ConversationRunFrameRef,
```

Change `StartRunRequest::new`:

```rust
pub fn new(
    agent_profile_id: impl Into<String>,
    user_intent: impl Into<String>,
    conversation_frame_ref: ConversationRunFrameRef,
) -> Self {
    Self {
        agent_profile_id: AgentProfileId::new(agent_profile_id),
        user_intent: RunUserIntent::new(user_intent),
        conversation_frame_ref,
    }
}

pub fn conversation_frame_ref(&self) -> &ConversationRunFrameRef {
    &self.conversation_frame_ref
}
```

Inside `ResolvedRunSnapshot::new`, assign:

```rust
conversation_frame_ref: request.conversation_frame_ref().clone(),
```

Add:

```rust
pub fn conversation_frame_ref(&self) -> &ConversationRunFrameRef {
    &self.conversation_frame_ref
}
```

- [ ] **Step 4: Update all Rust `StartRunRequest::new` call sites**

For every test helper that creates a snapshot, add this helper:

```rust
fn frame_ref_fixture() -> ConversationRunFrameRef {
    ConversationRunFrameRef::new(
        ConversationFrameId::new("frame_1"),
        SessionId("session_1".into()),
        EntryId("branch_head_1".into()),
        EntryId("user_turn_1".into()),
    )
}
```

Then change calls to:

```rust
StartRunRequest::new("profile_1", "hello", frame_ref_fixture())
```

Use `rg "StartRunRequest::new" local-ios-agent/rust-core -n` to find every call.

- [ ] **Step 5: Run snapshot and execution tests**

Run:

```bash
cd local-ios-agent/rust-core
cargo test --test contract run_snapshot_resolution_agent_os -- --nocapture
cargo test --test contract runtime_execution_agent_os -- --nocapture
cargo test --test integration runtime_execution_lifecycle -- --nocapture
cargo test --test golden runtime_execution_trace -- --nocapture
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add local-ios-agent/rust-core/src/run_snapshot/snapshot.rs \
  local-ios-agent/rust-core/src/run_snapshot/resolver.rs \
  local-ios-agent/rust-core/src/run_snapshot/mod.rs \
  local-ios-agent/rust-core/tests/contract/run_snapshot_resolution_agent_os.rs \
  local-ios-agent/rust-core/tests/contract/runtime_execution_agent_os.rs \
  local-ios-agent/rust-core/tests/integration/runtime_execution_lifecycle.rs \
  local-ios-agent/rust-core/tests/golden/runtime_execution_trace.rs
git commit -m "feat: pin conversation frame ref in snapshots"
```

---

### Task 4: Add Focused Execution Services And Event Replay

**Files:**
- Create: `local-ios-agent/rust-core/src/execution/event_log.rs`
- Create: `local-ios-agent/rust-core/src/execution/run_lifecycle.rs`
- Create: `local-ios-agent/rust-core/src/execution/final_commit.rs`
- Create: `local-ios-agent/rust-core/src/execution/execution_service.rs`
- Create: `local-ios-agent/rust-core/src/execution/tool_loop.rs`
- Create: `local-ios-agent/rust-core/src/execution/debug_store.rs`
- Create: `local-ios-agent/rust-core/src/execution/inference_settings.rs`
- Modify: `local-ios-agent/rust-core/src/execution/mod.rs`
- Modify: `local-ios-agent/rust-core/tests/contract/conversation_execution_boundary.rs`
- Modify: `local-ios-agent/rust-core/tests/lint/architecture_agent_os.rs`

**Interfaces:**
- Produces: `ExecutionEventLog::append`, `ExecutionEventLog::replay`
- Produces: `RunLifecycleService::start_run`
- Produces: `FinalAssistantCommitService`
- Produces: `ExecutionService` facade over focused services

- [ ] **Step 1: Add failing service tests**

Append to `local-ios-agent/rust-core/tests/contract/conversation_execution_boundary.rs`:

```rust
use local_ios_agent_runtime::execution::{
    ExecutionEventLog, ExecutionService, ExecutionServiceParts, FinalAssistantCommitService,
    InferenceSettingsService, RunDebugStore, RunLifecycleService, ToolLoopService,
};

#[test]
fn execution_events_replay_from_durable_sequence() {
    let event_log = ExecutionEventLog::default();
    let lifecycle = RunLifecycleService::new(event_log.clone());

    let handle = lifecycle.start_run("run_1");
    event_log.append("run_1", "assistant.delta");

    let replayed = event_log.replay("run_1", handle.replay_from_sequence());

    assert_eq!(
        replayed.iter().map(|event| event.code()).collect::<Vec<_>>(),
        vec!["run.started", "assistant.delta"]
    );
}

#[test]
fn final_assistant_commit_is_idempotent() {
    let service = FinalAssistantCommitService::default();
    let frame_ref = ConversationRunFrameRef::new(
        ConversationFrameId::new("frame_commit_1"),
        SessionId("session_1".into()),
        EntryId("branch_head_1".into()),
        EntryId("user_turn_1".into()),
    );
    service.record_run_completed("run_1", "final_1", "output_ref_1", frame_ref);

    let first = service.commit_assistant_result("run_1", "final_1").unwrap();
    let second = service.commit_assistant_result("run_1", "final_1").unwrap();

    assert_eq!(first.assistant_message_id(), second.assistant_message_id());
    assert_eq!(service.commit_count(), 1);
}

#[test]
fn execution_service_is_thin_facade() {
    let event_log = ExecutionEventLog::default();
    let service = ExecutionService::new(ExecutionServiceParts {
        run_lifecycle: RunLifecycleService::new(event_log.clone()),
        event_log: event_log.clone(),
        final_commits: FinalAssistantCommitService::default(),
        tool_loop: ToolLoopService::default(),
        debug_store: RunDebugStore::default(),
        inference_settings: InferenceSettingsService::default(),
    });

    let handle = service.start_run("run_facade_1");
    let events = service.observe_events(handle.run_id(), handle.replay_from_sequence());

    assert_eq!(events[0].code(), "run.started");
    assert_eq!(service.tool_loop().pending_count(), 0);
}
```

- [ ] **Step 2: Add failing thin-service lint**

Add to `local-ios-agent/rust-core/tests/lint/architecture_agent_os.rs`:

```rust
#[test]
fn execution_service_stays_thin_facade() {
    let source = include_str!("../../src/execution/execution_service.rs");

    for forbidden in [
        "AgentProfileDraft",
        "ComponentCatalogService",
        "ToolRouter",
        "ContextAssembler",
        "ProviderRegistry",
        "ModelProvider",
        "InMemoryEventStore",
    ] {
        assert!(
            !source.contains(forbidden),
            "ExecutionService must delegate {forbidden} responsibilities to focused services"
        );
    }
}
```

- [ ] **Step 3: Run tests and confirm failure**

Run:

```bash
cd local-ios-agent/rust-core
cargo test --test contract execution_events_replay_from_durable_sequence -- --exact
cargo test --test lint execution_service_stays_thin_facade -- --exact
```

Expected: FAIL because execution services do not exist.

- [ ] **Step 4: Implement event log and lifecycle**

Create `local-ios-agent/rust-core/src/execution/event_log.rs`:

```rust
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

#[derive(Clone, Debug, Default)]
pub struct ExecutionEventLog {
    inner: Arc<Mutex<BTreeMap<String, Vec<ExecutionEvent>>>>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ExecutionEvent {
    run_id: String,
    sequence: u64,
    code: String,
}

impl ExecutionEventLog {
    pub fn append(&self, run_id: impl Into<String>, code: impl Into<String>) -> ExecutionEvent {
        let run_id = run_id.into();
        let mut inner = self.inner.lock().expect("execution event log poisoned");
        let events = inner.entry(run_id.clone()).or_default();
        let sequence = events.last().map(|event| event.sequence + 1).unwrap_or(1);
        let event = ExecutionEvent {
            run_id,
            sequence,
            code: code.into(),
        };
        events.push(event.clone());
        event
    }

    pub fn replay(&self, run_id: &str, from_sequence: Option<u64>) -> Vec<ExecutionEvent> {
        let from_sequence = from_sequence.unwrap_or(0);
        self.inner
            .lock()
            .expect("execution event log poisoned")
            .get(run_id)
            .cloned()
            .unwrap_or_default()
            .into_iter()
            .filter(|event| event.sequence > from_sequence)
            .collect()
    }
}

impl ExecutionEvent {
    pub fn sequence(&self) -> u64 {
        self.sequence
    }

    pub fn code(&self) -> &str {
        &self.code
    }

    pub fn run_id(&self) -> &str {
        &self.run_id
    }
}
```

Create `local-ios-agent/rust-core/src/execution/run_lifecycle.rs`:

```rust
use crate::execution::ExecutionEventLog;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RunHandle {
    run_id: String,
    replay_from_sequence: Option<u64>,
}

#[derive(Clone, Debug)]
pub struct RunLifecycleService {
    event_log: ExecutionEventLog,
}

impl RunLifecycleService {
    pub fn new(event_log: ExecutionEventLog) -> Self {
        Self { event_log }
    }

    pub fn start_run(&self, run_id: impl Into<String>) -> RunHandle {
        let run_id = run_id.into();
        self.event_log.append(run_id.clone(), "run.started");
        RunHandle::new(run_id, Some(0))
    }
}

impl RunHandle {
    pub fn new(run_id: impl Into<String>, replay_from_sequence: Option<u64>) -> Self {
        Self {
            run_id: run_id.into(),
            replay_from_sequence,
        }
    }

    pub fn run_id(&self) -> &str {
        &self.run_id
    }

    pub fn replay_from_sequence(&self) -> Option<u64> {
        self.replay_from_sequence
    }
}
```

- [ ] **Step 5: Implement final commit and small service shells**

Create `local-ios-agent/rust-core/src/execution/final_commit.rs`:

```rust
use std::collections::BTreeMap;
use std::fmt;
use std::sync::{Arc, Mutex};

use crate::conversation::ConversationRunFrameRef;

#[derive(Clone, Debug, Default)]
pub struct FinalAssistantCommitService {
    inner: Arc<Mutex<FinalAssistantCommitState>>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AssistantCommitRecord {
    assistant_message_id: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FinalAssistantCommitError {
    code: String,
    message: String,
}

#[derive(Debug, Default)]
struct FinalAssistantCommitState {
    completed_runs: BTreeMap<String, ConversationRunFrameRef>,
    commits: BTreeMap<String, AssistantCommitRecord>,
}

impl FinalAssistantCommitService {
    pub fn record_run_completed(
        &self,
        run_id: &str,
        final_message_id: &str,
        _final_output_ref: &str,
        frame_ref: ConversationRunFrameRef,
    ) {
        self.inner
            .lock()
            .expect("final commit state poisoned")
            .completed_runs
            .insert(idempotency_key(run_id, final_message_id), frame_ref);
    }

    pub fn commit_assistant_result(
        &self,
        run_id: &str,
        final_message_id: &str,
    ) -> Result<AssistantCommitRecord, FinalAssistantCommitError> {
        let key = idempotency_key(run_id, final_message_id);
        let mut inner = self.inner.lock().expect("final commit state poisoned");
        if let Some(existing) = inner.commits.get(&key) {
            return Ok(existing.clone());
        }
        if !inner.completed_runs.contains_key(&key) {
            return Err(FinalAssistantCommitError::new(
                "final_commit.completed_run_missing",
                format!("completed run not found for {key}"),
            ));
        }
        let record = AssistantCommitRecord {
            assistant_message_id: format!("assistant.{run_id}.{final_message_id}"),
        };
        inner.commits.insert(key, record.clone());
        Ok(record)
    }

    pub fn commit_count(&self) -> usize {
        self.inner
            .lock()
            .expect("final commit state poisoned")
            .commits
            .len()
    }
}

impl AssistantCommitRecord {
    pub fn assistant_message_id(&self) -> &str {
        &self.assistant_message_id
    }
}

impl FinalAssistantCommitError {
    fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }

    pub fn code(&self) -> &str {
        &self.code
    }
}

impl fmt::Display for FinalAssistantCommitError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for FinalAssistantCommitError {}

fn idempotency_key(run_id: &str, final_message_id: &str) -> String {
    format!("{run_id}:{final_message_id}")
}
```

Create `tool_loop.rs`, `debug_store.rs`, and `inference_settings.rs`:

```rust
#[derive(Clone, Debug, Default)]
pub struct ToolLoopService;

impl ToolLoopService {
    pub fn pending_count(&self) -> usize {
        0
    }
}
```

```rust
#[derive(Clone, Debug, Default)]
pub struct RunDebugStore;

impl RunDebugStore {
    pub fn archive_count(&self) -> usize {
        0
    }
}
```

```rust
#[derive(Clone, Debug, Default)]
pub struct InferenceSettingsService;

impl InferenceSettingsService {
    pub fn active_provider_id(&self) -> Option<&str> {
        None
    }
}
```

- [ ] **Step 6: Implement thin `ExecutionService` facade**

Create `local-ios-agent/rust-core/src/execution/execution_service.rs`:

```rust
use crate::execution::{
    ExecutionEvent, ExecutionEventLog, FinalAssistantCommitService, InferenceSettingsService,
    RunDebugStore, RunHandle, RunLifecycleService, ToolLoopService,
};

#[derive(Clone, Debug)]
pub struct ExecutionService {
    parts: ExecutionServiceParts,
}

#[derive(Clone, Debug)]
pub struct ExecutionServiceParts {
    pub run_lifecycle: RunLifecycleService,
    pub event_log: ExecutionEventLog,
    pub final_commits: FinalAssistantCommitService,
    pub tool_loop: ToolLoopService,
    pub debug_store: RunDebugStore,
    pub inference_settings: InferenceSettingsService,
}

impl ExecutionService {
    pub fn new(parts: ExecutionServiceParts) -> Self {
        Self { parts }
    }

    pub fn start_run(&self, run_id: impl Into<String>) -> RunHandle {
        self.parts.run_lifecycle.start_run(run_id)
    }

    pub fn observe_events(
        &self,
        run_id: &str,
        from_sequence: Option<u64>,
    ) -> Vec<ExecutionEvent> {
        self.parts.event_log.replay(run_id, from_sequence)
    }

    pub fn tool_loop(&self) -> &ToolLoopService {
        &self.parts.tool_loop
    }
}
```

Update `local-ios-agent/rust-core/src/execution/mod.rs`:

```rust
mod debug_store;
mod event_log;
mod execution_service;
mod final_commit;
mod inference_settings;
mod run_lifecycle;
mod tool_loop;

pub use debug_store::RunDebugStore;
pub use event_log::{ExecutionEvent, ExecutionEventLog};
pub use execution_service::{ExecutionService, ExecutionServiceParts};
pub use final_commit::{
    AssistantCommitRecord, FinalAssistantCommitError, FinalAssistantCommitService,
};
pub use inference_settings::InferenceSettingsService;
pub use run_lifecycle::{RunHandle, RunLifecycleService};
pub use tool_loop::ToolLoopService;
```

Keep existing exports in `execution/mod.rs`; add these exports without deleting `ExecutionPlan`, `ExecutionPlanner`, budgets, or trace exports.

- [ ] **Step 7: Run service tests**

Run:

```bash
cd local-ios-agent/rust-core
cargo test --test contract execution_events_replay_from_durable_sequence -- --exact
cargo test --test contract final_assistant_commit_is_idempotent -- --exact
cargo test --test contract execution_service_is_thin_facade -- --exact
cargo test --test lint execution_service_stays_thin_facade -- --exact
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add local-ios-agent/rust-core/src/execution/mod.rs \
  local-ios-agent/rust-core/src/execution/event_log.rs \
  local-ios-agent/rust-core/src/execution/run_lifecycle.rs \
  local-ios-agent/rust-core/src/execution/final_commit.rs \
  local-ios-agent/rust-core/src/execution/execution_service.rs \
  local-ios-agent/rust-core/src/execution/tool_loop.rs \
  local-ios-agent/rust-core/src/execution/debug_store.rs \
  local-ios-agent/rust-core/src/execution/inference_settings.rs \
  local-ios-agent/rust-core/tests/contract/conversation_execution_boundary.rs \
  local-ios-agent/rust-core/tests/lint/architecture_agent_os.rs
git commit -m "feat: add focused execution boundary services"
```

---

### Task 5: Add ConversationFrameProjector And Legacy Marker

**Files:**
- Create: `local-ios-agent/rust-core/src/conversation/projection.rs`
- Modify: `local-ios-agent/rust-core/src/conversation/mod.rs`
- Modify: `local-ios-agent/rust-core/src/core/runtime.rs`
- Modify: `local-ios-agent/rust-core/tests/contract/conversation_execution_boundary.rs`

**Interfaces:**
- Produces: `ConversationFrameProjector::project(branch: Vec<RuntimeEvent>) -> Vec<ConversationFrameMessage>`
- Produces: `LEGACY_COMPATIBILITY_STREAMING_PATH` marker in `core/runtime.rs`

- [ ] **Step 1: Add failing projector test**

Append to `local-ios-agent/rust-core/tests/contract/conversation_execution_boundary.rs`:

```rust
use local_ios_agent_runtime::conversation::ConversationFrameProjector;
use local_ios_agent_runtime::core::{EventKind, RuntimeEvent};

#[test]
fn conversation_frame_projector_outputs_visible_messages() {
    let user_event = RuntimeEvent::new(
        EntryId("user_1".into()),
        SessionId("session_1".into()),
        None,
        None,
        1,
        0,
        EventKind::UserMessage,
        "hello",
    );
    let assistant_event = RuntimeEvent::new(
        EntryId("assistant_1".into()),
        SessionId("session_1".into()),
        Some(EntryId("user_1".into())),
        None,
        2,
        1,
        EventKind::AssistantMessageCompleted,
        "hi",
    );

    let messages = ConversationFrameProjector::new().project(vec![user_event, assistant_event]);

    assert_eq!(messages[0].role(), "user");
    assert_eq!(messages[0].content(), "hello");
    assert_eq!(messages[1].role(), "assistant");
    assert_eq!(messages[1].content(), "hi");
}
```

- [ ] **Step 2: Implement projector**

Create `local-ios-agent/rust-core/src/conversation/projection.rs`:

```rust
use crate::conversation::ConversationFrameMessage;
use crate::core::{EventKind, RuntimeEvent};

#[derive(Clone, Debug, Default)]
pub struct ConversationFrameProjector;

impl ConversationFrameProjector {
    pub fn new() -> Self {
        Self
    }

    pub fn project(&self, branch: Vec<RuntimeEvent>) -> Vec<ConversationFrameMessage> {
        let mut messages = Vec::new();
        for event in branch {
            match event.kind {
                EventKind::UserMessage => {
                    messages.push(
                        ConversationFrameMessage::user(event.id, event.payload)
                            .with_blob_refs(event.blob_refs),
                    );
                }
                EventKind::AssistantMessageCompleted => {
                    messages.push(ConversationFrameMessage::assistant(event.id, event.payload));
                }
                EventKind::BranchSummaryCreated => {
                    messages.clear();
                    messages.push(ConversationFrameMessage::summary(event.id, event.payload));
                }
                _ => {}
            }
        }
        messages
    }
}
```

Modify `local-ios-agent/rust-core/src/conversation/mod.rs`:

```rust
mod projection;

pub use projection::ConversationFrameProjector;
```

Do not add a `PromptMessage` adapter in `conversation/`.

- [ ] **Step 3: Mark legacy path**

Add near `ROOT_PARENT_EVENT_ID` in `local-ios-agent/rust-core/src/core/runtime.rs`:

```rust
const LEGACY_COMPATIBILITY_STREAMING_PATH: &str =
    "AgentRuntime.send_message_streaming bypasses ConversationRunFrameRef and ExecutionPlan during migration";
```

Add at the start of `send_message_streaming`:

```rust
let _legacy_path_marker = LEGACY_COMPATIBILITY_STREAMING_PATH;
```

- [ ] **Step 4: Run tests**

Run:

```bash
cd local-ios-agent/rust-core
cargo test --test contract conversation_frame_projector_outputs_visible_messages -- --exact
cargo test --test lint legacy_streaming_path_is_marked_as_compatibility -- --exact
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add local-ios-agent/rust-core/src/conversation/mod.rs \
  local-ios-agent/rust-core/src/conversation/projection.rs \
  local-ios-agent/rust-core/src/core/runtime.rs \
  local-ios-agent/rust-core/tests/contract/conversation_execution_boundary.rs
git commit -m "feat: add conversation frame projector"
```

---

### Task 6: Route AgentOS Start Run JSON Through Frame Ref Contract

**Files:**
- Modify: `local-ios-agent/rust-core/src/ffi_bridge.rs`
- Modify: `local-ios-agent/rust-core/src/app_service.rs`
- Modify: `local-ios-agent/rust-core/tests/integration/ffi_bridge.rs`

**Interfaces:**
- Consumes: `ConversationRunFrameRef`
- Produces: JSON `conversation_frame_ref`
- Produces: `RunHandleJson { run_id, replay_from_sequence }`

- [ ] **Step 1: Update FFI integration test**

In `local-ios-agent/rust-core/tests/integration/ffi_bridge.rs`, update the start-run JSON in `c_abi_start_run_resolves_snapshot_plan_and_debug_archive_in_rust`:

```rust
let request = serde_json::json!({
    "agent_profile_id": "profile_1",
    "user_intent": "hello",
    "conversation_frame_ref": {
        "frame_id": "frame_1",
        "session_id": "session_1",
        "branch_head_id": "branch_head_1",
        "user_turn_id": "user_turn_1"
    }
});
```

Assert the handle has a replay cursor:

```rust
assert_eq!(handle["replay_from_sequence"], 0);
```

- [ ] **Step 2: Update FFI JSON structs**

Modify `local-ios-agent/rust-core/src/ffi_bridge.rs`:

```rust
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ConversationRunFrameRefJson {
    frame_id: String,
    session_id: String,
    branch_head_id: String,
    user_turn_id: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct StartRunRequestJson {
    agent_profile_id: String,
    user_intent: String,
    conversation_frame_ref: ConversationRunFrameRefJson,
}

#[derive(Serialize)]
struct RunHandleJson {
    run_id: String,
    replay_from_sequence: Option<u64>,
}
```

Add imports:

```rust
use crate::conversation::{ConversationFrameId, ConversationRunFrameRef};
```

Update `start_run_json`:

```rust
let frame_ref = ConversationRunFrameRef::new(
    ConversationFrameId::new(request.conversation_frame_ref.frame_id),
    SessionId(request.conversation_frame_ref.session_id),
    EntryId(request.conversation_frame_ref.branch_head_id),
    EntryId(request.conversation_frame_ref.user_turn_id),
);
let request = StartRunRequest::new(request.agent_profile_id, request.user_intent, frame_ref);
```

- [ ] **Step 3: Update application service handle**

If `start_agent_os_run` currently creates `RunHandleJson { run_id }`, change it to:

```rust
RunHandleJson {
    run_id,
    replay_from_sequence: Some(0),
}
```

This is a compatibility cursor for the current synchronous AgentOS path. The future streaming path can set the cursor from `ExecutionEventLog`.

- [ ] **Step 4: Run FFI test**

Run:

```bash
cd local-ios-agent/rust-core
cargo test --test integration c_abi_start_run_resolves_snapshot_plan_and_debug_archive_in_rust -- --exact
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add local-ios-agent/rust-core/src/ffi_bridge.rs \
  local-ios-agent/rust-core/src/app_service.rs \
  local-ios-agent/rust-core/tests/integration/ffi_bridge.rs
git commit -m "feat: route start run ffi through frame ref"
```

---

### Task 7: Final Rust Verification

**Files:**
- Modify only files needed for fixes discovered by verification.

**Interfaces:**
- Consumes all prior tasks.
- Produces a passing Rust kernel boundary contract.

- [ ] **Step 1: Run focused contracts**

Run:

```bash
cd local-ios-agent/rust-core
cargo test --test contract conversation_execution_boundary -- --nocapture
cargo test --test contract run_snapshot_resolution_agent_os -- --nocapture
cargo test --test contract runtime_execution_agent_os -- --nocapture
cargo test --test lint architecture_agent_os -- --nocapture
```

Expected: PASS.

- [ ] **Step 2: Run touched integrations and golden tests**

Run:

```bash
cd local-ios-agent/rust-core
cargo test --test integration ffi_bridge -- --nocapture
cargo test --test integration runtime_execution_lifecycle -- --nocapture
cargo test --test golden runtime_execution_trace -- --nocapture
```

Expected: PASS.

- [ ] **Step 3: Run full Rust suite**

Run:

```bash
cd local-ios-agent/rust-core
cargo test
```

Expected: PASS.

- [ ] **Step 4: Commit verification fixes if needed**

If fixes were required:

```bash
git add local-ios-agent/rust-core
git commit -m "test: verify rust kernel boundary migration"
```

If no fixes were required, do not create a commit.

---

## Self-Review

Spec coverage:

- Old path classification: Tasks 1 and 5.
- New conversation frame/ref path: Tasks 1, 2, and 5.
- Snapshot pinning: Task 3.
- Thin execution services: Task 4.
- Replayable events: Task 4.
- Idempotent final commit: Task 4.
- FFI start-run frame ref contract: Task 6.
- Verification: Task 7.

Placeholder scan:

- No red-flag unfinished wording remains in task steps.

Type consistency:

- `ConversationRunFrameRef` is introduced in Task 2 and used by snapshot, execution, and FFI tasks.
- `RunHandle.replay_from_sequence` is introduced in Task 4 and surfaced through FFI in Task 6.
- `ExecutionService` composes focused services and is guarded by lint in Task 4.
