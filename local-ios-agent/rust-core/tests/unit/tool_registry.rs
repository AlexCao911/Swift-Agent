use local_ios_agent_runtime::security::RiskLevel;
use local_ios_agent_runtime::tool::{ToolRegistry, ToolSchema};

#[test]
fn registry_registers_and_formats_prompt_schemas() {
    let mut registry = ToolRegistry::new();
    registry
        .register(ToolSchema {
            name: "calendar.search_events".into(),
            description: "Search calendar events.".into(),
            parameters_json_schema: r#"{"type":"object"}"#.into(),
            risk_level: RiskLevel::ReadOnly,
            metadata_json: None,
        })
        .unwrap();

    assert!(registry.schema("calendar.search_events").is_some());
    assert!(registry.prompt_schemas()[0].contains("calendar.search_events"));
}
