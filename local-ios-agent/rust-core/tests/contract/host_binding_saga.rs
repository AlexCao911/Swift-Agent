use local_ios_agent_runtime::llm_contracts::{
    HostBindingCommit, HostBindingStagingReceipt, HostBindingTuple,
};

#[test]
fn staging_receipt_is_bound_to_the_full_opaque_tuple() {
    let binding = HostBindingTuple::new("binding-1", 7, "binding-hash-1");
    let receipt = HostBindingStagingReceipt::new(
        "token-digest-1",
        "assistant",
        "requirements-hash-1",
        binding.clone(),
        "receipt-digest-1",
    );

    let commit = HostBindingCommit::new("publish-token-1", binding.clone(), receipt.clone());
    assert_eq!(commit.binding(), &binding);
    assert_eq!(commit.receipt(), &receipt);

    let mismatched = HostBindingTuple::new("binding-1", 8, "binding-hash-1");
    assert_ne!(receipt.binding(), &mismatched);
}

#[test]
fn host_binding_contract_contains_no_swift_owned_target_details() {
    let binding = HostBindingTuple::new("binding-1", 1, "opaque-hash");
    let receipt =
        HostBindingStagingReceipt::new("token-digest", "slot", "requirements", binding, "receipt");
    let json = serde_json::to_value(receipt).unwrap();
    let object = json.as_object().unwrap();

    for forbidden in [
        "provider",
        "provider_profile",
        "api_key",
        "credential",
        "base_url",
        "model_id",
        "local_path",
        "installation_id",
        "llm_target",
    ] {
        assert!(
            !object.contains_key(forbidden),
            "forbidden field: {forbidden}"
        );
    }
}
