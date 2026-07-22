use std::fs;
use std::path::{Path, PathBuf};

use local_ios_agent_runtime::llm_contracts::{
    HostAttestation, HostAttestationV1Document, HostCommandEnvelope, HostDispatchEnvelope,
    LLMEventEnvelope, LLMEventReceipt, LLMEventSubmissionResult, SequenceEffect,
};
use serde::de::DeserializeOwned;
use serde_json::Value;

#[test]
fn production_contract_builders_match_shared_wire_fixtures() {
    let command: HostCommandEnvelope = wire_fixture("host-command-envelope-v1.json");
    assert_eq!(
        command.payload().expected_digest().unwrap(),
        command.payload_digest()
    );
    assert_eq!(
        command.expected_digest().unwrap(),
        command.command_envelope_digest()
    );

    let event: LLMEventEnvelope = wire_fixture("llm-event-envelope-v1.json");
    let receipt: LLMEventReceipt = wire_fixture("llm-event-receipt-v1.json");
    assert_eq!(
        event.expected_digest().unwrap(),
        event.event_envelope_digest()
    );
    assert_eq!(receipt.expected_digest().unwrap(), receipt.receipt_digest());
    assert_eq!(
        receipt.event_envelope_digest(),
        event.event_envelope_digest()
    );
}

#[test]
fn sole_attestation_builder_matches_cloud_and_local_fixtures() {
    for (name, expected) in [
        (
            "egress-attestation-cloud-v1.json",
            "9de220bd518ebd4ee705a14b26737fc5b7cea4f1a1b378a112e013c12d404822",
        ),
        (
            "egress-attestation-local-v1.json",
            "58ef0e04243b5a3b4f324869b60de728ba04928eec536f8d72eff217132c4034",
        ),
    ] {
        let document: HostAttestationV1Document = document_fixture(name);
        let attestation = HostAttestation::for_contract_fixture(document);
        assert_eq!(attestation.expected_egress_digest().unwrap(), expected);
    }
}

#[test]
fn event_submission_result_matrix_is_explicit() {
    assert_eq!(
        LLMEventSubmissionResult::Accepted.sequence_effect(),
        SequenceEffect::ConsumeNew
    );
    assert_eq!(
        LLMEventSubmissionResult::Duplicate.sequence_effect(),
        SequenceEffect::AlreadyConsumed
    );
    assert_eq!(
        LLMEventSubmissionResult::Backpressure.sequence_effect(),
        SequenceEffect::DoNotConsume
    );
    assert_eq!(
        LLMEventSubmissionResult::TurnTerminal.sequence_effect(),
        SequenceEffect::ConsumeNew
    );
    assert_eq!(
        LLMEventSubmissionResult::GenerationTerminal.sequence_effect(),
        SequenceEffect::ConsumeNew
    );
    assert!(LLMEventSubmissionResult::Backpressure.retry_same_envelope());
    assert!(!LLMEventSubmissionResult::StaleSession.retry_same_envelope());
}

#[test]
fn command_and_event_digest_mutations_are_detected() {
    let mut command: Value = wire_value("host-command-envelope-v1.json");
    command["command_sequence"] = Value::from(2);
    let changed: HostCommandEnvelope = serde_json::from_value(command).unwrap();
    assert_ne!(
        changed.expected_digest().unwrap(),
        changed.command_envelope_digest()
    );

    let mut event: Value = wire_value("llm-event-envelope-v1.json");
    event["host_process_epoch"] = Value::from("different-epoch");
    let changed: LLMEventEnvelope = serde_json::from_value(event).unwrap();
    assert_ne!(
        changed.expected_digest().unwrap(),
        changed.event_envelope_digest()
    );
}

#[test]
fn host_dispatch_rejects_payload_that_does_not_match_tag() {
    let invalid = serde_json::json!({
        "schema_version": 1,
        "dispatch_kind": "command",
        "command": null,
        "prepared_session_cleanup": null
    });

    assert!(serde_json::from_value::<HostDispatchEnvelope>(invalid).is_err());
}

#[test]
fn rust_attestation_builder_rejects_noncanonical_digest_fields() {
    let mut document = fixture_value("egress-attestation-local-v1.json")["document"].clone();
    document["binding_hash"] = Value::from("not-a-sha256-digest");
    let document: HostAttestationV1Document = serde_json::from_value(document).unwrap();

    assert_eq!(
        document.expected_digest().unwrap_err().code(),
        "preparation.egress_attestation_document_invalid"
    );
}

fn wire_fixture<T: DeserializeOwned>(name: &str) -> T {
    serde_json::from_value(wire_value(name)).unwrap()
}

fn document_fixture<T: DeserializeOwned>(name: &str) -> T {
    let value = fixture_value(name);
    serde_json::from_value(value["document"].clone()).unwrap()
}

fn wire_value(name: &str) -> Value {
    fixture_value(name)["wire"].clone()
}

fn fixture_value(name: &str) -> Value {
    let path = contracts_root().join("fixtures").join(name);
    serde_json::from_slice(
        &fs::read(&path)
            .unwrap_or_else(|error| panic!("failed to read fixture {}: {error}", path.display())),
    )
    .unwrap()
}

fn contracts_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("contracts")
        .join("canonical-digest-v1")
}
