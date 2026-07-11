use std::collections::BTreeSet;

use local_ios_agent_runtime::llm_contracts::BearerTokenIssuer;

#[test]
fn issuer_uses_unique_256_bit_unpadded_base64url_tokens() {
    let issuer = BearerTokenIssuer::system();
    let mut observed = BTreeSet::new();

    for _ in 0..256 {
        let issued = issuer.issue("preparation-token:v1").unwrap();
        assert_eq!(issued.raw().len(), 43);
        assert!(issued
            .raw()
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_'));
        assert_ne!(issued.raw(), issued.authority().token_digest());
        assert_eq!(issued.authority().token_generation(), 1);
        assert!(observed.insert(issued.raw().to_string()));
    }
}

#[test]
fn rotating_a_bearer_changes_digest_and_generation() {
    let issuer = BearerTokenIssuer::system();
    let first = issuer.issue("saga-token:v1").unwrap();
    let second = issuer.rotate("saga-token:v1", first.authority()).unwrap();

    assert_ne!(first.raw(), second.raw());
    assert_ne!(
        first.authority().token_digest(),
        second.authority().token_digest()
    );
    assert_eq!(second.authority().token_generation(), 2);
}
