use local_ios_agent_runtime::protocol::ProviderKindDTO;
use local_ios_agent_runtime::user_customization::ComponentKindDTO;

#[test]
fn component_kind_unknown_fixture_stays_decode_safe() {
    let raw = include_str!("../fixtures/user_component/unknown_component_kind.json");
    let decoded = serde_json::from_str::<ComponentKindDTO>(raw).unwrap();

    assert!(matches!(decoded, ComponentKindDTO::Unknown(value) if value == "future_component"));
}

#[test]
fn provider_kind_unknown_fixture_stays_decode_safe() {
    let decoded = serde_json::from_str::<ProviderKindDTO>(r#""future_provider""#).unwrap();

    assert!(matches!(decoded, ProviderKindDTO::Unknown(value) if value == "future_provider"));
}
