use local_ios_agent_runtime::core::{EntryId, RunId, SessionId};
use local_ios_agent_runtime::security::{
    PermissionScope, PermissionState, RiskLevel, SecurityManager,
};
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
        metadata_json: None,
    }
}

#[test]
fn router_routes_read_tool_to_swift_execution_request() {
    let mut registry = ToolRegistry::new();
    registry
        .register(schema("calendar.search_events", RiskLevel::ReadOnly))
        .unwrap();
    let mut router = ToolRouter::new(registry);

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
    let mut router = ToolRouter::new(registry);

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
    let mut router = ToolRouter::new(registry);

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
        ToolRouteOutcome::ApprovalRequired {
            request, reason, ..
        } => {
            assert_eq!(request.tool_name, "calendar.create_event");
            assert!(reason.contains("calendar.create_event"));
        }
        _ => panic!("expected approval required route"),
    }
}

#[test]
fn router_rejects_empty_tool_call_name_before_registry_lookup() {
    let registry = ToolRegistry::new();
    let mut router = ToolRouter::new(registry);

    let error = router
        .route(
            &RunId("run_1".into()),
            &SessionId("session_1".into()),
            &EntryId("entry_1".into()),
            ToolCall {
                id: "call_1".into(),
                name: "".into(),
                arguments_json: "{}".into(),
            },
        )
        .unwrap_err();

    match error {
        local_ios_agent_runtime::core::AgentError::ToolValidation(message) => {
            assert!(message.contains("name"));
            assert!(!message.contains("unknown tool"));
        }
        _ => panic!("expected tool validation error"),
    }
}

#[test]
fn router_uses_security_manager_permission_scope_for_tool_policy() {
    let mut registry = ToolRegistry::new();
    registry
        .register(schema("calendar.search_events", RiskLevel::ReadOnly))
        .unwrap();
    let mut security = SecurityManager::new();
    security.set_tool_permission_scope("calendar.search_events", "calendar.read");
    security.set_permission(PermissionScope {
        name: "calendar.read".into(),
        state: PermissionState::Denied,
    });
    let mut router = ToolRouter::with_security_manager(registry, security);

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

    assert!(matches!(outcome, ToolRouteOutcome::Denied(_)));
}

#[test]
fn router_queues_approval_with_real_run_and_entry_ids() {
    let mut registry = ToolRegistry::new();
    registry
        .register(schema("calendar.create_event", RiskLevel::Confirm))
        .unwrap();
    let mut router = ToolRouter::new(registry);

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
        ToolRouteOutcome::ApprovalRequired { approval, .. } => {
            let pending = router.pending_approvals();

            assert_eq!(pending.len(), 1);
            assert_eq!(pending[0].run_id, RunId("run_1".into()));
            assert_eq!(pending[0].tool_call_entry_id, EntryId("entry_1".into()));
            assert_eq!(approval.approval_id, pending[0].approval_id);
            assert_eq!(approval.run_id, RunId("run_1".into()));
            assert_eq!(approval.tool_call_entry_id, EntryId("entry_1".into()));
            assert!(approval.requires_local_authentication);
        }
        _ => panic!("expected approval required route"),
    }
}
