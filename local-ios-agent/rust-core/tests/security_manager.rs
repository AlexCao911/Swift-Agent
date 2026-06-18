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
