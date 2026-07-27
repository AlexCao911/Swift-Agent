#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct UserProvidedBindings;

impl UserProvidedBindings {
    pub fn empty() -> Self {
        Self
    }

    pub fn credential(
        self,
        _binding_key: impl Into<String>,
        _reference: impl Into<String>,
    ) -> Self {
        self
    }
}
