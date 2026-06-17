use local_ios_agent_runtime::context::MockTokenizer;
use local_ios_agent_runtime::core::{
    AgentRuntime, AgentRuntimeConfig, EventKind, MockStreamingProvider, RunState, SendMessageInput,
};
use local_ios_agent_runtime::security::RiskLevel;
use local_ios_agent_runtime::tool::{ToolRegistry, ToolRouter, ToolSchema};

#[test]
fn runtime_exposes_pending_swift_tool_request() {
    let mut registry = ToolRegistry::new();
    registry
        .register(ToolSchema {
            name: "debug.echo".into(),
            description: "Echo".into(),
            parameters_json_schema: r#"{"type":"object"}"#.into(),
            risk_level: RiskLevel::ReadOnly,
        })
        .unwrap();

    let mut runtime = AgentRuntime::new(AgentRuntimeConfig {
        system_prompt: "system".into(),
        runtime_policy: "policy".into(),
        tool_schemas: Vec::new(),
        tokenizer: Box::new(MockTokenizer::new(100)),
        provider: Box::new(MockStreamingProvider::new()),
        tool_router: Some(ToolRouter::new(registry)),
    });
    let session_id = runtime.create_session().unwrap();

    let result = runtime
        .send_message_turn(SendMessageInput {
            session_id,
            parent_event_id: None,
            text: "use tool debug.echo".into(),
        })
        .unwrap();

    assert_eq!(result.state, RunState::WaitingTool);
    assert!(runtime
        .pending_tool_requests()
        .iter()
        .any(|request| request.tool_name == "debug.echo"));
}

#[test]
fn runtime_recovers_from_denied_tool_route() {
    let mut registry = ToolRegistry::new();
    registry
        .register(ToolSchema {
            name: "debug.echo".into(),
            description: "Echo".into(),
            parameters_json_schema: r#"{"type":"object"}"#.into(),
            risk_level: RiskLevel::Destructive,
        })
        .unwrap();

    let mut runtime = AgentRuntime::new(AgentRuntimeConfig {
        system_prompt: "system".into(),
        runtime_policy: "policy".into(),
        tool_schemas: Vec::new(),
        tokenizer: Box::new(MockTokenizer::new(100)),
        provider: Box::new(MockStreamingProvider::new()),
        tool_router: Some(ToolRouter::new(registry)),
    });
    let session_id = runtime.create_session().unwrap();

    let result = runtime
        .send_message_turn(SendMessageInput {
            session_id,
            parent_event_id: None,
            text: "use tool debug.echo".into(),
        })
        .unwrap();

    assert_eq!(result.state, RunState::Completed);
    assert!(runtime.pending_tool_requests().is_empty());
    assert!(result
        .events
        .iter()
        .any(|event| event.kind == EventKind::ToolResultMessage));
}
