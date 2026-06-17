use local_ios_agent_runtime::core::{EntryId, RunId, SessionId};
use local_ios_agent_runtime::security::RiskLevel;
use local_ios_agent_runtime::tool::{
    ToolCall, ToolExecutionRequest, ToolRegistry, ToolRouteOutcome, ToolRouter, ToolSchema,
};

#[test]
fn execution_request_carries_swift_boundary_payload() {
    let request = ToolExecutionRequest::new(
        RunId("run_1".into()),
        SessionId("session_1".into()),
        EntryId("entry_1".into()),
        ToolCall {
            id: "call_1".into(),
            name: "calendar.search_events".into(),
            arguments_json: "{}".into(),
        },
    );

    assert_eq!(request.tool_name, "calendar.search_events");
    assert_eq!(request.arguments_json, "{}");
}

fn schema(name: &str, risk_level: RiskLevel) -> ToolSchema {
    ToolSchema {
        name: name.into(),
        description: format!("{name} description"),
        parameters_json_schema: r#"{"type":"object"}"#.into(),
        risk_level,
    }
}

#[test]
fn router_routes_read_tool_to_swift_execution_request() {
    let mut registry = ToolRegistry::new();
    registry
        .register(schema("calendar.search_events", RiskLevel::ReadOnly))
        .unwrap();
    let router = ToolRouter::new(registry);

    let outcome = router
        .route(
            &RunId("run_1".into()),
            &SessionId("session_1".into()),
            &EntryId("entry_1".into()),
            ToolCall {
                id: "call_1".into(),
                name: "calendar.search_events".into(),
                arguments_json: "{}".into(),
            },
        )
        .unwrap();

    assert!(matches!(outcome, ToolRouteOutcome::ExecuteInSwift(_)));
}

#[test]
fn router_denies_destructive_tool_as_recoverable_error() {
    let mut registry = ToolRegistry::new();
    registry
        .register(schema("files.delete_all", RiskLevel::Destructive))
        .unwrap();
    let router = ToolRouter::new(registry);

    let outcome = router
        .route(
            &RunId("run_1".into()),
            &SessionId("session_1".into()),
            &EntryId("entry_1".into()),
            ToolCall {
                id: "call_1".into(),
                name: "files.delete_all".into(),
                arguments_json: "{}".into(),
            },
        )
        .unwrap();

    assert!(matches!(outcome, ToolRouteOutcome::Denied(_)));
}

#[test]
fn router_routes_confirm_tool_to_approval_required_with_reason() {
    let mut registry = ToolRegistry::new();
    registry
        .register(schema("calendar.create_event", RiskLevel::Confirm))
        .unwrap();
    let router = ToolRouter::new(registry);

    let outcome = router
        .route(
            &RunId("run_1".into()),
            &SessionId("session_1".into()),
            &EntryId("entry_1".into()),
            ToolCall {
                id: "call_1".into(),
                name: "calendar.create_event".into(),
                arguments_json: "{}".into(),
            },
        )
        .unwrap();

    match outcome {
        ToolRouteOutcome::ApprovalRequired { request, reason } => {
            assert_eq!(request.tool_name, "calendar.create_event");
            assert!(reason.contains("calendar.create_event"));
        }
        _ => panic!("expected approval required route"),
    }
}
