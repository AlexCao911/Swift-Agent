use serde_json::{json, Value};

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

impl ToolResult {
    pub fn to_event_payload(&self) -> String {
        json!({
            "type": "tool_result",
            "display_text": self.display_text,
            "model_text": self.model_text,
            "structured_json": self.structured_json,
            "audit_text": self.audit_text,
            "sensitivity": self.sensitivity.as_str(),
            "retention": self.retention.as_str(),
            "is_error": self.is_error,
        })
        .to_string()
    }

    pub fn from_event_payload(payload: &str) -> Option<Self> {
        let value: Value = serde_json::from_str(payload).ok()?;
        if value.get("type").and_then(Value::as_str) != Some("tool_result") {
            return None;
        }

        Some(Self {
            display_text: value.get("display_text")?.as_str()?.to_string(),
            model_text: value.get("model_text")?.as_str()?.to_string(),
            structured_json: value.get("structured_json")?.as_str()?.to_string(),
            audit_text: value.get("audit_text")?.as_str()?.to_string(),
            sensitivity: Sensitivity::from_str(value.get("sensitivity")?.as_str()?)?,
            retention: RetentionPolicy::from_str(value.get("retention")?.as_str()?)?,
            is_error: value.get("is_error")?.as_bool()?,
        })
    }
}

impl Sensitivity {
    fn as_str(&self) -> &'static str {
        match self {
            Self::Public => "public",
            Self::Private => "private",
            Self::Secret => "secret",
        }
    }

    fn from_str(value: &str) -> Option<Self> {
        match value {
            "public" => Some(Self::Public),
            "private" => Some(Self::Private),
            "secret" => Some(Self::Secret),
            _ => None,
        }
    }
}

impl RetentionPolicy {
    fn as_str(&self) -> &'static str {
        match self {
            Self::RunOnly => "run_only",
            Self::Session => "session",
            Self::MemoryCandidate => "memory_candidate",
            Self::AuditOnly => "audit_only",
        }
    }

    fn from_str(value: &str) -> Option<Self> {
        match value {
            "run_only" => Some(Self::RunOnly),
            "session" => Some(Self::Session),
            "memory_candidate" => Some(Self::MemoryCandidate),
            "audit_only" => Some(Self::AuditOnly),
            _ => None,
        }
    }
}
