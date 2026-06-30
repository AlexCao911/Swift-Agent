use std::collections::{BTreeMap, BTreeSet};
use std::fmt;

#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct CredentialRef(String);

impl CredentialRef {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub enum CredentialPurpose {
    RemoteProvider,
    RemoteInference,
    HttpTool,
    ExternalMemory,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CredentialResolveError {
    code: String,
    message: String,
}

impl CredentialResolveError {
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }

    pub fn code(&self) -> &str {
        &self.code
    }
}

impl fmt::Display for CredentialResolveError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for CredentialResolveError {}

pub type CredentialResolveResult<T> = Result<T, CredentialResolveError>;

#[derive(Clone, Eq, PartialEq)]
pub struct ResolvedSecret(String);

impl ResolvedSecret {
    pub(crate) fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }
}

impl fmt::Debug for ResolvedSecret {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("ResolvedSecret([redacted])")
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RedactedSecret(String);

impl RedactedSecret {
    fn new() -> Self {
        Self("[redacted]".to_string())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

pub trait CredentialRefResolver: Send + Sync {
    fn resolve(
        &self,
        reference: &CredentialRef,
        purpose: CredentialPurpose,
    ) -> CredentialResolveResult<ResolvedSecret>;
    fn redact(&self, value: &str) -> RedactedSecret;
}

#[derive(Clone, Default)]
pub struct InMemoryCredentialResolver {
    secrets: BTreeMap<CredentialRef, CredentialEntry>,
}

#[derive(Clone, Eq, PartialEq)]
struct CredentialEntry {
    secret: String,
    allowed_purposes: BTreeSet<CredentialPurpose>,
}

impl InMemoryCredentialResolver {
    pub fn with_secret(mut self, reference: impl Into<String>, secret: impl Into<String>) -> Self {
        self = self.with_secret_for(reference, secret, [CredentialPurpose::RemoteProvider]);
        self
    }

    pub fn with_secret_for<I>(
        mut self,
        reference: impl Into<String>,
        secret: impl Into<String>,
        allowed_purposes: I,
    ) -> Self
    where
        I: IntoIterator<Item = CredentialPurpose>,
    {
        self.secrets.insert(
            CredentialRef::new(reference),
            CredentialEntry {
                secret: secret.into(),
                allowed_purposes: allowed_purposes.into_iter().collect(),
            },
        );
        self
    }

    pub fn resolve(
        &self,
        reference: &CredentialRef,
        purpose: CredentialPurpose,
    ) -> CredentialResolveResult<ResolvedSecret> {
        <Self as CredentialRefResolver>::resolve(self, reference, purpose)
    }

    pub fn redact(&self, value: &str) -> RedactedSecret {
        <Self as CredentialRefResolver>::redact(self, value)
    }
}

impl CredentialRefResolver for InMemoryCredentialResolver {
    fn resolve(
        &self,
        reference: &CredentialRef,
        purpose: CredentialPurpose,
    ) -> CredentialResolveResult<ResolvedSecret> {
        let entry = self.secrets.get(reference).ok_or_else(|| {
            CredentialResolveError::new(
                "security.credential_not_found",
                format!("credential ref not found: {}", reference.as_str()),
            )
        })?;

        if !entry.allowed_purposes.contains(&purpose) {
            return Err(CredentialResolveError::new(
                "security.credential_purpose_mismatch",
                format!(
                    "credential ref {} is not allowed for {:?}",
                    reference.as_str(),
                    purpose
                ),
            ));
        }

        Ok(ResolvedSecret::new(entry.secret.clone()))
    }

    fn redact(&self, _value: &str) -> RedactedSecret {
        RedactedSecret::new()
    }
}

impl fmt::Debug for InMemoryCredentialResolver {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("InMemoryCredentialResolver")
            .field("secret_count", &self.secrets.len())
            .finish()
    }
}
