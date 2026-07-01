#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct SafetyReview {
    findings: Vec<SafetyReviewFinding>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SafetyReviewFinding {
    code: String,
    message: String,
    requires_user_review: bool,
}

impl SafetyReview {
    pub fn ready() -> Self {
        Self::default()
    }

    pub fn fixture_high_egress_risk() -> Self {
        Self::ready().finding(SafetyReviewFinding::user_review_required(
            "safety.egress.high",
            "selected components may send data to external services",
        ))
    }

    pub fn finding(mut self, finding: SafetyReviewFinding) -> Self {
        self.findings.push(finding);
        self
    }

    pub fn findings(&self) -> &[SafetyReviewFinding] {
        &self.findings
    }

    pub fn requires_user_review(&self) -> bool {
        self.findings
            .iter()
            .any(SafetyReviewFinding::requires_user_review)
    }
}

impl SafetyReviewFinding {
    pub fn user_review_required(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
            requires_user_review: true,
        }
    }

    pub fn code(&self) -> &str {
        &self.code
    }

    pub fn message(&self) -> &str {
        &self.message
    }

    pub fn requires_user_review(&self) -> bool {
        self.requires_user_review
    }
}
