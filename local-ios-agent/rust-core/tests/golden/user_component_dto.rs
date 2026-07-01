use local_ios_agent_runtime::user_customization::ComponentContent;

#[test]
fn component_content_fixture_stays_stable_json() {
    let raw = include_str!("../fixtures/user_component/component_content_v1.json");
    let decoded: Vec<serde_json::Value> = serde_json::from_str(raw).unwrap();

    assert!(decoded.iter().any(|value| value["kind"] == "persona"));
    assert!(decoded.iter().any(|value| value["kind"] == "prompt"));
    assert!(decoded.iter().any(|value| value["kind"] == "tool_recipe"));
}

#[test]
fn component_content_round_trip_does_not_drop_kind() {
    let persona = ComponentContent::persona("Research persona");
    let value = serde_json::to_value(&persona).unwrap();

    assert_eq!(value["kind"], "persona");
}
