use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

use local_ios_agent_runtime::canonical_digest::CanonicalDigestV1;
use serde::Deserialize;
use serde_json::{json, Value};

#[derive(Debug, Deserialize)]
struct CanonicalFixture {
    domain: Option<String>,
    document: Value,
    expected_canonical_utf8: String,
    expected_sha256: Option<String>,
}

#[derive(Debug, Deserialize)]
struct DigestRegistry {
    domains: Vec<DigestDomainRegistration>,
}

#[derive(Debug, Deserialize)]
struct DigestDomainRegistration {
    domain: String,
}

impl DigestRegistry {
    fn domain_names(&self) -> BTreeSet<&str> {
        self.domains
            .iter()
            .map(|registration| registration.domain.as_str())
            .collect()
    }
}

#[test]
fn canonicalizes_rfc8785_number_sample() {
    let fixture = fixture("jcs-number-samples.json");

    let canonical = CanonicalDigestV1::canonicalize(&fixture.document).unwrap();

    assert_eq!(
        String::from_utf8(canonical).unwrap(),
        fixture.expected_canonical_utf8
    );
}

#[test]
fn computes_domain_separated_agent_requirements_digest() {
    let fixture = fixture("agent-requirements-v1.json");

    let digest =
        CanonicalDigestV1::digest(fixture.domain.as_deref().unwrap(), &fixture.document).unwrap();

    assert_eq!(digest.as_str(), fixture.expected_sha256.as_deref().unwrap());
    assert_eq!(
        digest.as_str(),
        "df309a1f80fb005d51e9aa7f249939f9480d106d5d5ea43d102935bdd1baee30"
    );
}

#[test]
fn local_runtime_digests_match_shared_fixtures() {
    for name in [
        "capability-snapshot-local-v1.json",
        "resolved-parameters-local-v1.json",
    ] {
        let fixture = fixture(name);
        let canonical = CanonicalDigestV1::canonicalize(&fixture.document).unwrap();
        assert_eq!(
            String::from_utf8(canonical).unwrap(),
            fixture.expected_canonical_utf8,
            "canonical bytes differ for {name}"
        );
        let digest = CanonicalDigestV1::digest(
            fixture.domain.as_deref().unwrap(),
            &fixture.document,
        )
        .unwrap();
        assert_eq!(
            digest.as_str(),
            fixture.expected_sha256.as_deref().unwrap(),
            "digest differs for {name}"
        );
    }
}

#[test]
fn cloud_policy_digests_match_shared_fixtures_without_parsing_provider_semantics() {
    for name in [
        "generation-disclosure-cloud-v1.json",
        "provider-retention-approval-cloud-v1.json",
        "credential-use-lease-cloud-v1.json",
        "egress-approval-summary-cloud-v1.json",
        "egress-scope-grant-cloud-v1.json",
        "egress-generation-authorization-cloud-v1.json",
        "egress-subject-cloud-v1.json",
        "egress-attestation-cloud-v1.json",
        "egress-audit-chain-cloud-v1.json",
        "capability-evidence-cloud-v1.json",
        "capability-observation-cloud-v1.json",
        "capability-snapshot-cloud-v1.json",
        "resolved-parameters-cloud-v1.json",
    ] {
        let fixture = fixture(name);
        let canonical = CanonicalDigestV1::canonicalize(&fixture.document).unwrap();
        assert_eq!(
            String::from_utf8(canonical).unwrap(),
            fixture.expected_canonical_utf8,
            "canonical bytes differ for {name}"
        );
        let digest = CanonicalDigestV1::digest(
            fixture.domain.as_deref().unwrap(),
            &fixture.document,
        )
        .unwrap();
        assert_eq!(
            digest.as_str(),
            fixture.expected_sha256.as_deref().unwrap(),
            "digest differs for {name}"
        );
    }
}

#[test]
fn rejects_unregistered_or_malformed_domains() {
    let document = json!({"schema_version": "1"});

    let unregistered = CanonicalDigestV1::digest("not-registered:v1", &document).unwrap_err();
    let contains_nul =
        CanonicalDigestV1::digest("agent-requirements:v1\0x", &document).unwrap_err();
    let uppercase = CanonicalDigestV1::digest("Agent-requirements:v1", &document).unwrap_err();

    assert_eq!(unregistered.code(), "canonical_digest.domain_unregistered");
    assert_eq!(contains_nul.code(), "canonical_digest.domain_invalid");
    assert_eq!(uppercase.code(), "canonical_digest.domain_invalid");
}

#[test]
fn runtime_registered_domains_match_shared_registry() {
    let registry = registry();

    assert_eq!(
        CanonicalDigestV1::registered_domains(),
        registry.domain_names()
    );
}

fn fixture(name: &str) -> CanonicalFixture {
    decode_json(&contracts_root().join("fixtures").join(name))
}

fn registry() -> DigestRegistry {
    decode_json(&contracts_root().join("registry.json"))
}

fn contracts_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("contracts")
        .join("canonical-digest-v1")
}

fn decode_json<T: for<'de> Deserialize<'de>>(path: &Path) -> T {
    let bytes = fs::read(path)
        .unwrap_or_else(|error| panic!("failed to read fixture {}: {error}", path.display()));
    serde_json::from_slice(&bytes)
        .unwrap_or_else(|error| panic!("failed to decode fixture {}: {error}", path.display()))
}
