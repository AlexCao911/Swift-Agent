# Security Manager Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Rust security manager layer: policy engine, permission scopes, per-tool risk policy, approval pending queue, audit log writing policy, Rust-Swift approval protocol, and LocalAuthentication integration-point protocol.

**Architecture:** Rust owns security decisions and approval state. Swift owns native UI, LocalAuthentication, and iOS permission prompts. The boundary is an explicit approval request/decision protocol that can later be exposed over UniFFI without blocking the agent loop thread.

**Tech Stack:** Rust 2021, existing `PolicyEngine`, `ApprovalRequest`, `ApprovalDecision`, `RiskLevel`, `ToolSchema`, SQLite audit APIs from Plan 6, `cargo test`, TDD.

---

## Current Code Audit

Checked current code with:

```bash
rg -n "PolicyEngine|RiskLevel|ApprovalRequest|ApprovalDecision|PermissionScope|ApprovalQueue|LocalAuthentication|audit" local-ios-agent/rust-core/src local-ios-agent/rust-core/tests
sed -n '1,260p' local-ios-agent/rust-core/src/security/policy.rs
sed -n '1,260p' local-ios-agent/rust-core/src/security/approval.rs
```

Observed:

- `RiskLevel` has `ReadOnly`, `Confirm`, and `Destructive`.
- `PolicyEngine::decide` exists but is simple and does not know permission
  state, tool-specific policy, audit requirements, or LocalAuthentication.
- `ApprovalRequest`, `ApprovalDecision`, and `SuspendedRun` exist.
- No `ApprovalQueue`, `PermissionScope`, `SecurityManager`, audit policy, or
  Rust-Swift approval protocol exists.

Assigned to this plan:

- Security manager facade.
- Permission scopes and states.
- Per-tool risk policy.
- Approval queue.
- Audit log writing policy.
- Approval protocol DTOs for Swift.
- LocalAuthentication requirement modeling.

Deferred:

- Actual LocalAuthentication call: Swift Native Toolkit plan.
- UniFFI exposure: later bridge plan.
- SQLCipher/Data Protection: later hardening after iOS storage path is final.

## File Structure

Create:

```text
local-ios-agent/rust-core/src/security/manager.rs
local-ios-agent/rust-core/src/security/permission.rs
local-ios-agent/rust-core/src/security/approval_queue.rs
local-ios-agent/rust-core/src/security/approval_protocol.rs
local-ios-agent/rust-core/src/security/audit_policy.rs
local-ios-agent/rust-core/tests/security_manager.rs
local-ios-agent/rust-core/tests/security_approval_protocol.rs
```

Modify:

```text
local-ios-agent/rust-core/src/security/mod.rs
local-ios-agent/rust-core/src/security/policy.rs
local-ios-agent/rust-core/src/core/runtime.rs
```

## Task 1: Add Permission Scope Model

**Files:**
- Create: `local-ios-agent/rust-core/src/security/permission.rs`
- Modify: `local-ios-agent/rust-core/src/security/mod.rs`
- Test: `local-ios-agent/rust-core/tests/security_manager.rs`

- [ ] **Step 1: Write failing permission test**

Create `tests/security_manager.rs`:

```rust
use local_ios_agent_runtime::security::{PermissionScope, PermissionState};

#[test]
fn permission_scope_models_ios_permission_state() {
    let scope = PermissionScope {
        name: "calendar.read".into(),
        state: PermissionState::NotDetermined,
    };

    assert_eq!(scope.name, "calendar.read");
    assert_eq!(scope.state, PermissionState::NotDetermined);
}
```

- [ ] **Step 2: Implement permission types**

Create `src/security/permission.rs`:

```rust
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PermissionState {
    NotDetermined,
    Granted,
    Denied,
    Restricted,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PermissionScope {
    pub name: String,
    pub state: PermissionState,
}
```

- [ ] **Step 3: Export and verify**

Modify `src/security/mod.rs`:

```rust
pub mod permission;
pub use permission::{PermissionScope, PermissionState};
```

Run:

```bash
cargo fmt
cargo test --test security_manager permission_scope_models_ios_permission_state
cargo test
```

- [ ] **Step 4: Commit**

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/rust-core/src/security/permission.rs local-ios-agent/rust-core/src/security/mod.rs local-ios-agent/rust-core/tests/security_manager.rs
git commit -m "feat: add permission scopes"
```

## Task 2: Add Approval Queue

**Files:**
- Create: `local-ios-agent/rust-core/src/security/approval_queue.rs`
- Modify: `local-ios-agent/rust-core/src/security/mod.rs`
- Modify: `local-ios-agent/rust-core/tests/security_manager.rs`

- [ ] **Step 1: Add failing queue test**

Append:

```rust
use local_ios_agent_runtime::core::{EntryId, RunId};
use local_ios_agent_runtime::security::{ApprovalQueue, ApprovalRequest};

#[test]
fn approval_queue_tracks_pending_requests() {
    let mut queue = ApprovalQueue::new();
    queue.push(ApprovalRequest {
        approval_id: "approval_1".into(),
        run_id: RunId("run_1".into()),
        tool_call_id: EntryId("entry_1".into()),
        message: "Allow?".into(),
    });

    assert_eq!(queue.pending().len(), 1);
    assert!(queue.take("approval_1").is_some());
    assert!(queue.pending().is_empty());
}
```

- [ ] **Step 2: Implement queue**

Create `src/security/approval_queue.rs`:

```rust
use std::collections::HashMap;

use crate::security::ApprovalRequest;

#[derive(Clone, Debug, Default)]
pub struct ApprovalQueue {
    pending: HashMap<String, ApprovalRequest>,
}

impl ApprovalQueue {
    pub fn new() -> Self { Self::default() }

    pub fn push(&mut self, request: ApprovalRequest) {
        self.pending.insert(request.approval_id.clone(), request);
    }

    pub fn pending(&self) -> Vec<ApprovalRequest> {
        let mut pending: Vec<_> = self.pending.values().cloned().collect();
        pending.sort_by(|left, right| left.approval_id.cmp(&right.approval_id));
        pending
    }

    pub fn take(&mut self, approval_id: &str) -> Option<ApprovalRequest> {
        self.pending.remove(approval_id)
    }
}
```

- [ ] **Step 3: Export, verify, commit**

Run:

```bash
cargo fmt
cargo test --test security_manager approval_queue_tracks_pending_requests
cargo test
```

Commit:

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/rust-core/src/security/approval_queue.rs local-ios-agent/rust-core/src/security/mod.rs local-ios-agent/rust-core/tests/security_manager.rs
git commit -m "feat: add approval queue"
```

## Task 3: Upgrade Policy Engine

**Files:**
- Modify: `local-ios-agent/rust-core/src/security/policy.rs`
- Modify: `local-ios-agent/rust-core/tests/security_manager.rs`

- [ ] **Step 1: Add policy tests**

Append:

```rust
use local_ios_agent_runtime::security::{PolicyDecision, PolicyEngine, RiskLevel};

#[test]
fn policy_requires_approval_when_permission_is_not_granted() {
    let engine = PolicyEngine::default();
    let decision = engine.decide_with_permission(
        &RiskLevel::ReadOnly,
        "calendar.search_events",
        PermissionState::NotDetermined,
    );

    assert!(matches!(decision, PolicyDecision::RequireApproval(_)));
}

#[test]
fn policy_denies_destructive_tools() {
    let engine = PolicyEngine::default();

    assert!(matches!(
        engine.decide(&RiskLevel::Destructive, "files.delete_all"),
        PolicyDecision::Deny(_)
    ));
}
```

- [ ] **Step 2: Implement permission-aware policy**

Add to `PolicyEngine`:

```rust
pub fn decide_with_permission(
    &self,
    risk_level: &RiskLevel,
    tool_name: &str,
    permission_state: PermissionState,
) -> PolicyDecision
```

Rules:

- `PermissionState::Denied` or `Restricted` returns `Deny`.
- `PermissionState::NotDetermined` returns `RequireApproval`.
- `PermissionState::Granted` falls back to `decide`.

- [ ] **Step 3: Verify and commit**

Run:

```bash
cargo fmt
cargo test --test security_manager policy_requires_approval_when_permission_is_not_granted
cargo test
```

Commit:

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/rust-core/src/security/policy.rs local-ios-agent/rust-core/tests/security_manager.rs
git commit -m "feat: add permission aware policy"
```

## Task 4: Add Rust-Swift Approval Protocol

**Files:**
- Create: `local-ios-agent/rust-core/src/security/approval_protocol.rs`
- Modify: `local-ios-agent/rust-core/src/security/mod.rs`
- Test: `local-ios-agent/rust-core/tests/security_approval_protocol.rs`

- [ ] **Step 1: Write protocol test**

Create `tests/security_approval_protocol.rs`:

```rust
use local_ios_agent_runtime::security::{ApprovalProtocolRequest, ApprovalProtocolResponse};

#[test]
fn approval_protocol_carries_local_authentication_requirement() {
    let request = ApprovalProtocolRequest {
        approval_id: "approval_1".into(),
        message: "Allow reminder?".into(),
        requires_local_authentication: true,
    };

    let response = ApprovalProtocolResponse {
        approval_id: request.approval_id.clone(),
        approved: true,
        reason: None,
    };

    assert!(request.requires_local_authentication);
    assert!(response.approved);
}
```

- [ ] **Step 2: Implement protocol DTOs**

Create `src/security/approval_protocol.rs`:

```rust
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ApprovalProtocolRequest {
    pub approval_id: String,
    pub message: String,
    pub requires_local_authentication: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ApprovalProtocolResponse {
    pub approval_id: String,
    pub approved: bool,
    pub reason: Option<String>,
}
```

- [ ] **Step 3: Export and commit**

Run:

```bash
cargo fmt
cargo test --test security_approval_protocol
cargo test
```

Commit:

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/rust-core/src/security/approval_protocol.rs local-ios-agent/rust-core/src/security/mod.rs local-ios-agent/rust-core/tests/security_approval_protocol.rs
git commit -m "feat: add approval protocol dto"
```

## Task 5: Add Audit Policy

**Files:**
- Create: `local-ios-agent/rust-core/src/security/audit_policy.rs`
- Modify: `local-ios-agent/rust-core/src/security/mod.rs`
- Modify: `local-ios-agent/rust-core/tests/security_manager.rs`

- [ ] **Step 1: Add audit policy test**

Append:

```rust
use local_ios_agent_runtime::security::AuditPolicy;

#[test]
fn audit_policy_requires_audit_for_tools_and_approvals() {
    assert!(AuditPolicy::default().should_audit_event("ToolExecutionCompleted"));
    assert!(AuditPolicy::default().should_audit_event("RunSuspended"));
    assert!(!AuditPolicy::default().should_audit_event("AssistantTextDelta"));
}
```

- [ ] **Step 2: Implement audit policy**

Create `src/security/audit_policy.rs`:

```rust
#[derive(Clone, Debug, Default)]
pub struct AuditPolicy;

impl AuditPolicy {
    pub fn should_audit_event(&self, event_kind: &str) -> bool {
        matches!(
            event_kind,
            "ToolCallRequested"
                | "ToolExecutionStarted"
                | "ToolExecutionCompleted"
                | "ToolExecutionFailed"
                | "ToolResultMessage"
                | "RunSuspended"
                | "RunResumed"
                | "ToolCallApproved"
                | "ToolCallRejected"
        )
    }
}
```

- [ ] **Step 3: Verify and commit**

Run:

```bash
cargo fmt
cargo test --test security_manager audit_policy_requires_audit_for_tools_and_approvals
cargo test
```

Commit:

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/rust-core/src/security/audit_policy.rs local-ios-agent/rust-core/src/security/mod.rs local-ios-agent/rust-core/tests/security_manager.rs
git commit -m "feat: add audit policy"
```

## Task 6: Add SecurityManager Facade

**Files:**
- Create: `local-ios-agent/rust-core/src/security/manager.rs`
- Modify: `local-ios-agent/rust-core/src/security/mod.rs`
- Modify: `local-ios-agent/rust-core/tests/security_manager.rs`

- [ ] **Step 1: Add manager test**

Append:

```rust
use local_ios_agent_runtime::security::SecurityManager;

#[test]
fn security_manager_queues_local_auth_approval() {
    let mut manager = SecurityManager::new();
    let request = manager.request_approval(
        "approval_1",
        "Allow write?",
        true,
    );

    assert!(request.requires_local_authentication);
    assert_eq!(manager.pending_approvals().len(), 1);
}
```

- [ ] **Step 2: Implement facade**

Create `src/security/manager.rs`:

```rust
use crate::core::{EntryId, RunId};
use crate::security::{
    ApprovalProtocolRequest, ApprovalQueue, ApprovalRequest, AuditPolicy, PermissionScope,
    PermissionState, PolicyEngine,
};

#[derive(Clone, Debug)]
pub struct SecurityManager {
    pub policy: PolicyEngine,
    pub audit_policy: AuditPolicy,
    approvals: ApprovalQueue,
    permissions: Vec<PermissionScope>,
}

impl SecurityManager {
    pub fn new() -> Self {
        Self {
            policy: PolicyEngine::default(),
            audit_policy: AuditPolicy::default(),
            approvals: ApprovalQueue::new(),
            permissions: Vec::new(),
        }
    }

    pub fn set_permission(&mut self, scope: PermissionScope) {
        self.permissions.retain(|existing| existing.name != scope.name);
        self.permissions.push(scope);
    }

    pub fn permission_state(&self, name: &str) -> PermissionState {
        self.permissions
            .iter()
            .find(|scope| scope.name == name)
            .map(|scope| scope.state.clone())
            .unwrap_or(PermissionState::NotDetermined)
    }

    pub fn request_approval(
        &mut self,
        approval_id: impl Into<String>,
        message: impl Into<String>,
        requires_local_authentication: bool,
    ) -> ApprovalProtocolRequest {
        let approval_id = approval_id.into();
        let message = message.into();
        self.approvals.push(ApprovalRequest {
            approval_id: approval_id.clone(),
            run_id: RunId("pending".into()),
            tool_call_id: EntryId("pending".into()),
            message: message.clone(),
        });
        ApprovalProtocolRequest {
            approval_id,
            message,
            requires_local_authentication,
        }
    }

    pub fn pending_approvals(&self) -> Vec<ApprovalRequest> {
        self.approvals.pending()
    }
}
```

- [ ] **Step 3: Verify and commit**

Run:

```bash
cargo fmt
cargo test --test security_manager security_manager_queues_local_auth_approval
cargo test
```

Commit:

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/rust-core/src/security/manager.rs local-ios-agent/rust-core/src/security/mod.rs local-ios-agent/rust-core/tests/security_manager.rs
git commit -m "feat: add security manager"
```

## Exit Criteria

- Permission scopes model iOS permission state.
- Approval queue tracks pending approvals.
- Policy engine considers permission state.
- Approval protocol DTO can carry LocalAuthentication requirement.
- Audit policy identifies security-sensitive runtime events.
- `SecurityManager` coordinates policy, permissions, approvals, and audit policy.
- `cargo test` passes.
