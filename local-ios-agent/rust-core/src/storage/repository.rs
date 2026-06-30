#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RepositoryName(String);

impl RepositoryName {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

pub trait StorageRepository: Send + Sync {
    fn repository_name(&self) -> RepositoryName;
}
