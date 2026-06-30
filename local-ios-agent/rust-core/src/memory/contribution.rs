use crate::core::AgentError;

#[derive(Clone, Debug, PartialEq)]
pub struct MemoryContribution {
    pub id: MemoryContributionId,
    pub content: String,
    pub provenance: Provenance,
    pub confidence: Confidence,
    pub sensitivity: SensitivityLevel,
}

#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct MemoryContributionId(String);

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Provenance {
    source_kind: ProvenanceSourceKind,
    source_id: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ProvenanceSourceKind {
    Local,
    External,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Confidence(f32);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SensitivityLevel {
    Public,
    Normal,
    Sensitive,
    Secret,
}

#[derive(Clone, Debug)]
pub struct MemoryContributionBuilder {
    content: String,
    id: Option<MemoryContributionId>,
    provenance: Option<Provenance>,
    confidence: Option<f32>,
    sensitivity: Option<SensitivityLevel>,
}

impl MemoryContribution {
    pub fn new(content: impl Into<String>) -> MemoryContributionBuilder {
        MemoryContributionBuilder {
            content: content.into(),
            id: None,
            provenance: None,
            confidence: None,
            sensitivity: None,
        }
    }
}

impl MemoryContributionId {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl MemoryContributionBuilder {
    pub fn with_id(mut self, id: MemoryContributionId) -> Self {
        self.id = Some(id);
        self
    }

    pub fn with_provenance(mut self, provenance: Provenance) -> Self {
        self.provenance = Some(provenance);
        self
    }

    pub fn with_confidence(mut self, confidence: f32) -> Self {
        self.confidence = Some(confidence);
        self
    }

    pub fn with_sensitivity(mut self, sensitivity: SensitivityLevel) -> Self {
        self.sensitivity = Some(sensitivity);
        self
    }

    pub fn build(self) -> Result<MemoryContribution, AgentError> {
        let id = self
            .id
            .ok_or_else(|| AgentError::Storage("memory contribution requires id".to_string()))?;
        let provenance = self.provenance.ok_or_else(|| {
            AgentError::Storage("memory contribution requires provenance".to_string())
        })?;
        let confidence = self.confidence.ok_or_else(|| {
            AgentError::Storage("memory contribution requires confidence".to_string())
        })?;
        let confidence = Confidence::new(confidence)?;
        let sensitivity = self.sensitivity.ok_or_else(|| {
            AgentError::Storage("memory contribution requires sensitivity".to_string())
        })?;

        Ok(MemoryContribution {
            id,
            content: self.content,
            provenance,
            confidence,
            sensitivity,
        })
    }
}

impl Provenance {
    pub fn local(source_id: impl Into<String>) -> Self {
        Self {
            source_kind: ProvenanceSourceKind::Local,
            source_id: source_id.into(),
        }
    }

    pub fn external(source_id: impl Into<String>) -> Self {
        Self {
            source_kind: ProvenanceSourceKind::External,
            source_id: source_id.into(),
        }
    }

    pub fn source_id(&self) -> &str {
        &self.source_id
    }

    pub fn source_kind(&self) -> &ProvenanceSourceKind {
        &self.source_kind
    }
}

impl Confidence {
    fn new(value: f32) -> Result<Self, AgentError> {
        if !(0.0..=1.0).contains(&value) || value.is_nan() {
            return Err(AgentError::Storage(format!(
                "memory contribution confidence must be between 0.0 and 1.0: {value}"
            )));
        }
        Ok(Self(value))
    }

    pub fn value(self) -> f32 {
        self.0
    }
}

impl PartialEq<f32> for Confidence {
    fn eq(&self, other: &f32) -> bool {
        self.0 == *other
    }
}
