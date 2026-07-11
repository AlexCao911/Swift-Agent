# Plan 3: Core Agent Loop + Run State Machine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the core multi-step agent loop skeleton with run state, cancellation, replay, and multi-session cursors.

**Architecture:** This plan makes `core` own the run lifecycle before tool routing exists. The runtime should be able to stop at a tool call, wait for external tool work, resume with a `ToolResult`, call the provider again, and complete. Tool registry, tool validation, and Swift execution are deliberately left to Plan 4.

**Tech Stack:** Rust 2021, existing `EventStore`, `InMemoryEventStore`, `SqliteEventStore`, `MockStreamingProvider`, `cargo test`, TDD.

---

## Current Code Audit

Checked current code with:

```bash
rg -n "RunState|running|suspended|waiting_tool|cancel|replay|resume|completed|failed" local-ios-agent/rust-core/src local-ios-agent/rust-core/tests
sed -n '1,260p' local-ios-agent/rust-core/src/core/runtime.rs
sed -n '1,260p' local-ios-agent/rust-core/src/core/provider.rs
sed -n '1,260p' local-ios-agent/rust-core/src/memory/event_store.rs
```

Observed:

- `AgentRuntime::send_message` is a one-turn mock path.
- Runtime sessions are `HashMap<SessionId, SessionTree>` and are not replayed
  from SQLite.
- There is no `RunState`, `RunRecord`, cancellation API, or resume API.
- `ModelProviderOutput` has only `TextDelta` and `Completed`.
- `EventStore` has `append`, `get`, and `active_branch`, but no replay queries.
- `ToolCall`, `ToolResult`, and approval DTOs already exist and can be used as
  boundary DTOs for the loop contract.

Assigned to this plan:

- Run state machine.
- Multi-session runtime cursor.
- Store replay queries.
- `send_message_turn` result shape.
- Provider tool-call output slot.
- `submit_tool_result` continuation skeleton.
- `cancel(run_id)` event path.

Deferred:

- Tool registry and JSON validation: Plan 4.
- Security policy and approval queue: Plan 7.
- Context compaction and memory prompt: Plan 5.

## MVP Architecture Constraints

- Replay restores the active leaf for each session and only recovers the active
  branch's pending tool run. MVP assumes at most one active pending run per
  session, matching the iOS chat UI's single visible branch cursor.
- Non-active branches may still exist in the session tree, but their suspended
  tool calls are treated as dormant history until a later branch-activation
  design adds a persisted pending-run index.
- A future multi-branch agent runtime should add a durable `runs` or
  `pending_tool_calls` table keyed by `run_id`, `session_id`, and branch leaf so
  replay does not depend on the session's active leaf.

## File Structure

Create:

```text
local-ios-agent/rust-core/src/core/run_state.rs
local-ios-agent/rust-core/src/core/session_cursor.rs
local-ios-agent/rust-core/src/core/turn.rs
local-ios-agent/rust-core/tests/run_state.rs
local-ios-agent/rust-core/tests/agent_loop.rs
local-ios-agent/rust-core/tests/runtime_replay.rs
```

Modify:

```text
local-ios-agent/rust-core/src/core/mod.rs
local-ios-agent/rust-core/src/core/provider.rs
local-ios-agent/rust-core/src/core/runtime.rs
local-ios-agent/rust-core/src/memory/event_store.rs
local-ios-agent/rust-core/src/memory/in_memory.rs
local-ios-agent/rust-core/src/memory/sqlite.rs
local-ios-agent/rust-core/tests/runtime_mock.rs
local-ios-agent/rust-core/tests/sqlite_store.rs
```

## Task 1: Add Run State Types

**Files:**
- Create: `local-ios-agent/rust-core/src/core/run_state.rs`
- Modify: `local-ios-agent/rust-core/src/core/mod.rs`
- Test: `local-ios-agent/rust-core/tests/run_state.rs`

- [ ] **Step 1: Write failing test**

Create `tests/run_state.rs`:

```rust
use local_ios_agent_runtime::core::{AgentError, RunId, RunRecord, RunState, SessionId};

#[test]
fn run_record_moves_through_waiting_and_completed() {
    let mut run = RunRecord::new(RunId("run_1".into()), SessionId("session_1".into()));

    run.mark_waiting_tool().unwrap();
    assert_eq!(run.state, RunState::WaitingTool);

    run.mark_running().unwrap();
    run.mark_completed().unwrap();
    assert_eq!(run.state, RunState::Completed);
}

#[test]
fn terminal_run_rejects_later_cancellation() {
    let mut run = RunRecord::new(RunId("run_1".into()), SessionId("session_1".into()));
    run.mark_completed().unwrap();

    let error = run.cancel().unwrap_err();

    assert!(matches!(error, AgentError::Cancelled(_)));
}
```

- [ ] **Step 2: Run failing test**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo test --test run_state
```

Expected: unresolved import for `RunRecord`.

- [ ] **Step 3: Implement run state**

Create `src/core/run_state.rs` with:

```rust
use crate::core::{AgentError, RunId, SessionId};

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum RunState {
    Running,
    WaitingTool,
    Suspended,
    Failed,
    Cancelled,
    Completed,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RunRecord {
    pub run_id: RunId,
    pub session_id: SessionId,
    pub state: RunState,
}

impl RunRecord {
    pub fn new(run_id: RunId, session_id: SessionId) -> Self {
        Self { run_id, session_id, state: RunState::Running }
    }

    pub fn mark_running(&mut self) -> Result<(), AgentError> {
        self.ensure_not_terminal()?;
        self.state = RunState::Running;
        Ok(())
    }

    pub fn mark_waiting_tool(&mut self) -> Result<(), AgentError> {
        self.ensure_not_terminal()?;
        self.state = RunState::WaitingTool;
        Ok(())
    }

    pub fn mark_suspended(&mut self) -> Result<(), AgentError> {
        self.ensure_not_terminal()?;
        self.state = RunState::Suspended;
        Ok(())
    }

    pub fn mark_failed(&mut self) -> Result<(), AgentError> {
        self.ensure_not_terminal()?;
        self.state = RunState::Failed;
        Ok(())
    }

    pub fn mark_completed(&mut self) -> Result<(), AgentError> {
        self.ensure_not_terminal()?;
        self.state = RunState::Completed;
        Ok(())
    }

    pub fn cancel(&mut self) -> Result<(), AgentError> {
        self.ensure_not_terminal()?;
        self.state = RunState::Cancelled;
        Ok(())
    }

    fn ensure_not_terminal(&self) -> Result<(), AgentError> {
        match self.state {
            RunState::Failed | RunState::Cancelled | RunState::Completed => {
                Err(AgentError::Cancelled(format!("run already terminal: {:?}", self.state)))
            }
            RunState::Running | RunState::WaitingTool | RunState::Suspended => Ok(()),
        }
    }
}
```

- [ ] **Step 4: Export and verify**

Modify `src/core/mod.rs`:

```rust
pub mod run_state;
pub use run_state::{RunRecord, RunState};
```

Run:

```bash
cargo fmt
cargo test --test run_state
cargo test
```

- [ ] **Step 5: Commit**

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/rust-core/src/core/run_state.rs local-ios-agent/rust-core/src/core/mod.rs local-ios-agent/rust-core/tests/run_state.rs
git commit -m "feat: add core run state"
```

## Task 2: Add Runtime Session Cursor and Replay Queries

**Files:**
- Create: `local-ios-agent/rust-core/src/core/session_cursor.rs`
- Modify: `local-ios-agent/rust-core/src/core/mod.rs`
- Modify: `local-ios-agent/rust-core/src/memory/event_store.rs`
- Modify: `local-ios-agent/rust-core/src/memory/in_memory.rs`
- Modify: `local-ios-agent/rust-core/src/memory/sqlite.rs`
- Test: `local-ios-agent/rust-core/tests/runtime_replay.rs`
- Test: `local-ios-agent/rust-core/tests/sqlite_store.rs`

- [ ] **Step 1: Write failing replay tests**

Create `tests/runtime_replay.rs`:

```rust
use local_ios_agent_runtime::core::{EntryId, EventKind, RuntimeEvent, SessionCursor, SessionId};

#[test]
fn cursor_replays_active_leaf_and_sequence() {
    let event = RuntimeEvent::new(
        EntryId("entry_3".into()),
        SessionId("session_1".into()),
        None,
        None,
        3,
        0,
        EventKind::UserMessage,
        "hello",
    );

    let cursor = SessionCursor::from_last_event(SessionId("session_1".into()), Some(event));

    assert_eq!(cursor.active_leaf, Some(EntryId("entry_3".into())));
    assert_eq!(cursor.next_sequence, 4);
}
```

Append to `tests/sqlite_store.rs`:

```rust
#[test]
fn sqlite_store_exposes_replay_queries() {
    let tempdir = tempfile::tempdir().unwrap();
    let db_path = tempdir.path().join("agent.sqlite");
    let mut store = SqliteEventStore::open(&db_path).unwrap();

    store.append(sqlite_event("root", None, 1, 0, "root")).unwrap();
    store.append(sqlite_event("leaf", Some("root"), 2, 1, "leaf")).unwrap();

    assert_eq!(store.list_sessions().unwrap(), vec![SessionId("session_sqlite".into())]);
    assert_eq!(store.active_leaf(&SessionId("session_sqlite".into())).unwrap(), Some(EntryId("leaf".into())));
    assert_eq!(store.last_event(&SessionId("session_sqlite".into())).unwrap().unwrap().payload, "leaf");
}
```

- [ ] **Step 2: Implement cursor**

Create `src/core/session_cursor.rs`:

```rust
use crate::core::{EntryId, RuntimeEvent, SessionId};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SessionCursor {
    pub session_id: SessionId,
    pub active_leaf: Option<EntryId>,
    pub next_sequence: u64,
}

impl SessionCursor {
    pub fn new(session_id: SessionId) -> Self {
        Self { session_id, active_leaf: None, next_sequence: 1 }
    }

    pub fn from_last_event(session_id: SessionId, last_event: Option<RuntimeEvent>) -> Self {
        match last_event {
            Some(event) => Self {
                session_id,
                active_leaf: Some(event.id),
                next_sequence: event.sequence + 1,
            },
            None => Self::new(session_id),
        }
    }
}
```

- [ ] **Step 3: Extend EventStore**

Add to `src/memory/event_store.rs`:

```rust
fn list_sessions(&self) -> Result<Vec<SessionId>, AgentError>;
fn active_leaf(&self, session_id: &SessionId) -> Result<Option<EntryId>, AgentError>;
fn last_event(&self, session_id: &SessionId) -> Result<Option<RuntimeEvent>, AgentError>;
```

Implement these for both `InMemoryEventStore` and `SqliteEventStore`.

- [ ] **Step 4: Export and verify**

Modify `src/core/mod.rs`:

```rust
pub mod session_cursor;
pub use session_cursor::SessionCursor;
```

Run:

```bash
cargo fmt
cargo test --test runtime_replay
cargo test --test sqlite_store sqlite_store_exposes_replay_queries
cargo test
```

- [ ] **Step 5: Commit**

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/rust-core/src/core/session_cursor.rs local-ios-agent/rust-core/src/core/mod.rs local-ios-agent/rust-core/src/memory/event_store.rs local-ios-agent/rust-core/src/memory/in_memory.rs local-ios-agent/rust-core/src/memory/sqlite.rs local-ios-agent/rust-core/tests/runtime_replay.rs local-ios-agent/rust-core/tests/sqlite_store.rs
git commit -m "feat: add runtime replay cursors"
```

## Task 3: Add Turn Result and Provider Tool-Call Slot

**Files:**
- Create: `local-ios-agent/rust-core/src/core/turn.rs`
- Modify: `local-ios-agent/rust-core/src/core/mod.rs`
- Modify: `local-ios-agent/rust-core/src/core/provider.rs`
- Test: `local-ios-agent/rust-core/tests/agent_loop.rs`
- Test: `local-ios-agent/rust-core/tests/mock_provider.rs`

- [ ] **Step 1: Write failing tests**

Create `tests/agent_loop.rs`:

```rust
use local_ios_agent_runtime::core::{AgentTurnResult, RunState};

#[test]
fn turn_result_reports_waiting_tool_state() {
    let result = AgentTurnResult {
        run_id: "run_1".into(),
        state: RunState::WaitingTool,
        events: Vec::new(),
        pending_tool_call_id: Some("call_1".into()),
    };

    assert_eq!(result.pending_tool_call_id, Some("call_1".into()));
}
```

Append to `tests/mock_provider.rs`:

```rust
use local_ios_agent_runtime::tool::ToolCall;

#[test]
fn mock_provider_can_emit_tool_call() {
    let provider = MockStreamingProvider::new();
    let frame = PromptFrame {
        system_prompt: "system".into(),
        runtime_policy: "policy".into(),
        tool_schemas: vec!["debug.echo".into()],
        messages: vec![PromptMessage::User("use tool debug.echo".into())],
    };

    assert!(matches!(
        provider.stream_chat(&frame).unwrap().first(),
        Some(ModelProviderOutput::ToolCall(ToolCall { name, .. })) if name == "debug.echo"
    ));
}
```

- [ ] **Step 2: Implement turn result**

Create `src/core/turn.rs`:

```rust
use crate::core::{RunState, RuntimeEvent};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgentTurnResult {
    pub run_id: String,
    pub state: RunState,
    pub events: Vec<RuntimeEvent>,
    pub pending_tool_call_id: Option<String>,
}
```

- [ ] **Step 3: Extend provider output**

Modify `src/core/provider.rs`:

```rust
use crate::tool::ToolCall;

pub enum ModelProviderOutput {
    TextDelta(String),
    ToolCall(ToolCall),
    Completed(String),
}
```

Update `MockStreamingProvider` so the exact last user message
`"use tool debug.echo"` returns:

```rust
ModelProviderOutput::ToolCall(ToolCall {
    id: "call_mock_1".to_string(),
    name: "debug.echo".to_string(),
    arguments_json: r#"{"text":"hello"}"#.to_string(),
})
```

- [ ] **Step 4: Export and verify**

Modify `src/core/mod.rs`:

```rust
pub mod turn;
pub use turn::AgentTurnResult;
```

Run:

```bash
cargo fmt
cargo test --test agent_loop
cargo test --test mock_provider
cargo test
```

- [ ] **Step 5: Commit**

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/rust-core/src/core/turn.rs local-ios-agent/rust-core/src/core/mod.rs local-ios-agent/rust-core/src/core/provider.rs local-ios-agent/rust-core/tests/agent_loop.rs local-ios-agent/rust-core/tests/mock_provider.rs
git commit -m "feat: add agent turn result"
```

## Task 4: Refactor Runtime Around Store and Cursors

**Files:**
- Modify: `local-ios-agent/rust-core/src/core/runtime.rs`
- Modify: `local-ios-agent/rust-core/tests/runtime_mock.rs`
- Modify: `local-ios-agent/rust-core/tests/runtime_replay.rs`

- [ ] **Step 1: Write failing runtime replay test**

Append to `tests/runtime_replay.rs`:

```rust
use local_ios_agent_runtime::context::MockTokenizer;
use local_ios_agent_runtime::core::{AgentRuntime, AgentRuntimeConfig, MockStreamingProvider, SendMessageInput};
use local_ios_agent_runtime::memory::SqliteEventStore;

fn config() -> AgentRuntimeConfig {
    AgentRuntimeConfig {
        system_prompt: "system".into(),
        runtime_policy: "policy".into(),
        tool_schemas: Vec::new(),
        tokenizer: Box::new(MockTokenizer::new(100)),
        provider: Box::new(MockStreamingProvider::new()),
    }
}

#[test]
fn runtime_replays_sessions_from_sqlite() {
    let tempdir = tempfile::tempdir().unwrap();
    let db_path = tempdir.path().join("agent.sqlite");
    let session_id = {
        let store = SqliteEventStore::open(&db_path).unwrap();
        let mut runtime = AgentRuntime::with_store(config(), store).unwrap();
        let session_id = runtime.create_session().unwrap();
        runtime.send_message(SendMessageInput {
            session_id: session_id.clone(),
            parent_event_id: None,
            text: "hello".into(),
        }).unwrap();
        session_id
    };

    let store = SqliteEventStore::open(&db_path).unwrap();
    let runtime = AgentRuntime::with_store(config(), store).unwrap();

    assert!(runtime.session_ids().contains(&session_id));
}
```

- [ ] **Step 2: Refactor runtime storage**

Change runtime shape to:

```rust
pub struct AgentRuntime<S: EventStore = InMemoryEventStore> {
    config: AgentRuntimeConfig,
    ids: IdGenerator,
    store: S,
    sessions: HashMap<SessionId, SessionCursor>,
    runs: HashMap<RunId, RunRecord>,
}
```

Keep `AgentRuntime::new(config)` as the in-memory convenience constructor.

Add:

```rust
pub fn with_store(config: AgentRuntimeConfig, store: S) -> Result<Self, AgentError>
pub fn session_ids(&self) -> Vec<SessionId>
```

- [ ] **Step 3: Add append helper**

Inside `impl<S: EventStore> AgentRuntime<S>`, add one helper that calculates
depth, sequence, appends a `RuntimeEvent`, updates the cursor, and returns the
new event id:

```rust
fn append_event(
    &mut self,
    session_id: &SessionId,
    parent_id: Option<EntryId>,
    run_id: Option<RunId>,
    kind: EventKind,
    payload: impl Into<String>,
) -> Result<EntryId, AgentError>
```

- [ ] **Step 4: Verify and commit**

Run:

```bash
cargo fmt
cargo test --test runtime_replay runtime_replays_sessions_from_sqlite
cargo test
```

Commit:

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/rust-core/src/core/runtime.rs local-ios-agent/rust-core/tests/runtime_mock.rs local-ios-agent/rust-core/tests/runtime_replay.rs
git commit -m "feat: replay runtime sessions"
```

## Task 5: Implement Multi-Step Loop Skeleton

**Files:**
- Modify: `local-ios-agent/rust-core/src/core/runtime.rs`
- Modify: `local-ios-agent/rust-core/tests/agent_loop.rs`

- [ ] **Step 1: Write failing waiting-tool test**

Append to `tests/agent_loop.rs`:

```rust
use local_ios_agent_runtime::context::MockTokenizer;
use local_ios_agent_runtime::core::{AgentRuntime, AgentRuntimeConfig, EventKind, MockStreamingProvider, SendMessageInput};

#[test]
fn runtime_stops_at_tool_call_and_marks_waiting_tool() {
    let mut runtime = AgentRuntime::new(AgentRuntimeConfig {
        system_prompt: "system".into(),
        runtime_policy: "policy".into(),
        tool_schemas: vec!["debug.echo".into()],
        tokenizer: Box::new(MockTokenizer::new(100)),
        provider: Box::new(MockStreamingProvider::new()),
    });
    let session_id = runtime.create_session().unwrap();

    let result = runtime.send_message_turn(SendMessageInput {
        session_id,
        parent_event_id: None,
        text: "use tool debug.echo".into(),
    }).unwrap();

    assert_eq!(result.state, RunState::WaitingTool);
    assert!(result.events.iter().any(|event| event.kind == EventKind::ToolCallRequested));
}
```

- [ ] **Step 2: Implement `send_message_turn`**

Add:

```rust
pub fn send_message_turn(&mut self, input: SendMessageInput) -> Result<AgentTurnResult, AgentError>
```

It must:

1. Create `RunRecord`.
2. Append `UserMessage`.
3. Build `PromptFrame`.
4. Stream provider outputs.
5. Persist text deltas.
6. On `ToolCall`, append `ToolCallRequested`, mark run `WaitingTool`, and
   return.
7. On `Completed`, append `AssistantMessageCompleted`, mark run `Completed`,
   and return.
8. On provider error, append `RunFailed` and mark `Failed`.

Keep existing `send_message` as a wrapper returning `send_message_turn(...).events`
to avoid breaking earlier tests.

- [ ] **Step 3: Verify and commit**

Run:

```bash
cargo fmt
cargo test --test agent_loop runtime_stops_at_tool_call_and_marks_waiting_tool
cargo test
```

Commit:

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/rust-core/src/core/runtime.rs local-ios-agent/rust-core/tests/agent_loop.rs
git commit -m "feat: add multi step agent loop"
```

## Task 6: Resume Loop With Tool Result

**Files:**
- Modify: `local-ios-agent/rust-core/src/core/runtime.rs`
- Modify: `local-ios-agent/rust-core/tests/agent_loop.rs`

- [ ] **Step 1: Write failing resume test**

Append:

```rust
use local_ios_agent_runtime::tool::{RetentionPolicy, Sensitivity, ToolResult};

#[test]
fn runtime_resumes_from_tool_result_and_completes() {
    let mut runtime = AgentRuntime::new(AgentRuntimeConfig {
        system_prompt: "system".into(),
        runtime_policy: "policy".into(),
        tool_schemas: vec!["debug.echo".into()],
        tokenizer: Box::new(MockTokenizer::new(100)),
        provider: Box::new(MockStreamingProvider::new()),
    });
    let session_id = runtime.create_session().unwrap();
    let turn = runtime.send_message_turn(SendMessageInput {
        session_id: session_id.clone(),
        parent_event_id: None,
        text: "use tool debug.echo".into(),
    }).unwrap();

    let resumed = runtime.submit_tool_result(
        turn.run_id.clone(),
        ToolResult {
            display_text: "echoed".into(),
            model_text: "tool said hello".into(),
            structured_json: "{}".into(),
            audit_text: "audit".into(),
            sensitivity: Sensitivity::Public,
            retention: RetentionPolicy::RunOnly,
            is_error: false,
        },
    ).unwrap();

    assert_eq!(resumed.state, RunState::Completed);
    assert!(resumed.events.iter().any(|event| event.kind == EventKind::ToolResultMessage));
    assert!(resumed.events.iter().any(|event| event.kind == EventKind::AssistantMessageCompleted));
}
```

- [ ] **Step 2: Implement `submit_tool_result`**

Add:

```rust
pub fn submit_tool_result(
    &mut self,
    run_id: String,
    result: ToolResult,
) -> Result<AgentTurnResult, AgentError>
```

It must find the waiting run, append `ToolResultMessage`, build a follow-up
prompt from the active branch, call the provider again, and complete the run.

- [ ] **Step 3: Verify and commit**

Run:

```bash
cargo fmt
cargo test --test agent_loop runtime_resumes_from_tool_result_and_completes
cargo test
```

Commit:

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/rust-core/src/core/runtime.rs local-ios-agent/rust-core/tests/agent_loop.rs
git commit -m "feat: resume loop with tool result"
```

## Task 7: Add Cancellation

**Files:**
- Modify: `local-ios-agent/rust-core/src/core/runtime.rs`
- Modify: `local-ios-agent/rust-core/tests/agent_loop.rs`

- [ ] **Step 1: Write failing cancellation test**

Append:

```rust
#[test]
fn runtime_cancel_appends_run_cancelled() {
    let mut runtime = AgentRuntime::new(AgentRuntimeConfig {
        system_prompt: "system".into(),
        runtime_policy: "policy".into(),
        tool_schemas: vec!["debug.echo".into()],
        tokenizer: Box::new(MockTokenizer::new(100)),
        provider: Box::new(MockStreamingProvider::new()),
    });
    let session_id = runtime.create_session().unwrap();
    let turn = runtime.send_message_turn(SendMessageInput {
        session_id,
        parent_event_id: None,
        text: "use tool debug.echo".into(),
    }).unwrap();

    let event = runtime.cancel(turn.run_id).unwrap();

    assert_eq!(event.kind, EventKind::RunCancelled);
}
```

- [ ] **Step 2: Implement cancellation**

Add:

```rust
pub fn cancel(&mut self, run_id: String) -> Result<RuntimeEvent, AgentError>
```

It must transition the run to `Cancelled` and append `RunCancelled` under the
current active leaf.

- [ ] **Step 3: Verify and commit**

Run:

```bash
cargo fmt
cargo test --test agent_loop runtime_cancel_appends_run_cancelled
cargo test
```

Commit:

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/rust-core/src/core/runtime.rs local-ios-agent/rust-core/tests/agent_loop.rs
git commit -m "feat: add runtime cancellation"
```

## Exit Criteria

- Runtime can replay sessions from SQLite.
- Runtime can run a normal mock turn to completion.
- Runtime can stop at a tool call with `WaitingTool`.
- Runtime can resume from `ToolResult` and complete.
- Runtime can cancel waiting runs.
- `send_message` remains backward-compatible.
- `cargo test` passes.
