use std::fmt;

use serde::{Deserialize, Serialize};

use crate::canonical_digest::CanonicalDigestV1;

const TOKEN_BYTES: usize = 32;
const BASE64URL: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct BearerAuthority {
    token_generation: u64,
    token_digest: String,
}

impl BearerAuthority {
    pub fn token_generation(&self) -> u64 {
        self.token_generation
    }

    pub fn token_digest(&self) -> &str {
        &self.token_digest
    }

    pub fn matches(&self, domain: &str, raw: &str) -> Result<bool, BearerTokenError> {
        let actual = digest_token(domain, raw)?;
        Ok(constant_time_eq(
            self.token_digest.as_bytes(),
            actual.as_bytes(),
        ))
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct IssuedBearerToken {
    raw: String,
    authority: BearerAuthority,
}

impl IssuedBearerToken {
    pub fn raw(&self) -> &str {
        &self.raw
    }

    pub fn authority(&self) -> &BearerAuthority {
        &self.authority
    }

    pub fn into_parts(self) -> (String, BearerAuthority) {
        (self.raw, self.authority)
    }
}

#[derive(Clone, Copy, Debug, Default)]
pub struct BearerTokenIssuer;

impl BearerTokenIssuer {
    pub fn system() -> Self {
        Self
    }

    pub fn issue(&self, domain: &str) -> Result<IssuedBearerToken, BearerTokenError> {
        self.issue_generation(domain, 1)
    }

    pub(crate) fn issue_at_generation(
        &self,
        domain: &str,
        generation: u64,
    ) -> Result<IssuedBearerToken, BearerTokenError> {
        self.issue_generation(domain, generation)
    }

    pub fn rotate(
        &self,
        domain: &str,
        current: &BearerAuthority,
    ) -> Result<IssuedBearerToken, BearerTokenError> {
        let generation = current.token_generation.checked_add(1).ok_or_else(|| {
            BearerTokenError::new(
                "bearer_token.generation_exhausted",
                "bearer token generation exhausted",
            )
        })?;
        self.issue_generation(domain, generation)
    }

    pub fn digest(&self, domain: &str, raw: &str) -> Result<String, BearerTokenError> {
        digest_token(domain, raw)
    }

    pub fn matches_digest(
        &self,
        domain: &str,
        raw: &str,
        expected_digest: &str,
    ) -> Result<bool, BearerTokenError> {
        let actual = digest_token(domain, raw)?;
        Ok(constant_time_eq(
            actual.as_bytes(),
            expected_digest.as_bytes(),
        ))
    }

    fn issue_generation(
        &self,
        domain: &str,
        generation: u64,
    ) -> Result<IssuedBearerToken, BearerTokenError> {
        let mut bytes = [0_u8; TOKEN_BYTES];
        getrandom::fill(&mut bytes).map_err(|error| {
            BearerTokenError::new(
                "bearer_token.random_failed",
                format!("operating-system random generation failed: {error}"),
            )
        })?;
        let raw = encode_base64url(&bytes);
        let token_digest = digest_token(domain, &raw)?;
        Ok(IssuedBearerToken {
            raw,
            authority: BearerAuthority {
                token_generation: generation,
                token_digest,
            },
        })
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BearerTokenError {
    code: &'static str,
    message: String,
}

impl BearerTokenError {
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

impl fmt::Display for BearerTokenError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for BearerTokenError {}

fn digest_token(domain: &str, raw: &str) -> Result<String, BearerTokenError> {
    CanonicalDigestV1::digest(domain, &raw)
        .map(|digest| digest.as_str().to_string())
        .map_err(|error| BearerTokenError::new("bearer_token.digest_failed", error.to_string()))
}

fn encode_base64url(bytes: &[u8]) -> String {
    let mut encoded = String::with_capacity((bytes.len() * 4).div_ceil(3));
    for chunk in bytes.chunks(3) {
        let first = chunk[0];
        encoded.push(BASE64URL[(first >> 2) as usize] as char);
        let second = chunk.get(1).copied();
        encoded.push(
            BASE64URL[(((first & 0b0000_0011) << 4) | second.unwrap_or(0) >> 4) as usize] as char,
        );
        if let Some(second) = second {
            let third = chunk.get(2).copied();
            encoded.push(
                BASE64URL[(((second & 0b0000_1111) << 2) | third.unwrap_or(0) >> 6) as usize]
                    as char,
            );
            if let Some(third) = third {
                encoded.push(BASE64URL[(third & 0b0011_1111) as usize] as char);
            }
        }
    }
    encoded
}

fn constant_time_eq(left: &[u8], right: &[u8]) -> bool {
    if left.len() != right.len() {
        return false;
    }
    let mut difference = 0_u8;
    for (&left, &right) in left.iter().zip(right) {
        difference |= left ^ right;
    }
    difference == 0
}
