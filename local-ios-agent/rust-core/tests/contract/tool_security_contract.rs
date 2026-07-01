use std::sync::Arc;

use local_ios_agent_runtime::core::{EntryId, RunId, SessionId};
use local_ios_agent_runtime::security::{
    ApprovalDecision, ApprovalProtocolResponse, EgressDestination, OperationDescriptor,
    SecurityManager, StaticSecurityPermissionService,
};
use local_ios_agent_runtime::tool::{
    HttpConnectorPolicy, ToolCall, ToolRecipe, ToolRecipeCompiler, ToolRegistry, ToolRouteOutcome,
    ToolRouter,
};

fn compiled_http_registry() -> ToolRegistry {
    let recipe = ToolRecipe::http_connector("remote.lookup", "https://api.example.com/search")
        .with_policy(HttpConnectorPolicy::complete_for_test());
    let compiled = ToolRecipeCompiler::default().compile(recipe).unwrap();
    let mut registry = ToolRegistry::new();
    registry.register_compiled_recipe(compiled).unwrap();
    registry
}

fn route_remote_lookup(
    router: &mut ToolRouter,
) -> Result<ToolRouteOutcome, local_ios_agent_runtime::core::AgentError> {
    router.route(
        &RunId("run_recipe".into()),
        &SessionId("session_recipe".into()),
        &EntryId("entry_recipe".into()),
        ToolCall {
            id: "call_recipe".into(),
            name: "remote.lookup".into(),
            arguments_json: r#"{"query":"agent"}"#.into(),
        },
    )
}

fn security_allowing_api_example() -> SecurityManager {
    SecurityManager::with_permission_service(Arc::new(
        StaticSecurityPermissionService::default()
            .allow_destination(EgressDestination::new("https://api.example.com")),
    ))
}

#[test]
fn http_tool_route_uses_injected_security_manager_not_recipe_local_policy() {
    let registry = compiled_http_registry();
    let mut router = ToolRouter::with_security_manager(registry, SecurityManager::new());

    let error = route_remote_lookup(&mut router).unwrap_err();

    assert!(
        error.to_string().contains("not allowlisted"),
        "recipe allowlist must not bypass injected security manager: {error}"
    );
}

#[test]
fn http_tool_route_returns_authorized_request_with_bound_egress_metadata() {
    let registry = compiled_http_registry();
    let mut router = ToolRouter::with_security_manager(registry, security_allowing_api_example());

    let outcome = route_remote_lookup(&mut router).unwrap();

    let ToolRouteOutcome::ApprovalRequired {
        approval, request, ..
    } = outcome
    else {
        panic!("expected HTTP connector to require egress approval");
    };
    let initial_decision = request
        .egress_decision()
        .expect("approval request carries egress decision");
    assert_eq!(
        initial_decision.policy().destination().as_str(),
        "https://api.example.com"
    );

    let (_approval_request, decision, resumed) = router
        .resolve_approval(ApprovalProtocolResponse {
            approval_id: approval.approval_id,
            approved: true,
            reason: None,
        })
        .unwrap();

    assert_eq!(decision, ApprovalDecision::Approved);
    let resumed = resumed.expect("approved tool request should resume");
    let egress_decision = resumed.egress_decision().unwrap();
    let grant = resumed.approval_grant().unwrap();
    assert!(grant.matches_egress(
        &OperationDescriptor::new("tool.remote.lookup"),
        egress_decision
    ));
}

#[test]
fn authorized_tool_request_cannot_be_mutated_after_router_authorizes_it() {
    let source = include_str!("../../src/tool/execution_request.rs");

    assert!(
        !source.contains("pub compiled_recipe:"),
        "ToolExecutionRequest must not expose mutable compiled_recipe field"
    );
    assert!(
        !source.contains("pub egress_decision:"),
        "ToolExecutionRequest must not expose mutable egress_decision field"
    );
    assert!(
        !source.contains("pub approval_grant:"),
        "ToolExecutionRequest must not expose mutable approval_grant field"
    );
}
