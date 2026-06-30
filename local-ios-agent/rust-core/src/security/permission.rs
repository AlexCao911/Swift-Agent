use std::collections::BTreeMap;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PermissionState {
    NotDetermined,
    Granted,
    Denied,
    Restricted,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PermissionScope {
    pub name: String,
    pub state: PermissionState,
}

#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct CapabilityRequirement(String);

impl CapabilityRequirement {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PermissionReadinessReport {
    states: BTreeMap<CapabilityRequirement, PermissionState>,
}

impl PermissionReadinessReport {
    pub fn new(states: BTreeMap<CapabilityRequirement, PermissionState>) -> Self {
        Self { states }
    }

    pub fn is_ready(&self) -> bool {
        self.states
            .values()
            .all(|state| *state == PermissionState::Granted)
    }

    pub fn state_for(&self, capability: &str) -> Option<PermissionState> {
        self.states
            .get(&CapabilityRequirement::new(capability))
            .cloned()
    }
}
