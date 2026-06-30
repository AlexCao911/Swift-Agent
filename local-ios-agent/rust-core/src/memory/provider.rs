use crate::memory::MemoryContribution;

#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct MemoryProviderId(String);

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MemoryQuery {
    text: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct MemoryQueryResult {
    pub contributions: Vec<MemoryContribution>,
    pub trace: MemoryRetrievalTrace,
    pub readiness_issues: Vec<MemoryReadinessIssue>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MemoryRetrievalTrace {
    provider_id: Option<MemoryProviderId>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MemoryReadinessIssue {
    provider_id: MemoryProviderId,
    code: String,
    message: String,
}

pub trait MemoryProvider: std::fmt::Debug + Send + Sync {
    fn provider_id(&self) -> MemoryProviderId;
    fn query(&self, query: &MemoryQuery) -> MemoryQueryResult;
}

impl MemoryProviderId {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl MemoryQuery {
    pub fn new(text: impl Into<String>) -> Self {
        Self { text: text.into() }
    }

    pub fn text(&self) -> &str {
        &self.text
    }
}

impl MemoryQueryResult {
    pub fn from_contributions(contributions: Vec<MemoryContribution>) -> Self {
        let trace = MemoryRetrievalTrace::empty();
        Self {
            contributions,
            trace,
            readiness_issues: Vec::new(),
        }
    }

    pub fn with_trace(mut self, trace: MemoryRetrievalTrace) -> Self {
        self.trace = trace;
        self
    }

    pub fn with_readiness_issue(mut self, issue: MemoryReadinessIssue) -> Self {
        self.readiness_issues.push(issue);
        self
    }
}

impl MemoryRetrievalTrace {
    pub fn empty() -> Self {
        Self { provider_id: None }
    }

    pub fn provider(provider_id: MemoryProviderId) -> Self {
        Self {
            provider_id: Some(provider_id),
        }
    }

    pub fn provider_id(&self) -> Option<&MemoryProviderId> {
        self.provider_id.as_ref()
    }
}

impl MemoryReadinessIssue {
    pub fn blocked(provider_id: MemoryProviderId, message: impl Into<String>) -> Self {
        Self {
            provider_id,
            code: "memory.provider_blocked".to_string(),
            message: message.into(),
        }
    }

    pub fn provider_id(&self) -> &MemoryProviderId {
        &self.provider_id
    }

    pub fn code(&self) -> &str {
        &self.code
    }

    pub fn message(&self) -> &str {
        &self.message
    }
}
