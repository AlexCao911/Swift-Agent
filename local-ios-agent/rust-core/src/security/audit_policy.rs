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
