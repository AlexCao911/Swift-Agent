use std::collections::BTreeSet;
use std::fmt::{self, Write};

use serde::Serialize;
use sha2::{Digest, Sha256};

const REGISTERED_DOMAINS: [&str; 40] = [
    "agent-host-binding:v1",
    "agent-input:v1",
    "agent-requirements:v1",
    "capability-attestation:v1",
    "capability-evidence:v1",
    "capability-observation:v1",
    "capability-snapshot:v1",
    "conversation-frame:v1",
    "credential-use-lease:v1",
    "egress-approval-summary:v1",
    "egress-attestation:v1",
    "egress-audit-chain:v1",
    "egress-generation-authorization:v1",
    "egress-scope-grant:v1",
    "egress-subject:v1",
    "execution-plan:v1",
    "generation-disclosure:v1",
    "host-binding-staging-receipt:v1",
    "host-command-envelope:v1",
    "host-command-envelope:v2",
    "host-command-payload:v1",
    "host-command-payload:v2",
    "host-tool-effect-result:v1",
    "llm-event-envelope:v1",
    "llm-event-envelope:v2",
    "llm-event-receipt:v1",
    "legacy-profile-source:v1",
    "preparation-binding:v1",
    "preparation-token:v1",
    "prepared-session-cleanup-command:v1",
    "prepared-session-closed-receipt:v1",
    "prepared-session-registration:v1",
    "provider-retention-approval:v1",
    "resolved-parameters:v1",
    "resolved-run-snapshot:v1",
    "run-start-snapshot:v1",
    "saga-token:v1",
    "source-revisions:v1",
    "tool-schema:v1",
    "transcript-command:v1",
];

pub struct CanonicalDigestV1;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CanonicalDigest(String);

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CanonicalDigestError {
    code: &'static str,
    message: String,
}

impl CanonicalDigestV1 {
    pub fn canonicalize<T: Serialize>(value: &T) -> Result<Vec<u8>, CanonicalDigestError> {
        serde_json_canonicalizer::to_vec(value).map_err(|error| {
            CanonicalDigestError::new(
                "canonical_digest.serialization_failed",
                format!("canonical JSON serialization failed: {error}"),
            )
        })
    }

    pub fn digest<T: Serialize>(
        domain: &str,
        value: &T,
    ) -> Result<CanonicalDigest, CanonicalDigestError> {
        validate_domain(domain)?;
        if !REGISTERED_DOMAINS.contains(&domain) {
            return Err(CanonicalDigestError::new(
                "canonical_digest.domain_unregistered",
                format!("canonical digest domain is not registered: {domain}"),
            ));
        }

        let canonical = Self::canonicalize(value)?;
        let mut hasher = Sha256::new();
        hasher.update(domain.as_bytes());
        hasher.update([0]);
        hasher.update(canonical);
        let bytes = hasher.finalize();
        let mut hex = String::with_capacity(bytes.len() * 2);
        for byte in bytes {
            write!(&mut hex, "{byte:02x}").expect("writing to String cannot fail");
        }
        Ok(CanonicalDigest(hex))
    }

    pub fn registered_domains() -> BTreeSet<&'static str> {
        REGISTERED_DOMAINS.into_iter().collect()
    }
}

impl CanonicalDigest {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl CanonicalDigestError {
    fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }

    pub fn code(&self) -> &str {
        self.code
    }
}

impl fmt::Display for CanonicalDigestError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for CanonicalDigestError {}

fn validate_domain(domain: &str) -> Result<(), CanonicalDigestError> {
    let Some((name, version)) = domain.rsplit_once(":v") else {
        return Err(invalid_domain(domain));
    };
    if name.is_empty()
        || version.is_empty()
        || version.starts_with('0')
        || !version.bytes().all(|byte| byte.is_ascii_digit())
        || !name
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
    {
        return Err(invalid_domain(domain));
    }
    Ok(())
}

fn invalid_domain(domain: &str) -> CanonicalDigestError {
    CanonicalDigestError::new(
        "canonical_digest.domain_invalid",
        format!("canonical digest domain has invalid syntax: {domain:?}"),
    )
}
