use local_ios_agent_runtime::core::{EntryId, RunId};
use local_ios_agent_runtime::security::{ApprovalProtocolRequest, ApprovalProtocolResponse};

#[test]
fn approval_protocol_carries_local_authentication_requirement() {
    let request = ApprovalProtocolRequest {
        approval_id: "approval_1".into(),
        run_id: RunId("run_1".into()),
        tool_call_entry_id: EntryId("entry_1".into()),
        message: "Allow reminder?".into(),
        requires_local_authentication: true,
    };

    let response = ApprovalProtocolResponse {
        approval_id: request.approval_id.clone(),
        approved: true,
        reason: None,
    };

    assert!(request.requires_local_authentication);
    assert_eq!(request.run_id, RunId("run_1".into()));
    assert_eq!(request.tool_call_entry_id, EntryId("entry_1".into()));
    assert!(response.approved);
}
