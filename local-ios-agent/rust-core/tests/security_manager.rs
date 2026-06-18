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

use local_ios_agent_runtime::security::AuditPolicy;

#[test]
fn audit_policy_requires_audit_for_tools_and_approvals() {
    assert!(AuditPolicy::default().should_audit_event("ToolExecutionCompleted"));
    assert!(AuditPolicy::default().should_audit_event("RunSuspended"));
    assert!(!AuditPolicy::default().should_audit_event("AssistantTextDelta"));
}

use local_ios_agent_runtime::security::SecurityManager;

#[test]
fn security_manager_queues_local_auth_approval() {
    let mut manager = SecurityManager::new();
    let request = manager.request_approval("approval_1", "Allow write?", true);

    assert!(request.requires_local_authentication);
    assert_eq!(manager.pending_approvals().len(), 1);
}

#[test]
fn security_manager_tracks_permission_state_by_scope_name() {
    let mut manager = SecurityManager::new();

    assert_eq!(
        manager.permission_state("calendar.read"),
        PermissionState::NotDetermined
    );

    manager.set_permission(PermissionScope {
        name: "calendar.read".into(),
        state: PermissionState::Granted,
    });

    assert_eq!(
        manager.permission_state("calendar.read"),
        PermissionState::Granted
    );
}
