use local_ios_agent_runtime::context::{MockTokenizer, PromptFrame};
use local_ios_agent_runtime::core::{
    AgentError, AgentRuntime, AgentRuntimeConfig, CancellationToken, MockStreamingProvider,
    ModelProvider, ModelProviderOutput,
};
use local_ios_agent_runtime::ffi_bridge::{
    local_agent_runtime_bridge_create_session, local_agent_runtime_bridge_free,
    local_agent_runtime_bridge_new_with_config, local_agent_runtime_bridge_send_message,
    local_agent_runtime_bridge_send_message_streaming, local_agent_runtime_bridge_session_ids,
    local_agent_runtime_bridge_set_permission_state, local_agent_runtime_bridge_string_free,
    RuntimeJsonBridge,
};
use local_ios_agent_runtime::tool::ToolCall;
use serde_json::{json, Value};
use std::ffi::{c_void, CStr, CString};
use std::os::raw::c_char;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Condvar, Mutex,
};
use std::thread;
use std::time::{Duration, Instant};
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

#[derive(Clone, Debug)]
struct BlockingUntilCancelledProvider {
    probe: Arc<CancellationProbe>,
}

#[derive(Debug)]
struct CancellationProbe {
    started: (Mutex<bool>, Condvar),
    observed_cancelled: (Mutex<bool>, Condvar),
}

impl CancellationProbe {
    fn new() -> Self {
        Self {
            started: (Mutex::new(false), Condvar::new()),
            observed_cancelled: (Mutex::new(false), Condvar::new()),
        }
    }

    fn mark_started(&self) {
        let (lock, condition) = &self.started;
        *lock.lock().unwrap() = true;
        condition.notify_all();
    }

    fn mark_observed_cancelled(&self) {
        let (lock, condition) = &self.observed_cancelled;
        *lock.lock().unwrap() = true;
        condition.notify_all();
    }

    fn wait_for_started(&self) {
        wait_for_flag(&self.started);
    }

    fn wait_for_observed_cancelled(&self) {
        wait_for_flag(&self.observed_cancelled);
    }
}

impl ModelProvider for BlockingUntilCancelledProvider {
    fn id(&self) -> &str {
        "mock"
    }

    fn stream_chat(
        &self,
        _frame: &PromptFrame,
        cancellation: CancellationToken,
        on_output: &mut dyn FnMut(ModelProviderOutput) -> Result<(), AgentError>,
    ) -> Result<(), AgentError> {
        self.probe.mark_started();
        while !cancellation.is_cancelled() {
            thread::sleep(Duration::from_millis(5));
        }
        self.probe.mark_observed_cancelled();
        on_output(ModelProviderOutput::ToolCall(ToolCall {
            id: "call_cancelled".into(),
            name: "debug.echo".into(),
            arguments_json: r#"{"text":"cancelled"}"#.into(),
        }))?;
        Ok(())
    }
}

struct CallbackProbeProvider {
    delta_was_observed_by_ffi_callback: Arc<AtomicBool>,
}

impl ModelProvider for CallbackProbeProvider {
    fn id(&self) -> &str {
        "mock"
    }

    fn stream_chat(
        &self,
        _frame: &PromptFrame,
        _cancellation: CancellationToken,
        on_output: &mut dyn FnMut(ModelProviderOutput) -> Result<(), AgentError>,
    ) -> Result<(), AgentError> {
        on_output(ModelProviderOutput::TextDelta(
            "streamed token chunk longer than threshold".into(),
        ))?;
        assert!(
            self.delta_was_observed_by_ffi_callback
                .load(Ordering::SeqCst),
            "FFI event callback must observe the delta before provider stream_chat returns"
        );
        on_output(ModelProviderOutput::Completed(
            "streamed token chunk longer than threshold".into(),
        ))?;
        Ok(())
    }
}

unsafe extern "C" fn observe_stream_event(
    event_json: *const c_char,
    user_data: *mut c_void,
) -> i32 {
    assert!(!event_json.is_null());
    assert!(!user_data.is_null());
    let event = CStr::from_ptr(event_json).to_string_lossy();
    let event = decode(&event);
    if event["kind"] == "assistant_text_delta" {
        let observed = &*(user_data as *const AtomicBool);
        observed.store(true, Ordering::SeqCst);
    }
    0
}

fn wait_for_flag(flag: &(Mutex<bool>, Condvar)) {
    let started_at = Instant::now();
    let (lock, condition) = flag;
    let mut value = lock.lock().unwrap();
    while !*value {
        let (next_value, timeout) = condition
            .wait_timeout(value, Duration::from_millis(20))
            .unwrap();
        value = next_value;
        assert!(
            !timeout.timed_out() || started_at.elapsed() < Duration::from_secs(2),
            "timed out waiting for cancellation probe"
        );
    }
}

#[test]
fn c_abi_streaming_send_message_emits_events_during_provider_callback() {
    let observed_delta = Arc::new(AtomicBool::new(false));
    let runtime = RuntimeJsonBridge::new(AgentRuntime::new(AgentRuntimeConfig {
        system_prompt: "system".into(),
        runtime_policy: "policy".into(),
        tool_schemas: Vec::new(),
        tokenizer: Box::new(MockTokenizer::new(100)),
        provider: Box::new(CallbackProbeProvider {
            delta_was_observed_by_ffi_callback: observed_delta.clone(),
        }),
        tool_router: None,
    }));

    unsafe {
        let runtime = Box::into_raw(Box::new(runtime));
        let session = take_bridge_string(local_agent_runtime_bridge_create_session(runtime));
        let session_id = decode(&session).as_str().unwrap().to_string();
        let input = CString::new(format!(
            r#"{{"session_id":"{session_id}","parent_event_id":null,"text":"hello"}}"#
        ))
        .unwrap();

        let result = take_bridge_string(local_agent_runtime_bridge_send_message_streaming(
            runtime,
            input.as_ptr(),
            Some(observe_stream_event),
            Arc::as_ptr(&observed_delta) as *mut c_void,
        ));

        assert_eq!(decode(&result)["state"], "completed");
        assert!(observed_delta.load(Ordering::SeqCst));

        local_agent_runtime_bridge_free(runtime);
    }
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
    let bridge = bridge();

    let session = decode(&bridge.create_session_json().unwrap());
    let session_id = session.as_str().unwrap();
    assert!(session_id.starts_with("session_"));
    assert_eq!(
        decode(&bridge.session_ids_json().unwrap()),
        json!([session_id])
    );
    assert_eq!(
        decode(&bridge.latest_prompt_debug_snapshot_json().unwrap()),
        Value::Null
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
    let snapshot = decode(&bridge.latest_prompt_debug_snapshot_json().unwrap());
    assert!(snapshot["rendered_text"]
        .as_str()
        .unwrap()
        .contains("system\npolicy"));
    assert!(snapshot["rendered_text"]
        .as_str()
        .unwrap()
        .contains("hello"));
}

#[test]
fn bridge_exposes_provider_control_json() {
    let bridge = bridge();
    let session = decode(&bridge.create_session_json().unwrap());
    let session_id = session.as_str().unwrap();

    let profiles = decode(&bridge.provider_profiles_json().unwrap());
    assert_eq!(profiles[0]["id"], "mock");
    assert_eq!(profiles[0]["kind"], "mock");

    let active = decode(&bridge.active_provider_json().unwrap());
    assert_eq!(active["id"], "mock");

    let event = decode(
        &bridge
            .set_provider_json(&format!(
                r#"{{"session_id":"{session_id}","provider_id":"mock"}}"#
            ))
            .unwrap(),
    );
    assert_eq!(event["kind"], "provider_changed");
    assert!(event["payload"].as_str().unwrap().contains("mock"));
}

#[test]
fn bridge_config_can_create_runtime_with_desktop_minicpm_provider() {
    let bridge = RuntimeJsonBridge::from_config_json(
        r#"{
          "system_prompt": "configured system",
          "runtime_policy": "configured policy",
          "provider_id": "desktop_minicpm",
          "providers": [
            {
              "kind": "desktop_minicpm",
              "endpoint": "http://127.0.0.1:8000/v1/chat/completions",
              "model": "minicpm",
              "max_context_tokens": 4096
            }
          ],
          "store": {"kind": "in_memory"}
        }"#,
    )
    .unwrap();

    let profiles = decode(&bridge.provider_profiles_json().unwrap());
    assert!(profiles
        .as_array()
        .unwrap()
        .iter()
        .any(|profile| profile["id"] == "desktop_minicpm"));

    let active = decode(&bridge.active_provider_json().unwrap());
    assert_eq!(active["id"], "desktop_minicpm");
    assert_eq!(active["kind"], "desktop_mini_cpm");
    assert_eq!(active["max_context_tokens"], 4096);
}

#[test]
fn bridge_config_surfaces_unlinked_local_llm_provider() {
    let error = match RuntimeJsonBridge::from_config_json(
        r#"{
          "system_prompt": "configured system",
          "runtime_policy": "configured policy",
          "provider_id": "local_llm",
          "providers": [
            {
              "kind": "local_llm",
              "model": "local.gguf.simulator",
              "model_config_json": "{\"backend\":\"mock\",\"model_path\":\"/tmp/mock.gguf\"}",
              "max_context_tokens": 2048
            }
          ],
          "store": {"kind": "in_memory"}
        }"#,
    ) {
        Ok(_) => panic!("expected unlinked local_llm provider to fail"),
        Err(error) => error,
    };

    assert!(
        error
            .to_string()
            .contains("on-device backend is not linked"),
        "{error}"
    );
}

#[cfg(feature = "link-mock-local-inference")]
#[test]
fn bridge_config_can_create_runtime_with_local_llm_provider_when_linked() {
    let bridge = RuntimeJsonBridge::from_config_json(
        r#"{
          "system_prompt": "configured system",
          "runtime_policy": "configured policy",
          "provider_id": "local_llm",
          "providers": [
            {
              "kind": "local_llm",
              "model": "local.gguf.simulator",
              "model_config_json": "{\"backend\":\"mock\",\"model_path\":\"/tmp/mock.gguf\"}",
              "max_context_tokens": 2048
            }
          ],
          "store": {"kind": "in_memory"}
        }"#,
    )
    .unwrap();

    let active = decode(&bridge.active_provider_json().unwrap());
    assert_eq!(active["id"], "local_llm");
    assert_eq!(active["kind"], "local_llm");
    assert_eq!(active["max_context_tokens"], 2048);
}

#[test]
fn bridge_cancel_signals_provider_while_send_message_is_blocked() {
    let probe = Arc::new(CancellationProbe::new());
    let bridge = Arc::new(RuntimeJsonBridge::new(AgentRuntime::new(
        AgentRuntimeConfig {
            system_prompt: "system".into(),
            runtime_policy: "policy".into(),
            tool_schemas: Vec::new(),
            tokenizer: Box::new(MockTokenizer::new(100)),
            provider: Box::new(BlockingUntilCancelledProvider {
                probe: probe.clone(),
            }),
            tool_router: None,
        },
    )));
    let session = decode(&bridge.create_session_json().unwrap());
    let session_id = session.as_str().unwrap().to_string();
    bridge
        .register_tool_schema_json(
            r#"{"name":"debug.echo","description":"Echo","parameters_json_schema":"{\"type\":\"object\"}","risk_level":"read_only"}"#,
        )
        .unwrap();

    let sending_bridge = bridge.clone();
    let sender = thread::spawn(move || {
        sending_bridge
            .send_message_json(&format!(
                r#"{{"session_id":"{session_id}","parent_event_id":null,"text":"block"}}"#
            ))
            .unwrap()
    });
    probe.wait_for_started();

    let cancelling_bridge = bridge.clone();
    let canceller = thread::spawn(move || cancelling_bridge.cancel_json("run_3").unwrap());
    probe.wait_for_observed_cancelled();

    let turn = decode(&sender.join().unwrap());
    let cancelled = decode(&canceller.join().unwrap());

    assert_eq!(turn["state"], "waiting_tool");
    assert_eq!(cancelled["kind"], "run_cancelled");
    assert_eq!(cancelled["run_id"], "run_3");
}

#[test]
fn bridge_registers_tool_schema_and_completes_tool_lifecycle() {
    let bridge = bridge();
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
fn bridge_set_permission_state_affects_tool_policy() {
    let bridge = bridge();
    let session = decode(&bridge.create_session_json().unwrap());
    let session_id = session.as_str().unwrap();
    bridge
        .register_tool_schema_json(
            r#"{"name":"calendar.search_events","description":"Search events","parameters_json_schema":"{\"type\":\"object\"}","risk_level":"read_only","metadata_json":"{\"native_permission_scope\":\"calendar.events\"}"}"#,
        )
        .unwrap();
    bridge
        .set_permission_state_json(r#"{"scope":"calendar.events","state":"denied"}"#)
        .unwrap();

    let turn = decode(
        &bridge
            .send_message_json(&format!(
                r#"{{"session_id":"{session_id}","parent_event_id":null,"text":"use tool calendar.search_events"}}"#
            ))
            .unwrap(),
    );

    assert_eq!(turn["state"], "completed");
    assert_eq!(
        decode(&bridge.pending_tool_requests_json().unwrap()),
        json!([])
    );
}

#[test]
fn bridge_exposes_and_resolves_approval_requests_json() {
    let bridge = bridge();
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
    let run_id = turn["run_id"].as_str().unwrap();
    let tool_call_entry_id = turn["events"]
        .as_array()
        .unwrap()
        .iter()
        .find(|event| event["kind"] == "tool_call_requested")
        .and_then(|event| event["id"].as_str())
        .unwrap();
    assert_eq!(
        decode(&bridge.pending_tool_requests_json().unwrap()),
        json!([])
    );

    let approvals = decode(&bridge.pending_approval_requests_json().unwrap());
    assert_eq!(approvals.as_array().unwrap().len(), 1);
    let approval_id = approvals[0]["approval_id"].as_str().unwrap();
    assert!(approval_id.starts_with("approval_"));
    assert_eq!(approvals[0]["run_id"], run_id);
    assert_eq!(approvals[0]["tool_call_entry_id"], tool_call_entry_id);
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
    let bridge = bridge();
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
fn c_abi_accepts_permission_state_json() {
    unsafe {
        let runtime = new_in_memory_c_bridge();
        assert!(!runtime.is_null());
        let input = CString::new(r#"{"scope":"calendar.events","state":"denied"}"#).unwrap();

        let result = take_bridge_string(local_agent_runtime_bridge_set_permission_state(
            runtime,
            input.as_ptr(),
        ));

        assert_eq!(decode(&result), Value::Null);

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
