#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct AgentReadinessReport {
    issues: Vec<AgentReadinessIssue>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgentReadinessIssue {
    code: String,
    message: String,
}

impl AgentReadinessReport {
    pub fn ready() -> Self {
        Self::default()
    }

    pub fn push_issue(&mut self, issue: AgentReadinessIssue) {
        self.issues.push(issue);
    }

    pub fn has_issue(&self, code: &str) -> bool {
        self.issues.iter().any(|issue| issue.code == code)
    }

    pub fn issues(&self) -> &[AgentReadinessIssue] {
        &self.issues
    }

    pub fn is_ready(&self) -> bool {
        self.issues.is_empty()
    }
}

impl AgentReadinessIssue {
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }

    pub fn code(&self) -> &str {
        &self.code
    }

    pub fn message(&self) -> &str {
        &self.message
    }
}
