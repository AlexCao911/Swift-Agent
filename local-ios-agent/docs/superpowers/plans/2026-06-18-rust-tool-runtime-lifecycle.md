# Rust Tool Runtime Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the first complete Rust-side tool-call lifecycle: provider-emitted tool calls, registry lookup, policy routing, read-only execution, approval-required suspension, tool-result persistence, and follow-up model continuation.

**Architecture:** Swift will own real iOS tool implementations later. This plan creates the Rust orchestration contract first by using a mock `ToolExecutor` in tests. `AgentRuntime` remains the semantic owner of tool lifecycle events, while `tool` owns registry/routing and `security` owns approval decisions.

**Tech Stack:** Rust 2021, `serde_json`, existing `AgentRuntime`, existing `PolicyEngine`, existing event store/session tree, `cargo test`, TDD.

---

## Scope

This is Plan 3 of the MVP. It implements the Rust tool runtime boundary under:

```text
/Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
```

It does not implement:

- UniFFI.
- Swift Native Toolkit.
- iOS permissions.
- Real EventKit, Reminders, Shortcuts, or App Intents calls.
- Persistent SQLite-backed `AgentRuntime`.
- Desktop MiniCPM.
- On-device C++ inference.

## Current Code Audit

This plan was drafted after reading the current Rust runtime code and running
targeted searches for tool/runtime/context/security gaps.

Verified current state:

- `AgentRuntime::send_message` currently handles `TextDelta` and `Completed`
  provider outputs only.
- `ModelProviderOutput` has no tool-call variant.
- `tool` exports `ToolSchema`, `ToolCall`, and `ToolResult`, but no
  `ToolRegistry`, `ToolExecutor`, or `ToolRouter`.
- `PolicyEngine` can already return allow, approval-required, or deny decisions
  from `RiskLevel`.
- `ApprovalRequest` and `SuspendedRun` exist, but `AgentRuntime` does not yet
  create approval requests.
- `ContextController` already converts `ToolResultMessage` events into
  `PromptMessage::ToolResult`, which makes tool-result follow-up calls possible
  after runtime persists tool result events.

Review report items assigned to this plan:

- Tool registry.
- Tool-call JSON validation.
- Policy-based allow/approval/deny routing.
- Mock executor boundary that later maps to Swift native execution.
- Tool result injection into the next provider call.
- Recoverable denied-tool modeling through `ToolExecutionFailed`.

Review report items deliberately deferred:

- Full run state machine, cancellation, and replay: Plan 4.
- Full context budget, compaction, memory prompt, and provider tokenizer
  alignment: Plan 4 and Plan 8.
- Long-term memory, semantic retrieval, SQLCipher, and iOS Data Protection:
  post-MVP or a later hardening plan after the iOS app storage model exists.
- UniFFI async approval and Swift tool execution request boundary: Plan 5.
- LocalAuthentication / Face ID UI: Plan 7 in Swift, with Rust tracking approval
  state only.

## File Structure

Create:

```text
local-ios-agent/rust-core/src/tool/executor.rs
local-ios-agent/rust-core/src/tool/registry.rs
local-ios-agent/rust-core/src/tool/router.rs
local-ios-agent/rust-core/tests/tool_registry.rs
local-ios-agent/rust-core/tests/tool_router.rs
local-ios-agent/rust-core/tests/runtime_tool_lifecycle.rs
```

Modify:

```text
local-ios-agent/rust-core/Cargo.toml
local-ios-agent/rust-core/src/core/provider.rs
local-ios-agent/rust-core/src/core/runtime.rs
local-ios-agent/rust-core/src/core/mod.rs
local-ios-agent/rust-core/src/tool/mod.rs
local-ios-agent/rust-core/src/tool/schema.rs
local-ios-agent/rust-core/tests/mock_provider.rs
local-ios-agent/rust-core/tests/runtime_mock.rs
```

## Task 1: Add Tool Executor and Registry

**Files:**
- Modify: `local-ios-agent/rust-core/Cargo.toml`
- Create: `local-ios-agent/rust-core/src/tool/executor.rs`
- Create: `local-ios-agent/rust-core/src/tool/registry.rs`
- Modify: `local-ios-agent/rust-core/src/tool/mod.rs`
- Test: `local-ios-agent/rust-core/tests/tool_registry.rs`

- [ ] **Step 1: Add serde_json dependency**

Edit `local-ios-agent/rust-core/Cargo.toml`:

```toml
[dependencies]
rusqlite = { version = "0.32", features = ["bundled"] }
serde_json = "1.0"
```

- [ ] **Step 2: Write failing registry test**

Create `local-ios-agent/rust-core/tests/tool_registry.rs`:

```rust
use local_ios_agent_runtime::security::RiskLevel;
use local_ios_agent_runtime::tool::{
    RetentionPolicy, Sensitivity, ToolCall, ToolExecutor, ToolRegistry, ToolResult, ToolSchema,
};
use local_ios_agent_runtime::core::AgentError;

#[derive(Debug)]
struct EchoExecutor;

impl ToolExecutor for EchoExecutor {
    fn execute(&self, call: &ToolCall) -> Result<ToolResult, AgentError> {
        Ok(ToolResult {
            display_text: format!("display {}", call.arguments_json),
            model_text: format!("model {}", call.arguments_json),
            structured_json: call.arguments_json.clone(),
            audit_text: format!("audit {}", call.name),
            sensitivity: Sensitivity::Public,
            retention: RetentionPolicy::RunOnly,
            is_error: false,
        })
    }
}

fn echo_schema() -> ToolSchema {
    ToolSchema {
        name: "debug.echo".to_string(),
        description: "Echo JSON arguments.".to_string(),
        parameters_json_schema: r#"{"type":"object","properties":{"text":{"type":"string"}}}"#.to_string(),
        risk_level: RiskLevel::ReadOnly,
    }
}

#[test]
fn registry_registers_schema_and_executes_tool() {
    let mut registry = ToolRegistry::new();
    registry
        .register(echo_schema(), Box::new(EchoExecutor))
        .unwrap();

    let call = ToolCall {
        id: "call_1".to_string(),
        name: "debug.echo".to_string(),
        arguments_json: r#"{"text":"hello"}"#.to_string(),
    };

    let result = registry.execute(&call).unwrap();

    assert_eq!(registry.schema("debug.echo").unwrap().risk_level, RiskLevel::ReadOnly);
    assert_eq!(result.model_text, r#"model {"text":"hello"}"#);
}

#[test]
fn registry_rejects_invalid_json_arguments() {
    let mut registry = ToolRegistry::new();
    registry
        .register(echo_schema(), Box::new(EchoExecutor))
        .unwrap();

    let call = ToolCall {
        id: "call_1".to_string(),
        name: "debug.echo".to_string(),
        arguments_json: "not-json".to_string(),
    };

    let error = registry.execute(&call).unwrap_err();

    assert!(matches!(error, AgentError::ToolValidation(_)));
}
```

- [ ] **Step 3: Run test to verify it fails**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo test --test tool_registry
```

Expected:

```text
unresolved import `local_ios_agent_runtime::tool::ToolRegistry`
```

- [ ] **Step 4: Add ToolExecutor trait**

Create `local-ios-agent/rust-core/src/tool/executor.rs`:

```rust
use crate::core::AgentError;
use crate::tool::{ToolCall, ToolResult};

pub trait ToolExecutor: Send + Sync + std::fmt::Debug {
    fn execute(&self, call: &ToolCall) -> Result<ToolResult, AgentError>;
}
```

- [ ] **Step 5: Add ToolRegistry**

Create `local-ios-agent/rust-core/src/tool/registry.rs`:

```rust
use std::collections::HashMap;

use serde_json::Value;

use crate::core::AgentError;
use crate::tool::{ToolCall, ToolExecutor, ToolResult, ToolSchema};

#[derive(Default)]
pub struct ToolRegistry {
    schemas: HashMap<String, ToolSchema>,
    executors: HashMap<String, Box<dyn ToolExecutor>>,
}

impl ToolRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn register(
        &mut self,
        schema: ToolSchema,
        executor: Box<dyn ToolExecutor>,
    ) -> Result<(), AgentError> {
        if self.schemas.contains_key(&schema.name) {
            return Err(AgentError::ToolValidation(format!(
                "tool already registered: {}",
                schema.name
            )));
        }
        let name = schema.name.clone();
        self.schemas.insert(name.clone(), schema);
        self.executors.insert(name, executor);
        Ok(())
    }

    pub fn schema(&self, name: &str) -> Option<&ToolSchema> {
        self.schemas.get(name)
    }

    pub fn prompt_schemas(&self) -> Vec<String> {
        let mut schemas: Vec<_> = self
            .schemas
            .values()
            .map(|schema| {
                format!(
                    "{}: {} params={}",
                    schema.name, schema.description, schema.parameters_json_schema
                )
            })
            .collect();
        schemas.sort();
        schemas
    }

    pub fn execute(&self, call: &ToolCall) -> Result<ToolResult, AgentError> {
        let _: Value = serde_json::from_str(&call.arguments_json).map_err(|error| {
            AgentError::ToolValidation(format!(
                "invalid JSON arguments for {}: {error}",
                call.name
            ))
        })?;

        let executor = self.executors.get(&call.name).ok_or_else(|| {
            AgentError::ToolValidation(format!("unknown tool: {}", call.name))
        })?;
        executor.execute(call)
    }
}
```

- [ ] **Step 6: Export registry types**

Modify `local-ios-agent/rust-core/src/tool/mod.rs`:

```rust
pub mod executor;
pub mod registry;
pub mod result;
pub mod schema;

pub use executor::ToolExecutor;
pub use registry::ToolRegistry;
pub use result::{RetentionPolicy, Sensitivity, ToolResult};
pub use schema::{ToolCall, ToolSchema};
```

- [ ] **Step 7: Run registry tests**

Run:

```bash
cargo fmt
cargo test --test tool_registry
```

Expected:

```text
test result: ok. 2 passed
```

- [ ] **Step 8: Run full tests**

Run:

```bash
cargo test
```

Expected:

```text
test result: ok
```

- [ ] **Step 9: Commit**

Run from `/Users/alexandercou/Projects/Alex-agent`:

```bash
git add local-ios-agent/rust-core/Cargo.toml local-ios-agent/rust-core/Cargo.lock local-ios-agent/rust-core/src/tool/executor.rs local-ios-agent/rust-core/src/tool/registry.rs local-ios-agent/rust-core/src/tool/mod.rs local-ios-agent/rust-core/tests/tool_registry.rs
git commit -m "feat: add tool registry"
```

## Task 2: Let Model Providers Emit Tool Calls

**Files:**
- Modify: `local-ios-agent/rust-core/src/core/provider.rs`
- Modify: `local-ios-agent/rust-core/tests/mock_provider.rs`

- [ ] **Step 1: Write failing mock-provider tool-call test**

Append this test to `local-ios-agent/rust-core/tests/mock_provider.rs`:

```rust
#[test]
fn mock_provider_emits_tool_call_for_debug_echo_request() {
    let provider = MockStreamingProvider::new();
    let frame = PromptFrame {
        system_prompt: "system".to_string(),
        runtime_policy: "policy".to_string(),
        tool_schemas: vec!["debug.echo".to_string()],
        messages: vec![PromptMessage::User("please use debug echo hello".to_string())],
    };

    let output = provider.stream_chat(&frame).unwrap();

    assert_eq!(
        output,
        vec![ModelProviderOutput::ToolCall(ToolCall {
            id: "call_mock_1".to_string(),
            name: "debug.echo".to_string(),
            arguments_json: r#"{"text":"hello"}"#.to_string(),
        })]
    );
}
```

Also add `ToolCall` to the imports at the top:

```rust
use local_ios_agent_runtime::tool::ToolCall;
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cargo test --test mock_provider mock_provider_emits_tool_call_for_debug_echo_request
```

Expected:

```text
no variant or associated item named `ToolCall` found for enum `ModelProviderOutput`
```

- [ ] **Step 3: Add provider tool-call output**

Modify `local-ios-agent/rust-core/src/core/provider.rs`:

```rust
use crate::context::{PromptFrame, PromptMessage};
use crate::core::AgentError;
use crate::tool::ToolCall;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ModelProviderOutput {
    TextDelta(String),
    ToolCall(ToolCall),
    Completed(String),
}
```

- [ ] **Step 4: Extend MockStreamingProvider**

Replace the body of `MockStreamingProvider::stream_chat` with:

```rust
fn stream_chat(&self, frame: &PromptFrame) -> Result<Vec<ModelProviderOutput>, AgentError> {
    if let Some(tool_result) = frame.messages.iter().rev().find_map(|message| match message {
        PromptMessage::ToolResult(content) => Some(content.as_str()),
        _ => None,
    }) {
        return Ok(vec![ModelProviderOutput::Completed(format!(
            "Tool result observed: {tool_result}"
        ))]);
    }

    let last_user = frame
        .messages
        .iter()
        .rev()
        .find_map(|message| match message {
            PromptMessage::User(content) => Some(content.as_str()),
            _ => None,
        })
        .unwrap_or("");

    if last_user == "please use debug echo hello" {
        return Ok(vec![ModelProviderOutput::ToolCall(ToolCall {
            id: "call_mock_1".to_string(),
            name: "debug.echo".to_string(),
            arguments_json: r#"{"text":"hello"}"#.to_string(),
        })]);
    }

    let response = format!("Mock response to: {last_user}");
    Ok(vec![
        ModelProviderOutput::TextDelta("Mock ".to_string()),
        ModelProviderOutput::TextDelta(format!("response to: {last_user}")),
        ModelProviderOutput::Completed(response),
    ])
}
```

- [ ] **Step 5: Run mock provider tests**

Run:

```bash
cargo fmt
cargo test --test mock_provider
```

Expected:

```text
test result: ok. 2 passed
```

- [ ] **Step 6: Run full tests**

Run:

```bash
cargo test
```

Expected:

```text
test result: ok
```

- [ ] **Step 7: Commit**

Run from `/Users/alexandercou/Projects/Alex-agent`:

```bash
git add local-ios-agent/rust-core/src/core/provider.rs local-ios-agent/rust-core/tests/mock_provider.rs
git commit -m "feat: let providers emit tool calls"
```

## Task 3: Add ToolRouter Policy Outcomes

**Files:**
- Create: `local-ios-agent/rust-core/src/tool/router.rs`
- Modify: `local-ios-agent/rust-core/src/tool/mod.rs`
- Test: `local-ios-agent/rust-core/tests/tool_router.rs`

- [ ] **Step 1: Write failing router tests**

Create `local-ios-agent/rust-core/tests/tool_router.rs`:

```rust
use local_ios_agent_runtime::core::{AgentError, EntryId, RunId};
use local_ios_agent_runtime::security::RiskLevel;
use local_ios_agent_runtime::tool::{
    RetentionPolicy, Sensitivity, ToolCall, ToolExecutor, ToolRegistry, ToolResult, ToolRouteOutcome,
    ToolRouter, ToolSchema,
};

#[derive(Debug)]
struct EchoExecutor;

impl ToolExecutor for EchoExecutor {
    fn execute(&self, call: &ToolCall) -> Result<ToolResult, AgentError> {
        Ok(ToolResult {
            display_text: "echo display".to_string(),
            model_text: call.arguments_json.clone(),
            structured_json: call.arguments_json.clone(),
            audit_text: "echo audit".to_string(),
            sensitivity: Sensitivity::Public,
            retention: RetentionPolicy::RunOnly,
            is_error: false,
        })
    }
}

fn schema(name: &str, risk_level: RiskLevel) -> ToolSchema {
    ToolSchema {
        name: name.to_string(),
        description: format!("{name} description"),
        parameters_json_schema: r#"{"type":"object"}"#.to_string(),
        risk_level,
    }
}

fn call(name: &str) -> ToolCall {
    ToolCall {
        id: "call_1".to_string(),
        name: name.to_string(),
        arguments_json: r#"{"text":"hello"}"#.to_string(),
    }
}

#[test]
fn router_executes_read_only_tool() {
    let mut registry = ToolRegistry::new();
    registry
        .register(schema("debug.echo", RiskLevel::ReadOnly), Box::new(EchoExecutor))
        .unwrap();
    let mut router = ToolRouter::new(registry);

    let outcome = router
        .route(&RunId("run_1".to_string()), &EntryId("entry_call".to_string()), &call("debug.echo"))
        .unwrap();

    assert!(matches!(outcome, ToolRouteOutcome::Executed(_)));
}

#[test]
fn router_requires_approval_for_confirm_tool() {
    let mut registry = ToolRegistry::new();
    registry
        .register(schema("reminders.create", RiskLevel::Confirm), Box::new(EchoExecutor))
        .unwrap();
    let mut router = ToolRouter::new(registry);

    let outcome = router
        .route(
            &RunId("run_1".to_string()),
            &EntryId("entry_call".to_string()),
            &call("reminders.create"),
        )
        .unwrap();

    match outcome {
        ToolRouteOutcome::ApprovalRequired(request) => {
            assert_eq!(request.run_id, RunId("run_1".to_string()));
            assert_eq!(request.tool_call_id, EntryId("entry_call".to_string()));
            assert!(request.message.contains("reminders.create"));
        }
        other => panic!("unexpected outcome: {other:?}"),
    }
}

#[test]
fn router_denies_destructive_tool_as_recoverable_tool_result() {
    let mut registry = ToolRegistry::new();
    registry
        .register(schema("files.delete_all", RiskLevel::Destructive), Box::new(EchoExecutor))
        .unwrap();
    let mut router = ToolRouter::new(registry);

    let outcome = router
        .route(
            &RunId("run_1".to_string()),
            &EntryId("entry_call".to_string()),
            &call("files.delete_all"),
        )
        .unwrap();

    match outcome {
        ToolRouteOutcome::Denied(result) => {
            assert!(result.is_error);
            assert!(result.model_text.contains("destructive"));
        }
        other => panic!("unexpected outcome: {other:?}"),
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cargo test --test tool_router
```

Expected:

```text
unresolved import `local_ios_agent_runtime::tool::ToolRouter`
```

- [ ] **Step 3: Add router implementation**

Create `local-ios-agent/rust-core/src/tool/router.rs`:

```rust
use crate::core::{AgentError, EntryId, RunId};
use crate::security::{ApprovalRequest, PolicyDecision, PolicyEngine};
use crate::tool::{ToolCall, ToolRegistry, ToolResult};
use crate::utils::id::IdGenerator;

#[derive(Debug, Eq, PartialEq)]
pub enum ToolRouteOutcome {
    Executed(ToolResult),
    ApprovalRequired(ApprovalRequest),
    Denied(ToolResult),
}

pub struct ToolRouter {
    registry: ToolRegistry,
    policy: PolicyEngine,
    ids: IdGenerator,
}

impl ToolRouter {
    pub fn new(registry: ToolRegistry) -> Self {
        Self {
            registry,
            policy: PolicyEngine,
            ids: IdGenerator::new(),
        }
    }

    pub fn prompt_schemas(&self) -> Vec<String> {
        self.registry.prompt_schemas()
    }

    pub fn route(
        &mut self,
        run_id: &RunId,
        tool_call_entry_id: &EntryId,
        call: &ToolCall,
    ) -> Result<ToolRouteOutcome, AgentError> {
        let schema = self.registry.schema(&call.name).ok_or_else(|| {
            AgentError::ToolValidation(format!("unknown tool: {}", call.name))
        })?;

        match self.policy.decide(&schema.risk_level, &schema.name) {
            PolicyDecision::Allow => {
                let result = self.registry.execute(call)?;
                Ok(ToolRouteOutcome::Executed(result))
            }
            PolicyDecision::RequireApproval(message) => Ok(ToolRouteOutcome::ApprovalRequired(
                ApprovalRequest {
                    approval_id: self.ids.next_id("approval"),
                    run_id: run_id.clone(),
                    tool_call_id: tool_call_entry_id.clone(),
                    message,
                },
            )),
            PolicyDecision::Deny(reason) => Ok(ToolRouteOutcome::Denied(ToolResult {
                display_text: reason.clone(),
                model_text: reason.clone(),
                structured_json: "{}".to_string(),
                audit_text: reason,
                sensitivity: crate::tool::Sensitivity::Public,
                retention: crate::tool::RetentionPolicy::RunOnly,
                is_error: true,
            })),
        }
    }
}
```

- [ ] **Step 4: Export router types**

Modify `local-ios-agent/rust-core/src/tool/mod.rs`:

```rust
pub mod executor;
pub mod registry;
pub mod result;
pub mod router;
pub mod schema;

pub use executor::ToolExecutor;
pub use registry::ToolRegistry;
pub use result::{RetentionPolicy, Sensitivity, ToolResult};
pub use router::{ToolRouteOutcome, ToolRouter};
pub use schema::{ToolCall, ToolSchema};
```

- [ ] **Step 5: Run router tests**

Run:

```bash
cargo fmt
cargo test --test tool_router
```

Expected:

```text
test result: ok. 3 passed
```

- [ ] **Step 6: Run full tests**

Run:

```bash
cargo test
```

Expected:

```text
test result: ok
```

- [ ] **Step 7: Commit**

Run from `/Users/alexandercou/Projects/Alex-agent`:

```bash
git add local-ios-agent/rust-core/src/tool/router.rs local-ios-agent/rust-core/src/tool/mod.rs local-ios-agent/rust-core/tests/tool_router.rs
git commit -m "feat: add tool router"
```

## Task 4: Execute Read-Only Tools Inside AgentRuntime

**Files:**
- Modify: `local-ios-agent/rust-core/src/core/runtime.rs`
- Modify: `local-ios-agent/rust-core/tests/runtime_mock.rs`
- Test: `local-ios-agent/rust-core/tests/runtime_tool_lifecycle.rs`

- [ ] **Step 1: Update existing runtime config construction**

Modify `local-ios-agent/rust-core/tests/runtime_mock.rs` so `AgentRuntimeConfig`
includes a `tool_router` field:

```rust
tool_router: None,
```

- [ ] **Step 2: Write failing runtime tool lifecycle test**

Create `local-ios-agent/rust-core/tests/runtime_tool_lifecycle.rs`:

```rust
use local_ios_agent_runtime::context::MockTokenizer;
use local_ios_agent_runtime::core::{
    AgentError, AgentRuntime, AgentRuntimeConfig, EventKind, MockStreamingProvider, SendMessageInput,
};
use local_ios_agent_runtime::security::RiskLevel;
use local_ios_agent_runtime::tool::{
    RetentionPolicy, Sensitivity, ToolCall, ToolExecutor, ToolRegistry, ToolResult, ToolRouter,
    ToolSchema,
};

#[derive(Debug)]
struct EchoExecutor;

impl ToolExecutor for EchoExecutor {
    fn execute(&self, call: &ToolCall) -> Result<ToolResult, AgentError> {
        Ok(ToolResult {
            display_text: "echoed hello".to_string(),
            model_text: format!("debug.echo returned {}", call.arguments_json),
            structured_json: call.arguments_json.clone(),
            audit_text: "debug echo executed".to_string(),
            sensitivity: Sensitivity::Public,
            retention: RetentionPolicy::RunOnly,
            is_error: false,
        })
    }
}

fn runtime_with_echo_tool() -> AgentRuntime {
    let mut registry = ToolRegistry::new();
    registry
        .register(
            ToolSchema {
                name: "debug.echo".to_string(),
                description: "Echo JSON arguments.".to_string(),
                parameters_json_schema: r#"{"type":"object","properties":{"text":{"type":"string"}}}"#.to_string(),
                risk_level: RiskLevel::ReadOnly,
            },
            Box::new(EchoExecutor),
        )
        .unwrap();

    AgentRuntime::new(AgentRuntimeConfig {
        system_prompt: "system".to_string(),
        runtime_policy: "policy".to_string(),
        tool_schemas: Vec::new(),
        tokenizer: Box::new(MockTokenizer::new(100)),
        provider: Box::new(MockStreamingProvider::new()),
        tool_router: Some(ToolRouter::new(registry)),
    })
}

#[test]
fn runtime_executes_read_only_tool_and_continues_model() {
    let mut runtime = runtime_with_echo_tool();
    let session_id = runtime.create_session().unwrap();

    let events = runtime
        .send_message(SendMessageInput {
            session_id,
            parent_event_id: None,
            text: "please use debug echo hello".to_string(),
        })
        .unwrap();

    assert!(events.iter().any(|event| event.kind == EventKind::ToolCallRequested));
    assert!(events.iter().any(|event| event.kind == EventKind::ToolExecutionStarted));
    assert!(events.iter().any(|event| event.kind == EventKind::ToolExecutionCompleted));
    assert!(events.iter().any(|event| event.kind == EventKind::ToolResultMessage));
    assert!(events.iter().any(|event| {
        event.kind == EventKind::AssistantMessageCompleted
            && event.payload.contains("Tool result observed")
    }));
}
```

- [ ] **Step 3: Run test to verify it fails**

Run:

```bash
cargo test --test runtime_tool_lifecycle runtime_executes_read_only_tool_and_continues_model
```

Expected:

```text
struct `AgentRuntimeConfig` has no field named `tool_router`
```

- [ ] **Step 4: Add optional ToolRouter to runtime config**

Modify `local-ios-agent/rust-core/src/core/runtime.rs` imports:

```rust
use crate::tool::{ToolRouteOutcome, ToolRouter};
```

Modify `AgentRuntimeConfig`:

```rust
pub struct AgentRuntimeConfig {
    pub system_prompt: String,
    pub runtime_policy: String,
    pub tool_schemas: Vec<String>,
    pub tokenizer: Box<dyn TokenizerAdapter>,
    pub provider: Box<dyn ModelProvider>,
    pub tool_router: Option<ToolRouter>,
}
```

- [ ] **Step 5: Inject registered schemas into PromptFrame**

Inside `send_message`, before constructing `ContextController`, replace direct
schema usage with:

```rust
let mut tool_schemas = self.config.tool_schemas.clone();
if let Some(router) = &self.config.tool_router {
    tool_schemas.extend(router.prompt_schemas());
}
```

Then pass `tool_schemas` into `ContextController::new`.

- [ ] **Step 6: Handle provider tool-call outputs**

Inside the provider event loop in `send_message`, add a match arm:

```rust
ModelProviderOutput::ToolCall(call) => {
    let call_payload = format!(
        r#"{{"id":"{}","name":"{}","arguments":{}}}"#,
        call.id, call.name, call.arguments_json
    );
    let call_event_id = tree.append(
        Some(parent.clone()),
        EventKind::ToolCallRequested,
        call_payload,
    )?;
    emitted.push(
        tree.active_branch(&call_event_id)?
            .last()
            .cloned()
            .ok_or_else(|| AgentError::Storage("missing tool call event".to_string()))?,
    );

    let router = self.config.tool_router.as_mut().ok_or_else(|| {
        AgentError::ToolValidation(format!("tool router missing for {}", call.name))
    })?;

    match router.route(&run_id, &call_event_id, &call)? {
        ToolRouteOutcome::Executed(result) => {
            let started_id = tree.append(
                Some(call_event_id.clone()),
                EventKind::ToolExecutionStarted,
                call.name.clone(),
            )?;
            emitted.push(tree.active_branch(&started_id)?.last().cloned().ok_or_else(|| {
                AgentError::Storage("missing tool started event".to_string())
            })?);

            let completed_id = tree.append(
                Some(started_id.clone()),
                EventKind::ToolExecutionCompleted,
                result.audit_text.clone(),
            )?;
            emitted.push(tree.active_branch(&completed_id)?.last().cloned().ok_or_else(|| {
                AgentError::Storage("missing tool completed event".to_string())
            })?);

            let result_id = tree.append(
                Some(completed_id.clone()),
                EventKind::ToolResultMessage,
                result.model_text,
            )?;
            emitted.push(tree.active_branch(&result_id)?.last().cloned().ok_or_else(|| {
                AgentError::Storage("missing tool result event".to_string())
            })?);
            parent = result_id.clone();

            let follow_up_branch = tree.active_branch(&result_id)?;
            let follow_up_context = ContextController::new(
                self.config.system_prompt.clone(),
                self.config.runtime_policy.clone(),
                tool_schemas.clone(),
                self.config.tokenizer.boxed_clone(),
            )
            .build_prompt_frame(follow_up_branch)?;
            for follow_up_event in self.config.provider.stream_chat(&follow_up_context)? {
                if let ModelProviderOutput::Completed(completed) = follow_up_event {
                    let completed_id = tree.append(
                        Some(parent.clone()),
                        EventKind::AssistantMessageCompleted,
                        completed,
                    )?;
                    emitted.push(tree.active_branch(&completed_id)?.last().cloned().ok_or_else(
                        || AgentError::Storage("missing follow-up completed event".to_string()),
                    )?);
                    parent = completed_id;
                }
            }
        }
        ToolRouteOutcome::ApprovalRequired(request) => {
            let suspended_id = tree.append(
                Some(call_event_id.clone()),
                EventKind::RunSuspended,
                request.message,
            )?;
            emitted.push(tree.active_branch(&suspended_id)?.last().cloned().ok_or_else(|| {
                AgentError::Storage("missing run suspended event".to_string())
            })?);
            parent = suspended_id;
        }
        ToolRouteOutcome::Denied(result) => {
            let failed_id = tree.append(
                Some(call_event_id.clone()),
                EventKind::ToolExecutionFailed,
                result.model_text,
            )?;
            emitted.push(tree.active_branch(&failed_id)?.last().cloned().ok_or_else(|| {
                AgentError::Storage("missing tool failed event".to_string())
            })?);
            parent = failed_id;
        }
    }
}
```

- [ ] **Step 7: Run runtime tool lifecycle test**

Run:

```bash
cargo fmt
cargo test --test runtime_tool_lifecycle runtime_executes_read_only_tool_and_continues_model
```

Expected:

```text
test result: ok. 1 passed
```

- [ ] **Step 8: Run full tests**

Run:

```bash
cargo test
```

Expected:

```text
test result: ok
```

- [ ] **Step 9: Commit**

Run from `/Users/alexandercou/Projects/Alex-agent`:

```bash
git add local-ios-agent/rust-core/src/core/runtime.rs local-ios-agent/rust-core/tests/runtime_mock.rs local-ios-agent/rust-core/tests/runtime_tool_lifecycle.rs
git commit -m "feat: execute runtime tool calls"
```

## Task 5: Persist Approval-Required Suspension Path

**Files:**
- Modify: `local-ios-agent/rust-core/tests/runtime_tool_lifecycle.rs`
- Modify: `local-ios-agent/rust-core/src/core/runtime.rs`

- [ ] **Step 1: Add confirmation-required runtime test**

Append this test to `local-ios-agent/rust-core/tests/runtime_tool_lifecycle.rs`:

```rust
fn runtime_with_confirm_tool() -> AgentRuntime {
    let mut registry = ToolRegistry::new();
    registry
        .register(
            ToolSchema {
                name: "reminders.create".to_string(),
                description: "Create a reminder.".to_string(),
                parameters_json_schema: r#"{"type":"object","properties":{"title":{"type":"string"}}}"#.to_string(),
                risk_level: RiskLevel::Confirm,
            },
            Box::new(EchoExecutor),
        )
        .unwrap();

    AgentRuntime::new(AgentRuntimeConfig {
        system_prompt: "system".to_string(),
        runtime_policy: "policy".to_string(),
        tool_schemas: Vec::new(),
        tokenizer: Box::new(MockTokenizer::new(100)),
        provider: Box::new(MockReminderProvider),
        tool_router: Some(ToolRouter::new(registry)),
    })
}

#[derive(Debug)]
struct MockReminderProvider;

impl local_ios_agent_runtime::core::ModelProvider for MockReminderProvider {
    fn id(&self) -> &str {
        "mock-reminder"
    }

    fn stream_chat(
        &self,
        _frame: &local_ios_agent_runtime::context::PromptFrame,
    ) -> Result<Vec<local_ios_agent_runtime::core::ModelProviderOutput>, AgentError> {
        Ok(vec![local_ios_agent_runtime::core::ModelProviderOutput::ToolCall(
            ToolCall {
                id: "call_reminder_1".to_string(),
                name: "reminders.create".to_string(),
                arguments_json: r#"{"title":"Buy milk"}"#.to_string(),
            },
        )])
    }
}

#[test]
fn runtime_suspends_for_confirmation_required_tool() {
    let mut runtime = runtime_with_confirm_tool();
    let session_id = runtime.create_session().unwrap();

    let events = runtime
        .send_message(SendMessageInput {
            session_id,
            parent_event_id: None,
            text: "create reminder".to_string(),
        })
        .unwrap();

    assert!(events.iter().any(|event| event.kind == EventKind::ToolCallRequested));
    assert!(events.iter().any(|event| {
        event.kind == EventKind::RunSuspended && event.payload.contains("reminders.create")
    }));
    assert!(!events
        .iter()
        .any(|event| event.kind == EventKind::ToolExecutionCompleted));
}
```

- [ ] **Step 2: Stop the current turn after suspension**

In `local-ios-agent/rust-core/src/core/runtime.rs`, ensure the
`ToolRouteOutcome::ApprovalRequired` branch ends the current provider loop after
appending `RunSuspended`:

```rust
ToolRouteOutcome::ApprovalRequired(request) => {
    let suspended_id = tree.append(
        Some(call_event_id.clone()),
        EventKind::RunSuspended,
        request.message,
    )?;
    emitted.push(tree.active_branch(&suspended_id)?.last().cloned().ok_or_else(|| {
        AgentError::Storage("missing run suspended event".to_string())
    })?);
    parent = suspended_id;
    break;
}
```

- [ ] **Step 3: Run confirmation test**

Run:

```bash
cargo test --test runtime_tool_lifecycle runtime_suspends_for_confirmation_required_tool
```

Expected:

```text
test result: ok. 1 passed
```

- [ ] **Step 4: Run full tests**

Run:

```bash
cargo fmt
cargo test
```

Expected:

```text
test result: ok
```

- [ ] **Step 5: Commit**

Run from `/Users/alexandercou/Projects/Alex-agent`:

```bash
git add local-ios-agent/rust-core/src/core/runtime.rs local-ios-agent/rust-core/tests/runtime_tool_lifecycle.rs
git commit -m "feat: suspend runtime for tool approval"
```

## Task 6: Document Tool Runtime Boundary

**Files:**
- Modify: `local-ios-agent/rust-core/README.md`

- [ ] **Step 1: Add README section**

Append this section to `local-ios-agent/rust-core/README.md` after `Memory Stores`:

```markdown
## Tool Runtime

The `tool` module owns Rust-side tool orchestration. Swift will own real iOS
tool implementations, but Rust owns the lifecycle:

1. Provider emits a structured tool call.
2. Runtime appends `ToolCallRequested`.
3. `ToolRouter` validates JSON arguments and applies `PolicyEngine`.
4. Read-only tools execute immediately through the registered executor.
5. Confirmation-required tools append `RunSuspended` and wait for Swift approval
   in a later UniFFI plan.
6. Tool results are persisted as `ToolResultMessage` before provider
   continuation.

This keeps iOS capability code out of Rust while keeping agent state and model
context assembly inside Rust.
```

- [ ] **Step 2: Run tests**

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

Run from `/Users/alexandercou/Projects/Alex-agent`:

```bash
git add local-ios-agent/rust-core/README.md
git commit -m "docs: document tool runtime boundary"
```

## Self-Review Checklist

- The plan keeps real iOS tool execution in Swift for later plans.
- Rust owns tool orchestration, policy decisions, event persistence, and context
  injection.
- The first executor is mock-only and exists to prove the lifecycle.
- The approval path suspends instead of executing confirmation-required tools.
- Every task has a focused test and a commit boundary.
- No file under `pi/` is staged or modified.
