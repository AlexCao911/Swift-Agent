use std::ffi::{c_void, CStr, CString};
use std::os::raw::c_char;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};

use local_ios_agent_runtime::context::{MockTokenizer, PromptFrame};
use local_ios_agent_runtime::core::{
    AgentError, AgentRuntime, AgentRuntimeConfig, CancellationToken, ModelProvider,
    ModelProviderOutput,
};
use local_ios_agent_runtime::ffi_bridge::{
    local_agent_runtime_bridge_create_session, local_agent_runtime_bridge_free,
    local_agent_runtime_bridge_send_message_streaming, local_agent_runtime_bridge_string_free,
    RuntimeJsonBridge,
};
use serde_json::Value;

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
    let event: Value = serde_json::from_str(&event).unwrap();
    if event["kind"] == "assistant_text_delta" {
        let observed = &*(user_data as *const AtomicBool);
        observed.store(true, Ordering::SeqCst);
    }
    0
}

unsafe fn take_bridge_string(ptr: *mut c_char) -> String {
    assert!(!ptr.is_null());
    let text = CStr::from_ptr(ptr).to_string_lossy().into_owned();
    local_agent_runtime_bridge_string_free(ptr);
    text
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
        let session_id = serde_json::from_str::<Value>(&session)
            .unwrap()
            .as_str()
            .unwrap()
            .to_string();
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
        let result = serde_json::from_str::<Value>(&result).unwrap();

        assert_eq!(result["state"], "completed");
        assert!(observed_delta.load(Ordering::SeqCst));

        local_agent_runtime_bridge_free(runtime);
    }
}
