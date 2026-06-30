use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use local_ios_agent_runtime::context::{MockTokenizer, PromptFrame, PromptMessage};
use local_ios_agent_runtime::core::{
    AgentError, AgentRuntime, AgentRuntimeConfig, CancellationToken, EventKind,
    MockStreamingProvider, ModelProvider, ModelProviderOutput, RunState, SendMessageInput,
};
use local_ios_agent_runtime::memory::SqliteEventStore;
use local_ios_agent_runtime::security::{ApprovalProtocolResponse, RiskLevel};
use local_ios_agent_runtime::tool::{
    RetentionPolicy, Sensitivity, ToolCall, ToolRegistry, ToolResult, ToolRouter, ToolSchema,
};
use serde_json::Value;

#[derive(Debug)]
struct FollowUpToolProvider {
    calls: AtomicUsize,
}

#[derive(Debug)]
struct InvalidToolProvider {
    call: ToolCall,
}

#[derive(Debug)]
struct CaptureToolResultFrameProvider {
    calls: AtomicUsize,
    captured_frames: Arc<Mutex<Vec<PromptFrame>>>,
}

impl CaptureToolResultFrameProvider {
    fn new(captured_frames: Arc<Mutex<Vec<PromptFrame>>>) -> Self {
        Self {
            calls: AtomicUsize::new(0),
            captured_frames,
        }
    }
}

impl ModelProvider for CaptureToolResultFrameProvider {
    fn id(&self) -> &str {
        "capture-tool-result-frame"
    }

    fn stream_chat(
        &self,
        frame: &PromptFrame,
        _cancellation: CancellationToken,
        on_output: &mut dyn FnMut(ModelProviderOutput) -> Result<(), AgentError>,
    ) -> Result<(), AgentError> {
        let call_index = self.calls.fetch_add(1, Ordering::SeqCst);
        if call_index == 0 {
            on_output(ModelProviderOutput::ToolCall(ToolCall {
                id: "call_1".into(),
                name: "debug.echo".into(),
                arguments_json: "{}".into(),
            }))?;
            return Ok(());
        }

        self.captured_frames.lock().unwrap().push(frame.clone());
        on_output(ModelProviderOutput::Completed("done".into()))?;
        Ok(())
    }
}

impl InvalidToolProvider {
    fn new(call: ToolCall) -> Self {
        Self { call }
    }
}

impl ModelProvider for InvalidToolProvider {
    fn id(&self) -> &str {
        "invalid-tool"
    }

    fn stream_chat(
        &self,
        _frame: &PromptFrame,
        _cancellation: CancellationToken,
        on_output: &mut dyn FnMut(ModelProviderOutput) -> Result<(), AgentError>,
    ) -> Result<(), AgentError> {
        on_output(ModelProviderOutput::ToolCall(self.call.clone()))?;
        Ok(())
    }
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

    fn stream_chat(
        &self,
        _frame: &PromptFrame,
        _cancellation: CancellationToken,
        on_output: &mut dyn FnMut(ModelProviderOutput) -> Result<(), AgentError>,
    ) -> Result<(), AgentError> {
        let call_index = self.calls.fetch_add(1, Ordering::SeqCst);
        let id = if call_index == 0 { "call_1" } else { "call_2" };

        on_output(ModelProviderOutput::ToolCall(ToolCall {
            id: id.into(),
            name: "debug.echo".into(),
            arguments_json: format!(r#"{{"text":"{id}"}}"#),
        }))?;
        Ok(())
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
            metadata_json: None,
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
        provenance: "tool.test".into(),
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
            blob_refs: Vec::new(),
        })
        .unwrap();

    assert_eq!(result.state, RunState::WaitingTool);
    assert!(runtime
        .pending_tool_requests()
        .iter()
        .any(|request| request.tool_name == "debug.echo"));
}

#[test]
fn runtime_suspends_confirm_tool_until_approval() {
    let mut runtime = AgentRuntime::new(AgentRuntimeConfig {
        system_prompt: "system".into(),
        runtime_policy: "policy".into(),
        tool_schemas: Vec::new(),
        tokenizer: Box::new(MockTokenizer::new(100)),
        provider: Box::new(MockStreamingProvider::new()),
        tool_router: Some(ToolRouter::new(echo_registry(RiskLevel::Confirm))),
    });
    let session_id = runtime.create_session().unwrap();

    let result = runtime
        .send_message_turn(SendMessageInput {
            session_id,
            parent_event_id: None,
            text: "use tool debug.echo".into(),
            blob_refs: Vec::new(),
        })
        .unwrap();

    let approvals = runtime.pending_approval_requests();

    assert_eq!(result.state, RunState::Suspended);
    assert!(runtime.pending_tool_requests().is_empty());
    assert_eq!(approvals.len(), 1);
    assert!(approvals[0].requires_local_authentication);
    assert!(result
        .events
        .iter()
        .any(|event| event.kind == EventKind::RunSuspended));
}

#[test]
fn approval_response_resumes_suspended_tool_execution() {
    let mut runtime = AgentRuntime::new(AgentRuntimeConfig {
        system_prompt: "system".into(),
        runtime_policy: "policy".into(),
        tool_schemas: Vec::new(),
        tokenizer: Box::new(MockTokenizer::new(100)),
        provider: Box::new(MockStreamingProvider::new()),
        tool_router: Some(ToolRouter::new(echo_registry(RiskLevel::Confirm))),
    });
    let session_id = runtime.create_session().unwrap();
    let turn = runtime
        .send_message_turn(SendMessageInput {
            session_id,
            parent_event_id: None,
            text: "use tool debug.echo".into(),
            blob_refs: Vec::new(),
        })
        .unwrap();
    let approval = runtime.pending_approval_requests()[0].clone();

    let resumed = runtime
        .submit_approval_response(ApprovalProtocolResponse {
            approval_id: approval.approval_id,
            approved: true,
            reason: None,
        })
        .unwrap();

    assert_eq!(turn.state, RunState::Suspended);
    assert_eq!(resumed.state, RunState::WaitingTool);
    assert!(runtime.pending_approval_requests().is_empty());
    assert_eq!(runtime.pending_tool_requests().len(), 1);
    assert_eq!(runtime.pending_tool_requests()[0].tool_name, "debug.echo");
    assert!(resumed
        .events
        .iter()
        .any(|event| event.kind == EventKind::ToolCallApproved));
    assert!(resumed
        .events
        .iter()
        .any(|event| event.kind == EventKind::RunResumed));
}

#[test]
fn approval_rejection_resumes_with_tool_error_result() {
    let mut runtime = AgentRuntime::new(AgentRuntimeConfig {
        system_prompt: "system".into(),
        runtime_policy: "policy".into(),
        tool_schemas: Vec::new(),
        tokenizer: Box::new(MockTokenizer::new(100)),
        provider: Box::new(MockStreamingProvider::new()),
        tool_router: Some(ToolRouter::new(echo_registry(RiskLevel::Confirm))),
    });
    let session_id = runtime.create_session().unwrap();
    runtime
        .send_message_turn(SendMessageInput {
            session_id,
            parent_event_id: None,
            text: "use tool debug.echo".into(),
            blob_refs: Vec::new(),
        })
        .unwrap();
    let approval = runtime.pending_approval_requests()[0].clone();

    let resumed = runtime
        .submit_approval_response(ApprovalProtocolResponse {
            approval_id: approval.approval_id,
            approved: false,
            reason: Some("No".into()),
        })
        .unwrap();

    assert_eq!(resumed.state, RunState::Completed);
    assert!(runtime.pending_approval_requests().is_empty());
    assert!(runtime.pending_tool_requests().is_empty());
    assert!(resumed
        .events
        .iter()
        .any(|event| event.kind == EventKind::ToolCallRejected));
    assert!(resumed
        .events
        .iter()
        .any(|event| event.kind == EventKind::ToolResultMessage));
}

#[test]
fn runtime_writes_audit_rows_for_security_sensitive_events() {
    let tempdir = tempfile::tempdir().unwrap();
    let db_path = tempdir.path().join("agent.sqlite");
    let store = SqliteEventStore::open(&db_path).unwrap();
    let mut runtime = AgentRuntime::with_store(
        AgentRuntimeConfig {
            system_prompt: "system".into(),
            runtime_policy: "policy".into(),
            tool_schemas: Vec::new(),
            tokenizer: Box::new(MockTokenizer::new(100)),
            provider: Box::new(MockStreamingProvider::new()),
            tool_router: Some(ToolRouter::new(echo_registry(RiskLevel::Confirm))),
        },
        store,
    )
    .unwrap();
    let session_id = runtime.create_session().unwrap();
    let session_key = session_id.0.clone();

    runtime
        .send_message_turn(SendMessageInput {
            session_id,
            parent_event_id: None,
            text: "use tool debug.echo".into(),
            blob_refs: Vec::new(),
        })
        .unwrap();
    drop(runtime);

    let reopened = SqliteEventStore::open(&db_path).unwrap();
    let audit_rows = reopened.audit_rows(&session_key).unwrap();

    assert!(audit_rows
        .iter()
        .any(|row| row.summary.contains("ToolCallRequested")));
    assert!(audit_rows
        .iter()
        .any(|row| row.summary.contains("RunSuspended")));
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
            blob_refs: Vec::new(),
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
            blob_refs: Vec::new(),
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
            blob_refs: Vec::new(),
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
fn runtime_fills_swift_tool_result_provenance_from_pending_request() {
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
            blob_refs: Vec::new(),
        })
        .unwrap();
    let mut result = tool_result("echoed");
    result.provenance = "swift.tool_result".into();

    let resumed = runtime.submit_tool_result(turn.run_id, result).unwrap();

    let tool_result_payload = resumed
        .events
        .iter()
        .find(|event| event.kind == EventKind::ToolResultMessage)
        .map(|event| event.payload.as_str())
        .expect("tool result event");
    let payload: Value = serde_json::from_str(tool_result_payload).unwrap();
    assert_eq!(payload["provenance"], "tool.debug.echo");
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
            blob_refs: Vec::new(),
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

#[test]
fn runtime_rejects_provider_tool_call_with_empty_id() {
    let mut runtime = AgentRuntime::new(AgentRuntimeConfig {
        system_prompt: "system".into(),
        runtime_policy: "policy".into(),
        tool_schemas: Vec::new(),
        tokenizer: Box::new(MockTokenizer::new(100)),
        provider: Box::new(InvalidToolProvider::new(ToolCall {
            id: "".into(),
            name: "debug.echo".into(),
            arguments_json: "{}".into(),
        })),
        tool_router: None,
    });
    let session_id = runtime.create_session().unwrap();

    let error = runtime
        .send_message_turn(SendMessageInput {
            session_id,
            parent_event_id: None,
            text: "start".into(),
            blob_refs: Vec::new(),
        })
        .unwrap_err();

    assert!(matches!(error, AgentError::ToolValidation(_)));
    assert!(runtime.pending_tool_requests().is_empty());
}

#[test]
fn runtime_filters_secret_audit_only_tool_result_from_followup_context() {
    let captured_frames = Arc::new(Mutex::new(Vec::new()));
    let mut runtime = AgentRuntime::new(AgentRuntimeConfig {
        system_prompt: "system".into(),
        runtime_policy: "policy".into(),
        tool_schemas: Vec::new(),
        tokenizer: Box::new(MockTokenizer::new(100)),
        provider: Box::new(CaptureToolResultFrameProvider::new(captured_frames.clone())),
        tool_router: None,
    });
    let session_id = runtime.create_session().unwrap();
    let turn = runtime
        .send_message_turn(SendMessageInput {
            session_id,
            parent_event_id: None,
            text: "start".into(),
            blob_refs: Vec::new(),
        })
        .unwrap();

    runtime
        .submit_tool_result(
            turn.run_id,
            ToolResult {
                display_text: "hidden".into(),
                model_text: "secret model text".into(),
                structured_json: "{}".into(),
                audit_text: "audit only".into(),
                sensitivity: Sensitivity::Secret,
                retention: RetentionPolicy::AuditOnly,
                provenance: "tool.test".into(),
                is_error: false,
            },
        )
        .unwrap();

    let frames = captured_frames.lock().unwrap();
    let followup = frames.last().unwrap();
    assert!(!followup
        .messages
        .iter()
        .any(|message| matches!(message, PromptMessage::ToolResult(content) if content.contains("secret"))));
}
