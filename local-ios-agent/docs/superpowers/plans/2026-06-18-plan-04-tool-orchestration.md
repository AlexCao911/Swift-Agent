# Plan 4: Tool Orchestration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Rust tool orchestration layer: registry, parser, validation, policy route, Swift execution request, result submission, and recoverable tool errors.

**Architecture:** `tool` owns schema registration, tool-call parsing, argument validation, and routing. `core` owns run lifecycle. `security` owns policy decisions. Swift will execute native tools later; this plan creates the Rust request/result boundary without calling iOS APIs.

**Tech Stack:** Rust 2021, `serde_json`, existing `ToolSchema`, `ToolCall`, `ToolResult`, existing `PolicyEngine`, `cargo test`, TDD.

---

## Current Code Audit

Checked current code with:

```bash
rg -n "ToolRegistry|ToolRouter|ToolExecutor|ToolExecutionRequest|ToolCall|ToolResult|PolicyDecision" local-ios-agent/rust-core/src local-ios-agent/rust-core/tests
sed -n '1,260p' local-ios-agent/rust-core/src/tool/schema.rs
sed -n '1,260p' local-ios-agent/rust-core/src/tool/result.rs
sed -n '1,260p' local-ios-agent/rust-core/src/security/policy.rs
```

Observed:

- `ToolSchema`, `ToolCall`, and `ToolResult` exist.
- No registry, parser, router, executor request, or tool error normalization
  exists.
- `PolicyEngine` already maps `RiskLevel` to allow, approval, or deny.
- Plan 3 provides the run lifecycle slots for waiting and resuming.

Assigned to this plan:

- Tool schema registry.
- JSON parse and argument validation.
- Tool route outcome.
- `ToolExecutionRequest` for Swift.
- Submit tool result into the core runtime.
- Recoverable tool failures.

Deferred:

- Permission scopes and approval queue: Plan 7.
- Real Swift execution: later Swift Native Toolkit plan.

## File Structure

Create:

```text
local-ios-agent/rust-core/src/tool/parser.rs
local-ios-agent/rust-core/src/tool/registry.rs
local-ios-agent/rust-core/src/tool/router.rs
local-ios-agent/rust-core/src/tool/execution_request.rs
local-ios-agent/rust-core/tests/tool_parser.rs
local-ios-agent/rust-core/tests/tool_registry.rs
local-ios-agent/rust-core/tests/tool_router.rs
local-ios-agent/rust-core/tests/runtime_tool_orchestration.rs
```

Modify:

```text
local-ios-agent/rust-core/Cargo.toml
local-ios-agent/rust-core/src/tool/mod.rs
local-ios-agent/rust-core/src/core/runtime.rs
```

## Task 1: Add Tool Call Parser

**Files:**
- Modify: `local-ios-agent/rust-core/Cargo.toml`
- Create: `local-ios-agent/rust-core/src/tool/parser.rs`
- Modify: `local-ios-agent/rust-core/src/tool/mod.rs`
- Test: `local-ios-agent/rust-core/tests/tool_parser.rs`

- [ ] **Step 1: Add dependency**

Add:

```toml
serde_json = "1.0"
```

- [ ] **Step 2: Write failing parser tests**

Create `tests/tool_parser.rs`:

```rust
use local_ios_agent_runtime::core::AgentError;
use local_ios_agent_runtime::tool::ToolCallParser;

#[test]
fn parser_reads_structured_tool_call_json() {
    let call = ToolCallParser::new()
        .parse(r#"{"id":"call_1","name":"calendar.search_events","arguments":{"query":"today"}}"#)
        .unwrap();

    assert_eq!(call.id, "call_1");
    assert_eq!(call.name, "calendar.search_events");
    assert_eq!(call.arguments_json, r#"{"query":"today"}"#);
}

#[test]
fn parser_rejects_missing_tool_name() {
    let error = ToolCallParser::new().parse(r#"{"id":"call_1","arguments":{}}"#).unwrap_err();

    assert!(matches!(error, AgentError::ToolParse(_)));
}
```

- [ ] **Step 3: Implement parser**

Create `src/tool/parser.rs`:

```rust
use serde_json::Value;

use crate::core::AgentError;
use crate::tool::ToolCall;

#[derive(Clone, Debug, Default)]
pub struct ToolCallParser;

impl ToolCallParser {
    pub fn new() -> Self {
        Self
    }

    pub fn parse(&self, json: &str) -> Result<ToolCall, AgentError> {
        let value: Value = serde_json::from_str(json)
            .map_err(|error| AgentError::ToolParse(format!("invalid tool call JSON: {error}")))?;
        let id = value["id"].as_str().unwrap_or("call_1").to_string();
        let name = value["name"]
            .as_str()
            .ok_or_else(|| AgentError::ToolParse("missing tool name".to_string()))?
            .to_string();
        let arguments_json = value["arguments"].to_string();
        Ok(ToolCall { id, name, arguments_json })
    }
}
```

- [ ] **Step 4: Export and verify**

Export:

```rust
pub mod parser;
pub use parser::ToolCallParser;
```

Run:

```bash
cargo fmt
cargo test --test tool_parser
cargo test
```

- [ ] **Step 5: Commit**

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/rust-core/Cargo.toml local-ios-agent/rust-core/Cargo.lock local-ios-agent/rust-core/src/tool/parser.rs local-ios-agent/rust-core/src/tool/mod.rs local-ios-agent/rust-core/tests/tool_parser.rs
git commit -m "feat: add tool call parser"
```

## Task 2: Add Tool Registry

**Files:**
- Create: `local-ios-agent/rust-core/src/tool/registry.rs`
- Modify: `local-ios-agent/rust-core/src/tool/mod.rs`
- Test: `local-ios-agent/rust-core/tests/tool_registry.rs`

- [ ] **Step 1: Write failing registry test**

Create `tests/tool_registry.rs`:

```rust
use local_ios_agent_runtime::security::RiskLevel;
use local_ios_agent_runtime::tool::{ToolRegistry, ToolSchema};

#[test]
fn registry_registers_and_formats_prompt_schemas() {
    let mut registry = ToolRegistry::new();
    registry.register(ToolSchema {
        name: "calendar.search_events".into(),
        description: "Search calendar events.".into(),
        parameters_json_schema: r#"{"type":"object"}"#.into(),
        risk_level: RiskLevel::ReadOnly,
    }).unwrap();

    assert!(registry.schema("calendar.search_events").is_some());
    assert!(registry.prompt_schemas()[0].contains("calendar.search_events"));
}
```

- [ ] **Step 2: Implement registry**

Create `src/tool/registry.rs`:

```rust
use std::collections::HashMap;

use crate::core::AgentError;
use crate::tool::ToolSchema;

#[derive(Clone, Debug, Default)]
pub struct ToolRegistry {
    schemas: HashMap<String, ToolSchema>,
}

impl ToolRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn register(&mut self, schema: ToolSchema) -> Result<(), AgentError> {
        if self.schemas.contains_key(&schema.name) {
            return Err(AgentError::ToolValidation(format!("tool already registered: {}", schema.name)));
        }
        self.schemas.insert(schema.name.clone(), schema);
        Ok(())
    }

    pub fn schema(&self, name: &str) -> Option<&ToolSchema> {
        self.schemas.get(name)
    }

    pub fn prompt_schemas(&self) -> Vec<String> {
        let mut schemas: Vec<_> = self.schemas.values().map(|schema| {
            format!("{}: {} params={}", schema.name, schema.description, schema.parameters_json_schema)
        }).collect();
        schemas.sort();
        schemas
    }
}
```

- [ ] **Step 3: Export, verify, commit**

Export:

```rust
pub mod registry;
pub use registry::ToolRegistry;
```

Run:

```bash
cargo fmt
cargo test --test tool_registry
cargo test
```

Commit:

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/rust-core/src/tool/registry.rs local-ios-agent/rust-core/src/tool/mod.rs local-ios-agent/rust-core/tests/tool_registry.rs
git commit -m "feat: add tool registry"
```

## Task 3: Add Tool Execution Request

**Files:**
- Create: `local-ios-agent/rust-core/src/tool/execution_request.rs`
- Modify: `local-ios-agent/rust-core/src/tool/mod.rs`
- Test: `local-ios-agent/rust-core/tests/tool_router.rs`

- [ ] **Step 1: Write failing request test**

Create `tests/tool_router.rs`:

```rust
use local_ios_agent_runtime::core::{EntryId, RunId, SessionId};
use local_ios_agent_runtime::tool::{ToolCall, ToolExecutionRequest};

#[test]
fn execution_request_carries_swift_boundary_payload() {
    let request = ToolExecutionRequest::new(
        RunId("run_1".into()),
        SessionId("session_1".into()),
        EntryId("entry_1".into()),
        ToolCall {
            id: "call_1".into(),
            name: "calendar.search_events".into(),
            arguments_json: "{}".into(),
        },
    );

    assert_eq!(request.tool_name, "calendar.search_events");
    assert_eq!(request.arguments_json, "{}");
}
```

- [ ] **Step 2: Implement request**

Create `src/tool/execution_request.rs`:

```rust
use crate::core::{EntryId, RunId, SessionId};
use crate::tool::ToolCall;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ToolExecutionRequest {
    pub run_id: RunId,
    pub session_id: SessionId,
    pub tool_call_entry_id: EntryId,
    pub tool_call_id: String,
    pub tool_name: String,
    pub arguments_json: String,
}

impl ToolExecutionRequest {
    pub fn new(run_id: RunId, session_id: SessionId, tool_call_entry_id: EntryId, call: ToolCall) -> Self {
        Self {
            run_id,
            session_id,
            tool_call_entry_id,
            tool_call_id: call.id,
            tool_name: call.name,
            arguments_json: call.arguments_json,
        }
    }
}
```

- [ ] **Step 3: Export and commit**

Run:

```bash
cargo fmt
cargo test --test tool_router execution_request_carries_swift_boundary_payload
cargo test
```

Commit:

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/rust-core/src/tool/execution_request.rs local-ios-agent/rust-core/src/tool/mod.rs local-ios-agent/rust-core/tests/tool_router.rs
git commit -m "feat: add tool execution request"
```

## Task 4: Add Tool Router

**Files:**
- Create: `local-ios-agent/rust-core/src/tool/router.rs`
- Modify: `local-ios-agent/rust-core/src/tool/mod.rs`
- Modify: `local-ios-agent/rust-core/tests/tool_router.rs`

- [ ] **Step 1: Add router tests**

Append:

```rust
use local_ios_agent_runtime::security::RiskLevel;
use local_ios_agent_runtime::tool::{ToolRouteOutcome, ToolRouter, ToolRegistry, ToolSchema};

fn schema(name: &str, risk_level: RiskLevel) -> ToolSchema {
    ToolSchema {
        name: name.into(),
        description: format!("{name} description"),
        parameters_json_schema: r#"{"type":"object"}"#.into(),
        risk_level,
    }
}

#[test]
fn router_routes_read_tool_to_swift_execution_request() {
    let mut registry = ToolRegistry::new();
    registry.register(schema("calendar.search_events", RiskLevel::ReadOnly)).unwrap();
    let router = ToolRouter::new(registry);

    let outcome = router.route(
        &RunId("run_1".into()),
        &SessionId("session_1".into()),
        &EntryId("entry_1".into()),
        ToolCall {
            id: "call_1".into(),
            name: "calendar.search_events".into(),
            arguments_json: "{}".into(),
        },
    ).unwrap();

    assert!(matches!(outcome, ToolRouteOutcome::ExecuteInSwift(_)));
}

#[test]
fn router_denies_destructive_tool_as_recoverable_error() {
    let mut registry = ToolRegistry::new();
    registry.register(schema("files.delete_all", RiskLevel::Destructive)).unwrap();
    let router = ToolRouter::new(registry);

    let outcome = router.route(
        &RunId("run_1".into()),
        &SessionId("session_1".into()),
        &EntryId("entry_1".into()),
        ToolCall {
            id: "call_1".into(),
            name: "files.delete_all".into(),
            arguments_json: "{}".into(),
        },
    ).unwrap();

    assert!(matches!(outcome, ToolRouteOutcome::Denied(_)));
}
```

- [ ] **Step 2: Implement router**

Create `src/tool/router.rs`:

```rust
use crate::core::{AgentError, EntryId, RunId, SessionId};
use crate::security::{PolicyDecision, PolicyEngine};
use crate::tool::{RetentionPolicy, Sensitivity, ToolCall, ToolExecutionRequest, ToolRegistry, ToolResult};

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ToolRouteOutcome {
    ExecuteInSwift(ToolExecutionRequest),
    ApprovalRequired(ToolExecutionRequest),
    Denied(ToolResult),
}

#[derive(Clone, Debug)]
pub struct ToolRouter {
    registry: ToolRegistry,
    policy: PolicyEngine,
}

impl ToolRouter {
    pub fn new(registry: ToolRegistry) -> Self {
        Self { registry, policy: PolicyEngine }
    }

    pub fn route(
        &self,
        run_id: &RunId,
        session_id: &SessionId,
        tool_call_entry_id: &EntryId,
        call: ToolCall,
    ) -> Result<ToolRouteOutcome, AgentError> {
        let schema = self.registry.schema(&call.name)
            .ok_or_else(|| AgentError::ToolValidation(format!("unknown tool: {}", call.name)))?;
        let request = ToolExecutionRequest::new(run_id.clone(), session_id.clone(), tool_call_entry_id.clone(), call);
        match self.policy.decide(&schema.risk_level, &schema.name) {
            PolicyDecision::Allow => Ok(ToolRouteOutcome::ExecuteInSwift(request)),
            PolicyDecision::RequireApproval(_) => Ok(ToolRouteOutcome::ApprovalRequired(request)),
            PolicyDecision::Deny(reason) => Ok(ToolRouteOutcome::Denied(ToolResult {
                display_text: reason.clone(),
                model_text: reason.clone(),
                structured_json: "{}".into(),
                audit_text: reason,
                sensitivity: Sensitivity::Public,
                retention: RetentionPolicy::RunOnly,
                is_error: true,
            })),
        }
    }
}
```

- [ ] **Step 3: Export, verify, commit**

Run:

```bash
cargo fmt
cargo test --test tool_router
cargo test
```

Commit:

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/rust-core/src/tool/router.rs local-ios-agent/rust-core/src/tool/mod.rs local-ios-agent/rust-core/tests/tool_router.rs
git commit -m "feat: add tool router"
```

## Task 5: Wire Router Into Runtime Boundary

**Files:**
- Modify: `local-ios-agent/rust-core/src/core/runtime.rs`
- Test: `local-ios-agent/rust-core/tests/runtime_tool_orchestration.rs`

- [ ] **Step 1: Write runtime orchestration test**

Create `tests/runtime_tool_orchestration.rs`:

```rust
use local_ios_agent_runtime::context::MockTokenizer;
use local_ios_agent_runtime::core::{AgentRuntime, AgentRuntimeConfig, MockStreamingProvider, RunState, SendMessageInput};
use local_ios_agent_runtime::security::RiskLevel;
use local_ios_agent_runtime::tool::{ToolRegistry, ToolRouter, ToolSchema};

#[test]
fn runtime_exposes_pending_swift_tool_request() {
    let mut registry = ToolRegistry::new();
    registry.register(ToolSchema {
        name: "debug.echo".into(),
        description: "Echo".into(),
        parameters_json_schema: r#"{"type":"object"}"#.into(),
        risk_level: RiskLevel::ReadOnly,
    }).unwrap();

    let mut runtime = AgentRuntime::new(AgentRuntimeConfig {
        system_prompt: "system".into(),
        runtime_policy: "policy".into(),
        tool_schemas: Vec::new(),
        tokenizer: Box::new(MockTokenizer::new(100)),
        provider: Box::new(MockStreamingProvider::new()),
        tool_router: Some(ToolRouter::new(registry)),
    });
    let session_id = runtime.create_session().unwrap();

    let result = runtime.send_message_turn(SendMessageInput {
        session_id,
        parent_event_id: None,
        text: "use tool debug.echo".into(),
    }).unwrap();

    assert_eq!(result.state, RunState::WaitingTool);
    assert!(runtime.pending_tool_requests().iter().any(|request| request.tool_name == "debug.echo"));
}
```

- [ ] **Step 2: Add runtime config router and pending request store**

Add to `AgentRuntimeConfig`:

```rust
pub tool_router: Option<ToolRouter>,
```

Add to runtime:

```rust
pending_tool_requests: Vec<ToolExecutionRequest>
```

Expose:

```rust
pub fn pending_tool_requests(&self) -> &[ToolExecutionRequest]
```

- [ ] **Step 3: Verify and commit**

Run:

```bash
cargo fmt
cargo test --test runtime_tool_orchestration
cargo test
```

Commit:

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/rust-core/src/core/runtime.rs local-ios-agent/rust-core/tests/runtime_tool_orchestration.rs
git commit -m "feat: wire tool router to runtime"
```

## Exit Criteria

- Tool calls can be parsed from JSON.
- Tool schemas can be registered and rendered for prompt injection.
- Router can produce Swift execution requests.
- Router can deny tools as recoverable tool results.
- Runtime can expose pending Swift tool requests.
- Runtime can accept Swift tool result through Plan 3 `submit_tool_result`.
- `cargo test` passes.
