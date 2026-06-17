use std::sync::atomic::{AtomicUsize, Ordering};

use local_ios_agent_runtime::context::{MockTokenizer, PromptFrame};
use local_ios_agent_runtime::core::{
    AgentError, AgentRuntime, AgentRuntimeConfig, EventKind, MockStreamingProvider, ModelProvider,
    ModelProviderOutput, RunState, SendMessageInput,
};
use local_ios_agent_runtime::security::RiskLevel;
use local_ios_agent_runtime::tool::{
    RetentionPolicy, Sensitivity, ToolCall, ToolRegistry, ToolResult, ToolRouter, ToolSchema,
};

#[derive(Debug)]
struct FollowUpToolProvider {
    calls: AtomicUsize,
}

impl FollowUpToolProvider {
    fn new() -> Self {
        Self {
            calls: AtomicUsize::new(0),
        }
    }
}

impl ModelProvider for FollowUpToolProvider {
    fn id(&self) -> &str {
        "follow-up-tool"
    }

    fn stream_chat(&self, _frame: &PromptFrame) -> Result<Vec<ModelProviderOutput>, AgentError> {
        let call_index = self.calls.fetch_add(1, Ordering::SeqCst);
        let id = if call_index == 0 { "call_1" } else { "call_2" };

        Ok(vec![ModelProviderOutput::ToolCall(ToolCall {
            id: id.into(),
            name: "debug.echo".into(),
            arguments_json: format!(r#"{{"text":"{id}"}}"#),
        })])
    }
}

fn echo_registry(risk_level: RiskLevel) -> ToolRegistry {
    let mut registry = ToolRegistry::new();
    registry
        .register(ToolSchema {
            name: "debug.echo".into(),
            description: "Echo".into(),
            parameters_json_schema: r#"{"type":"object"}"#.into(),
            risk_level,
        })
        .unwrap();
    registry
}

fn tool_result(text: &str) -> ToolResult {
    ToolResult {
        display_text: text.into(),
        model_text: text.into(),
        structured_json: "{}".into(),
        audit_text: text.into(),
        sensitivity: Sensitivity::Public,
        retention: RetentionPolicy::RunOnly,
        is_error: false,
    }
}

#[test]
fn runtime_exposes_pending_swift_tool_request() {
    let mut runtime = AgentRuntime::new(AgentRuntimeConfig {
        system_prompt: "system".into(),
        runtime_policy: "policy".into(),
        tool_schemas: Vec::new(),
        tokenizer: Box::new(MockTokenizer::new(100)),
        provider: Box::new(MockStreamingProvider::new()),
        tool_router: Some(ToolRouter::new(echo_registry(RiskLevel::ReadOnly))),
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
    let mut runtime = AgentRuntime::new(AgentRuntimeConfig {
        system_prompt: "system".into(),
        runtime_policy: "policy".into(),
        tool_schemas: Vec::new(),
        tokenizer: Box::new(MockTokenizer::new(100)),
        provider: Box::new(MockStreamingProvider::new()),
        tool_router: Some(ToolRouter::new(echo_registry(RiskLevel::Destructive))),
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

#[test]
fn runtime_persists_structured_tool_call_payload() {
    let mut runtime = AgentRuntime::new(AgentRuntimeConfig {
        system_prompt: "system".into(),
        runtime_policy: "policy".into(),
        tool_schemas: Vec::new(),
        tokenizer: Box::new(MockTokenizer::new(100)),
        provider: Box::new(MockStreamingProvider::new()),
        tool_router: Some(ToolRouter::new(echo_registry(RiskLevel::ReadOnly))),
    });
    let session_id = runtime.create_session().unwrap();

    let result = runtime
        .send_message_turn(SendMessageInput {
            session_id,
            parent_event_id: None,
            text: "use tool debug.echo".into(),
        })
        .unwrap();

    let tool_call_event = result
        .events
        .iter()
        .find(|event| event.kind == EventKind::ToolCallRequested)
        .unwrap();
    let payload: serde_json::Value = serde_json::from_str(&tool_call_event.payload).unwrap();

    assert_eq!(payload["call_id"], "call_mock_1");
    assert_eq!(payload["name"], "debug.echo");
    assert_eq!(payload["arguments_json"], r#"{"text":"hello"}"#);
    assert_eq!(payload["route_state"], "execute_in_swift");
}

#[test]
fn submit_tool_result_consumes_matching_pending_request() {
    let mut runtime = AgentRuntime::new(AgentRuntimeConfig {
        system_prompt: "system".into(),
        runtime_policy: "policy".into(),
        tool_schemas: Vec::new(),
        tokenizer: Box::new(MockTokenizer::new(100)),
        provider: Box::new(MockStreamingProvider::new()),
        tool_router: Some(ToolRouter::new(echo_registry(RiskLevel::ReadOnly))),
    });
    let session_id = runtime.create_session().unwrap();
    let turn = runtime
        .send_message_turn(SendMessageInput {
            session_id,
            parent_event_id: None,
            text: "use tool debug.echo".into(),
        })
        .unwrap();

    assert_eq!(runtime.pending_tool_requests().len(), 1);

    let resumed = runtime
        .submit_tool_result(turn.run_id, tool_result("echoed"))
        .unwrap();

    assert_eq!(resumed.state, RunState::Completed);
    assert!(runtime.pending_tool_requests().is_empty());
}

#[test]
fn runtime_routes_follow_up_tool_call_after_tool_result() {
    let mut runtime = AgentRuntime::new(AgentRuntimeConfig {
        system_prompt: "system".into(),
        runtime_policy: "policy".into(),
        tool_schemas: Vec::new(),
        tokenizer: Box::new(MockTokenizer::new(100)),
        provider: Box::new(FollowUpToolProvider::new()),
        tool_router: Some(ToolRouter::new(echo_registry(RiskLevel::ReadOnly))),
    });
    let session_id = runtime.create_session().unwrap();
    let turn = runtime
        .send_message_turn(SendMessageInput {
            session_id,
            parent_event_id: None,
            text: "start".into(),
        })
        .unwrap();

    assert_eq!(turn.state, RunState::WaitingTool);
    assert_eq!(runtime.pending_tool_requests().len(), 1);
    assert_eq!(runtime.pending_tool_requests()[0].tool_call_id, "call_1");

    let resumed = runtime
        .submit_tool_result(turn.run_id, tool_result("first result"))
        .unwrap();

    assert_eq!(resumed.state, RunState::WaitingTool);
    assert_eq!(resumed.pending_tool_call_id, Some("call_2".into()));
    assert_eq!(runtime.pending_tool_requests().len(), 1);
    assert_eq!(runtime.pending_tool_requests()[0].tool_call_id, "call_2");
}
