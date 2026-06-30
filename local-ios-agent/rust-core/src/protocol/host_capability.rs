use std::collections::BTreeSet;

#[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd, Hash)]
pub struct HostCapability(String);

impl HostCapability {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl From<&str> for HostCapability {
    fn from(value: &str) -> Self {
        Self::new(value)
    }
}

impl From<String> for HostCapability {
    fn from(value: String) -> Self {
        Self::new(value)
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct HostCapabilityManifest {
    capabilities: BTreeSet<HostCapability>,
}

impl HostCapabilityManifest {
    pub fn new(capabilities: impl IntoIterator<Item = impl Into<HostCapability>>) -> Self {
        Self {
            capabilities: capabilities.into_iter().map(Into::into).collect(),
        }
    }

    pub fn all_supported() -> Self {
        Self::new(["native_inference", "keychain", "network"])
    }

    pub fn supports(&self, capability: &str) -> bool {
        self.capabilities
            .iter()
            .any(|candidate| candidate.as_str() == capability)
    }
}
