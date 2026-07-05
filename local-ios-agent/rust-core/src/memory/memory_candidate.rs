use crate::core::AgentError;
use crate::memory::{Confidence, SensitivityLevel};

#[derive(Clone, Debug, PartialEq)]
pub struct MemoryCandidate {
    pub text: String,
    pub confirmed: bool,
    source_event_id: Option<String>,
    kind: Option<String>,
    confidence: Option<Confidence>,
    sensitivity: SensitivityLevel,
    review_state: MemoryReviewState,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MemoryReviewState {
    Pending,
    Approved,
    Rejected,
}

impl MemoryCandidate {
    pub fn new(text: impl Into<String>) -> Self {
        Self {
            text: text.into(),
            confirmed: false,
            source_event_id: None,
            kind: None,
            confidence: None,
            sensitivity: SensitivityLevel::Normal,
            review_state: MemoryReviewState::Pending,
        }
    }

    pub(crate) fn persisted(text: impl Into<String>, confirmed: bool) -> Self {
        let mut candidate = Self::new(text);
        candidate.confirmed = confirmed;
        candidate.review_state = if confirmed {
            MemoryReviewState::Approved
        } else {
            MemoryReviewState::Pending
        };
        candidate
    }

    pub fn confirm(mut self) -> Self {
        self.confirmed = true;
        self.review_state = MemoryReviewState::Approved;
        self
    }

    pub fn reject(mut self) -> Self {
        self.confirmed = false;
        self.review_state = MemoryReviewState::Rejected;
        self
    }

    pub fn with_source_event_id(mut self, source_event_id: impl Into<String>) -> Self {
        self.source_event_id = Some(source_event_id.into());
        self
    }

    pub fn with_kind(mut self, kind: impl Into<String>) -> Self {
        self.kind = Some(kind.into());
        self
    }

    pub fn with_confidence(mut self, confidence: f32) -> Result<Self, AgentError> {
        self.confidence = Some(Confidence::new(confidence)?);
        Ok(self)
    }

    pub fn with_sensitivity(mut self, sensitivity: SensitivityLevel) -> Self {
        self.sensitivity = sensitivity;
        self
    }

    pub fn source_event_id(&self) -> Option<&str> {
        self.source_event_id.as_deref()
    }

    pub fn kind(&self) -> Option<&str> {
        self.kind.as_deref()
    }

    pub fn confidence(&self) -> Option<Confidence> {
        self.confidence
    }

    pub fn sensitivity(&self) -> SensitivityLevel {
        self.sensitivity
    }

    pub fn review_state(&self) -> MemoryReviewState {
        self.review_state
    }
}
