use local_ios_agent_runtime::context::MockTokenizer;
use local_ios_agent_runtime::core::{AgentRuntime, AgentRuntimeConfig, MockStreamingProvider};
use local_ios_agent_runtime::ffi_bridge::{
    local_agent_runtime_bridge_create_session, local_agent_runtime_bridge_free,
    local_agent_runtime_bridge_new_with_config, local_agent_runtime_bridge_send_message,
    local_agent_runtime_bridge_session_ids, local_agent_runtime_bridge_string_free,
    RuntimeJsonBridge,
};
use serde_json::{json, Value};
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use tempfile::tempdir;

fn bridge() -> RuntimeJsonBridge {
    RuntimeJsonBridge::new(AgentRuntime::new(AgentRuntimeConfig {
        system_prompt: "system".into(),
        runtime_policy: "policy".into(),
        tool_schemas: Vec::new(),
        tokenizer: Box::new(MockTokenizer::new(100)),
        provider: Box::new(MockStreamingProvider::new()),
        tool_router: None,
    }))
}

fn decode(json: &str) -> Value {
    serde_json::from_str(json).unwrap()
}

unsafe fn take_bridge_string(ptr: *mut c_char) -> String {
    assert!(!ptr.is_null());
    let text = CStr::from_ptr(ptr).to_string_lossy().into_owned();
    local_agent_runtime_bridge_string_free(ptr);
    text
}

unsafe fn new_in_memory_c_bridge() -> *mut RuntimeJsonBridge {
    let config = CString::new(
        r#"{
          "system_prompt": "configured system",
          "runtime_policy": "configured policy",
          "provider_id": "mock",
          "store": {"kind": "in_memory"}
        }"#,
    )
    .unwrap();
    local_agent_runtime_bridge_new_with_config(config.as_ptr())
}

#[test]
fn bridge_exposes_session_turn_and_prompt_snapshot_json() {
    let mut bridge = bridge();

    let session = decode(&bridge.create_session_json().unwrap());
    let session_id = session.as_str().unwrap();
    assert!(session_id.starts_with("session_"));
    assert_eq!(
        decode(&bridge.session_ids_json().unwrap()),
        json!([session_id])
    );

    let turn = decode(
        &bridge
            .send_message_json(&format!(
                r#"{{"session_id":"{session_id}","parent_event_id":null,"text":"hello"}}"#
            ))
            .unwrap(),
    );

    assert!(turn["run_id"].as_str().unwrap().starts_with("run_"));
    assert_eq!(turn["state"], "completed");
    assert_eq!(turn["pending_tool_call_id"], Value::Null);
    assert_eq!(turn["events"][0]["kind"], "user_message");
    assert_eq!(turn["events"][0]["session_id"], session_id);
    assert_eq!(turn["events"][0]["blob_refs"], json!([]));
    assert_eq!(
        decode(&bridge.latest_prompt_debug_snapshot_json().unwrap()),
        Value::Null
    );
}

#[test]
fn bridge_registers_tool_schema_and_completes_tool_lifecycle() {
    let mut bridge = bridge();
    let session = decode(&bridge.create_session_json().unwrap());
    let session_id = session.as_str().unwrap();
    bridge
        .register_tool_schema_json(
            r#"{"name":"debug.echo","description":"Echo","parameters_json_schema":"{\"type\":\"object\"}","risk_level":"read_only"}"#,
        )
        .unwrap();

    let turn = decode(
        &bridge
            .send_message_json(&format!(
                r#"{{"session_id":"{session_id}","parent_event_id":null,"text":"use tool debug.echo"}}"#
            ))
            .unwrap(),
    );
    let run_id = turn["run_id"].as_str().unwrap();

    assert_eq!(turn["state"], "waiting_tool");
    assert_eq!(turn["pending_tool_call_id"], "call_mock_1");

    let pending = decode(&bridge.pending_tool_requests_json().unwrap());
    assert_eq!(pending.as_array().unwrap().len(), 1);
    assert_eq!(pending[0]["run_id"], run_id);
    assert_eq!(pending[0]["session_id"], session_id);
    assert_eq!(pending[0]["tool_call_id"], "call_mock_1");
    assert_eq!(pending[0]["tool_name"], "debug.echo");
    assert_eq!(pending[0]["arguments_json"], r#"{"text":"hello"}"#);

    let resumed = decode(
        &bridge
            .submit_tool_result_json(
                run_id,
                r#"{"display_text":"echoed","model_text":"tool said hello","structured_json":"{}","audit_text":"audit","sensitivity":"public","retention":"run_only","is_error":false}"#,
            )
            .unwrap(),
    );

    assert_eq!(resumed["state"], "completed");
    assert_eq!(
        decode(&bridge.pending_tool_requests_json().unwrap()),
        json!([])
    );
}

#[test]
fn bridge_exposes_and_resolves_approval_requests_json() {
    let mut bridge = bridge();
    let session = decode(&bridge.create_session_json().unwrap());
    let session_id = session.as_str().unwrap();
    bridge
        .register_tool_schema_json(
            r#"{"name":"debug.echo","description":"Echo","parameters_json_schema":"{\"type\":\"object\"}","risk_level":"confirm"}"#,
        )
        .unwrap();

    let turn = decode(
        &bridge
            .send_message_json(&format!(
                r#"{{"session_id":"{session_id}","parent_event_id":null,"text":"use tool debug.echo"}}"#
            ))
            .unwrap(),
    );

    assert_eq!(turn["state"], "suspended");
    assert_eq!(
        decode(&bridge.pending_tool_requests_json().unwrap()),
        json!([])
    );

    let approvals = decode(&bridge.pending_approval_requests_json().unwrap());
    assert_eq!(approvals.as_array().unwrap().len(), 1);
    let approval_id = approvals[0]["approval_id"].as_str().unwrap();
    assert!(approval_id.starts_with("approval_"));
    assert_eq!(approvals[0]["requires_local_authentication"], true);

    let resumed = decode(
        &bridge
            .submit_approval_response_json(&format!(
                r#"{{"approval_id":"{approval_id}","approved":true,"reason":null}}"#
            ))
            .unwrap(),
    );

    assert_eq!(resumed["state"], "waiting_tool");
    assert_eq!(
        decode(&bridge.pending_approval_requests_json().unwrap()),
        json!([])
    );
    assert_eq!(
        decode(&bridge.pending_tool_requests_json().unwrap())[0]["run_id"],
        resumed["run_id"]
    );
}

#[test]
fn bridge_cancel_returns_runtime_event_json() {
    let mut bridge = bridge();
    let session = decode(&bridge.create_session_json().unwrap());
    let session_id = session.as_str().unwrap();
    bridge
        .register_tool_schema_json(
            r#"{"name":"debug.echo","description":"Echo","parameters_json_schema":"{\"type\":\"object\"}","risk_level":"read_only"}"#,
        )
        .unwrap();
    let turn = decode(
        &bridge
            .send_message_json(&format!(
                r#"{{"session_id":"{session_id}","parent_event_id":null,"text":"use tool debug.echo"}}"#
            ))
            .unwrap(),
    );

    let cancelled = decode(
        &bridge
            .cancel_json(turn["run_id"].as_str().unwrap())
            .unwrap(),
    );

    assert_eq!(cancelled["kind"], "run_cancelled");
    assert_eq!(cancelled["run_id"], turn["run_id"]);
}

#[test]
fn c_abi_returns_caller_owned_json_strings() {
    unsafe {
        let runtime = new_in_memory_c_bridge();
        assert!(!runtime.is_null());

        let session = take_bridge_string(local_agent_runtime_bridge_create_session(runtime));
        let session = decode(&session);
        let session_id = session.as_str().unwrap();
        assert!(session_id.starts_with("session_"));

        let session_ids = take_bridge_string(local_agent_runtime_bridge_session_ids(runtime));
        assert_eq!(decode(&session_ids), json!([session_id]));

        local_agent_runtime_bridge_free(runtime);
    }
}

#[test]
fn c_abi_returns_json_error_payloads() {
    unsafe {
        let runtime = new_in_memory_c_bridge();
        assert!(!runtime.is_null());
        let input = CString::new(r#"{"session_id":"session_1"}"#).unwrap();

        let error_json = take_bridge_string(local_agent_runtime_bridge_send_message(
            runtime,
            input.as_ptr(),
        ));
        let error = decode(&error_json);

        assert_eq!(error["error"]["kind"], "ffi");
        assert!(error["error"]["message"].as_str().unwrap().contains("text"));

        local_agent_runtime_bridge_free(runtime);
    }
}

#[test]
fn c_abi_constructor_uses_supplied_runtime_configuration() {
    let tempdir = tempdir().unwrap();
    let db_path = tempdir.path().join("agent.sqlite");
    let config = CString::new(format!(
        r#"{{
          "system_prompt": "configured system",
          "runtime_policy": "configured policy",
          "provider_id": "mock",
          "store": {{"kind": "sqlite", "path": "{}"}}
        }}"#,
        db_path.display()
    ))
    .unwrap();

    unsafe {
        let first = local_agent_runtime_bridge_new_with_config(config.as_ptr());
        assert!(!first.is_null());
        let created = take_bridge_string(local_agent_runtime_bridge_create_session(first));
        local_agent_runtime_bridge_free(first);

        let second = local_agent_runtime_bridge_new_with_config(config.as_ptr());
        assert!(!second.is_null());
        let session_ids = take_bridge_string(local_agent_runtime_bridge_session_ids(second));
        local_agent_runtime_bridge_free(second);

        assert_eq!(
            decode(&session_ids),
            json!([decode(&created).as_str().unwrap()])
        );
    }
}
