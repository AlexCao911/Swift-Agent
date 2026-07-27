use std::ffi::{c_char, CStr, CString};

use local_ios_agent_runtime::context::MockTokenizer;
use local_ios_agent_runtime::core::{AgentRuntime, AgentRuntimeConfig, MockStreamingProvider};
use local_ios_agent_runtime::ffi_bridge::{
    local_agent_runtime_bridge_begin_legacy_profile_migration, local_agent_runtime_bridge_free,
    local_agent_runtime_bridge_list_legacy_profile_migration_actions,
    local_agent_runtime_bridge_string_free, RuntimeJsonBridge,
};
use serde_json::{json, Value};

#[test]
fn migration_ffi_returns_only_portable_action_fields() {
    unsafe {
        let runtime = Box::into_raw(Box::new(RuntimeJsonBridge::new_development_seeded(
            AgentRuntime::new(AgentRuntimeConfig {
                system_prompt: "system".into(),
                runtime_policy: "policy".into(),
                tool_schemas: vec![],
                tokenizer: Box::new(MockTokenizer::new(100)),
                provider: Box::new(MockStreamingProvider::new()),
                tool_router: None,
            }),
        )));
        let request = CString::new(
            json!({
                "attempt_id":"ffi-migration-attempt",
                "profile_id":"profile_1",
                "profile_revision":1
            })
            .to_string(),
        )
        .unwrap();
        let action = decode(&take(
            local_agent_runtime_bridge_begin_legacy_profile_migration(runtime, request.as_ptr()),
        ));

        assert_eq!(action["state"], "pending");
        assert!(action["source_digest"].as_str().is_some());
        let encoded = action.to_string();
        for forbidden in [
            "provider_account",
            "provider_id",
            "credential",
            "base_url",
            "local_path",
            "engine_id",
            "request_field",
        ] {
            assert!(!encoded.contains(forbidden), "forbidden field: {forbidden}");
        }
        local_agent_runtime_bridge_free(runtime);
    }
}

#[test]
fn migration_action_inventory_does_not_begin_an_attempt() {
    unsafe {
        let runtime = Box::into_raw(Box::new(RuntimeJsonBridge::new_development_seeded(
            AgentRuntime::new(AgentRuntimeConfig {
                system_prompt: "system".into(),
                runtime_policy: "policy".into(),
                tool_schemas: vec![],
                tokenizer: Box::new(MockTokenizer::new(100)),
                provider: Box::new(MockStreamingProvider::new()),
                tool_router: None,
            }),
        )));
        let request = CString::new("{}").unwrap();
        let actions = decode(&take(
            local_agent_runtime_bridge_list_legacy_profile_migration_actions(
                runtime,
                request.as_ptr(),
            ),
        ));

        assert_eq!(actions.as_array().unwrap().len(), 1);
        assert!(actions[0]["successor"].is_null());
        assert_eq!(actions[0]["migration_subject"], "profile_1:1");
        local_agent_runtime_bridge_free(runtime);
    }
}

unsafe fn take(pointer: *mut c_char) -> String {
    assert!(!pointer.is_null());
    let value = CStr::from_ptr(pointer).to_string_lossy().into_owned();
    local_agent_runtime_bridge_string_free(pointer);
    value
}

fn decode(value: &str) -> Value {
    serde_json::from_str(value).unwrap()
}
