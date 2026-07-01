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
    tool_config_with_registry(tool_registry(RiskLevel::ReadOnly))
}

fn destructive_tool_config() -> AgentRuntimeConfig {
    tool_config_with_registry(tool_registry(RiskLevel::Destructive))
}

fn confirm_tool_config() -> AgentRuntimeConfig {
    tool_config_with_registry(tool_registry(RiskLevel::Confirm))
}

fn empty_tool_registry_config() -> AgentRuntimeConfig {
    tool_config_with_registry(ToolRegistry::new())
}

fn tool_registry(risk_level: RiskLevel) -> ToolRegistry {
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

fn tool_config_with_registry(registry: ToolRegistry) -> AgentRuntimeConfig {
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
        provenance: "tool.test".into(),
        is_error: false,
    }
}

#[test]
fn runtime_replays_sessions_from_sqlite() {
    let tempdir = tempfile::tempdir().unwrap();
    let db_path = tempdir.path().join("agent.sqlite");
    let blob_refs = vec!["local-agent-chat:v1:metadata".to_string()];
    let session_id = {
        let store = SqliteEventStore::open(&db_path).unwrap();
        let mut runtime = AgentRuntime::with_store(config(), store).unwrap();
        let session_id = runtime.create_session().unwrap();
        runtime
            .send_message(SendMessageInput {
                session_id: session_id.clone(),
                parent_event_id: None,
                text: "hello".into(),
                blob_refs: blob_refs.clone(),
            })
            .unwrap();
        session_id
    };

    let store = SqliteEventStore::open(&db_path).unwrap();
    let runtime = AgentRuntime::with_store(config(), store).unwrap();

    assert!(runtime.session_ids().unwrap().contains(&session_id));
    let replayed = runtime.active_branch_events(&session_id, None).unwrap();
    let user_event = replayed
        .iter()
        .find(|event| event.kind == EventKind::UserMessage)
        .unwrap();
    assert_eq!(user_event.blob_refs, blob_refs);
}

#[test]
fn runtime_replay_seeds_ids_from_archived_sqlite_sessions() {
    let tempdir = tempfile::tempdir().unwrap();
    let db_path = tempdir.path().join("agent.sqlite");
    let archived_session_id = {
        let store = SqliteEventStore::open(&db_path).unwrap();
        let mut runtime = AgentRuntime::with_store(config(), store).unwrap();
        let session_id = runtime.create_session().unwrap();
        runtime
            .send_message(SendMessageInput {
                session_id: session_id.clone(),
                parent_event_id: None,
                text: "archive me".into(),
                blob_refs: Vec::new(),
            })
            .unwrap();
        runtime.archive_session(&session_id).unwrap();
        session_id
    };

    let store = SqliteEventStore::open(&db_path).unwrap();
    let mut runtime = AgentRuntime::with_store(config(), store).unwrap();
    let next_session_id = runtime.create_session().unwrap();

    assert_ne!(next_session_id, archived_session_id);
    assert!(!runtime
        .session_ids()
        .unwrap()
        .contains(&archived_session_id));
    assert!(runtime.session_ids().unwrap().contains(&next_session_id));
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
                blob_refs: Vec::new(),
            })
            .unwrap();

        assert_eq!(turn.state, RunState::WaitingTool);
        assert_eq!(runtime.pending_tool_requests().len(), 1);
        (session_id, turn.run_id)
    };

    let store = SqliteEventStore::open(&db_path).unwrap();
    let mut runtime = AgentRuntime::with_store(tool_config(), store).unwrap();

    assert!(runtime.session_ids().unwrap().contains(&session_id));
    assert_eq!(runtime.pending_tool_requests().len(), 1);
    assert_eq!(runtime.pending_tool_requests()[0].run_id().0, run_id);
    assert_eq!(runtime.pending_tool_requests()[0].tool_name(), "debug.echo");

    let resumed = runtime
        .submit_tool_result(run_id, tool_result("echoed after restart"))
        .unwrap();

    assert_eq!(resumed.state, RunState::Completed);
    assert!(runtime.pending_tool_requests().is_empty());
}

#[test]
fn runtime_replays_suspended_approval_from_sqlite() {
    let tempdir = tempfile::tempdir().unwrap();
    let db_path = tempdir.path().join("agent.sqlite");
    let (session_id, approval_id) = {
        let store = SqliteEventStore::open(&db_path).unwrap();
        let mut runtime = AgentRuntime::with_store(confirm_tool_config(), store).unwrap();
        let session_id = runtime.create_session().unwrap();
        let turn = runtime
            .send_message_turn(SendMessageInput {
                session_id: session_id.clone(),
                parent_event_id: None,
                text: "use tool debug.echo".into(),
                blob_refs: Vec::new(),
            })
            .unwrap();

        assert_eq!(turn.state, RunState::Suspended);
        assert!(runtime.pending_tool_requests().is_empty());
        assert_eq!(runtime.pending_approval_requests().len(), 1);
        (
            session_id,
            runtime.pending_approval_requests()[0].approval_id.clone(),
        )
    };

    let store = SqliteEventStore::open(&db_path).unwrap();
    let runtime = AgentRuntime::with_store(confirm_tool_config(), store).unwrap();

    assert!(runtime.session_ids().unwrap().contains(&session_id));
    assert!(runtime.pending_tool_requests().is_empty());
    assert_eq!(runtime.pending_approval_requests().len(), 1);
    assert_eq!(
        runtime.pending_approval_requests()[0].approval_id,
        approval_id
    );
}

#[test]
fn runtime_replay_marks_waiting_tool_failed_when_policy_now_denies() {
    let tempdir = tempfile::tempdir().unwrap();
    let db_path = tempdir.path().join("agent.sqlite");
    let session_id = create_waiting_tool_run(&db_path);

    {
        let store = SqliteEventStore::open(&db_path).unwrap();
        let runtime = AgentRuntime::with_store(destructive_tool_config(), store).unwrap();
        assert!(runtime.pending_tool_requests().is_empty());
    }

    let store = SqliteEventStore::open(&db_path).unwrap();
    let last_event = store.last_event(&session_id).unwrap().unwrap();

    assert_eq!(last_event.kind, EventKind::RunFailed);
    assert!(last_event.payload.contains("replay"));
    assert!(last_event.payload.contains("denied"));
}

#[test]
fn runtime_replay_marks_waiting_tool_failed_when_tool_is_no_longer_registered() {
    let tempdir = tempfile::tempdir().unwrap();
    let db_path = tempdir.path().join("agent.sqlite");
    let session_id = create_waiting_tool_run(&db_path);

    {
        let store = SqliteEventStore::open(&db_path).unwrap();
        let runtime = AgentRuntime::with_store(empty_tool_registry_config(), store).unwrap();
        assert!(runtime.pending_tool_requests().is_empty());
    }

    let store = SqliteEventStore::open(&db_path).unwrap();
    let last_event = store.last_event(&session_id).unwrap().unwrap();

    assert_eq!(last_event.kind, EventKind::RunFailed);
    assert!(last_event.payload.contains("replay"));
    assert!(last_event.payload.contains("unknown tool"));
}

fn create_waiting_tool_run(db_path: &std::path::Path) -> SessionId {
    let store = SqliteEventStore::open(db_path).unwrap();
    let mut runtime = AgentRuntime::with_store(tool_config(), store).unwrap();
    let session_id = runtime.create_session().unwrap();
    let turn = runtime
        .send_message_turn(SendMessageInput {
            session_id: session_id.clone(),
            parent_event_id: None,
            text: "use tool debug.echo".into(),
            blob_refs: Vec::new(),
        })
        .unwrap();

    assert_eq!(turn.state, RunState::WaitingTool);
    assert_eq!(runtime.pending_tool_requests().len(), 1);
    session_id
}
