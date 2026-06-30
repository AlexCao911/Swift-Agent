use local_ios_agent_runtime::protocol::ProviderKindDTO;

#[test]
fn dto_enum_decodes_unknown_value_without_crashing() {
    let dto: ProviderKindDTO = serde_json::from_str(r#""future_quantum_provider""#).unwrap();

    assert!(matches!(
        dto,
        ProviderKindDTO::Unknown(value) if value == "future_quantum_provider"
    ));
}
