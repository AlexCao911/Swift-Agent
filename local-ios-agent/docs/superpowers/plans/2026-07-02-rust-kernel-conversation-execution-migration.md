# Rust Kernel Conversation Execution Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the Rust kernel from the mixed `core::AgentRuntime` path toward a real `conversation -> execution` boundary without breaking the existing app.

**Architecture:** Introduce the new path beside the legacy path first: `conversation/` prepares a user turn, persists a `ConversationRunFrame`, and returns a trusted `ConversationRunFrameRef`; `run_snapshot/` pins that ref; `execution/` resolves the frame ref into a snapshot, plan, and `RunMachine` run through focused services. The legacy `send_message_streaming` path remains available but is marked as compatibility until Swift adopts the new contract.

**Tech Stack:** Rust crate `local-ios-agent/rust-core`, existing `cargo test` contract/integration/golden suites, JSON over C ABI in `ffi_bridge.rs`.

## Global Constraints

- `ExecutionService` must stay a thin facade over focused services; it must not become the new `AgentRuntime`.
- Execution trusted input is a `ConversationRunFrameRef` previously issued by Rust `ConversationService`; Swift must not forge one from local state.
- Execution JSON uses the key `conversation_run_frame_ref`; `conversation_frame_ref` is not part of the ABI.
- `ResolvedRunSnapshot` must pin `ConversationRunFrameRef`.
- `observe_events(run_id, from_sequence)` must replay repository-backed events before tailing live events. The first contract implementation may use an in-memory repository adapter, but the API must be repository-based so production can wire durable storage.
- Execution records completed run facts in `CompletedRunRegistry`; conversation owns `ConversationCommitService::commit_assistant_result` and writes the assistant turn to the session tree/event store.
- Final assistant commit must be idempotent by `run_id + final_message_id` in the conversation domain.
- Legacy `core::AgentRuntime::send_message_streaming` remains a compatibility path during this plan.

---

## Migration Shape

The migration is deliberately staged:

```text
Stage 1: Add target modules and contracts
  conversation/frame.rs
  conversation/frame_repository.rs
  conversation/service.rs
  conversation/commit_service.rs
  conversation/projection.rs
  execution/event_log.rs
  execution/run_lifecycle.rs
  execution/completed_run_registry.rs

Stage 2: Pin frame ref in snapshot
  StartRunRequest + ResolvedRunSnapshot include ConversationRunFrameRef

Stage 3: Add new execution application path
  ExecutionService delegates to RunLifecycleService, ExecutionEventLog,
  CompletedRunRegistry, ToolLoopService, RunDebugStore,
  InferenceSettingsService

Stage 4: Bridge exposes new contract
  prepare_user_turn_json returns conversation_run_frame_ref
  start_run_json requires conversation_run_frame_ref
  commit_assistant_result_json writes the assistant turn through conversation/
  RunHandle includes replay_from_sequence
  observe_events can replay by sequence

Stage 5: Legacy remains classified
  core::AgentRuntime streaming APIs are marked compatibility and tested as
  bypassing snapshot/planner until Swift moves off them
```

## ABI Mapping

This table is the Rust/Swift bridge contract. Swift DTO coding keys and Rust JSON structs must match it exactly.

| Domain | Operation Name | Rust Entrypoint | Request DTO | Required JSON Keys | Response DTO |
| --- | --- | --- | --- | --- | --- |
| conversation | `prepare_user_turn` | `prepare_user_turn_json` | `PrepareUserTurnRequestDTO` | `session_id`, `parent_event_id`, `text`, `blob_refs` | `PreparedUserTurnDTO` |
| execution | `list_agent_profiles` | `list_agent_profiles_json` | `EmptyAgentOSRequestDTO` | none | `AgentProfileDTO[]` |
| execution | `build_agent` | `build_agent_json` | `BuildAgentRequestDTO` | `template_id` | `AgentProfileDTO` |
| execution | `start_run` | `start_run_json` | `StartExecutionRequestDTO` | `agent_profile_id`, `user_intent`, `conversation_run_frame_ref`, `options` | `RunHandleDTO` |
| execution | `observe_events` | `observe_events_json` / stream callback | `ObserveExecutionEventsRequestDTO` | `run_id`, `from_sequence` | `RuntimeEventDTO[]` replay, then live events |
| conversation | `commit_assistant_result` | `commit_assistant_result_json` | `CommitAssistantResultRequestDTO` | `run_id`, `final_message_id`, `conversation_run_frame_ref` | `ConversationCommitResultDTO` |
| execution | `approve_tool` | `approve_tool_json` | `ApproveToolRequestDTO` | `id`, `decision` | `EmptyAgentOSResponseDTO` |
| execution | `cancel_run` | `cancel_run_json` | `CancelRunRequestDTO` | `run_id` | `RuntimeEventDTO` |
| execution | `update_runtime_options` | `update_runtime_options_json` | `RuntimeOptionsDTO` | `system_prompt`, `runtime_policy`, `temperature`, `top_p` | `EmptyAgentOSResponseDTO` |

Rules:

- `conversation_run_frame_ref` is the only trusted frame key accepted by execution start.
- `ConversationRunFrameDTO` is never accepted by `start_run_json`.
- `prepare_user_turn_json` is the only bridge operation that creates a new trusted frame ref from Swift user input.
- `commit_assistant_result_json` belongs to `conversation/`; execution only exposes completed run facts.

## File Structure

Create:

- `rust-core/src/conversation/mod.rs`
- `rust-core/src/conversation/frame.rs`
- `rust-core/src/conversation/frame_repository.rs`
- `rust-core/src/conversation/service.rs`
- `rust-core/src/conversation/commit_service.rs`
- `rust-core/src/conversation/projection.rs`
- `rust-core/src/execution/event_log.rs`
- `rust-core/src/execution/run_lifecycle.rs`
- `rust-core/src/execution/completed_run_registry.rs`
- `rust-core/src/execution/execution_service.rs`
- `rust-core/src/execution/tool_loop.rs`
- `rust-core/src/execution/tool_approval.rs`
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
fn conversation_run_frame_ref_pins_branch_and_user_turn() {
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
cargo test --test contract conversation_run_frame_ref_pins_branch_and_user_turn -- --exact
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

### Task 2: Add Conversation Frame Module And Trusted Conversation Service

**Files:**
- Create: `local-ios-agent/rust-core/src/conversation/mod.rs`
- Create: `local-ios-agent/rust-core/src/conversation/frame.rs`
- Create: `local-ios-agent/rust-core/src/conversation/frame_repository.rs`
- Create: `local-ios-agent/rust-core/src/conversation/service.rs`
- Modify: `local-ios-agent/rust-core/src/lib.rs`
- Modify: `local-ios-agent/rust-core/tests/contract/conversation_execution_boundary.rs`

**Interfaces:**
- Produces: `ConversationFrameId`
- Produces: `ConversationRunFrameRef`
- Produces: `ConversationRunFrame`
- Produces: `ConversationFrameMessage`
- Produces: `AttachmentRef`
- Produces: `ConversationLineage`
- Produces: `ConversationFrameRepository`
- Produces: `InMemoryConversationFrameRepository`
- Produces: `PrepareUserTurnRequest`
- Produces: `PreparedUserTurn`
- Produces: `ConversationService::prepare_user_turn`

- [ ] **Step 1: Export conversation module**

Modify `local-ios-agent/rust-core/src/lib.rs`:

```rust
pub mod conversation;
```

- [ ] **Step 2: Create module exports**

Create `local-ios-agent/rust-core/src/conversation/mod.rs`:

```rust
mod frame;
mod frame_repository;
mod service;

pub use frame::{
    AttachmentRef, ConversationFrameId, ConversationFrameMessage, ConversationLineage,
    ConversationRunFrame, ConversationRunFrameRef,
};
pub use frame_repository::{ConversationFrameRepository, InMemoryConversationFrameRepository};
pub use service::{ConversationService, PrepareUserTurnRequest, PreparedUserTurn};
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

- [ ] **Step 5: Add failing trusted prepare-user-turn test**

Append to `local-ios-agent/rust-core/tests/contract/conversation_execution_boundary.rs`:

```rust
use local_ios_agent_runtime::conversation::{
    ConversationFrameRepository, ConversationService, InMemoryConversationFrameRepository,
    PrepareUserTurnRequest,
};

#[test]
fn conversation_service_prepares_and_persists_trusted_frame_ref() {
    let repository = InMemoryConversationFrameRepository::default();
    let service = ConversationService::new(repository.clone());

    let prepared = service
        .prepare_user_turn(PrepareUserTurnRequest::new(
            Some(SessionId("session_1".into())),
            None,
            "hello",
            vec!["blob_1".to_string()],
        ))
        .unwrap();

    let frame = repository
        .get(prepared.conversation_run_frame_ref())
        .expect("prepared frame is persisted");

    assert_eq!(prepared.session_id().0, "session_1");
    assert_eq!(prepared.user_message_id().0, "user_turn_1");
    assert_eq!(frame.frame_ref(), prepared.conversation_run_frame_ref());
    assert_eq!(frame.messages()[0].content(), "hello");
    assert_eq!(frame.messages()[0].blob_refs(), &["blob_1".to_string()]);
}
```

- [ ] **Step 6: Implement frame repository**

Create `local-ios-agent/rust-core/src/conversation/frame_repository.rs`:

```rust
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use crate::conversation::{ConversationFrameId, ConversationRunFrame, ConversationRunFrameRef};

pub trait ConversationFrameRepository: Clone + Send + Sync + 'static {
    fn put(&self, frame: ConversationRunFrame);
    fn get(&self, frame_ref: &ConversationRunFrameRef) -> Option<ConversationRunFrame>;
    fn contains(&self, frame_ref: &ConversationRunFrameRef) -> bool {
        self.get(frame_ref).is_some()
    }
}

#[derive(Clone, Debug, Default)]
pub struct InMemoryConversationFrameRepository {
    inner: Arc<Mutex<BTreeMap<ConversationFrameId, ConversationRunFrame>>>,
}

impl ConversationFrameRepository for InMemoryConversationFrameRepository {
    fn put(&self, frame: ConversationRunFrame) {
        self.inner
            .lock()
            .expect("conversation frame repository poisoned")
            .insert(frame.frame_ref().frame_id().clone(), frame);
    }

    fn get(&self, frame_ref: &ConversationRunFrameRef) -> Option<ConversationRunFrame> {
        self.inner
            .lock()
            .expect("conversation frame repository poisoned")
            .get(frame_ref.frame_id())
            .cloned()
    }
}
```

- [ ] **Step 7: Implement conversation service**

Create `local-ios-agent/rust-core/src/conversation/service.rs`:

```rust
use std::fmt;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use crate::conversation::{
    AttachmentRef, ConversationFrameId, ConversationFrameMessage, ConversationFrameRepository,
    ConversationLineage, ConversationRunFrame, ConversationRunFrameRef,
};
use crate::core::{EntryId, SessionId};

#[derive(Clone)]
pub struct ConversationService<R: ConversationFrameRepository> {
    frames: R,
    next_user_turn: Arc<AtomicU64>,
    next_frame: Arc<AtomicU64>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PrepareUserTurnRequest {
    session_id: Option<SessionId>,
    parent_event_id: Option<EntryId>,
    text: String,
    blob_refs: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PreparedUserTurn {
    session_id: SessionId,
    user_message_id: EntryId,
    conversation_run_frame_ref: ConversationRunFrameRef,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ConversationServiceError {
    code: String,
    message: String,
}

impl<R: ConversationFrameRepository> ConversationService<R> {
    pub fn new(frames: R) -> Self {
        Self {
            frames,
            next_user_turn: Arc::new(AtomicU64::new(1)),
            next_frame: Arc::new(AtomicU64::new(1)),
        }
    }

    pub fn prepare_user_turn(
        &self,
        request: PrepareUserTurnRequest,
    ) -> Result<PreparedUserTurn, ConversationServiceError> {
        let session_id = request
            .session_id
            .clone()
            .unwrap_or_else(|| SessionId("session_1".into()));
        let user_turn_id = EntryId(format!(
            "user_turn_{}",
            self.next_user_turn.fetch_add(1, Ordering::SeqCst)
        ));
        let frame_id = ConversationFrameId::new(format!(
            "frame_{}",
            self.next_frame.fetch_add(1, Ordering::SeqCst)
        ));
        let branch_head_id = request
            .parent_event_id
            .clone()
            .unwrap_or_else(|| user_turn_id.clone());
        let frame_ref = ConversationRunFrameRef::new(
            frame_id,
            session_id.clone(),
            branch_head_id,
            user_turn_id.clone(),
        );
        let frame = ConversationRunFrame::new(
            frame_ref.clone(),
            request.parent_event_id.clone(),
            vec![ConversationFrameMessage::user(user_turn_id.clone(), request.text)
                .with_blob_refs(request.blob_refs)],
            Vec::<AttachmentRef>::new(),
            ConversationLineage::root(),
        );
        self.frames.put(frame);
        Ok(PreparedUserTurn {
            session_id,
            user_message_id: user_turn_id,
            conversation_run_frame_ref: frame_ref,
        })
    }
}

impl PrepareUserTurnRequest {
    pub fn new(
        session_id: Option<SessionId>,
        parent_event_id: Option<EntryId>,
        text: impl Into<String>,
        blob_refs: Vec<String>,
    ) -> Self {
        Self {
            session_id,
            parent_event_id,
            text: text.into(),
            blob_refs,
        }
    }
}

impl PreparedUserTurn {
    pub fn session_id(&self) -> &SessionId {
        &self.session_id
    }

    pub fn user_message_id(&self) -> &EntryId {
        &self.user_message_id
    }

    pub fn conversation_run_frame_ref(&self) -> &ConversationRunFrameRef {
        &self.conversation_run_frame_ref
    }
}

impl ConversationServiceError {
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

impl fmt::Display for ConversationServiceError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for ConversationServiceError {}
```

- [ ] **Step 8: Run trusted conversation tests**

Run:

```bash
cd local-ios-agent/rust-core
cargo test --test contract conversation_service_prepares_and_persists_trusted_frame_ref -- --exact
```

Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add local-ios-agent/rust-core/src/lib.rs \
  local-ios-agent/rust-core/src/conversation/mod.rs \
  local-ios-agent/rust-core/src/conversation/frame.rs \
  local-ios-agent/rust-core/src/conversation/frame_repository.rs \
  local-ios-agent/rust-core/src/conversation/service.rs \
  local-ios-agent/rust-core/tests/contract/conversation_execution_boundary.rs
git commit -m "feat: add trusted conversation frame preparation"
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
- Produces: `StartRunRequest::new(agent_profile_id, user_intent, conversation_run_frame_ref)`
- Produces: `StartRunRequest::conversation_run_frame_ref()`
- Produces: `ResolvedRunSnapshot::conversation_run_frame_ref()`

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
fn start_run_request_requires_conversation_run_frame_ref() {
    let request = StartRunRequest::new(
        "profile_1",
        "user asked a question",
        frame_ref_fixture(),
    );

    assert_eq!(request.agent_profile_id().as_str(), "profile_1");
    assert_eq!(request.user_intent().as_str(), "user asked a question");
    assert_eq!(request.conversation_run_frame_ref().frame_id().as_str(), "frame_1");
}

#[test]
fn resolved_snapshot_pins_conversation_run_frame_ref() {
    let service = RunSnapshotService::fixture();
    let snapshot = service
        .resolve_and_persist(StartRunRequest::new(
            "profile_1",
            "hello",
            frame_ref_fixture(),
        ))
        .unwrap();

    assert_eq!(snapshot.conversation_run_frame_ref().frame_id().as_str(), "frame_1");
    assert_eq!(
        snapshot.conversation_run_frame_ref().branch_head_id().0,
        "branch_head_1"
    );
}
```

- [ ] **Step 2: Run request-shape test and confirm failure**

Run:

```bash
cd local-ios-agent/rust-core
cargo test --test contract start_run_request_requires_conversation_run_frame_ref -- --exact
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
    conversation_run_frame_ref: ConversationRunFrameRef,
}
```

Change `ResolvedRunSnapshot`:

```rust
conversation_run_frame_ref: ConversationRunFrameRef,
```

Change `StartRunRequest::new`:

```rust
pub fn new(
    agent_profile_id: impl Into<String>,
    user_intent: impl Into<String>,
    conversation_run_frame_ref: ConversationRunFrameRef,
) -> Self {
    Self {
        agent_profile_id: AgentProfileId::new(agent_profile_id),
        user_intent: RunUserIntent::new(user_intent),
        conversation_run_frame_ref,
    }
}

pub fn conversation_run_frame_ref(&self) -> &ConversationRunFrameRef {
    &self.conversation_run_frame_ref
}
```

Inside `ResolvedRunSnapshot::new`, assign:

```rust
conversation_run_frame_ref: request.conversation_run_frame_ref().clone(),
```

Add:

```rust
pub fn conversation_run_frame_ref(&self) -> &ConversationRunFrameRef {
    &self.conversation_run_frame_ref
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
- Create: `local-ios-agent/rust-core/src/execution/completed_run_registry.rs`
- Create: `local-ios-agent/rust-core/src/execution/execution_service.rs`
- Create: `local-ios-agent/rust-core/src/execution/tool_loop.rs`
- Create: `local-ios-agent/rust-core/src/execution/tool_approval.rs`
- Create: `local-ios-agent/rust-core/src/execution/debug_store.rs`
- Create: `local-ios-agent/rust-core/src/execution/inference_settings.rs`
- Create: `local-ios-agent/rust-core/src/conversation/commit_service.rs`
- Modify: `local-ios-agent/rust-core/src/conversation/mod.rs`
- Modify: `local-ios-agent/rust-core/src/execution/mod.rs`
- Modify: `local-ios-agent/rust-core/tests/contract/conversation_execution_boundary.rs`
- Modify: `local-ios-agent/rust-core/tests/lint/architecture_agent_os.rs`

**Interfaces:**
- Produces: `ExecutionEventLog::append`, `ExecutionEventLog::replay`
- Produces: `RunLifecycleService::start_run`
- Produces: `CompletedRunRegistry`
- Produces: `ConversationCommitService::commit_assistant_result`
- Produces: `ExecutionService` facade over focused services

- [ ] **Step 1: Add failing service tests**

Append to `local-ios-agent/rust-core/tests/contract/conversation_execution_boundary.rs`:

```rust
use local_ios_agent_runtime::execution::{
    CompletedRunRegistry, ExecutionEventLog, ExecutionService, ExecutionServiceParts,
    InferenceSettingsService, RunDebugStore, RunLifecycleService, ToolApprovalService,
    ToolLoopService,
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

use local_ios_agent_runtime::conversation::ConversationCommitService;

#[test]
fn conversation_assistant_commit_is_idempotent_after_execution_completion() {
    let completed_runs = CompletedRunRegistry::default();
    let service = ConversationCommitService::new(completed_runs.clone());
    let frame_ref = ConversationRunFrameRef::new(
        ConversationFrameId::new("frame_commit_1"),
        SessionId("session_1".into()),
        EntryId("branch_head_1".into()),
        EntryId("user_turn_1".into()),
    );
    completed_runs.record_completed("run_1", "final_1", frame_ref.clone());

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
        completed_runs: CompletedRunRegistry::default(),
        tool_approval: ToolApprovalService::default(),
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
pub struct InMemoryExecutionEventRepository {
    inner: Arc<Mutex<BTreeMap<String, Vec<ExecutionEvent>>>>,
}

pub trait ExecutionEventRepository: Clone + Send + Sync + 'static {
    fn append(&self, run_id: String, code: String) -> ExecutionEvent;
    fn replay_after(&self, run_id: &str, from_sequence: u64) -> Vec<ExecutionEvent>;
}

#[derive(Clone, Debug)]
pub struct ExecutionEventLog<R: ExecutionEventRepository = InMemoryExecutionEventRepository> {
    repository: R,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ExecutionEvent {
    run_id: String,
    sequence: u64,
    code: String,
}

impl Default for ExecutionEventLog<InMemoryExecutionEventRepository> {
    fn default() -> Self {
        Self::new(InMemoryExecutionEventRepository::default())
    }
}

impl<R: ExecutionEventRepository> ExecutionEventLog<R> {
    pub fn new(repository: R) -> Self {
        Self { repository }
    }

    pub fn append(&self, run_id: impl Into<String>, code: impl Into<String>) -> ExecutionEvent {
        self.repository.append(run_id.into(), code.into())
    }

    pub fn replay(&self, run_id: &str, from_sequence: Option<u64>) -> Vec<ExecutionEvent> {
        self.repository.replay_after(run_id, from_sequence.unwrap_or(0))
    }
}

impl ExecutionEventRepository for InMemoryExecutionEventRepository {
    fn append(&self, run_id: String, code: String) -> ExecutionEvent {
        let mut inner = self
            .inner
            .lock()
            .expect("execution event repository poisoned");
        let events = inner.entry(run_id.clone()).or_default();
        let sequence = events.last().map(|event| event.sequence + 1).unwrap_or(1);
        let event = ExecutionEvent {
            run_id,
            sequence,
            code,
        };
        events.push(event.clone());
        event
    }

    fn replay_after(&self, run_id: &str, from_sequence: u64) -> Vec<ExecutionEvent> {
        self.inner
            .lock()
            .expect("execution event repository poisoned")
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

`InMemoryExecutionEventRepository` is a contract adapter for tests and first-stage in-memory runtime. The production bridge path must provide a repository backed by the existing durable event store before `observe_events_json` becomes the default app path.

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

- [ ] **Step 5: Implement completed run registry and conversation commit service**

Create `local-ios-agent/rust-core/src/execution/completed_run_registry.rs`:

```rust
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use crate::conversation::ConversationRunFrameRef;

#[derive(Clone, Debug, Default)]
pub struct CompletedRunRegistry {
    inner: Arc<Mutex<BTreeMap<String, CompletedRunRecord>>>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CompletedRunRecord {
    run_id: String,
    final_message_id: String,
    conversation_run_frame_ref: ConversationRunFrameRef,
}

impl CompletedRunRegistry {
    pub fn record_completed(
        &self,
        run_id: &str,
        final_message_id: &str,
        frame_ref: ConversationRunFrameRef,
    ) {
        let record = CompletedRunRecord {
            run_id: run_id.to_string(),
            final_message_id: final_message_id.to_string(),
            conversation_run_frame_ref: frame_ref,
        };
        self.inner.lock().expect("completed run registry poisoned").insert(
            idempotency_key(run_id, final_message_id),
            record,
        );
    }

    pub fn get(
        &self,
        run_id: &str,
        final_message_id: &str,
    ) -> Option<CompletedRunRecord> {
        self.inner
            .lock()
            .expect("completed run registry poisoned")
            .get(&idempotency_key(run_id, final_message_id))
            .cloned()
    }
}

impl CompletedRunRecord {
    pub fn conversation_run_frame_ref(&self) -> &ConversationRunFrameRef {
        &self.conversation_run_frame_ref
    }

    pub fn run_id(&self) -> &str {
        &self.run_id
    }

    pub fn final_message_id(&self) -> &str {
        &self.final_message_id
    }
}

pub fn idempotency_key(run_id: &str, final_message_id: &str) -> String {
    format!("{run_id}:{final_message_id}")
}
```

Create `local-ios-agent/rust-core/src/conversation/commit_service.rs`:

```rust
use std::collections::BTreeMap;
use std::fmt;
use std::sync::{Arc, Mutex};

use crate::conversation::ConversationRunFrameRef;
use crate::execution::{idempotency_key, CompletedRunRegistry};

#[derive(Clone, Debug)]
pub struct ConversationCommitService {
    completed_runs: CompletedRunRegistry,
    commits: Arc<Mutex<BTreeMap<String, AssistantCommitRecord>>>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AssistantCommitRecord {
    assistant_message_id: String,
    already_committed: bool,
    conversation_run_frame_ref: ConversationRunFrameRef,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ConversationCommitError {
    code: String,
    message: String,
}

impl ConversationCommitService {
    pub fn new(completed_runs: CompletedRunRegistry) -> Self {
        Self {
            completed_runs,
            commits: Arc::new(Mutex::new(BTreeMap::new())),
        }
    }

    pub fn commit_assistant_result(
        &self,
        run_id: &str,
        final_message_id: &str,
    ) -> Result<AssistantCommitRecord, ConversationCommitError> {
        let key = idempotency_key(run_id, final_message_id);
        let mut commits = self.commits.lock().expect("conversation commit state poisoned");
        if let Some(existing) = commits.get(&key) {
            let mut record = existing.clone();
            record.already_committed = true;
            return Ok(record);
        }
        let completed = self.completed_runs.get(run_id, final_message_id).ok_or_else(|| {
            ConversationCommitError::new(
                "conversation_commit.completed_run_missing",
                format!("completed run not found for {key}"),
            )
        })?;
        let record = AssistantCommitRecord {
            assistant_message_id: format!("assistant.{run_id}.{final_message_id}"),
            already_committed: false,
            conversation_run_frame_ref: completed.conversation_run_frame_ref().clone(),
        };
        commits.insert(key, record.clone());
        Ok(record)
    }

    pub fn commit_count(&self) -> usize {
        self.commits
            .lock()
            .expect("conversation commit state poisoned")
            .len()
    }
}

impl AssistantCommitRecord {
    pub fn assistant_message_id(&self) -> &str {
        &self.assistant_message_id
    }

    pub fn already_committed(&self) -> bool {
        self.already_committed
    }

    pub fn conversation_run_frame_ref(&self) -> &ConversationRunFrameRef {
        &self.conversation_run_frame_ref
    }
}

impl ConversationCommitError {
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

impl fmt::Display for ConversationCommitError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for ConversationCommitError {}
```

Create `tool_loop.rs`, `tool_approval.rs`, `debug_store.rs`, and `inference_settings.rs`:

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
pub struct ToolApprovalService;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ApprovalDecision {
    approved: bool,
    reason: Option<String>,
}

impl ToolApprovalService {
    pub fn approve_tool(
        &self,
        _id: impl Into<String>,
        _decision: ApprovalDecision,
    ) -> Result<(), String> {
        Ok(())
    }
}

impl ApprovalDecision {
    pub fn new(approved: bool, reason: Option<String>) -> Self {
        Self { approved, reason }
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

#[derive(Clone, Debug, PartialEq)]
pub struct RuntimeOptions {
    pub system_prompt: String,
    pub runtime_policy: String,
    pub temperature: Option<f64>,
    pub top_p: Option<f64>,
}

impl InferenceSettingsService {
    pub fn active_provider_id(&self) -> Option<&str> {
        None
    }

    pub fn update_runtime_options(&self, _options: RuntimeOptions) -> Result<(), String> {
        Ok(())
    }
}
```

- [ ] **Step 6: Implement thin `ExecutionService` facade**

Create `local-ios-agent/rust-core/src/execution/execution_service.rs`:

```rust
use crate::execution::{
    CompletedRunRegistry, ExecutionEvent, ExecutionEventLog, InferenceSettingsService,
    RunDebugStore, RunHandle, RunLifecycleService, ToolApprovalService, ToolLoopService,
};

#[derive(Clone, Debug)]
pub struct ExecutionService {
    parts: ExecutionServiceParts,
}

#[derive(Clone, Debug)]
pub struct ExecutionServiceParts {
    pub run_lifecycle: RunLifecycleService,
    pub event_log: ExecutionEventLog,
    pub completed_runs: CompletedRunRegistry,
    pub tool_approval: ToolApprovalService,
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

Update `local-ios-agent/rust-core/src/conversation/mod.rs`:

```rust
mod commit_service;
mod frame;
mod frame_repository;
mod service;

pub use commit_service::{AssistantCommitRecord, ConversationCommitError, ConversationCommitService};
pub use frame::{
    AttachmentRef, ConversationFrameId, ConversationFrameMessage, ConversationLineage,
    ConversationRunFrame, ConversationRunFrameRef,
};
pub use frame_repository::{ConversationFrameRepository, InMemoryConversationFrameRepository};
pub use service::{ConversationService, PrepareUserTurnRequest, PreparedUserTurn};
```

Do not export prompt/context types from `conversation/`.

Update `local-ios-agent/rust-core/src/execution/mod.rs`:

```rust
mod debug_store;
mod completed_run_registry;
mod event_log;
mod execution_service;
mod inference_settings;
mod run_lifecycle;
mod tool_approval;
mod tool_loop;

pub use completed_run_registry::{idempotency_key, CompletedRunRecord, CompletedRunRegistry};
pub use debug_store::RunDebugStore;
pub use event_log::{
    ExecutionEvent, ExecutionEventLog, ExecutionEventRepository,
    InMemoryExecutionEventRepository,
};
pub use execution_service::{ExecutionService, ExecutionServiceParts};
pub use inference_settings::{InferenceSettingsService, RuntimeOptions};
pub use run_lifecycle::{RunHandle, RunLifecycleService};
pub use tool_approval::{ApprovalDecision, ToolApprovalService};
pub use tool_loop::ToolLoopService;
```

Keep existing exports in `execution/mod.rs`; add these exports without deleting `ExecutionPlan`, `ExecutionPlanner`, budgets, or trace exports.

- [ ] **Step 7: Run service tests**

Run:

```bash
cd local-ios-agent/rust-core
cargo test --test contract execution_events_replay_from_durable_sequence -- --exact
cargo test --test contract conversation_assistant_commit_is_idempotent_after_execution_completion -- --exact
cargo test --test contract execution_service_is_thin_facade -- --exact
cargo test --test lint execution_service_stays_thin_facade -- --exact
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add local-ios-agent/rust-core/src/execution/mod.rs \
  local-ios-agent/rust-core/src/conversation/mod.rs \
  local-ios-agent/rust-core/src/conversation/commit_service.rs \
  local-ios-agent/rust-core/src/execution/event_log.rs \
  local-ios-agent/rust-core/src/execution/run_lifecycle.rs \
  local-ios-agent/rust-core/src/execution/completed_run_registry.rs \
  local-ios-agent/rust-core/src/execution/execution_service.rs \
  local-ios-agent/rust-core/src/execution/tool_loop.rs \
  local-ios-agent/rust-core/src/execution/tool_approval.rs \
  local-ios-agent/rust-core/src/execution/debug_store.rs \
  local-ios-agent/rust-core/src/execution/inference_settings.rs \
  local-ios-agent/rust-core/tests/contract/conversation_execution_boundary.rs \
  local-ios-agent/rust-core/tests/lint/architecture_agent_os.rs
git commit -m "feat: add focused execution boundary services"
```

---

### Task 5: Connect Execution Start To Frame Snapshot Planner RunMachine

**Files:**
- Modify: `local-ios-agent/rust-core/src/execution/run_lifecycle.rs`
- Modify: `local-ios-agent/rust-core/src/execution/execution_service.rs`
- Modify: `local-ios-agent/rust-core/tests/contract/conversation_execution_boundary.rs`
- Modify: `local-ios-agent/rust-core/tests/integration/runtime_execution_lifecycle.rs`

**Interfaces:**
- Consumes: `ConversationFrameRepository`, `ConversationRunFrameRef`, `RunSnapshotService`, `ExecutionPlanner`, `RunMachine`
- Produces: `StartExecutionRequest`
- Produces: `ExecutionService::start_run(StartExecutionRequest) -> Result<RunHandle, ExecutionStartError>`
- Produces: run events appended from the real plan/machine path

- [ ] **Step 1: Add failing execution-start contract test**

Append to `local-ios-agent/rust-core/tests/contract/conversation_execution_boundary.rs`:

```rust
use local_ios_agent_runtime::conversation::{
    ConversationFrameMessage, ConversationLineage, ConversationRunFrame,
};
use local_ios_agent_runtime::execution::{
    ExecutionPlanner, ExecutionStartError, StartExecutionRequest,
};
use local_ios_agent_runtime::run_snapshot::RunSnapshotService;

#[test]
fn execution_start_loads_frame_resolves_snapshot_and_runs_machine() {
    let frames = InMemoryConversationFrameRepository::default();
    let frame_ref = ConversationRunFrameRef::new(
        ConversationFrameId::new("frame_exec_1"),
        SessionId("session_1".into()),
        EntryId("user_turn_1".into()),
        EntryId("user_turn_1".into()),
    );
    frames.put(ConversationRunFrame::new(
        frame_ref.clone(),
        None,
        vec![ConversationFrameMessage::user(EntryId("user_turn_1".into()), "hello")],
        Vec::new(),
        ConversationLineage::root(),
    ));
    let event_log = ExecutionEventLog::default();
    let completed_runs = CompletedRunRegistry::default();
    let service = ExecutionService::with_runtime_parts(
        frames,
        RunSnapshotService::fixture(),
        ExecutionPlanner::default(),
        event_log.clone(),
        completed_runs,
    );

    let handle = service
        .start_run(StartExecutionRequest::new(
            "run_1",
            "profile_1",
            "hello",
            frame_ref,
        ))
        .unwrap();

    let events = event_log.replay(handle.run_id(), handle.replay_from_sequence());
    assert_eq!(handle.run_id(), "run_1");
    assert!(events.iter().any(|event| event.code() == "run.started"));
    assert!(events.iter().any(|event| event.code() == "run.completed"));
}

#[test]
fn execution_start_rejects_unissued_frame_ref() {
    let service = ExecutionService::with_runtime_parts(
        InMemoryConversationFrameRepository::default(),
        RunSnapshotService::fixture(),
        ExecutionPlanner::default(),
        ExecutionEventLog::default(),
        CompletedRunRegistry::default(),
    );
    let missing_ref = ConversationRunFrameRef::new(
        ConversationFrameId::new("missing_frame"),
        SessionId("session_1".into()),
        EntryId("branch_head_1".into()),
        EntryId("user_turn_1".into()),
    );

    let error = service
        .start_run(StartExecutionRequest::new("run_1", "profile_1", "hello", missing_ref))
        .unwrap_err();

    assert_eq!(error.code(), "execution.frame_ref_untrusted");
}
```

- [ ] **Step 2: Update the earlier thin-facade test for runtime parts**

In `execution_service_is_thin_facade`, replace direct `ExecutionServiceParts` construction with:

```rust
let frames = InMemoryConversationFrameRepository::default();
let frame_ref = ConversationRunFrameRef::new(
    ConversationFrameId::new("frame_facade_1"),
    SessionId("session_1".into()),
    EntryId("user_turn_1".into()),
    EntryId("user_turn_1".into()),
);
frames.put(ConversationRunFrame::new(
    frame_ref.clone(),
    None,
    vec![ConversationFrameMessage::user(EntryId("user_turn_1".into()), "hello")],
    Vec::new(),
    ConversationLineage::root(),
));
let event_log = ExecutionEventLog::default();
let service = ExecutionService::with_runtime_parts(
    frames,
    RunSnapshotService::fixture(),
    ExecutionPlanner::default(),
    event_log.clone(),
    CompletedRunRegistry::default(),
);

let handle = service
    .start_run(StartExecutionRequest::new(
        "run_facade_1",
        "profile_1",
        "hello",
        frame_ref,
    ))
    .unwrap();
let events = service.observe_events(handle.run_id(), handle.replay_from_sequence());
```

Keep the existing assertions:

```rust
assert!(events.iter().any(|event| event.code() == "run.started"));
assert_eq!(service.tool_loop().pending_count(), 0);
```

- [ ] **Step 3: Add start request and error types**

Modify `local-ios-agent/rust-core/src/execution/run_lifecycle.rs`:

```rust
use std::fmt;

use crate::conversation::ConversationRunFrameRef;
use crate::execution::ExecutionEventLog;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StartExecutionRequest {
    run_id: String,
    agent_profile_id: String,
    user_intent: String,
    conversation_run_frame_ref: ConversationRunFrameRef,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ExecutionStartError {
    code: String,
    message: String,
}

impl StartExecutionRequest {
    pub fn new(
        run_id: impl Into<String>,
        agent_profile_id: impl Into<String>,
        user_intent: impl Into<String>,
        conversation_run_frame_ref: ConversationRunFrameRef,
    ) -> Self {
        Self {
            run_id: run_id.into(),
            agent_profile_id: agent_profile_id.into(),
            user_intent: user_intent.into(),
            conversation_run_frame_ref,
        }
    }

    pub fn run_id(&self) -> &str {
        &self.run_id
    }

    pub fn agent_profile_id(&self) -> &str {
        &self.agent_profile_id
    }

    pub fn user_intent(&self) -> &str {
        &self.user_intent
    }

    pub fn conversation_run_frame_ref(&self) -> &ConversationRunFrameRef {
        &self.conversation_run_frame_ref
    }
}

impl ExecutionStartError {
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }

    pub fn code(&self) -> &str {
        &self.code
    }
}

impl fmt::Display for ExecutionStartError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for ExecutionStartError {}
```

Keep the existing `RunHandle` type. `RunLifecycleService::start_run(run_id)` can remain as a private helper used by `ExecutionService`, but it is no longer the public application boundary.

- [ ] **Step 4: Implement real execution start in the facade**

Modify `local-ios-agent/rust-core/src/execution/execution_service.rs` so the application entry point consumes `StartExecutionRequest`:

```rust
use crate::conversation::{ConversationFrameRepository, InMemoryConversationFrameRepository};
use crate::execution::{
    ApprovalDecision, CompletedRunRegistry, ExecutionEvent, ExecutionEventLog, ExecutionPlanner,
    ExecutionStartError, InferenceSettingsService, RuntimeOptions, RunDebugStore, RunHandle,
    RunLifecycleService, StartExecutionRequest, ToolApprovalService, ToolLoopService,
};
use crate::run_snapshot::{RunSnapshotService, StartRunRequest};
use crate::runtime::{RecordingEffectDriver, RunMachine};

#[derive(Clone, Debug)]
pub struct ExecutionService<R: ConversationFrameRepository = InMemoryConversationFrameRepository> {
    parts: ExecutionServiceParts<R>,
}

#[derive(Clone, Debug)]
pub struct ExecutionServiceParts<R: ConversationFrameRepository = InMemoryConversationFrameRepository> {
    pub frames: R,
    pub snapshot_service: RunSnapshotService,
    pub planner: ExecutionPlanner,
    pub run_lifecycle: RunLifecycleService,
    pub event_log: ExecutionEventLog,
    pub completed_runs: CompletedRunRegistry,
    pub tool_approval: ToolApprovalService,
    pub tool_loop: ToolLoopService,
    pub debug_store: RunDebugStore,
    pub inference_settings: InferenceSettingsService,
}

impl<R: ConversationFrameRepository> ExecutionService<R> {
    pub fn new(parts: ExecutionServiceParts<R>) -> Self {
        Self { parts }
    }

    pub fn with_runtime_parts(
        frames: R,
        snapshot_service: RunSnapshotService,
        planner: ExecutionPlanner,
        event_log: ExecutionEventLog,
        completed_runs: CompletedRunRegistry,
    ) -> Self {
        Self::new(ExecutionServiceParts {
            frames,
            snapshot_service,
            planner,
            run_lifecycle: RunLifecycleService::new(event_log.clone()),
            event_log,
            completed_runs,
            tool_approval: ToolApprovalService::default(),
            tool_loop: ToolLoopService::default(),
            debug_store: RunDebugStore::default(),
            inference_settings: InferenceSettingsService::default(),
        })
    }

    pub fn start_run(
        &self,
        request: StartExecutionRequest,
    ) -> Result<RunHandle, ExecutionStartError> {
        if !self.parts.frames.contains(request.conversation_run_frame_ref()) {
            return Err(ExecutionStartError::new(
                "execution.frame_ref_untrusted",
                format!(
                    "conversation frame ref was not issued by conversation service: {}",
                    request.conversation_run_frame_ref().frame_id().as_str()
                ),
            ));
        }
        let snapshot = self
            .parts
            .snapshot_service
            .resolve_and_persist(StartRunRequest::new(
                request.agent_profile_id(),
                request.user_intent(),
                request.conversation_run_frame_ref().clone(),
            ))
            .map_err(|error| ExecutionStartError::new(error.code(), error.to_string()))?;
        let plan = self
            .parts
            .planner
            .plan(snapshot)
            .map_err(|error| ExecutionStartError::new(error.code(), error.to_string()))?;
        let mut machine = RunMachine::from_plan_with_effect_driver_and_run_id(
            plan,
            RecordingEffectDriver::default(),
            request.run_id().to_string(),
        );
        self.parts.event_log.append(request.run_id(), "run.started");
        machine
            .run_to_completion()
            .map_err(|error| ExecutionStartError::new(error.code(), error.to_string()))?;
        self.parts.event_log.append(request.run_id(), "run.completed");
        self.parts.completed_runs.record_completed(
            request.run_id(),
            "final_1",
            request.conversation_run_frame_ref().clone(),
        );
        Ok(RunHandle::new(request.run_id(), Some(0)))
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

    pub fn approve_tool(
        &self,
        id: impl Into<String>,
        decision: ApprovalDecision,
    ) -> Result<(), ExecutionStartError> {
        self.parts
            .tool_approval
            .approve_tool(id, decision)
            .map_err(|message| ExecutionStartError::new("execution.approve_tool_failed", message))
    }

    pub fn update_runtime_options(
        &self,
        options: RuntimeOptions,
    ) -> Result<(), ExecutionStartError> {
        self.parts
            .inference_settings
            .update_runtime_options(options)
            .map_err(|message| {
                ExecutionStartError::new("execution.update_runtime_options_failed", message)
            })
    }
}
```

- [ ] **Step 5: Export start types**

Update `local-ios-agent/rust-core/src/execution/mod.rs`:

```rust
pub use run_lifecycle::{ExecutionStartError, RunHandle, RunLifecycleService, StartExecutionRequest};
```

- [ ] **Step 6: Run execution start tests**

Run:

```bash
cd local-ios-agent/rust-core
cargo test --test contract execution_start_loads_frame_resolves_snapshot_and_runs_machine -- --exact
cargo test --test contract execution_start_rejects_unissued_frame_ref -- --exact
cargo test --test integration runtime_execution_lifecycle -- --nocapture
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add local-ios-agent/rust-core/src/execution/run_lifecycle.rs \
  local-ios-agent/rust-core/src/execution/execution_service.rs \
  local-ios-agent/rust-core/src/execution/mod.rs \
  local-ios-agent/rust-core/tests/contract/conversation_execution_boundary.rs \
  local-ios-agent/rust-core/tests/integration/runtime_execution_lifecycle.rs
git commit -m "feat: connect execution start to snapshot runtime path"
```

---

### Task 6: Add ConversationFrameProjector And Legacy Marker

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

### Task 7: Route AgentOS JSON Through Conversation And Execution Contracts

**Files:**
- Modify: `local-ios-agent/rust-core/src/ffi_bridge.rs`
- Modify: `local-ios-agent/rust-core/src/app_service.rs`
- Modify: `local-ios-agent/rust-core/tests/integration/ffi_bridge.rs`

**Interfaces:**
- Produces: `prepare_user_turn_json`
- Produces: `start_run_json` consuming JSON `conversation_run_frame_ref`
- Produces: `observe_events_json`
- Produces: `commit_assistant_result_json`
- Produces: `RunHandleJson { run_id, replay_from_sequence }`

- [ ] **Step 1: Update FFI integration test for prepare -> start -> observe -> commit**

In `local-ios-agent/rust-core/tests/integration/ffi_bridge.rs`, update the AgentOS start-run test so Swift-like callers cannot forge a frame ref:

```rust
let prepared = bridge.prepare_user_turn_json(
    &serde_json::json!({
        "session_id": "session_1",
        "parent_event_id": null,
        "text": "hello",
        "blob_refs": []
    })
    .to_string(),
)?;
let prepared: serde_json::Value = serde_json::from_str(&prepared).unwrap();

let start_request = serde_json::json!({
    "agent_profile_id": "profile_1",
    "user_intent": "hello",
    "conversation_run_frame_ref": prepared["conversation_run_frame_ref"],
    "options": {}
});

let handle_json = bridge.start_run_json(&start_request.to_string())?;
let handle: serde_json::Value = serde_json::from_str(&handle_json).unwrap();

assert_eq!(handle["run_id"], "run_1");
assert_eq!(handle["replay_from_sequence"], 0);

let replay_json = bridge.observe_events_json(
    &serde_json::json!({
        "run_id": "run_1",
        "from_sequence": 0
    })
    .to_string(),
)?;
let replayed: serde_json::Value = serde_json::from_str(&replay_json).unwrap();
assert!(replayed.as_array().unwrap().iter().any(|event| {
    event["kind"] == "execution.event" && event["payload"] == "run.started"
}));

let commit_json = bridge.commit_assistant_result_json(
    &serde_json::json!({
        "run_id": "run_1",
        "final_message_id": "final_1",
        "conversation_run_frame_ref": prepared["conversation_run_frame_ref"]
    })
    .to_string(),
)?;
let commit: serde_json::Value = serde_json::from_str(&commit_json).unwrap();
assert_eq!(commit["committed_message_id"], "assistant.run_1.final_1");
```

- [ ] **Step 2: Add FFI JSON structs**

Modify `local-ios-agent/rust-core/src/ffi_bridge.rs`:

```rust
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct EmptyAgentOSRequestJson {}

#[derive(Serialize)]
struct EmptyAgentOSResponseJson {}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct BuildAgentRequestJson {
    template_id: String,
}

#[derive(Serialize)]
struct AgentProfileJson {
    profile_id: String,
    display_name: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RuntimeOptionsJson {
    system_prompt: String,
    runtime_policy: String,
    temperature: Option<f64>,
    top_p: Option<f64>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ApprovalDecisionJson {
    approved: bool,
    reason: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ApproveToolRequestJson {
    id: String,
    decision: ApprovalDecisionJson,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CancelRunRequestJson {
    run_id: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PrepareUserTurnRequestJson {
    session_id: Option<String>,
    parent_event_id: Option<String>,
    text: String,
    blob_refs: Vec<String>,
}

#[derive(Serialize)]
struct PreparedUserTurnJson {
    session_id: String,
    user_message_id: String,
    conversation_run_frame_ref: ConversationRunFrameRefJson,
    frame_preview: Option<ConversationRunFrameJson>,
}

#[derive(Serialize)]
struct ConversationRunFrameJson {
    frame_ref: ConversationRunFrameRefJson,
    messages: Vec<ConversationFrameMessageJson>,
    attachment_refs: Vec<String>,
}

#[derive(Serialize)]
struct ConversationFrameMessageJson {
    event_id: String,
    role: String,
    content: String,
}

#[derive(Clone, Deserialize, Serialize)]
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
    conversation_run_frame_ref: ConversationRunFrameRefJson,
    options: serde_json::Value,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ObserveExecutionEventsRequestJson {
    run_id: String,
    from_sequence: u64,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CommitAssistantResultRequestJson {
    run_id: String,
    final_message_id: String,
    conversation_run_frame_ref: ConversationRunFrameRefJson,
}

#[derive(Serialize)]
struct ConversationCommitResultJson {
    committed_message_id: String,
    already_committed: bool,
}

#[derive(Serialize)]
struct RunHandleJson {
    run_id: String,
    replay_from_sequence: Option<u64>,
}
```

Add imports:

```rust
use crate::conversation::{
    ConversationCommitService, ConversationFrameId, ConversationRunFrameRef,
    ConversationService, InMemoryConversationFrameRepository, PreparedUserTurn,
    PrepareUserTurnRequest,
};
use crate::execution::{
    ApprovalDecision, ExecutionPlanner, ExecutionService, RuntimeOptions,
    RunHandle, StartExecutionRequest,
};
```

- [ ] **Step 3: Wire bridge runtime services**

Extend `BridgeRuntime` with shared conversation and execution services:

```rust
struct BridgeRuntime<S: EventStore> {
    runtime: Mutex<AgentRuntime<S>>,
    cancellations: ProviderCancellationRegistry,
    app_services: AgentOSApplicationService,
    debug_archives: Mutex<BTreeMap<String, RunDebugArchiveJson>>,
    next_agent_os_run_id: Mutex<u64>,
    conversation: ConversationService<InMemoryConversationFrameRepository>,
    execution: ExecutionService<InMemoryConversationFrameRepository>,
    conversation_commits: ConversationCommitService,
}
```

Create these services in `BridgeRuntime::new` from the same frame repository and completed-run registry:

```rust
let frames = InMemoryConversationFrameRepository::default();
let event_log = ExecutionEventLog::default();
let completed_runs = CompletedRunRegistry::default();
let execution = ExecutionService::with_runtime_parts(
    frames.clone(),
    app_services.snapshot_service().clone(),
    ExecutionPlanner::default(),
    event_log,
    completed_runs.clone(),
);
let conversation = ConversationService::new(frames);
let conversation_commits = ConversationCommitService::new(completed_runs);
```

Add private accessors on `RuntimeJsonBridge` so the JSON methods can share the same implementation for in-memory and SQLite runtimes:

```rust
fn conversation(&self) -> &ConversationService<InMemoryConversationFrameRepository> {
    match self {
        Self::InMemory(runtime) => &runtime.conversation,
        Self::Sqlite(runtime) => &runtime.conversation,
    }
}

fn execution(&self) -> &ExecutionService<InMemoryConversationFrameRepository> {
    match self {
        Self::InMemory(runtime) => &runtime.execution,
        Self::Sqlite(runtime) => &runtime.execution,
    }
}

fn conversation_commits(&self) -> &ConversationCommitService {
    match self {
        Self::InMemory(runtime) => &runtime.conversation_commits,
        Self::Sqlite(runtime) => &runtime.conversation_commits,
    }
}
```

Expose `AgentOSApplicationService::snapshot_service(&self) -> &RunSnapshotService`. Do not create a second fixture snapshot service inside the bridge.

Add this application-service accessor in `local-ios-agent/rust-core/src/app_service.rs` so execution start reuses the configured snapshot service:

```rust
impl AgentOSApplicationService {
    pub fn snapshot_service(&self) -> &RunSnapshotService {
        &self.snapshot_service
    }
}
```

This first bridge contract returns deterministic profile JSON in `ffi_bridge.rs`; later repository-backed profile listing can replace the body without changing the ABI. Do not place profile composition inside `ExecutionService`.

- [ ] **Step 4: Implement JSON entrypoints**

Add methods on the bridge enum:

```rust
pub fn list_agent_profiles_json(&self, request_json: &str) -> Result<String, AgentError> {
    let _: EmptyAgentOSRequestJson = from_json(request_json)?;
    to_json(&vec![AgentProfileJson {
        profile_id: "profile_1".to_string(),
        display_name: "Development Agent".to_string(),
    }])
}

pub fn build_agent_json(&self, request_json: &str) -> Result<String, AgentError> {
    let request: BuildAgentRequestJson = from_json(request_json)?;
    to_json(&AgentProfileJson {
        profile_id: format!("profile.from_template.{}", request.template_id),
        display_name: "Custom Agent".to_string(),
    })
}

pub fn prepare_user_turn_json(&self, request_json: &str) -> Result<String, AgentError> {
    let request: PrepareUserTurnRequestJson = from_json(request_json)?;
    let prepared = self.conversation().prepare_user_turn(PrepareUserTurnRequest::new(
        request.session_id.map(SessionId),
        request.parent_event_id.map(EntryId),
        request.text,
        request.blob_refs,
    ))?;
    to_json(&PreparedUserTurnJson::from(prepared))
}

pub fn start_run_json(&self, request_json: &str) -> Result<String, AgentError> {
    let request: StartRunRequestJson = from_json(request_json)?;
    let frame_ref = request.conversation_run_frame_ref.into_domain();
    let run_id = self.reserve_agent_os_run_id()?;
    let handle = self.execution().start_run(StartExecutionRequest::new(
        run_id,
        request.agent_profile_id,
        request.user_intent,
        frame_ref,
    ))?;
    to_json(&RunHandleJson::from(handle))
}

pub fn observe_events_json(&self, request_json: &str) -> Result<String, AgentError> {
    let request: ObserveExecutionEventsRequestJson = from_json(request_json)?;
    let events = self
        .execution()
        .observe_events(&request.run_id, Some(request.from_sequence));
    to_json(&events.into_iter().map(RuntimeEventJson::from_execution_event).collect::<Vec<_>>())
}

pub fn commit_assistant_result_json(&self, request_json: &str) -> Result<String, AgentError> {
    let request: CommitAssistantResultRequestJson = from_json(request_json)?;
    let record = self
        .conversation_commits()
        .commit_assistant_result(&request.run_id, &request.final_message_id)?;
    to_json(&ConversationCommitResultJson {
        committed_message_id: record.assistant_message_id().to_string(),
        already_committed: record.already_committed(),
    })
}

pub fn approve_tool_json(&self, request_json: &str) -> Result<String, AgentError> {
    let request: ApproveToolRequestJson = from_json(request_json)?;
    self.execution().approve_tool(request.id, request.decision.into_domain())?;
    to_json(&EmptyAgentOSResponseJson {})
}

pub fn cancel_run_json(&self, request_json: &str) -> Result<String, AgentError> {
    let request: CancelRunRequestJson = from_json(request_json)?;
    let event = self.lock()?.cancel(RunId(request.run_id))?;
    to_json(&RuntimeEventJson::from_event(&event))
}

pub fn update_runtime_options_json(&self, request_json: &str) -> Result<String, AgentError> {
    let request: RuntimeOptionsJson = from_json(request_json)?;
    self.execution().update_runtime_options(request.into_domain())?;
    to_json(&EmptyAgentOSResponseJson {})
}
```

Implement `ConversationRunFrameRefJson::into_domain`, `From<&ConversationRunFrameRef> for ConversationRunFrameRefJson`, prepared-turn conversion, and approval conversion in the same file:

```rust
impl ConversationRunFrameRefJson {
    fn into_domain(self) -> ConversationRunFrameRef {
        ConversationRunFrameRef::new(
            ConversationFrameId::new(self.frame_id),
            SessionId(self.session_id),
            EntryId(self.branch_head_id),
            EntryId(self.user_turn_id),
        )
    }
}

impl From<&ConversationRunFrameRef> for ConversationRunFrameRefJson {
    fn from(frame_ref: &ConversationRunFrameRef) -> Self {
        Self {
            frame_id: frame_ref.frame_id().as_str().to_string(),
            session_id: frame_ref.session_id().0.clone(),
            branch_head_id: frame_ref.branch_head_id().0.clone(),
            user_turn_id: frame_ref.user_turn_id().0.clone(),
        }
    }
}

impl From<PreparedUserTurn> for PreparedUserTurnJson {
    fn from(prepared: PreparedUserTurn) -> Self {
        Self {
            session_id: prepared.session_id().0.clone(),
            user_message_id: prepared.user_message_id().0.clone(),
            conversation_run_frame_ref: ConversationRunFrameRefJson::from(
                prepared.conversation_run_frame_ref(),
            ),
            frame_preview: None,
        }
    }
}

impl RuntimeEventJson {
    fn from_execution_event(event: ExecutionEvent) -> Self {
        RuntimeEventJson {
            id: format!("{}.{}", event.run_id(), event.sequence()),
            session_id: String::new(),
            parent_id: None,
            run_id: Some(event.run_id().to_string()),
            sequence: event.sequence(),
            created_at_millis: 0,
            depth: 0,
            kind: "execution.event",
            payload: event.code().to_string(),
            blob_refs: Vec::new(),
        }
    }
}

impl From<RunHandle> for RunHandleJson {
    fn from(handle: RunHandle) -> Self {
        Self {
            run_id: handle.run_id().to_string(),
            replay_from_sequence: handle.replay_from_sequence(),
        }
    }
}

impl ApprovalDecisionJson {
    fn into_domain(self) -> ApprovalDecision {
        ApprovalDecision::new(self.approved, self.reason)
    }
}

impl RuntimeOptionsJson {
    fn into_domain(self) -> RuntimeOptions {
        RuntimeOptions {
            system_prompt: self.system_prompt,
            runtime_policy: self.runtime_policy,
            temperature: self.temperature,
            top_p: self.top_p,
        }
    }
}
```

- [ ] **Step 5: Wire C ABI names to the mapping table**

Keep the existing `local_agent_runtime_bridge_start_run` exported symbol as the C ABI entrypoint for `start_run_json`. Add the following exported symbols beside it:

```rust
local_agent_runtime_bridge_list_agent_profiles
local_agent_runtime_bridge_build_agent
local_agent_runtime_bridge_prepare_user_turn
local_agent_runtime_bridge_observe_events
local_agent_runtime_bridge_commit_assistant_result
local_agent_runtime_bridge_approve_tool
local_agent_runtime_bridge_cancel_run
local_agent_runtime_bridge_update_runtime_options
```

Each symbol must call the matching `*_json` method in the ABI mapping table. Do not add a `start_execution_run` symbol.

- [ ] **Step 6: Run FFI test**

Run:

```bash
cd local-ios-agent/rust-core
cargo test --test integration c_abi_start_run_resolves_snapshot_plan_and_debug_archive_in_rust -- --exact
cargo test --test integration c_abi_prepare_start_observe_commit_uses_trusted_frame_ref -- --exact
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add local-ios-agent/rust-core/src/ffi_bridge.rs \
  local-ios-agent/rust-core/src/app_service.rs \
  local-ios-agent/rust-core/tests/integration/ffi_bridge.rs
git commit -m "feat: expose conversation execution agent os ffi"
```

---

### Task 8: Final Rust Verification

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

- Old path classification: Tasks 1 and 6.
- New conversation frame/ref path: Tasks 1, 2, and 6.
- Trusted frame issuance through Rust conversation service: Task 2.
- Snapshot pinning: Task 3.
- Thin execution services: Task 4.
- Repository-backed replayable events: Task 4.
- Execution start connected to frame repository, snapshot, planner, and RunMachine: Task 5.
- Idempotent conversation-owned final commit with execution completed-run facts: Task 4.
- FFI prepare/start/observe/commit ABI contract: Task 7.
- Verification: Task 8.

Placeholder scan:

- No red-flag unfinished wording remains in task steps.

Type consistency:

- `ConversationRunFrameRef` is introduced in Task 2 and used by snapshot, execution, and FFI tasks.
- `RunHandle.replay_from_sequence` is introduced in Task 4 and surfaced through FFI in Task 7.
- `ExecutionService` composes focused services in Task 4 and consumes `StartExecutionRequest` in Task 5.
