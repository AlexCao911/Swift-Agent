use std::ffi::{c_char, CStr, CString};
use std::path::Path;
use std::sync::Arc;

use local_ios_agent_runtime::app_service::{
    AgentBuilderCardDraftInput, AgentOSApplicationService, AgentOSApplicationServiceConfig,
};
use local_ios_agent_runtime::ffi_bridge::{
    local_agent_runtime_bridge_begin_legacy_profile_migration, local_agent_runtime_bridge_free,
    local_agent_runtime_bridge_list_legacy_profile_migration_actions,
    local_agent_runtime_bridge_new_with_config, local_agent_runtime_bridge_string_free,
};
use local_ios_agent_runtime::llm_contracts::{AgentLLMRequirements, LLMToolCallingMode};
use local_ios_agent_runtime::storage::SqliteRuntimeStateStore;
use rusqlite::params;
use serde_json::{json, Value};

const EPOCH: &str = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";

#[test]
fn migration_ffi_lists_and_begins_only_portable_actions() {
    let directory = tempfile::tempdir().unwrap();
    let path = seed_legacy_store(directory.path());
    let runtime = open_runtime(&path);

    unsafe {
        let empty = CString::new("{}").unwrap();
        let actions = decode(&take(
            local_agent_runtime_bridge_list_legacy_profile_migration_actions(
                runtime,
                empty.as_ptr(),
            ),
        ));
        assert_eq!(actions.as_array().unwrap().len(), 1);
        assert_eq!(actions[0]["migration_subject"], "legacy-profile:1");
        assert!(actions[0]["successor"].is_null());

        let request = CString::new(
            json!({
                "attempt_id": "ffi-migration-attempt",
                "profile_id": "legacy-profile",
                "profile_revision": 1
            })
            .to_string(),
        )
        .unwrap();
        let action = decode(&take(
            local_agent_runtime_bridge_begin_legacy_profile_migration(runtime, request.as_ptr()),
        ));
        assert_eq!(action["state"], "pending");
        assert_eq!(action["successor"]["profile_revision"], 2);

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

fn seed_legacy_store(root: &Path) -> std::path::PathBuf {
    let path = root.join("agent.sqlite");
    let store = Arc::new(SqliteRuntimeStateStore::open(&path).unwrap());
    let app = AgentOSApplicationService::from_runtime_state(
        AgentOSApplicationServiceConfig::new(),
        store.clone(),
    )
    .unwrap();
    let profile = app
        .build_agent_v2(
            "seed-legacy-profile",
            Some("legacy-profile"),
            "template.assistant.default",
            AgentBuilderCardDraftInput {
                display_name: Some("Legacy Agent".into()),
                persona: Some("Careful".into()),
                selected_tool_ids: vec!["contacts.read".into()],
                ..AgentBuilderCardDraftInput::default()
            },
            AgentLLMRequirements::new(
                "slot.model.primary",
                4_096,
                true,
                LLMToolCallingMode::Allowed,
            ),
        )
        .unwrap();
    let mut source = serde_json::to_value(profile).unwrap();
    source.as_object_mut().unwrap().remove("llm_slot");
    source["llm_binding"] = json!({
        "schema": "legacy_v1",
        "binding": {
            "slot_id": "slot.model.primary",
            "selection": {
                "provider_id": "openai",
                "model_id": "gpt-4.1-mini"
            }
        }
    });
    drop(app);
    drop(store);
    let connection = rusqlite::Connection::open(&path).unwrap();
    connection
        .execute(
            "update agent_profile_revisions
             set binding_schema = 'legacy_v1', host_binding_state = 'not_required',
                 revision_json = ?1
             where profile_id = 'legacy-profile' and profile_revision = '1'",
            params![source.to_string()],
        )
        .unwrap();
    path
}

fn open_runtime(path: &Path) -> *mut local_ios_agent_runtime::ffi_bridge::RuntimeJsonBridge {
    let config = CString::new(
        json!({
            "host_process_epoch": EPOCH,
            "store": {"kind": "sqlite", "path": path},
            "agent_os": {}
        })
        .to_string(),
    )
    .unwrap();
    let runtime = unsafe { local_agent_runtime_bridge_new_with_config(config.as_ptr()) };
    assert!(!runtime.is_null());
    runtime
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
