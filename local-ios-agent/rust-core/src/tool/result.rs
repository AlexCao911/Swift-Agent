#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Sensitivity {
    Public,
    Private,
    Secret,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum RetentionPolicy {
    RunOnly,
    Session,
    MemoryCandidate,
    AuditOnly,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ToolResult {
    pub display_text: String,
    pub model_text: String,
    pub structured_json: String,
    pub audit_text: String,
    pub sensitivity: Sensitivity,
    pub retention: RetentionPolicy,
    pub is_error: bool,
}
