#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProviderDefinition {
    id: String,
    display_name: String,
}

impl ProviderDefinition {
    pub fn new(id: impl Into<String>, display_name: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            display_name: display_name.into(),
        }
    }

    pub fn id(&self) -> &str {
        &self.id
    }

    pub fn display_name(&self) -> &str {
        &self.display_name
    }
}
