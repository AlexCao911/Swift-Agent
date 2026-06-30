use local_ios_agent_runtime::core::{EntryId, RunId};
use local_ios_agent_runtime::security::{
    ApprovalDecision, ApprovalRequest, ApprovalScope, OperationDescriptor, SuspendedRun,
};

#[test]
fn suspended_run_resumes_with_matching_approval_id() {
    let request = ApprovalRequest {
        approval_id: "approval_1".to_string(),
        run_id: RunId("run_1".to_string()),
        tool_call_entry_id: EntryId("tool_1".to_string()),
        message: "Allow reminder creation?".to_string(),
        requires_local_authentication: false,
        scope: ApprovalScope::operation(OperationDescriptor::new("tool.reminders.create")),
    };
    let mut suspended = SuspendedRun::new(request);

    let decision = suspended
        .submit_decision("approval_1", ApprovalDecision::Approved)
        .unwrap();

    assert_eq!(decision, ApprovalDecision::Approved);
    assert!(suspended.is_resolved());
}

#[test]
fn suspended_run_rejects_wrong_approval_id() {
    let request = ApprovalRequest {
        approval_id: "approval_1".to_string(),
        run_id: RunId("run_1".to_string()),
        tool_call_entry_id: EntryId("tool_1".to_string()),
        message: "Allow reminder creation?".to_string(),
        requires_local_authentication: false,
        scope: ApprovalScope::operation(OperationDescriptor::new("tool.reminders.create")),
    };
    let mut suspended = SuspendedRun::new(request);

    let error = suspended
        .submit_decision("approval_2", ApprovalDecision::Approved)
        .unwrap_err();

    assert!(error.to_string().contains("approval id mismatch"));
}
