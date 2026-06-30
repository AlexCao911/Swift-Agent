#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DefinitionCompatibility {
    compatible: bool,
    reason: Option<String>,
}

impl DefinitionCompatibility {
    pub fn compatible() -> Self {
        Self {
            compatible: true,
            reason: None,
        }
    }

    pub fn incompatible(reason: impl Into<String>) -> Self {
        Self {
            compatible: false,
            reason: Some(reason.into()),
        }
    }

    pub fn is_compatible(&self) -> bool {
        self.compatible
    }

    pub fn reason(&self) -> Option<&str> {
        self.reason.as_deref()
    }
}
