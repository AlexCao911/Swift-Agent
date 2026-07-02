# Rust Conversation Execution Boundary Contract Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the Rust boundary contract that makes execution runs pin a trusted `ConversationRunFrameRef`, replay durable execution events, and commit final assistant output idempotently.

**Architecture:** Add a small `conversation` domain for frame identity/projection and keep `execution` as a thin facade over focused services. `RunSnapshotService` will pin `ConversationRunFrameRef`; `ExecutionEventLog` will make start/observe safe; `FinalAssistantCommitService` will make completed run recovery explicit.

**Tech Stack:** Rust crate `local-ios-agent/rust-core`, Swift bridge DTOs in `local-ios-agent/toolkit`, JSON over C ABI, `cargo test`.

## Global Constraints

- Execution trusted input accepts only `ConversationRunFrameRef`; full `ConversationRunFrameDTO` is UI/debug projection only.
- `ResolvedRunSnapshot` must persist the conversation frame reference used by the run.
- Split `startRun` / `observeEvents` is valid only if `observeEvents(runId, fromSequence:)` replays durable events before tailing live events.
- Final assistant commit is idempotent by `run_id + final_message_id` and recoverable after completed-but-uncommitted runs.
- `ExecutionService` must stay a thin facade and must not absorb agent composition, run lifecycle, tool loop, debug, or inference settings into one large object.
- Legacy `AgentRuntime.send_message_streaming` remains a compatibility path and must be documented/test-covered as bypassing snapshot/execution planning.

---

## Scope

This plan implements the Rust boundary contract first. It does not split Swift view models, redesign the chat UI, or remove the legacy streaming path.

The deliverable is a testable contract layer:

```text
conversation frame ref
  -> snapshot pinning
  -> start/observe execution event replay contract
  -> idempotent final assistant commit contract
  -> thin execution facade with small internal services
```

## File Structure

Create:

- `rust-core/src/conversation/mod.rs`
  Public exports for the new conversation boundary.
- `rust-core/src/conversation/frame.rs`
  `ConversationFrameId`, `ConversationRunFrameRef`, `ConversationRunFrame`, `ConversationFrameMessage`, `AttachmentRef`, and `ConversationLineage`.
- `rust-core/src/conversation/projection.rs`
  `ConversationFrameProjector` that converts visible branch facts into `ConversationFrameMessage`.
- `rust-core/src/execution/execution_service.rs`
  Thin facade delegating to focused execution services.
- `rust-core/src/execution/event_log.rs`
  Durable replayable `ExecutionEventLog`.
- `rust-core/src/execution/run_lifecycle.rs`
  Run start handle and small lifecycle helpers.
- `rust-core/src/execution/final_commit.rs`
  Idempotent final assistant commit records and recovery queries.
- `rust-core/tests/contract/conversation_execution_boundary.rs`
  Rust contract tests for frame refs, snapshot pinning, replay, final commit idempotency, and service decomposition.

Modify:

- `rust-core/src/lib.rs`
  Export `conversation`.
- `rust-core/src/run_snapshot/snapshot.rs`
  Add `ConversationRunFrameRef` to `StartRunRequest` and `ResolvedRunSnapshot`.
- `rust-core/src/run_snapshot/resolver.rs`
  Preserve frame ref through snapshot resolution and repository writes.
- `rust-core/src/run_snapshot/mod.rs`
  Export the new frame-aware snapshot API.
- `rust-core/src/run_snapshot/snapshot_service.rs`
  Keep preview/persist behavior intact with frame-aware requests.
- `rust-core/src/app_service.rs`
  Accept frame-aware `StartRunRequest`; keep application service focused on snapshot resolution.
- `rust-core/src/ffi_bridge.rs`
  Add `conversation_frame_ref` to start-run JSON and run handle replay cursor to response JSON.
- `rust-core/src/execution/mod.rs`
  Export small execution services; do not place all behavior in `ExecutionService`.
- `toolkit/Sources/LocalAgentBridge/AgentOSDTOs.swift`
  Add `ConversationRunFrameRefDTO`, update `StartRunRequestDTO`, and add `replayFromSequence` to `RunHandleDTO`.
- `rust-core/tests/contract.rs`
  Register the new contract test module.
- `rust-core/tests/contract/run_snapshot_resolution_agent_os.rs`
  Update request fixtures to pass a frame ref and assert snapshot pinning.
- `rust-core/tests/contract/runtime_execution_agent_os.rs`
  Update resolved snapshot fixtures and add event replay/final commit coverage if colocated tests are simpler.
- `rust-core/tests/lint/architecture_agent_os.rs`
  Strengthen lint checks for frame ref trust boundary and `ExecutionService` thinness.

Do not modify:

- Swift app view models.
- Legacy `AgentRuntime.send_message_streaming` behavior, except adding comments/tests that classify it as compatibility.
- C++ inference backend.

---

### Task 1: Add Conversation Frame Boundary Types

**Files:**
- Create: `local-ios-agent/rust-core/src/conversation/mod.rs`
- Create: `local-ios-agent/rust-core/src/conversation/frame.rs`
- Modify: `local-ios-agent/rust-core/src/lib.rs`
- Test: `local-ios-agent/rust-core/tests/contract/conversation_execution_boundary.rs`
- Modify: `local-ios-agent/rust-core/tests/contract.rs`

**Interfaces:**
- Produces: `ConversationFrameId::new(value: impl Into<String>) -> Self`
- Produces: `ConversationRunFrameRef::new(frame_id, session_id, branch_head_id, user_turn_id) -> Self`
- Produces: `ConversationRunFrameRef::{frame_id, session_id, branch_head_id, user_turn_id}`
- Produces: `ConversationRunFrame::new(ref, parent_event_id, messages, attachment_refs, lineage) -> Self`
- Consumes: `local_ios_agent_runtime::core::{EntryId, SessionId}`

- [ ] **Step 1: Write the failing contract test**

Add this module registration to `local-ios-agent/rust-core/tests/contract.rs`:

```rust
#[path = "contract/conversation_execution_boundary.rs"]
mod conversation_execution_boundary;
```

Create `local-ios-agent/rust-core/tests/contract/conversation_execution_boundary.rs`:

```rust
use local_ios_agent_runtime::conversation::{
    AttachmentRef, ConversationFrameId, ConversationFrameMessage, ConversationLineage,
    ConversationRunFrame, ConversationRunFrameRef,
};
use local_ios_agent_runtime::core::{EntryId, SessionId};

#[test]
fn conversation_run_frame_ref_pins_frame_branch_and_user_turn() {
    let frame_ref = ConversationRunFrameRef::new(
        ConversationFrameId::new("frame_1"),
        SessionId("session_1".into()),
        EntryId("assistant_leaf_1".into()),
        EntryId("user_turn_1".into()),
    );

    assert_eq!(frame_ref.frame_id().as_str(), "frame_1");
    assert_eq!(frame_ref.session_id().0, "session_1");
    assert_eq!(frame_ref.branch_head_id().0, "assistant_leaf_1");
    assert_eq!(frame_ref.user_turn_id().0, "user_turn_1");
}

#[test]
fn conversation_run_frame_is_projection_not_prompt() {
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
        vec![AttachmentRef::new("attachment.link.1")],
        ConversationLineage::root(),
    );

    assert_eq!(frame.frame_ref(), &frame_ref);
    assert_eq!(frame.messages()[0].role(), "user");
    assert_eq!(frame.messages()[0].content(), "hello");
    assert_eq!(frame.attachment_refs()[0].as_str(), "attachment.link.1");
    assert!(frame.system_prompt().is_none());
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd local-ios-agent/rust-core
cargo test --test contract conversation_run_frame_ref_pins_frame_branch_and_user_turn -- --exact
```

Expected: FAIL with unresolved import `local_ios_agent_runtime::conversation`.

- [ ] **Step 3: Add conversation module exports**

Modify `local-ios-agent/rust-core/src/lib.rs`:

```rust
pub mod conversation;
```

Create `local-ios-agent/rust-core/src/conversation/mod.rs`:

```rust
mod frame;

pub use frame::{
    AttachmentRef, ConversationFrameId, ConversationFrameMessage, ConversationLineage,
    ConversationRunFrame, ConversationRunFrameRef,
};
```

- [ ] **Step 4: Implement frame types**

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
        Self {
            event_id,
            role: ConversationFrameRole::User,
            content: content.into(),
            blob_refs: Vec::new(),
        }
    }

    pub fn assistant(event_id: EntryId, content: impl Into<String>) -> Self {
        Self {
            event_id,
            role: ConversationFrameRole::Assistant,
            content: content.into(),
            blob_refs: Vec::new(),
        }
    }

    pub fn summary(event_id: EntryId, content: impl Into<String>) -> Self {
        Self {
            event_id,
            role: ConversationFrameRole::Summary,
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

- [ ] **Step 5: Run tests to verify they pass**

Run:

```bash
cd local-ios-agent/rust-core
cargo test --test contract conversation_run_frame -- --nocapture
```

Expected: PASS for both `conversation_run_frame_ref_pins_frame_branch_and_user_turn` and `conversation_run_frame_is_projection_not_prompt`.

- [ ] **Step 6: Commit**

```bash
git add local-ios-agent/rust-core/src/lib.rs \
  local-ios-agent/rust-core/src/conversation/mod.rs \
  local-ios-agent/rust-core/src/conversation/frame.rs \
  local-ios-agent/rust-core/tests/contract.rs \
  local-ios-agent/rust-core/tests/contract/conversation_execution_boundary.rs
git commit -m "feat: add conversation run frame boundary"
```

---

### Task 2: Pin Conversation Frame Ref In Run Snapshot

**Files:**
- Modify: `local-ios-agent/rust-core/src/run_snapshot/snapshot.rs`
- Modify: `local-ios-agent/rust-core/src/run_snapshot/resolver.rs`
- Modify: `local-ios-agent/rust-core/src/run_snapshot/mod.rs`
- Modify: `local-ios-agent/rust-core/tests/contract/run_snapshot_resolution_agent_os.rs`
- Modify: `local-ios-agent/rust-core/tests/contract/runtime_execution_agent_os.rs`
- Modify: `local-ios-agent/rust-core/tests/integration/runtime_execution_lifecycle.rs`
- Modify: `local-ios-agent/rust-core/tests/golden/runtime_execution_trace.rs`
- Modify: `local-ios-agent/rust-core/tests/golden/lifecycle_debug_artifacts.rs`
- Modify: `local-ios-agent/rust-core/tests/integration/agent_lifecycle_profile_to_runtime.rs`

**Interfaces:**
- Consumes: `ConversationRunFrameRef`
- Produces: `StartRunRequest::new(agent_profile_id, user_intent, conversation_frame_ref) -> Self`
- Produces: `StartRunRequest::conversation_frame_ref(&self) -> &ConversationRunFrameRef`
- Produces: `ResolvedRunSnapshot::conversation_frame_ref(&self) -> &ConversationRunFrameRef`

- [ ] **Step 1: Write the failing snapshot test**

In `local-ios-agent/rust-core/tests/contract/run_snapshot_resolution_agent_os.rs`, replace `start_run_request_contains_only_profile_id_and_user_intent` with:

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
    assert_eq!(request.conversation_frame_ref().session_id().0, "session_1");
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
    assert_eq!(
        snapshot.conversation_frame_ref().user_turn_id().0,
        "user_turn_1"
    );
}
```

- [ ] **Step 2: Run the focused tests to verify they fail**

Run:

```bash
cd local-ios-agent/rust-core
cargo test --test contract start_run_request_requires_conversation_frame_ref -- --exact
```

Expected: FAIL because `StartRunRequest::new` takes two arguments and has no `conversation_frame_ref`.

- [ ] **Step 3: Update `StartRunRequest` and `ResolvedRunSnapshot`**

Modify `local-ios-agent/rust-core/src/run_snapshot/snapshot.rs`:

```rust
use crate::conversation::ConversationRunFrameRef;
```

Update the structs:

```rust
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StartRunRequest {
    agent_profile_id: AgentProfileId,
    user_intent: RunUserIntent,
    conversation_frame_ref: ConversationRunFrameRef,
}
```

```rust
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ResolvedRunSnapshot {
    snapshot_id: RunSnapshotId,
    agent_profile_id: AgentProfileId,
    user_intent: RunUserIntent,
    conversation_frame_ref: ConversationRunFrameRef,
    profile_version: AgentProfileVersion,
    component_versions: Vec<ResolvedComponentBinding>,
    model_binding: ResolvedModelBinding,
    tool_bindings: Vec<ResolvedToolBinding>,
    memory_binding: Option<ResolvedMemoryBinding>,
    voice_binding: Option<ResolvedVoiceBinding>,
    trusted_host_state: TrustedHostRunState,
    readiness_report: RunSnapshotReadinessReport,
    created_at_millis: u64,
}
```

Update constructor and accessors:

```rust
impl StartRunRequest {
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
}
```

Inside `ResolvedRunSnapshot::new`, set:

```rust
conversation_frame_ref: request.conversation_frame_ref().clone(),
```

Add accessor:

```rust
pub fn conversation_frame_ref(&self) -> &ConversationRunFrameRef {
    &self.conversation_frame_ref
}
```

- [ ] **Step 4: Update all request fixtures**

In each Rust test or source file that calls `StartRunRequest::new(profile, intent)`, add a local helper and pass it as the third argument.

Use this helper in Rust tests:

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

Import where needed:

```rust
use local_ios_agent_runtime::conversation::{ConversationFrameId, ConversationRunFrameRef};
use local_ios_agent_runtime::core::{EntryId, SessionId};
```

For crate-internal tests in `src` modules, use:

```rust
use crate::conversation::{ConversationFrameId, ConversationRunFrameRef};
use crate::core::{EntryId, SessionId};
```

Then convert calls:

```rust
StartRunRequest::new("profile_1", "hello", frame_ref_fixture())
```

- [ ] **Step 5: Run snapshot and execution contract tests**

Run:

```bash
cd local-ios-agent/rust-core
cargo test --test contract run_snapshot_resolution_agent_os -- --nocapture
cargo test --test contract runtime_execution_agent_os -- --nocapture
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
  local-ios-agent/rust-core/tests/golden/runtime_execution_trace.rs \
  local-ios-agent/rust-core/tests/golden/lifecycle_debug_artifacts.rs \
  local-ios-agent/rust-core/tests/integration/agent_lifecycle_profile_to_runtime.rs
git commit -m "feat: pin conversation frame ref in run snapshots"
```

---

### Task 3: Update FFI And Swift DTO Start-Run Contract

**Files:**
- Modify: `local-ios-agent/rust-core/src/ffi_bridge.rs`
- Modify: `local-ios-agent/toolkit/Sources/LocalAgentBridge/AgentOSDTOs.swift`
- Modify: `local-ios-agent/toolkit/Tests/LocalAgentBridgeTests/AgentOSDTOTests.swift`
- Modify: `local-ios-agent/rust-core/tests/integration/ffi_bridge.rs`
- Modify: `local-ios-agent/rust-core/tests/lint/architecture_agent_os.rs`

**Interfaces:**
- Consumes: `ConversationRunFrameRef`
- Produces: Swift `ConversationRunFrameRefDTO`
- Produces: Swift `StartRunRequestDTO(agentProfileId:userIntent:conversationRunFrameRef:)`
- Produces: Rust JSON `StartRunRequestJson { agent_profile_id, user_intent, conversation_frame_ref }`
- Produces: `RunHandleDTO.replayFromSequence`

- [ ] **Step 1: Write Swift DTO test**

In `local-ios-agent/toolkit/Tests/LocalAgentBridgeTests/AgentOSDTOTests.swift`, add:

```swift
func testStartRunRequestIncludesConversationFrameRefButNoTrustedHostState() throws {
    let request = StartRunRequestDTO(
        agentProfileId: "profile_1",
        userIntent: "hello",
        conversationRunFrameRef: ConversationRunFrameRefDTO(
            frameId: "frame_1",
            sessionId: "session_1",
            branchHeadId: "branch_head_1",
            userTurnId: "user_turn_1"
        )
    )

    let data = try JSONEncoder().encode(request)
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

    XCTAssertEqual(object?["agent_profile_id"] as? String, "profile_1")
    XCTAssertEqual(object?["user_intent"] as? String, "hello")
    let frame = object?["conversation_frame_ref"] as? [String: Any]
    XCTAssertEqual(frame?["frame_id"] as? String, "frame_1")
    XCTAssertNil(object?["permission_state"])
    XCTAssertNil(object?["local_bindings"])
    XCTAssertNil(object?["credential_availability"])
}

func testRunHandleDecodesReplayCursor() throws {
    let data = """
    {"run_id":"run_1","replay_from_sequence":0}
    """.data(using: .utf8)!

    let handle = try JSONDecoder().decode(RunHandleDTO.self, from: data)

    XCTAssertEqual(handle.runId, "run_1")
    XCTAssertEqual(handle.replayFromSequence, 0)
}
```

- [ ] **Step 2: Run Swift bridge tests to verify failure**

Run:

```bash
cd local-ios-agent/toolkit
swift test --filter LocalAgentBridgeTests.AgentOSDTOTests/testStartRunRequestIncludesConversationFrameRefButNoTrustedHostState
```

Expected: FAIL because `ConversationRunFrameRefDTO` and new initializer do not exist.

- [ ] **Step 3: Update Swift DTOs**

Modify `local-ios-agent/toolkit/Sources/LocalAgentBridge/AgentOSDTOs.swift`:

```swift
public struct ConversationRunFrameRefDTO: Codable, Equatable, Sendable {
    public var frameId: String
    public var sessionId: String
    public var branchHeadId: String
    public var userTurnId: String

    public init(
        frameId: String,
        sessionId: String,
        branchHeadId: String,
        userTurnId: String
    ) {
        self.frameId = frameId
        self.sessionId = sessionId
        self.branchHeadId = branchHeadId
        self.userTurnId = userTurnId
    }

    private enum CodingKeys: String, CodingKey {
        case frameId = "frame_id"
        case sessionId = "session_id"
        case branchHeadId = "branch_head_id"
        case userTurnId = "user_turn_id"
    }
}
```

Update `StartRunRequestDTO`:

```swift
public struct StartRunRequestDTO: Codable, Equatable, Sendable {
    public var agentProfileId: String
    public var userIntent: String
    public var conversationRunFrameRef: ConversationRunFrameRefDTO

    public init(
        agentProfileId: String,
        userIntent: String,
        conversationRunFrameRef: ConversationRunFrameRefDTO
    ) {
        self.agentProfileId = agentProfileId
        self.userIntent = userIntent
        self.conversationRunFrameRef = conversationRunFrameRef
    }

    private enum CodingKeys: String, CodingKey {
        case agentProfileId = "agent_profile_id"
        case userIntent = "user_intent"
        case conversationRunFrameRef = "conversation_frame_ref"
    }
}
```

Update `RunHandleDTO`:

```swift
public struct RunHandleDTO: Codable, Equatable, Sendable {
    public var runId: String
    public var replayFromSequence: UInt64?

    public init(runId: String, replayFromSequence: UInt64? = nil) {
        self.runId = runId
        self.replayFromSequence = replayFromSequence
    }

    private enum CodingKeys: String, CodingKey {
        case runId = "run_id"
        case replayFromSequence = "replay_from_sequence"
    }
}
```

- [ ] **Step 4: Update Rust FFI JSON structs**

Modify `local-ios-agent/rust-core/src/ffi_bridge.rs` near `StartRunRequestJson`:

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
```

Update imports:

```rust
use crate::conversation::{ConversationFrameId, ConversationRunFrameRef};
```

Update `start_run_json` request conversion:

```rust
let frame_ref = ConversationRunFrameRef::new(
    ConversationFrameId::new(request.conversation_frame_ref.frame_id),
    SessionId(request.conversation_frame_ref.session_id),
    EntryId(request.conversation_frame_ref.branch_head_id),
    EntryId(request.conversation_frame_ref.user_turn_id),
);
let request = StartRunRequest::new(request.agent_profile_id, request.user_intent, frame_ref);
```

Update `RunHandleJson`:

```rust
#[derive(Serialize)]
struct RunHandleJson {
    run_id: String,
    replay_from_sequence: Option<u64>,
}
```

When creating a handle for the synchronous current path, set:

```rust
RunHandleJson {
    run_id,
    replay_from_sequence: Some(0),
}
```

- [ ] **Step 5: Update architecture lint**

In `local-ios-agent/rust-core/tests/lint/architecture_agent_os.rs`, update `swift_start_run_request_dto_does_not_model_trusted_host_state` to assert the DTO includes `conversationRunFrameRef` and still excludes trusted state:

```rust
assert!(
    start_run_source.contains("conversationRunFrameRef"),
    "StartRunRequestDTO must carry ConversationRunFrameRef as execution trust input"
);
```

- [ ] **Step 6: Run bridge and lint tests**

Run:

```bash
cd local-ios-agent/toolkit
swift test --filter LocalAgentBridgeTests.AgentOSDTOTests
cd ../rust-core
cargo test --test integration ffi_bridge -- --nocapture
cargo test --test lint architecture_agent_os -- --nocapture
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add local-ios-agent/toolkit/Sources/LocalAgentBridge/AgentOSDTOs.swift \
  local-ios-agent/toolkit/Tests/LocalAgentBridgeTests/AgentOSDTOTests.swift \
  local-ios-agent/rust-core/src/ffi_bridge.rs \
  local-ios-agent/rust-core/tests/integration/ffi_bridge.rs \
  local-ios-agent/rust-core/tests/lint/architecture_agent_os.rs
git commit -m "feat: require conversation frame ref in start run DTO"
```

---

### Task 4: Add Replayable Execution Event Log

**Files:**
- Create: `local-ios-agent/rust-core/src/execution/event_log.rs`
- Create: `local-ios-agent/rust-core/src/execution/run_lifecycle.rs`
- Modify: `local-ios-agent/rust-core/src/execution/mod.rs`
- Modify: `local-ios-agent/rust-core/tests/contract/conversation_execution_boundary.rs`

**Interfaces:**
- Produces: `ExecutionEventLog::append(run_id: impl Into<String>, code: impl Into<String>) -> ExecutionEvent`
- Produces: `ExecutionEventLog::replay(run_id: &str, from_sequence: Option<u64>) -> Vec<ExecutionEvent>`
- Produces: `RunHandle::new(run_id: impl Into<String>, replay_from_sequence: Option<u64>) -> Self`
- Produces: `RunLifecycleService::start_run(run_id: impl Into<String>) -> RunHandle`

- [ ] **Step 1: Write failing replay test**

Append to `local-ios-agent/rust-core/tests/contract/conversation_execution_boundary.rs`:

```rust
use local_ios_agent_runtime::execution::{ExecutionEventLog, RunLifecycleService};

#[test]
fn observe_events_replays_persisted_events_before_live_tail() {
    let event_log = ExecutionEventLog::default();
    let lifecycle = RunLifecycleService::new(event_log.clone());

    let handle = lifecycle.start_run("run_1");
    event_log.append("run_1", "assistant.delta");

    let replayed = event_log.replay("run_1", handle.replay_from_sequence());

    assert_eq!(
        replayed.iter().map(|event| event.code()).collect::<Vec<_>>(),
        vec!["run.started", "assistant.delta"]
    );
    assert_eq!(handle.run_id(), "run_1");
    assert_eq!(handle.replay_from_sequence(), Some(0));
}

#[test]
fn observe_events_from_sequence_returns_only_newer_events() {
    let event_log = ExecutionEventLog::default();
    event_log.append("run_1", "run.started");
    let first_delta = event_log.append("run_1", "assistant.delta.1");
    event_log.append("run_1", "assistant.delta.2");

    let replayed = event_log.replay("run_1", Some(first_delta.sequence()));

    assert_eq!(
        replayed.iter().map(|event| event.code()).collect::<Vec<_>>(),
        vec!["assistant.delta.2"]
    );
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
cd local-ios-agent/rust-core
cargo test --test contract observe_events_replays_persisted_events_before_live_tail -- --exact
```

Expected: FAIL because `ExecutionEventLog` and `RunLifecycleService` do not exist.

- [ ] **Step 3: Export execution services**

Modify `local-ios-agent/rust-core/src/execution/mod.rs`:

```rust
mod event_log;
mod run_lifecycle;

pub use event_log::{ExecutionEvent, ExecutionEventLog};
pub use run_lifecycle::{RunHandle, RunLifecycleService};
```

- [ ] **Step 4: Implement `ExecutionEventLog`**

Create `local-ios-agent/rust-core/src/execution/event_log.rs`:

```rust
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

#[derive(Clone, Debug, Default)]
pub struct ExecutionEventLog {
    inner: Arc<Mutex<ExecutionEventLogInner>>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ExecutionEvent {
    run_id: String,
    sequence: u64,
    code: String,
}

#[derive(Debug, Default)]
struct ExecutionEventLogInner {
    events_by_run: BTreeMap<String, Vec<ExecutionEvent>>,
}

impl ExecutionEventLog {
    pub fn append(
        &self,
        run_id: impl Into<String>,
        code: impl Into<String>,
    ) -> ExecutionEvent {
        let run_id = run_id.into();
        let mut inner = self.inner.lock().expect("execution event log poisoned");
        let events = inner.events_by_run.entry(run_id.clone()).or_default();
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
        let inner = self.inner.lock().expect("execution event log poisoned");
        let from_sequence = from_sequence.unwrap_or(0);
        inner
            .events_by_run
            .get(run_id)
            .cloned()
            .unwrap_or_default()
            .into_iter()
            .filter(|event| event.sequence > from_sequence)
            .collect()
    }
}

impl ExecutionEvent {
    pub fn run_id(&self) -> &str {
        &self.run_id
    }

    pub fn sequence(&self) -> u64 {
        self.sequence
    }

    pub fn code(&self) -> &str {
        &self.code
    }
}
```

- [ ] **Step 5: Implement `RunLifecycleService`**

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

- [ ] **Step 6: Run contract tests**

Run:

```bash
cd local-ios-agent/rust-core
cargo test --test contract observe_events -- --nocapture
```

Expected: PASS for both event replay tests.

- [ ] **Step 7: Commit**

```bash
git add local-ios-agent/rust-core/src/execution/mod.rs \
  local-ios-agent/rust-core/src/execution/event_log.rs \
  local-ios-agent/rust-core/src/execution/run_lifecycle.rs \
  local-ios-agent/rust-core/tests/contract/conversation_execution_boundary.rs
git commit -m "feat: add replayable execution event log"
```

---

### Task 5: Add Idempotent Final Assistant Commit Contract

**Files:**
- Create: `local-ios-agent/rust-core/src/execution/final_commit.rs`
- Modify: `local-ios-agent/rust-core/src/execution/mod.rs`
- Modify: `local-ios-agent/rust-core/tests/contract/conversation_execution_boundary.rs`

**Interfaces:**
- Consumes: `ConversationRunFrameRef`
- Produces: `FinalAssistantCommitService::record_run_completed(run_id, final_message_id, final_output_ref, frame_ref)`
- Produces: `FinalAssistantCommitService::commit_assistant_result(run_id, final_message_id) -> AssistantCommitRecord`
- Produces: `FinalAssistantCommitService::completed_uncommitted_for_frame(&ConversationRunFrameRef) -> Vec<CompletedRunRecord>`

- [ ] **Step 1: Write failing idempotency and recovery tests**

Append to `local-ios-agent/rust-core/tests/contract/conversation_execution_boundary.rs`:

```rust
use local_ios_agent_runtime::execution::FinalAssistantCommitService;

#[test]
fn final_assistant_commit_is_idempotent_by_run_and_final_message() {
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
fn completed_uncommitted_run_can_be_discovered_for_recovery() {
    let service = FinalAssistantCommitService::default();
    let frame_ref = ConversationRunFrameRef::new(
        ConversationFrameId::new("frame_recover_1"),
        SessionId("session_1".into()),
        EntryId("branch_head_1".into()),
        EntryId("user_turn_1".into()),
    );
    service.record_run_completed("run_2", "final_2", "output_ref_2", frame_ref.clone());

    let pending = service.completed_uncommitted_for_frame(&frame_ref);

    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].run_id(), "run_2");
    assert_eq!(pending[0].final_message_id(), "final_2");
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
cd local-ios-agent/rust-core
cargo test --test contract final_assistant_commit -- --nocapture
```

Expected: FAIL because `FinalAssistantCommitService` does not exist.

- [ ] **Step 3: Export final commit service**

Modify `local-ios-agent/rust-core/src/execution/mod.rs`:

```rust
mod final_commit;

pub use final_commit::{
    AssistantCommitRecord, CompletedRunRecord, FinalAssistantCommitError,
    FinalAssistantCommitService,
};
```

- [ ] **Step 4: Implement final commit service**

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
pub struct CompletedRunRecord {
    run_id: String,
    final_message_id: String,
    final_output_ref: String,
    conversation_frame_ref: ConversationRunFrameRef,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AssistantCommitRecord {
    idempotency_key: String,
    assistant_message_id: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FinalAssistantCommitError {
    code: String,
    message: String,
}

#[derive(Debug, Default)]
struct FinalAssistantCommitState {
    completed_runs: BTreeMap<String, CompletedRunRecord>,
    commits_by_key: BTreeMap<String, AssistantCommitRecord>,
}

impl FinalAssistantCommitService {
    pub fn record_run_completed(
        &self,
        run_id: impl Into<String>,
        final_message_id: impl Into<String>,
        final_output_ref: impl Into<String>,
        conversation_frame_ref: ConversationRunFrameRef,
    ) {
        let record = CompletedRunRecord {
            run_id: run_id.into(),
            final_message_id: final_message_id.into(),
            final_output_ref: final_output_ref.into(),
            conversation_frame_ref,
        };
        let key = completed_run_key(&record.run_id, &record.final_message_id);
        self.inner
            .lock()
            .expect("final assistant commit state poisoned")
            .completed_runs
            .insert(key, record);
    }

    pub fn commit_assistant_result(
        &self,
        run_id: &str,
        final_message_id: &str,
    ) -> Result<AssistantCommitRecord, FinalAssistantCommitError> {
        let idempotency_key = completed_run_key(run_id, final_message_id);
        let mut inner = self
            .inner
            .lock()
            .expect("final assistant commit state poisoned");
        if let Some(existing) = inner.commits_by_key.get(&idempotency_key) {
            return Ok(existing.clone());
        }
        if !inner.completed_runs.contains_key(&idempotency_key) {
            return Err(FinalAssistantCommitError::new(
                "final_commit.completed_run_missing",
                format!("completed run not found for {idempotency_key}"),
            ));
        }
        let record = AssistantCommitRecord {
            idempotency_key: idempotency_key.clone(),
            assistant_message_id: format!("assistant.{run_id}.{final_message_id}"),
        };
        inner
            .commits_by_key
            .insert(idempotency_key, record.clone());
        Ok(record)
    }

    pub fn completed_uncommitted_for_frame(
        &self,
        frame_ref: &ConversationRunFrameRef,
    ) -> Vec<CompletedRunRecord> {
        let inner = self
            .inner
            .lock()
            .expect("final assistant commit state poisoned");
        inner
            .completed_runs
            .values()
            .filter(|record| &record.conversation_frame_ref == frame_ref)
            .filter(|record| {
                !inner
                    .commits_by_key
                    .contains_key(&completed_run_key(&record.run_id, &record.final_message_id))
            })
            .cloned()
            .collect()
    }

    pub fn commit_count(&self) -> usize {
        self.inner
            .lock()
            .expect("final assistant commit state poisoned")
            .commits_by_key
            .len()
    }
}

impl CompletedRunRecord {
    pub fn run_id(&self) -> &str {
        &self.run_id
    }

    pub fn final_message_id(&self) -> &str {
        &self.final_message_id
    }

    pub fn final_output_ref(&self) -> &str {
        &self.final_output_ref
    }

    pub fn conversation_frame_ref(&self) -> &ConversationRunFrameRef {
        &self.conversation_frame_ref
    }
}

impl AssistantCommitRecord {
    pub fn idempotency_key(&self) -> &str {
        &self.idempotency_key
    }

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

fn completed_run_key(run_id: &str, final_message_id: &str) -> String {
    format!("{run_id}:{final_message_id}")
}
```

- [ ] **Step 5: Run final commit tests**

Run:

```bash
cd local-ios-agent/rust-core
cargo test --test contract final_assistant_commit -- --nocapture
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add local-ios-agent/rust-core/src/execution/mod.rs \
  local-ios-agent/rust-core/src/execution/final_commit.rs \
  local-ios-agent/rust-core/tests/contract/conversation_execution_boundary.rs
git commit -m "feat: add idempotent final assistant commit service"
```

---

### Task 6: Keep ExecutionService Thin With Focused Internal Services

**Files:**
- Create: `local-ios-agent/rust-core/src/execution/execution_service.rs`
- Create: `local-ios-agent/rust-core/src/execution/tool_loop.rs`
- Create: `local-ios-agent/rust-core/src/execution/debug_store.rs`
- Create: `local-ios-agent/rust-core/src/execution/inference_settings.rs`
- Modify: `local-ios-agent/rust-core/src/execution/mod.rs`
- Modify: `local-ios-agent/rust-core/tests/contract/conversation_execution_boundary.rs`
- Modify: `local-ios-agent/rust-core/tests/lint/architecture_agent_os.rs`

**Interfaces:**
- Consumes: `RunLifecycleService`, `ExecutionEventLog`, `FinalAssistantCommitService`
- Produces: `ExecutionService::new(parts: ExecutionServiceParts) -> Self`
- Produces: `ExecutionService::start_run(run_id: impl Into<String>) -> RunHandle`
- Produces: `ExecutionService::observe_events(run_id: &str, from_sequence: Option<u64>) -> Vec<ExecutionEvent>`
- Produces: small service shells `ToolLoopService`, `RunDebugStore`, `InferenceSettingsService`

- [ ] **Step 1: Write thin facade contract test**

Append to `local-ios-agent/rust-core/tests/contract/conversation_execution_boundary.rs`:

```rust
use local_ios_agent_runtime::execution::{
    ExecutionService, ExecutionServiceParts, InferenceSettingsService, RunDebugStore,
    ToolLoopService,
};

#[test]
fn execution_service_is_facade_over_focused_services() {
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
    assert_eq!(service.debug_store().archive_count(), 0);
    assert_eq!(service.inference_settings().active_provider_id(), None);
}
```

- [ ] **Step 2: Run test to verify failure**

Run:

```bash
cd local-ios-agent/rust-core
cargo test --test contract execution_service_is_facade_over_focused_services -- --exact
```

Expected: FAIL because `ExecutionService` and its service parts do not exist.

- [ ] **Step 3: Export service modules**

Modify `local-ios-agent/rust-core/src/execution/mod.rs`:

```rust
mod debug_store;
mod execution_service;
mod inference_settings;
mod tool_loop;

pub use debug_store::RunDebugStore;
pub use execution_service::{ExecutionService, ExecutionServiceParts};
pub use inference_settings::InferenceSettingsService;
pub use tool_loop::ToolLoopService;
```

- [ ] **Step 4: Implement small service shells**

Create `local-ios-agent/rust-core/src/execution/tool_loop.rs`:

```rust
#[derive(Clone, Debug, Default)]
pub struct ToolLoopService {
    pending_count: usize,
}

impl ToolLoopService {
    pub fn pending_count(&self) -> usize {
        self.pending_count
    }
}
```

Create `local-ios-agent/rust-core/src/execution/debug_store.rs`:

```rust
#[derive(Clone, Debug, Default)]
pub struct RunDebugStore {
    archive_count: usize,
}

impl RunDebugStore {
    pub fn archive_count(&self) -> usize {
        self.archive_count
    }
}
```

Create `local-ios-agent/rust-core/src/execution/inference_settings.rs`:

```rust
#[derive(Clone, Debug, Default)]
pub struct InferenceSettingsService {
    active_provider_id: Option<String>,
}

impl InferenceSettingsService {
    pub fn active_provider_id(&self) -> Option<&str> {
        self.active_provider_id.as_deref()
    }
}
```

- [ ] **Step 5: Implement thin `ExecutionService` facade**

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

    pub fn final_commits(&self) -> &FinalAssistantCommitService {
        &self.parts.final_commits
    }

    pub fn tool_loop(&self) -> &ToolLoopService {
        &self.parts.tool_loop
    }

    pub fn debug_store(&self) -> &RunDebugStore {
        &self.parts.debug_store
    }

    pub fn inference_settings(&self) -> &InferenceSettingsService {
        &self.parts.inference_settings
    }
}
```

- [ ] **Step 6: Add lint guarding against a new large object**

In `local-ios-agent/rust-core/tests/lint/architecture_agent_os.rs`, add:

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

    assert!(
        source.contains("RunLifecycleService")
            && source.contains("ExecutionEventLog")
            && source.contains("FinalAssistantCommitService")
            && source.contains("ToolLoopService")
            && source.contains("RunDebugStore")
            && source.contains("InferenceSettingsService"),
        "ExecutionService should compose focused services instead of becoming the new runtime object"
    );
}
```

- [ ] **Step 7: Run contract and lint tests**

Run:

```bash
cd local-ios-agent/rust-core
cargo test --test contract execution_service_is_facade_over_focused_services -- --exact
cargo test --test lint execution_service_stays_thin_facade -- --exact
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add local-ios-agent/rust-core/src/execution/mod.rs \
  local-ios-agent/rust-core/src/execution/execution_service.rs \
  local-ios-agent/rust-core/src/execution/tool_loop.rs \
  local-ios-agent/rust-core/src/execution/debug_store.rs \
  local-ios-agent/rust-core/src/execution/inference_settings.rs \
  local-ios-agent/rust-core/tests/contract/conversation_execution_boundary.rs \
  local-ios-agent/rust-core/tests/lint/architecture_agent_os.rs
git commit -m "feat: keep execution service as focused facade"
```

---

### Task 7: Add ConversationFrameProjector And Mark Legacy Streaming Compatibility

**Files:**
- Create: `local-ios-agent/rust-core/src/conversation/projection.rs`
- Modify: `local-ios-agent/rust-core/src/conversation/mod.rs`
- Modify: `local-ios-agent/rust-core/src/core/runtime.rs`
- Modify: `local-ios-agent/rust-core/tests/contract/conversation_execution_boundary.rs`
- Modify: `local-ios-agent/rust-core/tests/lint/architecture_agent_os.rs`

**Interfaces:**
- Consumes: `Vec<RuntimeEvent>`
- Produces: `ConversationFrameProjector::project(branch: Vec<RuntimeEvent>) -> Vec<ConversationFrameMessage>`
- Produces: legacy marker comment constant in `core/runtime.rs`

- [ ] **Step 1: Write projector and legacy classification tests**

Append to `local-ios-agent/rust-core/tests/contract/conversation_execution_boundary.rs`:

```rust
use local_ios_agent_runtime::conversation::ConversationFrameProjector;
use local_ios_agent_runtime::core::{EventKind, RuntimeEvent};

#[test]
fn conversation_frame_projector_outputs_visible_messages_not_prompt_messages() {
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

    assert_eq!(messages.len(), 2);
    assert_eq!(messages[0].role(), "user");
    assert_eq!(messages[0].content(), "hello");
    assert_eq!(messages[1].role(), "assistant");
    assert_eq!(messages[1].content(), "hi");
}
```

In `local-ios-agent/rust-core/tests/lint/architecture_agent_os.rs`, add:

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

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
cd local-ios-agent/rust-core
cargo test --test contract conversation_frame_projector_outputs_visible_messages_not_prompt_messages -- --exact
cargo test --test lint legacy_streaming_path_is_marked_as_compatibility -- --exact
```

Expected: FAIL because `ConversationFrameProjector` and legacy marker do not exist.

- [ ] **Step 3: Implement `ConversationFrameProjector`**

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

Do not add a `PromptMessage` adapter in `conversation/`. If the legacy context path needs an adapter later, it should live in `context/`, because model-input roles belong to execution/context.

- [ ] **Step 4: Mark legacy runtime path**

Add this near `ROOT_PARENT_EVENT_ID` in `local-ios-agent/rust-core/src/core/runtime.rs`:

```rust
const LEGACY_COMPATIBILITY_STREAMING_PATH: &str =
    "AgentRuntime.send_message_streaming bypasses ConversationRunFrameRef and ExecutionPlan during migration";
```

Reference it inside `send_message_streaming` so the constant is not dead code:

```rust
let _legacy_path_marker = LEGACY_COMPATIBILITY_STREAMING_PATH;
```

- [ ] **Step 5: Run tests**

Run:

```bash
cd local-ios-agent/rust-core
cargo test --test contract conversation_frame_projector_outputs_visible_messages_not_prompt_messages -- --exact
cargo test --test lint legacy_streaming_path_is_marked_as_compatibility -- --exact
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add local-ios-agent/rust-core/src/conversation/mod.rs \
  local-ios-agent/rust-core/src/conversation/projection.rs \
  local-ios-agent/rust-core/src/core/runtime.rs \
  local-ios-agent/rust-core/tests/contract/conversation_execution_boundary.rs \
  local-ios-agent/rust-core/tests/lint/architecture_agent_os.rs
git commit -m "feat: add conversation frame projector contract"
```

---

### Task 8: Full Contract Test Sweep

**Files:**
- Modify: no source files unless failures from earlier tasks require small fixes.

**Interfaces:**
- Consumes: all interfaces from Tasks 1-7.
- Produces: verified Rust boundary contract.

- [ ] **Step 1: Run focused Rust contract suites**

Run:

```bash
cd local-ios-agent/rust-core
cargo test --test contract conversation_execution_boundary -- --nocapture
cargo test --test contract run_snapshot_resolution_agent_os -- --nocapture
cargo test --test contract runtime_execution_agent_os -- --nocapture
cargo test --test lint architecture_agent_os -- --nocapture
```

Expected: PASS.

- [ ] **Step 2: Run Rust integration/golden tests touched by snapshot changes**

Run:

```bash
cd local-ios-agent/rust-core
cargo test --test integration runtime_execution_lifecycle -- --nocapture
cargo test --test integration agent_lifecycle_profile_to_runtime -- --nocapture
cargo test --test integration ffi_bridge -- --nocapture
cargo test --test golden runtime_execution_trace -- --nocapture
cargo test --test golden lifecycle_debug_artifacts -- --nocapture
```

Expected: PASS.

- [ ] **Step 3: Run Swift bridge DTO tests**

Run:

```bash
cd local-ios-agent/toolkit
swift test --filter LocalAgentBridgeTests.AgentOSDTOTests
```

Expected: PASS.

- [ ] **Step 4: Run broad Rust test command**

Run:

```bash
cd local-ios-agent/rust-core
cargo test
```

Expected: PASS.

- [ ] **Step 5: Commit final fixups if needed**

If Step 1-4 required fixes, commit only those fixes:

```bash
git add local-ios-agent/rust-core local-ios-agent/toolkit
git commit -m "test: verify rust conversation execution boundary"
```

If no fixes were needed, do not create an empty commit.

---

## Self-Review Notes

Spec coverage:

- Frame ref-only trust source: Tasks 1-3.
- Snapshot pinning: Task 2.
- Durable event replay: Task 4.
- Final assistant commit idempotency and recovery: Task 5.
- ExecutionService not becoming a new large object: Task 6.
- ConversationFrameProjector replacing conversation-facing BranchProjector role: Task 7.
- Legacy streaming compatibility classification: Task 7.
- Full verification: Task 8.

Placeholder scan:

- No red-flag placeholder wording remains in the task steps.

Type consistency:

- `ConversationRunFrameRef` is produced in Task 1 and consumed by Tasks 2, 3, and 5.
- `RunHandle.replay_from_sequence()` is produced by Task 4 and mirrored by Swift `RunHandleDTO.replayFromSequence` in Task 3.
- `ExecutionService` in Task 6 composes focused services from Tasks 4 and 5.
