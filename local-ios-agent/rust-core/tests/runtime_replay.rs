use local_ios_agent_runtime::context::MockTokenizer;
use local_ios_agent_runtime::core::{
    AgentRuntime, AgentRuntimeConfig, MockStreamingProvider, RunState, SendMessageInput,
};
use local_ios_agent_runtime::core::{EntryId, EventKind, RuntimeEvent, SessionCursor, SessionId};
use local_ios_agent_runtime::memory::SqliteEventStore;
use local_ios_agent_runtime::security::RiskLevel;
use local_ios_agent_runtime::tool::{
    RetentionPolicy, Sensitivity, ToolRegistry, ToolResult, ToolRouter, ToolSchema,
};

#[test]
fn cursor_replays_active_leaf_and_sequence() {
    let event = RuntimeEvent::new(
        EntryId("entry_3".into()),
        SessionId("session_1".into()),
        None,
        None,
        3,
        0,
        EventKind::UserMessage,
        "hello",
    );

    let cursor = SessionCursor::from_last_event(SessionId("session_1".into()), Some(event));

    assert_eq!(cursor.active_leaf, Some(EntryId("entry_3".into())));
    assert_eq!(cursor.next_sequence, 4);
}

fn config() -> AgentRuntimeConfig {
    AgentRuntimeConfig {
        system_prompt: "system".into(),
        runtime_policy: "policy".into(),
        tool_schemas: Vec::new(),
        tokenizer: Box::new(MockTokenizer::new(100)),
        provider: Box::new(MockStreamingProvider::new()),
        tool_router: None,
    }
}

fn tool_config() -> AgentRuntimeConfig {
    let mut registry = ToolRegistry::new();
    registry
        .register(ToolSchema {
            name: "debug.echo".into(),
            description: "Echo".into(),
            parameters_json_schema: r#"{"type":"object"}"#.into(),
            risk_level: RiskLevel::ReadOnly,
        })
        .unwrap();

    AgentRuntimeConfig {
        system_prompt: "system".into(),
        runtime_policy: "policy".into(),
        tool_schemas: Vec::new(),
        tokenizer: Box::new(MockTokenizer::new(100)),
        provider: Box::new(MockStreamingProvider::new()),
        tool_router: Some(ToolRouter::new(registry)),
    }
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
fn runtime_replays_sessions_from_sqlite() {
    let tempdir = tempfile::tempdir().unwrap();
    let db_path = tempdir.path().join("agent.sqlite");
    let session_id = {
        let store = SqliteEventStore::open(&db_path).unwrap();
        let mut runtime = AgentRuntime::with_store(config(), store).unwrap();
        let session_id = runtime.create_session().unwrap();
        runtime
            .send_message(SendMessageInput {
                session_id: session_id.clone(),
                parent_event_id: None,
                text: "hello".into(),
            })
            .unwrap();
        session_id
    };

    let store = SqliteEventStore::open(&db_path).unwrap();
    let runtime = AgentRuntime::with_store(config(), store).unwrap();

    assert!(runtime.session_ids().contains(&session_id));
}

#[test]
fn runtime_replays_waiting_tool_run_and_pending_request_from_sqlite() {
    let tempdir = tempfile::tempdir().unwrap();
    let db_path = tempdir.path().join("agent.sqlite");
    let (session_id, run_id) = {
        let store = SqliteEventStore::open(&db_path).unwrap();
        let mut runtime = AgentRuntime::with_store(tool_config(), store).unwrap();
        let session_id = runtime.create_session().unwrap();
        let turn = runtime
            .send_message_turn(SendMessageInput {
                session_id: session_id.clone(),
                parent_event_id: None,
                text: "use tool debug.echo".into(),
            })
            .unwrap();

        assert_eq!(turn.state, RunState::WaitingTool);
        assert_eq!(runtime.pending_tool_requests().len(), 1);
        (session_id, turn.run_id)
    };

    let store = SqliteEventStore::open(&db_path).unwrap();
    let mut runtime = AgentRuntime::with_store(tool_config(), store).unwrap();

    assert!(runtime.session_ids().contains(&session_id));
    assert_eq!(runtime.pending_tool_requests().len(), 1);
    assert_eq!(runtime.pending_tool_requests()[0].run_id.0, run_id);
    assert_eq!(runtime.pending_tool_requests()[0].tool_name, "debug.echo");

    let resumed = runtime
        .submit_tool_result(run_id, tool_result("echoed after restart"))
        .unwrap();

    assert_eq!(resumed.state, RunState::Completed);
    assert!(runtime.pending_tool_requests().is_empty());
}
