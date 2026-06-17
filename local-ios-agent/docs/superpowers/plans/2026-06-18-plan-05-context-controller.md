# Plan 5: Context Controller Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a real Rust context controller that projects active branches, layers prompts, injects tools and memory, applies retention rules, manages token budget, aligns with provider tokenizers, and persists summary/compaction events.

**Architecture:** `context` decides what the model sees. It does not execute tools, mutate iOS state, or own durable memory tables. It consumes branch events, tool schemas, memory snippets, and tokenizer contracts, then emits a provider-ready `PromptFrame` plus debug metadata.

**Tech Stack:** Rust 2021, existing `PromptFrame`, `TokenizerAdapter`, `RuntimeEvent`, `ToolResult`, `cargo test`, TDD.

---

## Current Code Audit

Checked current code with:

```bash
rg -n "ContextBudget|ContextCache|Compaction|Summary|summary|truncate|TokenizerAdapter|PromptFrame|ToolResultMessage" local-ios-agent/rust-core/src local-ios-agent/rust-core/tests
sed -n '1,260p' local-ios-agent/rust-core/src/context/prompt_frame.rs
sed -n '1,260p' local-ios-agent/rust-core/src/context/tokenizer.rs
```

Observed:

- `PromptFrame` has system prompt, runtime policy, tool schema strings, and
  messages.
- `ContextController` projects a few event kinds inline.
- `TokenizerAdapter` exists but has only mock behavior.
- No branch projector, prompt section model, memory prompt, retention filter,
  budget truncation, compaction event logic, provider prompt adapter, or debug
  snapshot exists.

Assigned to this plan:

- Active branch to prompt messages converter.
- System/policy/memory prompt layering.
- Tool schema injection strategy.
- Tool result retention and sensitivity rules.
- Context budget manager.
- Provider tokenizer alignment interface.
- Summary and compaction event creation.

Deferred:

- Durable long-term memory storage: Plan 6.
- Security policy decisions: Plan 7.
- Desktop MiniCPM exact tokenizer: later provider plan.

## File Structure

Create:

```text
local-ios-agent/rust-core/src/context/branch_projector.rs
local-ios-agent/rust-core/src/context/prompt_layers.rs
local-ios-agent/rust-core/src/context/injection_policy.rs
local-ios-agent/rust-core/src/context/budget.rs
local-ios-agent/rust-core/src/context/debug_snapshot.rs
local-ios-agent/rust-core/src/context/compaction.rs
local-ios-agent/rust-core/tests/context_projection.rs
local-ios-agent/rust-core/tests/context_budget.rs
local-ios-agent/rust-core/tests/context_compaction.rs
```

Modify:

```text
local-ios-agent/rust-core/src/context/mod.rs
local-ios-agent/rust-core/src/context/prompt_frame.rs
local-ios-agent/rust-core/src/context/tokenizer.rs
local-ios-agent/rust-core/src/core/runtime.rs
```

## Task 1: Extract Active Branch Projector

**Files:**
- Create: `local-ios-agent/rust-core/src/context/branch_projector.rs`
- Modify: `local-ios-agent/rust-core/src/context/mod.rs`
- Modify: `local-ios-agent/rust-core/src/context/prompt_frame.rs`
- Test: `local-ios-agent/rust-core/tests/context_projection.rs`

- [ ] **Step 1: Write failing projector test**

Create `tests/context_projection.rs`:

```rust
use local_ios_agent_runtime::context::{BranchProjector, PromptMessage};
use local_ios_agent_runtime::core::{EntryId, EventKind, RuntimeEvent, SessionId};

fn event(id: &str, kind: EventKind, payload: &str) -> RuntimeEvent {
    RuntimeEvent::new(
        EntryId(id.into()),
        SessionId("session_1".into()),
        None,
        None,
        1,
        0,
        kind,
        payload,
    )
}

#[test]
fn projector_preserves_model_visible_branch_events() {
    let messages = BranchProjector::new().project(vec![
        event("summary", EventKind::BranchSummaryCreated, "summary so far"),
        event("user", EventKind::UserMessage, "hello"),
        event("tool", EventKind::ToolResultMessage, "tool result"),
        event("assistant", EventKind::AssistantMessageCompleted, "done"),
    ]);

    assert_eq!(
        messages,
        vec![
            PromptMessage::ToolResult("summary so far".into()),
            PromptMessage::User("hello".into()),
            PromptMessage::ToolResult("tool result".into()),
            PromptMessage::Assistant("done".into()),
        ]
    );
}
```

- [ ] **Step 2: Implement projector**

Create `src/context/branch_projector.rs`:

```rust
use crate::context::PromptMessage;
use crate::core::{EventKind, RuntimeEvent};

#[derive(Clone, Debug, Default)]
pub struct BranchProjector;

impl BranchProjector {
    pub fn new() -> Self { Self }

    pub fn project(&self, branch: Vec<RuntimeEvent>) -> Vec<PromptMessage> {
        branch.into_iter().filter_map(|event| match event.kind {
            EventKind::UserMessage => Some(PromptMessage::User(event.payload)),
            EventKind::AssistantMessageCompleted => Some(PromptMessage::Assistant(event.payload)),
            EventKind::ToolResultMessage => Some(PromptMessage::ToolResult(event.payload)),
            EventKind::BranchSummaryCreated => Some(PromptMessage::ToolResult(event.payload)),
            _ => None,
        }).collect()
    }
}
```

- [ ] **Step 3: Wire controller**

Update `ContextController::build_prompt_frame` to call `BranchProjector`.

- [ ] **Step 4: Verify and commit**

Run:

```bash
cargo fmt
cargo test --test context_projection
cargo test
```

Commit:

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/rust-core/src/context/branch_projector.rs local-ios-agent/rust-core/src/context/mod.rs local-ios-agent/rust-core/src/context/prompt_frame.rs local-ios-agent/rust-core/tests/context_projection.rs
git commit -m "feat: add branch projector"
```

## Task 2: Add Prompt Layers

**Files:**
- Create: `local-ios-agent/rust-core/src/context/prompt_layers.rs`
- Modify: `local-ios-agent/rust-core/src/context/mod.rs`
- Modify: `local-ios-agent/rust-core/src/context/prompt_frame.rs`
- Test: `local-ios-agent/rust-core/tests/context_projection.rs`

- [ ] **Step 1: Add prompt layer test**

Append:

```rust
use local_ios_agent_runtime::context::PromptLayers;

#[test]
fn prompt_layers_render_system_policy_and_memory() {
    let layers = PromptLayers {
        system: "system".into(),
        policy: "policy".into(),
        memory: vec!["memory one".into()],
    };

    assert!(layers.render_system_prompt().contains("system"));
    assert!(layers.render_system_prompt().contains("memory one"));
}
```

- [ ] **Step 2: Implement layers**

Create `src/context/prompt_layers.rs`:

```rust
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PromptLayers {
    pub system: String,
    pub policy: String,
    pub memory: Vec<String>,
}

impl PromptLayers {
    pub fn render_system_prompt(&self) -> String {
        let mut rendered = self.system.clone();
        if !self.memory.is_empty() {
            rendered.push_str("\n\nMemory:\n");
            rendered.push_str(&self.memory.join("\n"));
        }
        rendered
    }
}
```

- [ ] **Step 3: Use layers in ContextController**

Change `ContextController::new` to store `PromptLayers` internally while keeping
the public constructor arguments compatible.

- [ ] **Step 4: Verify and commit**

Run:

```bash
cargo fmt
cargo test --test context_projection
cargo test
```

Commit:

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/rust-core/src/context/prompt_layers.rs local-ios-agent/rust-core/src/context/mod.rs local-ios-agent/rust-core/src/context/prompt_frame.rs local-ios-agent/rust-core/tests/context_projection.rs
git commit -m "feat: add prompt layers"
```

## Task 3: Add Tool Schema Injection Strategy

**Files:**
- Modify: `local-ios-agent/rust-core/src/context/prompt_frame.rs`
- Test: `local-ios-agent/rust-core/tests/context_projection.rs`

- [ ] **Step 1: Add schema ordering test**

Append:

```rust
#[test]
fn context_sorts_tool_schemas_for_stable_prompt_frames() {
    let controller = local_ios_agent_runtime::context::ContextController::new(
        "system",
        "policy",
        vec!["z.tool".into(), "a.tool".into()],
        Box::new(local_ios_agent_runtime::context::MockTokenizer::new(100)),
    );

    let frame = controller.build_prompt_frame(Vec::new()).unwrap();

    assert_eq!(frame.tool_schemas, vec!["a.tool", "z.tool"]);
}
```

- [ ] **Step 2: Implement stable schema injection**

Sort and deduplicate `tool_schemas` inside `ContextController::new`.

- [ ] **Step 3: Verify and commit**

Run:

```bash
cargo fmt
cargo test --test context_projection context_sorts_tool_schemas_for_stable_prompt_frames
cargo test
```

Commit:

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/rust-core/src/context/prompt_frame.rs local-ios-agent/rust-core/tests/context_projection.rs
git commit -m "feat: stabilize tool schema injection"
```

## Task 4: Add Tool Result Retention Policy

**Files:**
- Create: `local-ios-agent/rust-core/src/context/injection_policy.rs`
- Modify: `local-ios-agent/rust-core/src/context/mod.rs`
- Test: `local-ios-agent/rust-core/tests/context_projection.rs`

- [ ] **Step 1: Add retention test**

Append:

```rust
use local_ios_agent_runtime::context::ContextInjectionPolicy;
use local_ios_agent_runtime::tool::{RetentionPolicy, Sensitivity, ToolResult};

#[test]
fn injection_policy_excludes_audit_only_and_secret_tool_results() {
    let policy = ContextInjectionPolicy::default();
    let result = ToolResult {
        display_text: "display".into(),
        model_text: "secret".into(),
        structured_json: "{}".into(),
        audit_text: "audit".into(),
        sensitivity: Sensitivity::Secret,
        retention: RetentionPolicy::AuditOnly,
        is_error: false,
    };

    assert!(!policy.should_inject_tool_result(&result));
}
```

- [ ] **Step 2: Implement policy**

Create `src/context/injection_policy.rs`:

```rust
use crate::tool::{RetentionPolicy, Sensitivity, ToolResult};

#[derive(Clone, Debug)]
pub struct ContextInjectionPolicy {
    pub include_secret_results: bool,
}

impl Default for ContextInjectionPolicy {
    fn default() -> Self {
        Self { include_secret_results: false }
    }
}

impl ContextInjectionPolicy {
    pub fn should_inject_tool_result(&self, result: &ToolResult) -> bool {
        result.retention != RetentionPolicy::AuditOnly
            && (result.sensitivity != Sensitivity::Secret || self.include_secret_results)
    }
}
```

- [ ] **Step 3: Verify and commit**

Run:

```bash
cargo fmt
cargo test --test context_projection injection_policy_excludes_audit_only_and_secret_tool_results
cargo test
```

Commit:

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/rust-core/src/context/injection_policy.rs local-ios-agent/rust-core/src/context/mod.rs local-ios-agent/rust-core/tests/context_projection.rs
git commit -m "feat: add tool result injection policy"
```

## Task 5: Add Context Budget and Tokenizer Alignment

**Files:**
- Create: `local-ios-agent/rust-core/src/context/budget.rs`
- Modify: `local-ios-agent/rust-core/src/context/mod.rs`
- Test: `local-ios-agent/rust-core/tests/context_budget.rs`

- [ ] **Step 1: Write budget test**

Create `tests/context_budget.rs`:

```rust
use local_ios_agent_runtime::context::{ContextBudget, PromptMessage};

#[test]
fn budget_drops_oldest_messages_at_message_boundaries() {
    let messages = vec![
        PromptMessage::User("one two three four".into()),
        PromptMessage::Assistant("five six seven eight".into()),
        PromptMessage::User("nine ten".into()),
    ];

    let kept = ContextBudget::new(4).fit_messages(messages);

    assert_eq!(kept, vec![PromptMessage::User("nine ten".into())]);
}
```

- [ ] **Step 2: Implement budget**

Create `src/context/budget.rs`:

```rust
use crate::context::PromptMessage;

pub struct ContextBudget {
    max_message_words: usize,
}

impl ContextBudget {
    pub fn new(max_message_words: usize) -> Self {
        Self { max_message_words }
    }

    pub fn fit_messages(&self, messages: Vec<PromptMessage>) -> Vec<PromptMessage> {
        let mut kept = Vec::new();
        let mut total = 0;
        for message in messages.into_iter().rev() {
            let count = message.content().split_whitespace().count();
            if total + count > self.max_message_words {
                break;
            }
            total += count;
            kept.push(message);
        }
        kept.reverse();
        kept
    }
}
```

- [ ] **Step 3: Verify and commit**

Run:

```bash
cargo fmt
cargo test --test context_budget
cargo test
```

Commit:

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/rust-core/src/context/budget.rs local-ios-agent/rust-core/src/context/mod.rs local-ios-agent/rust-core/tests/context_budget.rs
git commit -m "feat: add context budget"
```

## Task 6: Add Prompt Debug and Compaction Event Creator

**Files:**
- Create: `local-ios-agent/rust-core/src/context/debug_snapshot.rs`
- Create: `local-ios-agent/rust-core/src/context/compaction.rs`
- Modify: `local-ios-agent/rust-core/src/context/mod.rs`
- Test: `local-ios-agent/rust-core/tests/context_compaction.rs`

- [ ] **Step 1: Write compaction test**

Create `tests/context_compaction.rs`:

```rust
use local_ios_agent_runtime::context::{CompactionCandidate, PromptDebugSnapshot, PromptFrame};

#[test]
fn compaction_candidate_creates_summary_text() {
    let candidate = CompactionCandidate::new(vec!["hello".into(), "world".into()]);

    assert_eq!(candidate.summary_text(), "hello\nworld");
}

#[test]
fn prompt_debug_snapshot_renders_frame() {
    let frame = PromptFrame {
        system_prompt: "system".into(),
        runtime_policy: "policy".into(),
        tool_schemas: Vec::new(),
        messages: Vec::new(),
    };

    assert!(PromptDebugSnapshot::from_frame(&frame).rendered_text.contains("system"));
}
```

- [ ] **Step 2: Implement debug and compaction structs**

Create `debug_snapshot.rs`:

```rust
use crate::context::PromptFrame;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PromptDebugSnapshot {
    pub rendered_text: String,
}

impl PromptDebugSnapshot {
    pub fn from_frame(frame: &PromptFrame) -> Self {
        Self {
            rendered_text: format!(
                "{}\n{}\n{}\n{}",
                frame.system_prompt,
                frame.runtime_policy,
                frame.tool_schemas.join("\n"),
                frame.messages.iter().map(|message| message.content()).collect::<Vec<_>>().join("\n")
            ),
        }
    }
}
```

Create `compaction.rs`:

```rust
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CompactionCandidate {
    messages: Vec<String>,
}

impl CompactionCandidate {
    pub fn new(messages: Vec<String>) -> Self {
        Self { messages }
    }

    pub fn summary_text(&self) -> String {
        self.messages.join("\n")
    }
}
```

- [ ] **Step 3: Verify and commit**

Run:

```bash
cargo fmt
cargo test --test context_compaction
cargo test
```

Commit:

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/rust-core/src/context/debug_snapshot.rs local-ios-agent/rust-core/src/context/compaction.rs local-ios-agent/rust-core/src/context/mod.rs local-ios-agent/rust-core/tests/context_compaction.rs
git commit -m "feat: add context debug and compaction"
```

## Exit Criteria

- Active branch projection is centralized.
- Prompt layers separate system, policy, and memory.
- Tool schemas are stable and deduplicated.
- Tool result injection respects retention and sensitivity.
- Context budget truncates only at message boundaries.
- Prompt debug snapshot exists.
- Compaction candidate can create summary text for `BranchSummaryCreated`.
- `cargo test` passes.
