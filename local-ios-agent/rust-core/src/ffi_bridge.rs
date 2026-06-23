use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int, c_void};
use std::sync::{Mutex, MutexGuard};

use serde::{Deserialize, Serialize};
use serde_json::json;

use crate::context::{PromptFrame, TokenizerAdapter};
use crate::core::{
    register_desktop_minicpm_provider, AgentError, AgentRuntime, AgentRuntimeConfig,
    AgentTurnResult, CAbiLocalInferenceBackend, DesktopMiniCPMSettings, EntryId, EventKind,
    LocalLLMProvider, ProviderBundle, ProviderCancellationRegistry, ProviderKind, ProviderProfile,
    ProviderRegistry, RunId, RunState, RuntimeEvent, SendMessageInput, SessionId,
};
use crate::memory::{EventStore, InMemoryEventStore, SqliteEventStore};
use crate::security::{
    ApprovalProtocolRequest, ApprovalProtocolResponse, PermissionScope, PermissionState, RiskLevel,
};
use crate::tool::{RetentionPolicy, Sensitivity, ToolExecutionRequest, ToolResult, ToolSchema};

pub type RuntimeEventCallback =
    Option<unsafe extern "C" fn(event_json: *const c_char, user_data: *mut c_void) -> c_int>;

#[derive(Clone, Debug)]
struct BridgeWhitespaceTokenizer {
    provider_id: String,
    max_context_tokens: usize,
}

impl BridgeWhitespaceTokenizer {
    fn new(provider_id: impl Into<String>, max_context_tokens: usize) -> Self {
        Self {
            provider_id: provider_id.into(),
            max_context_tokens,
        }
    }
}

impl TokenizerAdapter for BridgeWhitespaceTokenizer {
    fn provider_id(&self) -> &str {
        &self.provider_id
    }

    fn max_context_tokens(&self) -> usize {
        self.max_context_tokens
    }

    fn safety_margin_tokens(&self) -> usize {
        let scaled = self.max_context_tokens / 16;
        scaled.max(32).min(512).min(self.max_context_tokens / 2)
    }

    fn count_text(&self, text: &str) -> usize {
        text.split_whitespace().count()
    }

    fn count_prompt_frame(&self, frame: &PromptFrame) -> usize {
        let mut count = self.count_text(&frame.system_prompt);
        count += self.count_text(&frame.runtime_policy);
        count += frame
            .tool_schemas
            .iter()
            .map(|tool| self.count_text(tool))
            .sum::<usize>();
        count += frame
            .messages
            .iter()
            .map(|message| self.count_text(message.content()))
            .sum::<usize>();
        count
    }

    fn boxed_clone(&self) -> Box<dyn TokenizerAdapter> {
        Box::new(self.clone())
    }
}

pub enum RuntimeJsonBridge {
    InMemory(BridgeRuntime<InMemoryEventStore>),
    Sqlite(BridgeRuntime<SqliteEventStore>),
}

pub struct BridgeRuntime<S: EventStore> {
    runtime: Mutex<AgentRuntime<S>>,
    cancellations: ProviderCancellationRegistry,
}

impl<S: EventStore> BridgeRuntime<S> {
    fn new(runtime: AgentRuntime<S>) -> Self {
        let cancellations = runtime.provider_cancellation_registry();
        Self {
            runtime: Mutex::new(runtime),
            cancellations,
        }
    }

    fn lock(&self) -> Result<MutexGuard<'_, AgentRuntime<S>>, AgentError> {
        self.runtime
            .lock()
            .map_err(|_| AgentError::Ffi("runtime bridge mutex poisoned".into()))
    }

    fn signal_provider_cancellation(&self, run_id: &RunId) {
        self.cancellations.signal(run_id);
    }
}

impl RuntimeJsonBridge {
    pub fn new(runtime: AgentRuntime<InMemoryEventStore>) -> Self {
        Self::InMemory(BridgeRuntime::new(runtime))
    }

    pub fn from_config_json(config_json: &str) -> Result<Self, AgentError> {
        let config: RuntimeBridgeConfigJson = from_json(config_json)?;
        let registry = config.provider_registry()?;
        let runtime_config = config.runtime_config(&registry)?;
        match config.store {
            StoreConfigJson::InMemory { .. } => Ok(Self::InMemory(BridgeRuntime::new(
                AgentRuntime::with_store_and_registry(
                    runtime_config,
                    InMemoryEventStore::new(),
                    registry,
                )?,
            ))),
            StoreConfigJson::Sqlite { path, .. } => Ok(Self::Sqlite(BridgeRuntime::new(
                AgentRuntime::with_store_and_registry(
                    runtime_config,
                    SqliteEventStore::open(path)?,
                    registry,
                )?,
            ))),
        }
    }

    pub fn create_session_json(&self) -> Result<String, AgentError> {
        let session_id = match self {
            Self::InMemory(runtime) => runtime.lock()?.create_session()?,
            Self::Sqlite(runtime) => runtime.lock()?.create_session()?,
        };
        to_json(&session_id.0)
    }

    pub fn session_ids_json(&self) -> Result<String, AgentError> {
        let session_ids: Vec<_> = match self {
            Self::InMemory(runtime) => runtime.lock()?.session_ids()?,
            Self::Sqlite(runtime) => runtime.lock()?.session_ids()?,
        }
        .into_iter()
        .map(|session_id| session_id.0)
        .collect();
        to_json(&session_ids)
    }

    pub fn conversation_summaries_json(&self) -> Result<String, AgentError> {
        let summaries = match self {
            Self::InMemory(runtime) => runtime.lock()?.conversation_summaries()?,
            Self::Sqlite(runtime) => runtime.lock()?.conversation_summaries()?,
        };
        let summaries: Vec<_> = summaries
            .into_iter()
            .map(|summary| ConversationSummaryJson {
                session_id: summary.session_id.0,
                title: summary.title,
                active_leaf_id: summary.active_leaf_id.map(|id| id.0),
                last_event_id: summary.last_event_id.map(|id| id.0),
                last_updated_sequence: summary.last_updated_sequence,
                last_updated_at_millis: summary.last_updated_at_millis,
            })
            .collect();
        to_json(&summaries)
    }

    pub fn fork_session_json(&self, session_id: &str, leaf_id: &str) -> Result<String, AgentError> {
        let source_session_id = SessionId(session_id.to_string());
        let leaf_id = EntryId(leaf_id.to_string());
        let forked_session_id = match self {
            Self::InMemory(runtime) => {
                runtime.lock()?.fork_session(&source_session_id, &leaf_id)?
            }
            Self::Sqlite(runtime) => runtime.lock()?.fork_session(&source_session_id, &leaf_id)?,
        };
        to_json(&forked_session_id.0)
    }

    pub fn archive_session_json(&self, session_id: &str) -> Result<String, AgentError> {
        let session_id = SessionId(session_id.to_string());
        match self {
            Self::InMemory(runtime) => runtime.lock()?.archive_session(&session_id)?,
            Self::Sqlite(runtime) => runtime.lock()?.archive_session(&session_id)?,
        }
        Ok("null".to_string())
    }

    pub fn delete_session_json(&self, session_id: &str) -> Result<String, AgentError> {
        let session_id = SessionId(session_id.to_string());
        match self {
            Self::InMemory(runtime) => runtime.lock()?.delete_session(&session_id)?,
            Self::Sqlite(runtime) => runtime.lock()?.delete_session(&session_id)?,
        }
        Ok("null".to_string())
    }

    pub fn active_branch_json(
        &self,
        session_id: &str,
        leaf_id: Option<&str>,
    ) -> Result<String, AgentError> {
        let session_id = SessionId(session_id.to_string());
        let leaf_id = leaf_id
            .filter(|value| !value.is_empty())
            .map(|value| EntryId(value.to_string()));
        let events = match self {
            Self::InMemory(runtime) => {
                runtime.lock()?.active_branch_events(&session_id, leaf_id)?
            }
            Self::Sqlite(runtime) => runtime.lock()?.active_branch_events(&session_id, leaf_id)?,
        };
        let events: Vec<_> = events.iter().map(RuntimeEventJson::from_event).collect();
        to_json(&events)
    }

    pub fn register_tool_schema_json(&self, schema_json: &str) -> Result<String, AgentError> {
        let schema: ToolSchemaJson = from_json(schema_json)?;
        let schema = schema.into_tool_schema()?;
        match self {
            Self::InMemory(runtime) => runtime.lock()?.register_tool(schema)?,
            Self::Sqlite(runtime) => runtime.lock()?.register_tool(schema)?,
        }
        Ok("null".to_string())
    }

    pub fn set_permission_state_json(&self, state_json: &str) -> Result<String, AgentError> {
        let state: PermissionStateJson = from_json(state_json)?;
        let permission = state.into_permission_scope()?;
        match self {
            Self::InMemory(runtime) => runtime.lock()?.set_permission(permission),
            Self::Sqlite(runtime) => runtime.lock()?.set_permission(permission),
        }
        Ok("null".to_string())
    }

    pub fn send_message_json(&self, input_json: &str) -> Result<String, AgentError> {
        let input: SendMessageJson = from_json(input_json)?;
        let input = SendMessageInput {
            session_id: SessionId(input.session_id),
            parent_event_id: input.parent_event_id.map(EntryId),
            text: input.text,
            blob_refs: input.blob_refs,
        };
        let result = match self {
            Self::InMemory(runtime) => runtime.lock()?.send_message_turn(input)?,
            Self::Sqlite(runtime) => runtime.lock()?.send_message_turn(input)?,
        };
        to_json(&AgentTurnResultJson::from_result(&result))
    }

    pub fn send_message_streaming_json(
        &self,
        input_json: &str,
        mut on_event: impl FnMut(&str) -> Result<(), AgentError>,
    ) -> Result<String, AgentError> {
        let input: SendMessageJson = from_json(input_json)?;
        let input = SendMessageInput {
            session_id: SessionId(input.session_id),
            parent_event_id: input.parent_event_id.map(EntryId),
            text: input.text,
            blob_refs: input.blob_refs,
        };
        let mut emit_event = |event: RuntimeEvent| {
            let event_json = to_json(&RuntimeEventJson::from_event(&event))?;
            on_event(&event_json)
        };
        let result = match self {
            Self::InMemory(runtime) => runtime
                .lock()?
                .send_message_streaming(input, &mut emit_event)?,
            Self::Sqlite(runtime) => runtime
                .lock()?
                .send_message_streaming(input, &mut emit_event)?,
        };
        to_json(&AgentTurnResultJson::from_result(&result))
    }

    pub fn pending_tool_requests_json(&self) -> Result<String, AgentError> {
        let requests: Vec<_> = match self {
            Self::InMemory(runtime) => {
                let runtime = runtime.lock()?;
                runtime
                    .pending_tool_requests()
                    .iter()
                    .map(ToolExecutionRequestJson::from_request)
                    .collect()
            }
            Self::Sqlite(runtime) => {
                let runtime = runtime.lock()?;
                runtime
                    .pending_tool_requests()
                    .iter()
                    .map(ToolExecutionRequestJson::from_request)
                    .collect()
            }
        };
        to_json(&requests)
    }

    pub fn pending_approval_requests_json(&self) -> Result<String, AgentError> {
        let requests: Vec<_> = match self {
            Self::InMemory(runtime) => runtime.lock()?.pending_approval_requests(),
            Self::Sqlite(runtime) => runtime.lock()?.pending_approval_requests(),
        }
        .iter()
        .map(ApprovalProtocolRequestJson::from_request)
        .collect();
        to_json(&requests)
    }

    pub fn submit_tool_result_json(
        &self,
        run_id: &str,
        result_json: &str,
    ) -> Result<String, AgentError> {
        let result: ToolResultJson = from_json(result_json)?;
        let result = result.into_tool_result()?;
        let turn = match self {
            Self::InMemory(runtime) => runtime
                .lock()?
                .submit_tool_result(run_id.to_string(), result),
            Self::Sqlite(runtime) => runtime
                .lock()?
                .submit_tool_result(run_id.to_string(), result),
        };
        to_json(&AgentTurnResultJson::from_result(&turn?))
    }

    pub fn submit_tool_result_streaming_json(
        &self,
        run_id: &str,
        result_json: &str,
        mut on_event: impl FnMut(&str) -> Result<(), AgentError>,
    ) -> Result<String, AgentError> {
        let result: ToolResultJson = from_json(result_json)?;
        let result = result.into_tool_result()?;
        let mut emit_event = |event: RuntimeEvent| {
            let event_json = to_json(&RuntimeEventJson::from_event(&event))?;
            on_event(&event_json)
        };
        let turn = match self {
            Self::InMemory(runtime) => runtime.lock()?.submit_tool_result_streaming(
                run_id.to_string(),
                result,
                &mut emit_event,
            ),
            Self::Sqlite(runtime) => runtime.lock()?.submit_tool_result_streaming(
                run_id.to_string(),
                result,
                &mut emit_event,
            ),
        };
        to_json(&AgentTurnResultJson::from_result(&turn?))
    }

    pub fn submit_approval_response_json(&self, response_json: &str) -> Result<String, AgentError> {
        let response: ApprovalProtocolResponseJson = from_json(response_json)?;
        let response = response.into_approval_response();
        let turn = match self {
            Self::InMemory(runtime) => runtime.lock()?.submit_approval_response(response),
            Self::Sqlite(runtime) => runtime.lock()?.submit_approval_response(response),
        };
        to_json(&AgentTurnResultJson::from_result(&turn?))
    }

    pub fn cancel_json(&self, run_id: &str) -> Result<String, AgentError> {
        let run_id_key = RunId(run_id.to_string());
        match self {
            Self::InMemory(runtime) => runtime.signal_provider_cancellation(&run_id_key),
            Self::Sqlite(runtime) => runtime.signal_provider_cancellation(&run_id_key),
        }
        let event = match self {
            Self::InMemory(runtime) => runtime.lock()?.cancel(run_id.to_string())?,
            Self::Sqlite(runtime) => runtime.lock()?.cancel(run_id.to_string())?,
        };
        to_json(&RuntimeEventJson::from_event(&event))
    }

    pub fn latest_prompt_debug_snapshot_json(&self) -> Result<String, AgentError> {
        let snapshot = match self {
            Self::InMemory(runtime) => runtime.lock()?.latest_prompt_debug_snapshot(),
            Self::Sqlite(runtime) => runtime.lock()?.latest_prompt_debug_snapshot(),
        };
        to_json(&snapshot)
    }

    pub fn provider_profiles_json(&self) -> Result<String, AgentError> {
        let profiles = match self {
            Self::InMemory(runtime) => runtime.lock()?.provider_profiles(),
            Self::Sqlite(runtime) => runtime.lock()?.provider_profiles(),
        };
        to_json(&profiles)
    }

    pub fn active_provider_json(&self) -> Result<String, AgentError> {
        let profile = match self {
            Self::InMemory(runtime) => runtime.lock()?.active_provider(),
            Self::Sqlite(runtime) => runtime.lock()?.active_provider(),
        };
        to_json(&profile)
    }

    pub fn set_provider_json(&self, request_json: &str) -> Result<String, AgentError> {
        let request: SetProviderJson = from_json(request_json)?;
        let event = match self {
            Self::InMemory(runtime) => runtime
                .lock()?
                .set_provider(SessionId(request.session_id), &request.provider_id)?,
            Self::Sqlite(runtime) => runtime
                .lock()?
                .set_provider(SessionId(request.session_id), &request.provider_id)?,
        };
        to_json(&RuntimeEventJson::from_event(&event))
    }
}

#[no_mangle]
pub extern "C" fn local_agent_runtime_bridge_new() -> *mut RuntimeJsonBridge {
    std::ptr::null_mut()
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_new_with_config(
    config_json: *const c_char,
) -> *mut RuntimeJsonBridge {
    let Ok(config_json) = c_str_arg(config_json, "config_json") else {
        return std::ptr::null_mut();
    };
    match RuntimeJsonBridge::from_config_json(config_json) {
        Ok(bridge) => Box::into_raw(Box::new(bridge)),
        Err(_) => std::ptr::null_mut(),
    }
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_free(runtime: *mut RuntimeJsonBridge) {
    if !runtime.is_null() {
        drop(Box::from_raw(runtime));
    }
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_string_free(value: *mut c_char) {
    if !value.is_null() {
        drop(CString::from_raw(value));
    }
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_create_session(
    runtime: *mut RuntimeJsonBridge,
) -> *mut c_char {
    c_result(|| bridge_ref(runtime)?.create_session_json())
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_session_ids(
    runtime: *mut RuntimeJsonBridge,
) -> *mut c_char {
    c_result(|| bridge_ref(runtime)?.session_ids_json())
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_conversation_summaries(
    runtime: *mut RuntimeJsonBridge,
) -> *mut c_char {
    c_result(|| bridge_ref(runtime)?.conversation_summaries_json())
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_fork_session(
    runtime: *mut RuntimeJsonBridge,
    session_id: *const c_char,
    leaf_id: *const c_char,
) -> *mut c_char {
    c_result(|| {
        let session_id = c_str_arg(session_id, "session_id")?;
        let leaf_id = c_str_arg(leaf_id, "leaf_id")?;
        bridge_ref(runtime)?.fork_session_json(session_id, leaf_id)
    })
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_active_branch(
    runtime: *mut RuntimeJsonBridge,
    session_id: *const c_char,
    leaf_id: *const c_char,
) -> *mut c_char {
    c_result(|| {
        let session_id = c_str_arg(session_id, "session_id")?;
        let leaf_id = optional_c_str_arg(leaf_id, "leaf_id")?;
        bridge_ref(runtime)?.active_branch_json(session_id, leaf_id)
    })
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_archive_session(
    runtime: *mut RuntimeJsonBridge,
    session_id: *const c_char,
) -> *mut c_char {
    c_result(|| {
        let session_id = c_str_arg(session_id, "session_id")?;
        bridge_ref(runtime)?.archive_session_json(session_id)
    })
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_delete_session(
    runtime: *mut RuntimeJsonBridge,
    session_id: *const c_char,
) -> *mut c_char {
    c_result(|| {
        let session_id = c_str_arg(session_id, "session_id")?;
        bridge_ref(runtime)?.delete_session_json(session_id)
    })
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_register_tool_schema(
    runtime: *mut RuntimeJsonBridge,
    schema_json: *const c_char,
) -> *mut c_char {
    c_result(|| {
        let schema_json = c_str_arg(schema_json, "schema_json")?;
        bridge_ref(runtime)?.register_tool_schema_json(schema_json)
    })
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_set_permission_state(
    runtime: *mut RuntimeJsonBridge,
    state_json: *const c_char,
) -> *mut c_char {
    c_result(|| {
        let state_json = c_str_arg(state_json, "state_json")?;
        bridge_ref(runtime)?.set_permission_state_json(state_json)
    })
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_send_message(
    runtime: *mut RuntimeJsonBridge,
    input_json: *const c_char,
) -> *mut c_char {
    c_result(|| {
        let input_json = c_str_arg(input_json, "input_json")?;
        bridge_ref(runtime)?.send_message_json(input_json)
    })
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_send_message_streaming(
    runtime: *mut RuntimeJsonBridge,
    input_json: *const c_char,
    on_event: RuntimeEventCallback,
    user_data: *mut c_void,
) -> *mut c_char {
    c_result(|| {
        let input_json = c_str_arg(input_json, "input_json")?;
        bridge_ref(runtime)?.send_message_streaming_json(input_json, |event_json| {
            dispatch_stream_event(on_event, user_data, event_json)
        })
    })
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_pending_tool_requests(
    runtime: *mut RuntimeJsonBridge,
) -> *mut c_char {
    c_result(|| bridge_ref(runtime)?.pending_tool_requests_json())
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_pending_approval_requests(
    runtime: *mut RuntimeJsonBridge,
) -> *mut c_char {
    c_result(|| bridge_ref(runtime)?.pending_approval_requests_json())
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_submit_tool_result(
    runtime: *mut RuntimeJsonBridge,
    run_id: *const c_char,
    result_json: *const c_char,
) -> *mut c_char {
    c_result(|| {
        let run_id = c_str_arg(run_id, "run_id")?;
        let result_json = c_str_arg(result_json, "result_json")?;
        bridge_ref(runtime)?.submit_tool_result_json(run_id, result_json)
    })
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_submit_tool_result_streaming(
    runtime: *mut RuntimeJsonBridge,
    run_id: *const c_char,
    result_json: *const c_char,
    on_event: RuntimeEventCallback,
    user_data: *mut c_void,
) -> *mut c_char {
    c_result(|| {
        let run_id = c_str_arg(run_id, "run_id")?;
        let result_json = c_str_arg(result_json, "result_json")?;
        bridge_ref(runtime)?.submit_tool_result_streaming_json(run_id, result_json, |event_json| {
            dispatch_stream_event(on_event, user_data, event_json)
        })
    })
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_submit_approval_response(
    runtime: *mut RuntimeJsonBridge,
    response_json: *const c_char,
) -> *mut c_char {
    c_result(|| {
        let response_json = c_str_arg(response_json, "response_json")?;
        bridge_ref(runtime)?.submit_approval_response_json(response_json)
    })
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_cancel(
    runtime: *mut RuntimeJsonBridge,
    run_id: *const c_char,
) -> *mut c_char {
    c_result(|| {
        let run_id = c_str_arg(run_id, "run_id")?;
        bridge_ref(runtime)?.cancel_json(run_id)
    })
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_latest_prompt_debug_snapshot(
    runtime: *mut RuntimeJsonBridge,
) -> *mut c_char {
    c_result(|| bridge_ref(runtime)?.latest_prompt_debug_snapshot_json())
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_provider_profiles(
    runtime: *mut RuntimeJsonBridge,
) -> *mut c_char {
    c_result(|| bridge_ref(runtime)?.provider_profiles_json())
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_active_provider(
    runtime: *mut RuntimeJsonBridge,
) -> *mut c_char {
    c_result(|| bridge_ref(runtime)?.active_provider_json())
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_set_provider(
    runtime: *mut RuntimeJsonBridge,
    request_json: *const c_char,
) -> *mut c_char {
    c_result(|| {
        let request_json = c_str_arg(request_json, "request_json")?;
        bridge_ref(runtime)?.set_provider_json(request_json)
    })
}

#[derive(Deserialize)]
struct SendMessageJson {
    session_id: String,
    parent_event_id: Option<String>,
    text: String,
    #[serde(default)]
    blob_refs: Vec<String>,
}

#[derive(Deserialize)]
struct SetProviderJson {
    session_id: String,
    provider_id: String,
}

#[derive(Deserialize)]
struct RuntimeBridgeConfigJson {
    system_prompt: String,
    runtime_policy: String,
    provider_id: String,
    #[serde(default)]
    providers: Vec<RuntimeProviderConfigJson>,
    store: StoreConfigJson,
}

impl RuntimeBridgeConfigJson {
    fn provider_registry(&self) -> Result<ProviderRegistry, AgentError> {
        let mut registry = ProviderRegistry::with_mock();
        for provider in &self.providers {
            provider.register(&mut registry)?;
        }
        Ok(registry)
    }

    fn runtime_config(
        &self,
        registry: &ProviderRegistry,
    ) -> Result<AgentRuntimeConfig, AgentError> {
        if registry.profile(&self.provider_id).is_none() {
            return Err(AgentError::Provider(format!(
                "unknown provider_id for bridge runtime: {}",
                self.provider_id
            )));
        }
        let bundle = registry.build(&self.provider_id)?;
        Ok(AgentRuntimeConfig {
            system_prompt: self.system_prompt.clone(),
            runtime_policy: self.runtime_policy.clone(),
            tool_schemas: Vec::new(),
            tokenizer: bundle.tokenizer,
            provider: bundle.provider,
            tool_router: None,
        })
    }
}

#[derive(Deserialize)]
#[serde(tag = "kind")]
enum RuntimeProviderConfigJson {
    #[serde(rename = "desktop_minicpm", alias = "desktop_mini_cpm")]
    DesktopMiniCpm {
        endpoint: String,
        model: String,
        max_context_tokens: usize,
    },
    #[serde(rename = "local_llm")]
    LocalLlm {
        model: String,
        model_config_json: String,
        max_context_tokens: usize,
    },
}

impl RuntimeProviderConfigJson {
    fn register(&self, registry: &mut ProviderRegistry) -> Result<(), AgentError> {
        match self {
            Self::DesktopMiniCpm {
                endpoint,
                model,
                max_context_tokens,
            } => register_desktop_minicpm_provider(
                registry,
                DesktopMiniCPMSettings {
                    endpoint: endpoint.clone(),
                    model: model.clone(),
                    max_context_tokens: *max_context_tokens,
                },
            ),
            Self::LocalLlm {
                model,
                model_config_json,
                max_context_tokens,
            } => {
                let model = model.clone();
                let model_config_json = model_config_json.clone();
                let max_context_tokens = *max_context_tokens;
                registry.register_fallible_factory(
                    ProviderProfile {
                        id: "local_llm".into(),
                        display_name: "Local LLM".into(),
                        kind: ProviderKind::LocalLlm,
                        max_context_tokens,
                    },
                    move || {
                        Ok(ProviderBundle {
                            provider: Box::new(LocalLLMProvider::new(
                                model.clone(),
                                model_config_json.clone(),
                                Box::new(CAbiLocalInferenceBackend::new()?),
                            )),
                            tokenizer: Box::new(BridgeWhitespaceTokenizer::new(
                                "local_llm",
                                max_context_tokens,
                            )),
                        })
                    },
                )
            }
        }
    }
}

#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
enum StoreConfigJson {
    InMemory {},
    Sqlite { path: String },
}

#[derive(Deserialize)]
struct ToolSchemaJson {
    name: String,
    description: String,
    parameters_json_schema: String,
    risk_level: String,
    metadata_json: Option<String>,
}

impl ToolSchemaJson {
    fn into_tool_schema(self) -> Result<ToolSchema, AgentError> {
        Ok(ToolSchema {
            name: self.name,
            description: self.description,
            parameters_json_schema: self.parameters_json_schema,
            risk_level: parse_risk_level(&self.risk_level)?,
            metadata_json: self.metadata_json,
        })
    }
}

#[derive(Deserialize)]
struct PermissionStateJson {
    scope: String,
    state: String,
}

impl PermissionStateJson {
    fn into_permission_scope(self) -> Result<PermissionScope, AgentError> {
        Ok(PermissionScope {
            name: self.scope,
            state: parse_permission_state(&self.state)?,
        })
    }
}

#[derive(Deserialize)]
struct ToolResultJson {
    display_text: String,
    model_text: String,
    structured_json: String,
    audit_text: String,
    sensitivity: String,
    retention: String,
    is_error: bool,
}

impl ToolResultJson {
    fn into_tool_result(self) -> Result<ToolResult, AgentError> {
        Ok(ToolResult {
            display_text: self.display_text,
            model_text: self.model_text,
            structured_json: self.structured_json,
            audit_text: self.audit_text,
            sensitivity: parse_sensitivity(&self.sensitivity)?,
            retention: parse_retention(&self.retention)?,
            is_error: self.is_error,
        })
    }
}

#[derive(Deserialize)]
struct ApprovalProtocolResponseJson {
    approval_id: String,
    approved: bool,
    reason: Option<String>,
}

impl ApprovalProtocolResponseJson {
    fn into_approval_response(self) -> ApprovalProtocolResponse {
        ApprovalProtocolResponse {
            approval_id: self.approval_id,
            approved: self.approved,
            reason: self.reason,
        }
    }
}

#[derive(Serialize)]
struct AgentTurnResultJson {
    run_id: String,
    state: &'static str,
    events: Vec<RuntimeEventJson>,
    pending_tool_call_id: Option<String>,
}

impl AgentTurnResultJson {
    fn from_result(result: &AgentTurnResult) -> Self {
        Self {
            run_id: result.run_id.clone(),
            state: run_state_json(&result.state),
            events: result
                .events
                .iter()
                .map(RuntimeEventJson::from_event)
                .collect(),
            pending_tool_call_id: result.pending_tool_call_id.clone(),
        }
    }
}

#[derive(Serialize)]
struct RuntimeEventJson {
    id: String,
    session_id: String,
    parent_id: Option<String>,
    run_id: Option<String>,
    sequence: u64,
    created_at_millis: u64,
    depth: u32,
    kind: &'static str,
    payload: String,
    blob_refs: Vec<String>,
}

impl RuntimeEventJson {
    fn from_event(event: &RuntimeEvent) -> Self {
        Self {
            id: event.id.0.clone(),
            session_id: event.session_id.0.clone(),
            parent_id: event.parent_id.as_ref().map(|id| id.0.clone()),
            run_id: event.run_id.as_ref().map(|id| id.0.clone()),
            sequence: event.sequence,
            created_at_millis: event.created_at_millis,
            depth: event.depth,
            kind: event_kind_json(&event.kind),
            payload: event.payload.clone(),
            blob_refs: event.blob_refs.clone(),
        }
    }
}

#[derive(Serialize)]
struct ConversationSummaryJson {
    session_id: String,
    title: String,
    active_leaf_id: Option<String>,
    last_event_id: Option<String>,
    last_updated_sequence: u64,
    last_updated_at_millis: u64,
}

#[derive(Serialize)]
struct ToolExecutionRequestJson {
    run_id: String,
    session_id: String,
    tool_call_entry_id: String,
    tool_call_id: String,
    tool_name: String,
    arguments_json: String,
}

impl ToolExecutionRequestJson {
    fn from_request(request: &ToolExecutionRequest) -> Self {
        Self {
            run_id: request.run_id.0.clone(),
            session_id: request.session_id.0.clone(),
            tool_call_entry_id: request.tool_call_entry_id.0.clone(),
            tool_call_id: request.tool_call_id.clone(),
            tool_name: request.tool_name.clone(),
            arguments_json: request.arguments_json.clone(),
        }
    }
}

#[derive(Serialize)]
struct ApprovalProtocolRequestJson {
    approval_id: String,
    run_id: String,
    tool_call_entry_id: String,
    message: String,
    requires_local_authentication: bool,
}

impl ApprovalProtocolRequestJson {
    fn from_request(request: &ApprovalProtocolRequest) -> Self {
        Self {
            approval_id: request.approval_id.clone(),
            run_id: request.run_id.0.clone(),
            tool_call_entry_id: request.tool_call_entry_id.0.clone(),
            message: request.message.clone(),
            requires_local_authentication: request.requires_local_authentication,
        }
    }
}

fn to_json<T: Serialize>(value: &T) -> Result<String, AgentError> {
    serde_json::to_string(value).map_err(|error| AgentError::Ffi(error.to_string()))
}

fn from_json<T: for<'de> Deserialize<'de>>(json: &str) -> Result<T, AgentError> {
    serde_json::from_str(json).map_err(|error| AgentError::Ffi(error.to_string()))
}

fn c_result(run: impl FnOnce() -> Result<String, AgentError>) -> *mut c_char {
    let json = match run() {
        Ok(json) => json,
        Err(error) => error_payload(&error),
    };
    into_c_string(json)
}

fn dispatch_stream_event(
    callback: RuntimeEventCallback,
    user_data: *mut c_void,
    event_json: &str,
) -> Result<(), AgentError> {
    let Some(callback) = callback else {
        return Ok(());
    };
    let event_json = CString::new(event_json).map_err(|error| {
        AgentError::Ffi(format!(
            "stream event contained interior nul byte at {}",
            error.nul_position()
        ))
    })?;
    let status = unsafe { callback(event_json.as_ptr(), user_data) };
    if status == 0 {
        Ok(())
    } else {
        Err(AgentError::Ffi(
            "stream event callback returned non-zero".into(),
        ))
    }
}

fn into_c_string(value: String) -> *mut c_char {
    match CString::new(value) {
        Ok(value) => value.into_raw(),
        Err(error) => CString::new(error_payload(&AgentError::Ffi(format!(
            "response contained interior nul byte at {}",
            error.nul_position()
        ))))
        .expect("static error JSON must not contain nul bytes")
        .into_raw(),
    }
}

unsafe fn bridge_ref<'a>(
    runtime: *const RuntimeJsonBridge,
) -> Result<&'a RuntimeJsonBridge, AgentError> {
    runtime
        .as_ref()
        .ok_or_else(|| AgentError::Ffi("runtime pointer must not be null".into()))
}

unsafe fn c_str_arg<'a>(value: *const c_char, name: &str) -> Result<&'a str, AgentError> {
    if value.is_null() {
        return Err(AgentError::Ffi(format!("{name} pointer must not be null")));
    }
    CStr::from_ptr(value)
        .to_str()
        .map_err(|error| AgentError::Ffi(format!("{name} must be UTF-8: {error}")))
}

unsafe fn optional_c_str_arg<'a>(
    value: *const c_char,
    name: &str,
) -> Result<Option<&'a str>, AgentError> {
    if value.is_null() {
        return Ok(None);
    }
    c_str_arg(value, name).map(Some)
}

fn error_payload(error: &AgentError) -> String {
    json!({
        "error": {
            "kind": agent_error_kind(error),
            "message": error.to_string(),
        }
    })
    .to_string()
}

fn agent_error_kind(error: &AgentError) -> &'static str {
    match error {
        AgentError::Storage(_) => "storage",
        AgentError::Provider(_) => "provider",
        AgentError::ToolParse(_) => "tool_parse",
        AgentError::ToolValidation(_) => "tool_validation",
        AgentError::ToolPermission(_) => "tool_permission",
        AgentError::ToolExecution(_) => "tool_execution",
        AgentError::PolicyDenied(_) => "policy_denied",
        AgentError::Cancelled(_) => "cancelled",
        AgentError::Ffi(_) => "ffi",
        AgentError::Unknown(_) => "unknown",
    }
}

fn parse_risk_level(value: &str) -> Result<RiskLevel, AgentError> {
    match value {
        "read_only" => Ok(RiskLevel::ReadOnly),
        "confirm" => Ok(RiskLevel::Confirm),
        "destructive" => Ok(RiskLevel::Destructive),
        other => Err(AgentError::ToolValidation(format!(
            "unknown risk_level: {other}"
        ))),
    }
}

fn parse_permission_state(value: &str) -> Result<PermissionState, AgentError> {
    match value {
        "not_determined" => Ok(PermissionState::NotDetermined),
        "granted" => Ok(PermissionState::Granted),
        "denied" => Ok(PermissionState::Denied),
        "restricted" => Ok(PermissionState::Restricted),
        other => Err(AgentError::ToolValidation(format!(
            "unknown permission state: {other}"
        ))),
    }
}

fn parse_sensitivity(value: &str) -> Result<Sensitivity, AgentError> {
    match value {
        "public" => Ok(Sensitivity::Public),
        "private" => Ok(Sensitivity::Private),
        "secret" => Ok(Sensitivity::Secret),
        other => Err(AgentError::ToolValidation(format!(
            "unknown sensitivity: {other}"
        ))),
    }
}

fn parse_retention(value: &str) -> Result<RetentionPolicy, AgentError> {
    match value {
        "run_only" => Ok(RetentionPolicy::RunOnly),
        "session" => Ok(RetentionPolicy::Session),
        "memory_candidate" => Ok(RetentionPolicy::MemoryCandidate),
        "audit_only" => Ok(RetentionPolicy::AuditOnly),
        other => Err(AgentError::ToolValidation(format!(
            "unknown retention: {other}"
        ))),
    }
}

fn run_state_json(state: &RunState) -> &'static str {
    match state {
        RunState::Running => "running",
        RunState::WaitingTool => "waiting_tool",
        RunState::Suspended => "suspended",
        RunState::Failed => "failed",
        RunState::Cancelled => "cancelled",
        RunState::Completed => "completed",
    }
}

fn event_kind_json(kind: &EventKind) -> &'static str {
    match kind {
        EventKind::SessionCreated => "session_created",
        EventKind::ProviderChanged => "provider_changed",
        EventKind::ToolRegistered => "tool_registered",
        EventKind::UserMessage => "user_message",
        EventKind::AssistantMessageStarted => "assistant_message_started",
        EventKind::AssistantTextDelta => "assistant_text_delta",
        EventKind::AssistantMessageCompleted => "assistant_message_completed",
        EventKind::ToolCallRequested => "tool_call_requested",
        EventKind::ToolCallApproved => "tool_call_approved",
        EventKind::ToolCallRejected => "tool_call_rejected",
        EventKind::ToolExecutionStarted => "tool_execution_started",
        EventKind::ToolExecutionUpdate => "tool_execution_update",
        EventKind::ToolExecutionCompleted => "tool_execution_completed",
        EventKind::ToolExecutionFailed => "tool_execution_failed",
        EventKind::ToolResultMessage => "tool_result_message",
        EventKind::RunSuspended => "run_suspended",
        EventKind::RunResumed => "run_resumed",
        EventKind::CompactionCreated => "compaction_created",
        EventKind::BranchSummaryCreated => "branch_summary_created",
        EventKind::RunCancelled => "run_cancelled",
        EventKind::RunFailed => "run_failed",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tool_schema_json_preserves_metadata_json() {
        let schema: ToolSchemaJson = from_json(
            r#"{"name":"calendar.search_events","description":"Search","parameters_json_schema":"{\"type\":\"object\"}","risk_level":"read_only","metadata_json":"{\"native_permission_scope\":\"calendar.events\"}"}"#,
        )
        .unwrap();

        let schema = schema.into_tool_schema().unwrap();

        assert_eq!(
            schema.metadata_json.as_deref(),
            Some(r#"{"native_permission_scope":"calendar.events"}"#)
        );
    }
}
