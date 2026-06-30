use std::collections::BTreeMap;

use crate::security::RedactedSecret;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SecurityAuditEvent {
    event_type: String,
    fields: BTreeMap<String, String>,
}

impl SecurityAuditEvent {
    pub fn new(event_type: impl Into<String>) -> Self {
        Self {
            event_type: event_type.into(),
            fields: BTreeMap::new(),
        }
    }

    pub fn event_type(&self) -> &str {
        &self.event_type
    }

    pub fn with_redacted_field(mut self, name: impl Into<String>, value: RedactedSecret) -> Self {
        self.fields.insert(name.into(), value.as_str().to_string());
        self
    }

    pub fn field(&self, name: &str) -> Option<&str> {
        self.fields.get(name).map(String::as_str)
    }
}
