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
use local_ios_agent_runtime::security::{ApprovalQueue, ApprovalRequest, ApprovalScope};

#[test]
fn approval_queue_tracks_pending_requests() {
    let mut queue = ApprovalQueue::new();
    queue
        .push(ApprovalRequest {
            approval_id: "approval_1".into(),
            run_id: RunId("run_1".into()),
            tool_call_entry_id: EntryId("entry_1".into()),
            message: "Allow?".into(),
            requires_local_authentication: false,
            scope: ApprovalScope::operation(
                local_ios_agent_runtime::security::OperationDescriptor::new("tool.calendar"),
            ),
        })
        .unwrap();

    assert_eq!(queue.pending().len(), 1);
    assert!(queue.take("approval_1").is_some());
    assert!(queue.pending().is_empty());
}

#[test]
fn approval_queue_rejects_duplicate_pending_ids() {
    let mut queue = ApprovalQueue::new();
    queue
        .push(ApprovalRequest {
            approval_id: "approval_1".into(),
            run_id: RunId("run_1".into()),
            tool_call_entry_id: EntryId("entry_1".into()),
            message: "Allow first?".into(),
            requires_local_authentication: false,
            scope: ApprovalScope::operation(
                local_ios_agent_runtime::security::OperationDescriptor::new("tool.calendar"),
            ),
        })
        .unwrap();

    let error = queue
        .push(ApprovalRequest {
            approval_id: "approval_1".into(),
            run_id: RunId("run_1".into()),
            tool_call_entry_id: EntryId("entry_2".into()),
            message: "Allow replacement?".into(),
            requires_local_authentication: false,
            scope: ApprovalScope::operation(
                local_ios_agent_runtime::security::OperationDescriptor::new("tool.reminders"),
            ),
        })
        .unwrap_err();

    assert!(error.to_string().contains("duplicate approval id"));
    assert_eq!(queue.pending().len(), 1);
    assert_eq!(
        queue.pending()[0].tool_call_entry_id,
        EntryId("entry_1".into())
    );
}

#[test]
fn security_manager_rejects_duplicate_pending_approval_ids() {
    let mut manager = SecurityManager::new();
    manager
        .request_approval(
            "approval_1",
            RunId("run_1".into()),
            EntryId("entry_1".into()),
            "Allow first?",
            false,
            ApprovalScope::operation(local_ios_agent_runtime::security::OperationDescriptor::new(
                "tool.calendar",
            )),
        )
        .unwrap();

    let error = manager
        .request_approval(
            "approval_1",
            RunId("run_1".into()),
            EntryId("entry_2".into()),
            "Allow replacement?",
            false,
            ApprovalScope::operation(local_ios_agent_runtime::security::OperationDescriptor::new(
                "tool.reminders",
            )),
        )
        .unwrap_err();

    assert!(error.to_string().contains("duplicate approval id"));
    assert_eq!(manager.pending_approvals().len(), 1);
    assert_eq!(
        manager.pending_approvals()[0].tool_call_entry_id,
        EntryId("entry_1".into())
    );
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
fn policy_denies_when_permission_is_denied_or_restricted() {
    let engine = PolicyEngine::default();

    assert!(matches!(
        engine.decide_with_permission(
            &RiskLevel::ReadOnly,
            "calendar.search_events",
            PermissionState::Denied,
        ),
        PolicyDecision::Deny(_)
    ));
    assert!(matches!(
        engine.decide_with_permission(
            &RiskLevel::ReadOnly,
            "calendar.search_events",
            PermissionState::Restricted,
        ),
        PolicyDecision::Deny(_)
    ));
}

#[test]
fn policy_granted_permission_falls_back_to_tool_risk() {
    let engine = PolicyEngine::default();

    assert!(matches!(
        engine.decide_with_permission(
            &RiskLevel::Destructive,
            "files.delete_all",
            PermissionState::Granted,
        ),
        PolicyDecision::Deny(_)
    ));
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
    let request = manager
        .request_approval(
            "approval_1",
            RunId("run_1".into()),
            EntryId("entry_1".into()),
            "Allow write?",
            true,
            ApprovalScope::operation(local_ios_agent_runtime::security::OperationDescriptor::new(
                "tool.write",
            )),
        )
        .unwrap();

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

#[test]
fn security_manager_decides_tool_with_configured_permission_scope() {
    let mut manager = SecurityManager::new();
    manager.set_tool_permission_scope("calendar.search_events", "calendar.read");

    assert!(matches!(
        manager.decide_tool(&RiskLevel::ReadOnly, "calendar.search_events"),
        PolicyDecision::RequireApproval(_)
    ));

    manager.set_permission(PermissionScope {
        name: "calendar.read".into(),
        state: PermissionState::Granted,
    });

    assert_eq!(
        manager.decide_tool(&RiskLevel::ReadOnly, "calendar.search_events"),
        PolicyDecision::Allow
    );
}
