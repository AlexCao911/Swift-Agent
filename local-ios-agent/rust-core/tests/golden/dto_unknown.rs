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

#[test]
fn bridge_unknown_values_fixture_covers_all_dto_facing_enums() {
    let fixture: serde_json::Value = serde_json::from_str(include_str!(
        "../fixtures/golden/bridge/dto_unknown_values.json"
    ))
    .unwrap();

    assert_eq!(fixture["event"]["kind"], "future_runtime_event");
    assert_eq!(fixture["turn"]["state"], "future_run_state");
    assert_eq!(fixture["tool_schema"]["risk_level"], "future_risk");
    assert_eq!(fixture["tool_result"]["sensitivity"], "future_sensitivity");
    assert_eq!(fixture["tool_result"]["retention"], "future_retention");
    assert_eq!(fixture["permission_state"], "future_permission");
}
