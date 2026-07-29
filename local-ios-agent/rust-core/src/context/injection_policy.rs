use crate::tool::{RetentionPolicy, Sensitivity, ToolResult};

#[derive(Clone, Debug, Default)]
pub struct ContextInjectionPolicy {
    pub include_secret_results: bool,
}

impl ContextInjectionPolicy {
    pub fn should_inject_tool_result(&self, result: &ToolResult) -> bool {
        result.retention != RetentionPolicy::AuditOnly
            && (result.sensitivity != Sensitivity::Secret || self.include_secret_results)
    }
}
