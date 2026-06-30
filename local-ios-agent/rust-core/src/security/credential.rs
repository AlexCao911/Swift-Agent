use std::collections::BTreeMap;
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

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
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
    fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn expose_for_test(&self) -> &str {
        &self.0
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
    secrets: BTreeMap<CredentialRef, String>,
}

impl InMemoryCredentialResolver {
    pub fn with_secret(mut self, reference: impl Into<String>, secret: impl Into<String>) -> Self {
        self.secrets
            .insert(CredentialRef::new(reference), secret.into());
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
        _purpose: CredentialPurpose,
    ) -> CredentialResolveResult<ResolvedSecret> {
        self.secrets
            .get(reference)
            .cloned()
            .map(ResolvedSecret::new)
            .ok_or_else(|| {
                CredentialResolveError::new(
                    "security.credential_not_found",
                    format!("credential ref not found: {}", reference.as_str()),
                )
            })
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
