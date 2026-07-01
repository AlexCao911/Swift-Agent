use crate::user_customization::AgentProfileLocalBindings;

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct UserProvidedBindings {
    local_bindings: AgentProfileLocalBindings,
}

impl UserProvidedBindings {
    pub fn empty() -> Self {
        Self::default()
    }

    pub fn credential(
        mut self,
        binding_key: impl Into<String>,
        credential_ref: impl Into<String>,
    ) -> Self {
        self.local_bindings = self
            .local_bindings
            .with_credential_ref(binding_key, credential_ref);
        self
    }

    pub fn credential_ref(&self, binding_key: &str) -> Option<&str> {
        self.local_bindings.credential_ref(binding_key)
    }

    pub(crate) fn into_local_bindings(self) -> AgentProfileLocalBindings {
        self.local_bindings
    }
}
