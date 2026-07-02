use std::collections::BTreeMap;
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int, c_void};
use std::sync::{Mutex, MutexGuard};

use serde::{Deserialize, Serialize};
use serde_json::json;

use crate::app_service::{AgentOSApplicationService, AgentOSApplicationServiceConfig};
use crate::context::{InferenceOptions, PromptFrame, TokenizerAdapter};
use crate::conversation::{ConversationFrameId, ConversationRunFrameRef};
use crate::core::{
    register_desktop_minicpm_provider, AgentError, AgentRuntime, AgentRuntimeConfig,
    AgentTurnResult, CAbiLocalInferenceBackend, DesktopMiniCPMSettings, EntryId, EventKind,
    LocalLLMProvider, ProviderBundle, ProviderCancellationRegistry, ProviderKind, ProviderProfile,
    ProviderRegistry, RunId, RunState, RuntimeEvent, SendMessageInput, SessionId,
};
use crate::execution::ExecutionPlanner;
use crate::memory::{EventStore, InMemoryEventStore, SqliteEventStore};
use crate::run_snapshot::StartRunRequest;
use crate::runtime::{RecordingEffectDriver, RuntimeExecutionDebugTrace};
use crate::security::{
    ApprovalProtocolRequest, ApprovalProtocolResponse, CredentialPurpose, PermissionScope,
    PermissionState, RiskLevel,
};
use crate::tool::{
    CompiledToolRecipe, CompiledToolRecipeContent, HttpResponseSensitivity, RetentionPolicy,
    Sensitivity, ToolExecutionRequest, ToolRecipeKind, ToolResult, ToolSchema,
};

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
    app_services: AgentOSApplicationService,
    debug_archives: Mutex<BTreeMap<String, RunDebugArchiveJson>>,
    next_agent_os_run_id: Mutex<u64>,
}

impl<S: EventStore> BridgeRuntime<S> {
    fn new(runtime: AgentRuntime<S>, app_services: AgentOSApplicationService) -> Self {
        let cancellations = runtime.provider_cancellation_registry();
        Self {
            runtime: Mutex::new(runtime),
            cancellations,
            app_services,
            debug_archives: Mutex::new(BTreeMap::new()),
            next_agent_os_run_id: Mutex::new(1),
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

    fn start_agent_os_run(&self, request: StartRunRequest) -> Result<RunHandleJson, AgentError> {
        let snapshot = self
            .app_services
            .resolve_and_persist_snapshot(request)
            .map_err(|error| AgentError::Storage(error.to_string()))?;
        let plan = ExecutionPlanner
            .plan(snapshot)
            .map_err(|error| AgentError::Storage(error.to_string()))?;
        let run_id = self.reserve_agent_os_run_id()?;
        let trace = self.lock()?.execute_plan_with_run_id(
            plan,
            run_id.clone(),
            RecordingEffectDriver::default(),
        )?;
        self.store_debug_archive(debug_archive_from_trace(&trace))?;
        Ok(RunHandleJson { run_id })
    }

    fn load_debug_archive(&self, run_id: &str) -> Result<RunDebugArchiveJson, AgentError> {
        self.debug_archives
            .lock()
            .map_err(|_| AgentError::Ffi("debug archive mutex poisoned".into()))?
            .get(run_id)
            .cloned()
            .ok_or_else(|| AgentError::Storage(format!("missing debug archive for run: {run_id}")))
    }

    fn reserve_agent_os_run_id(&self) -> Result<String, AgentError> {
        let mut next = self
            .next_agent_os_run_id
            .lock()
            .map_err(|_| AgentError::Ffi("agent os run id mutex poisoned".into()))?;
        let run_id = format!("run_{}", *next);
        *next += 1;
        Ok(run_id)
    }

    fn store_debug_archive(&self, archive: RunDebugArchiveJson) -> Result<(), AgentError> {
        self.debug_archives
            .lock()
            .map_err(|_| AgentError::Ffi("debug archive mutex poisoned".into()))?
            .insert(archive.run_id.clone(), archive);
        Ok(())
    }
}

impl RuntimeJsonBridge {
    pub fn new(runtime: AgentRuntime<InMemoryEventStore>) -> Self {
        Self::InMemory(BridgeRuntime::new(
            runtime,
            AgentOSApplicationService::empty(),
        ))
    }

    pub fn from_config_json(config_json: &str) -> Result<Self, AgentError> {
        let config: RuntimeBridgeConfigJson = from_json(config_json)?;
        let registry = config.provider_registry()?;
        let runtime_config = config.runtime_config(&registry)?;
        let app_services = AgentOSApplicationService::from_config(config.agent_os.into())
            .map_err(|error| AgentError::Storage(error.to_string()))?;
        match config.store {
            StoreConfigJson::InMemory { .. } => Ok(Self::InMemory(BridgeRuntime::new(
                AgentRuntime::with_store_and_registry(
                    runtime_config,
                    InMemoryEventStore::new(),
                    registry,
                )?,
                app_services,
            ))),
            StoreConfigJson::Sqlite { path, .. } => Ok(Self::Sqlite(BridgeRuntime::new(
                AgentRuntime::with_store_and_registry(
                    runtime_config,
                    SqliteEventStore::open(path)?,
                    registry,
                )?,
                app_services,
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
                search_text: summary.search_text,
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

    pub fn rename_session_json(&self, session_id: &str, title: &str) -> Result<String, AgentError> {
        let session_id = SessionId(session_id.to_string());
        match self {
            Self::InMemory(runtime) => runtime.lock()?.rename_session(&session_id, title.into())?,
            Self::Sqlite(runtime) => runtime.lock()?.rename_session(&session_id, title.into())?,
        }
        Ok("null".to_string())
    }

    pub fn update_runtime_options_json(&self, options_json: &str) -> Result<String, AgentError> {
        let options: RuntimeOptionsJson = from_json(options_json)?;
        let inference_options = InferenceOptions {
            temperature: options.temperature,
            top_p: options.top_p,
        };
        match self {
            Self::InMemory(runtime) => runtime.lock()?.update_runtime_options(
                options.system_prompt,
                options.runtime_policy,
                inference_options,
            )?,
            Self::Sqlite(runtime) => runtime.lock()?.update_runtime_options(
                options.system_prompt,
                options.runtime_policy,
                inference_options,
            )?,
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

    pub fn start_run_json(&self, request_json: &str) -> Result<String, AgentError> {
        let request: StartRunRequestJson = from_json(request_json)?;
        let request = StartRunRequest::new(
            request.agent_profile_id,
            request.user_intent,
            legacy_compatibility_frame_ref(),
        );
        let handle = match self {
            Self::InMemory(runtime) => runtime.start_agent_os_run(request),
            Self::Sqlite(runtime) => runtime.start_agent_os_run(request),
        }?;
        to_json(&handle)
    }

    pub fn load_debug_archive_json(&self, run_id: &str) -> Result<String, AgentError> {
        let archive = match self {
            Self::InMemory(runtime) => runtime.load_debug_archive(run_id),
            Self::Sqlite(runtime) => runtime.load_debug_archive(run_id),
        }?;
        to_json(&archive)
    }
}

fn legacy_compatibility_frame_ref() -> ConversationRunFrameRef {
    ConversationRunFrameRef::new(
        ConversationFrameId::new("legacy_agent_os_frame"),
        SessionId("legacy_agent_os_session".into()),
        EntryId("legacy_agent_os_branch_head".into()),
        EntryId("legacy_agent_os_user_turn".into()),
    )
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
pub unsafe extern "C" fn local_agent_runtime_bridge_rename_session(
    runtime: *mut RuntimeJsonBridge,
    session_id: *const c_char,
    title: *const c_char,
) -> *mut c_char {
    c_result(|| {
        let session_id = c_str_arg(session_id, "session_id")?;
        let title = c_str_arg(title, "title")?;
        bridge_ref(runtime)?.rename_session_json(session_id, title)
    })
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_update_runtime_options(
    runtime: *mut RuntimeJsonBridge,
    options_json: *const c_char,
) -> *mut c_char {
    c_result(|| {
        let options_json = c_str_arg(options_json, "options_json")?;
        bridge_ref(runtime)?.update_runtime_options_json(options_json)
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

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_start_run(
    runtime: *mut RuntimeJsonBridge,
    request_json: *const c_char,
) -> *mut c_char {
    c_result(|| {
        let request_json = c_str_arg(request_json, "request_json")?;
        bridge_ref(runtime)?.start_run_json(request_json)
    })
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_load_debug_archive(
    runtime: *mut RuntimeJsonBridge,
    run_id: *const c_char,
) -> *mut c_char {
    c_result(|| {
        let run_id = c_str_arg(run_id, "run_id")?;
        bridge_ref(runtime)?.load_debug_archive_json(run_id)
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
#[serde(deny_unknown_fields)]
struct StartRunRequestJson {
    agent_profile_id: String,
    user_intent: String,
}

#[derive(Serialize)]
struct RunHandleJson {
    run_id: String,
}

#[derive(Clone, Serialize)]
struct RunDebugArchiveJson {
    run_id: String,
    state: String,
    events: Vec<RunDebugEventJson>,
    archives: Vec<DebugArchiveJson>,
    checkpoints: Vec<CheckpointJson>,
}

#[derive(Clone, Serialize)]
struct RunDebugEventJson {
    id: String,
    code: String,
    title: String,
}

#[derive(Clone, Serialize)]
struct DebugArchiveJson {
    id: String,
    kind: String,
    title: String,
    redacted_payload: String,
    source_links: Vec<DebugArchiveSourceLinkJson>,
}

#[derive(Clone, Serialize)]
struct DebugArchiveSourceLinkJson {
    kind: String,
    target_id: String,
}

#[derive(Clone, Serialize)]
struct CheckpointJson {
    id: String,
    title: String,
    can_resume: bool,
}

#[derive(Deserialize)]
struct RuntimeBridgeConfigJson {
    system_prompt: String,
    runtime_policy: String,
    provider_id: String,
    #[serde(default)]
    providers: Vec<RuntimeProviderConfigJson>,
    store: StoreConfigJson,
    #[serde(default)]
    agent_os: RuntimeAgentOSConfigJson,
}

#[derive(Clone, Debug, Default, Deserialize)]
struct RuntimeAgentOSConfigJson {
    #[serde(default)]
    seed_development_profile: bool,
}

impl From<RuntimeAgentOSConfigJson> for AgentOSApplicationServiceConfig {
    fn from(value: RuntimeAgentOSConfigJson) -> Self {
        AgentOSApplicationServiceConfig::new()
            .with_seed_development_profile(value.seed_development_profile)
    }
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
    provenance: Option<String>,
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
            provenance: self
                .provenance
                .unwrap_or_else(|| "swift.tool_result".into()),
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
    search_text: String,
    active_leaf_id: Option<String>,
    last_event_id: Option<String>,
    last_updated_sequence: u64,
    last_updated_at_millis: u64,
}

#[derive(Deserialize)]
struct RuntimeOptionsJson {
    system_prompt: String,
    runtime_policy: String,
    temperature: Option<f32>,
    top_p: Option<f32>,
}

#[derive(Serialize)]
struct ToolExecutionRequestJson {
    run_id: String,
    session_id: String,
    tool_call_entry_id: String,
    tool_call_id: String,
    tool_name: String,
    arguments_json: String,
    compiled_recipe: Option<CompiledToolRecipeJson>,
}

impl ToolExecutionRequestJson {
    fn from_request(request: &ToolExecutionRequest) -> Self {
        Self {
            run_id: request.run_id().0.clone(),
            session_id: request.session_id().0.clone(),
            tool_call_entry_id: request.tool_call_entry_id().0.clone(),
            tool_call_id: request.tool_call_id().to_string(),
            tool_name: request.tool_name().to_string(),
            arguments_json: request.arguments_json().to_string(),
            compiled_recipe: request
                .compiled_recipe()
                .map(CompiledToolRecipeJson::from_recipe),
        }
    }
}

#[derive(Serialize)]
struct CompiledToolRecipeJson {
    name: String,
    kind: &'static str,
    approval_requirement: &'static str,
    base_tools: Vec<String>,
    has_side_effects: bool,
    content: CompiledToolRecipeContentJson,
}

impl CompiledToolRecipeJson {
    fn from_recipe(recipe: &CompiledToolRecipe) -> Self {
        Self {
            name: recipe.name.clone(),
            kind: tool_recipe_kind_json(recipe.kind),
            approval_requirement: match &recipe.approval_requirement {
                crate::security::ApprovalRequirement::Required => "required",
                crate::security::ApprovalRequirement::NotRequired => "not_required",
            },
            base_tools: recipe.base_tools.clone(),
            has_side_effects: recipe.has_side_effects,
            content: CompiledToolRecipeContentJson::from_content(&recipe.content),
        }
    }
}

#[derive(Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
enum CompiledToolRecipeContentJson {
    HttpConnector {
        endpoint: String,
        policy: HttpConnectorPolicyJson,
        credential_ref: Option<String>,
    },
    PureTransform {
        expression: String,
    },
    Alias {
        base_tool_name: String,
    },
    Workflow {
        steps: Vec<WorkflowStepJson>,
    },
}

impl CompiledToolRecipeContentJson {
    fn from_content(content: &CompiledToolRecipeContent) -> Self {
        match content {
            CompiledToolRecipeContent::HttpConnector {
                endpoint,
                policy,
                credential_ref,
            } => Self::HttpConnector {
                endpoint: endpoint.clone(),
                policy: HttpConnectorPolicyJson {
                    timeout_millis: policy.timeout_millis,
                    retry_max_attempts: policy
                        .retry_policy
                        .as_ref()
                        .map(|retry| retry.max_attempts),
                    requests_per_minute: policy
                        .rate_limit_policy
                        .as_ref()
                        .map(|rate_limit| rate_limit.requests_per_minute),
                    network_allowlist: policy.network_allowlist.clone(),
                    data_egress_disclosure: policy.data_egress_disclosure.clone(),
                    credential_purpose: policy.credential_purpose.map(credential_purpose_json),
                    response_sensitivity: policy
                        .response_sensitivity
                        .map(http_response_sensitivity_json),
                },
                credential_ref: credential_ref
                    .as_ref()
                    .map(|reference| reference.as_str().to_string()),
            },
            CompiledToolRecipeContent::PureTransform { expression } => Self::PureTransform {
                expression: expression.clone(),
            },
            CompiledToolRecipeContent::Alias { base_tool_name } => Self::Alias {
                base_tool_name: base_tool_name.clone(),
            },
            CompiledToolRecipeContent::Workflow { steps } => Self::Workflow {
                steps: steps
                    .iter()
                    .map(|step| WorkflowStepJson {
                        id: step.id.clone(),
                        tool_name: step.tool_name.clone(),
                        depends_on: step.depends_on.clone(),
                        on_failure: format!("{:?}", step.on_failure),
                        compensation_for: step.compensation_for.clone(),
                    })
                    .collect(),
            },
        }
    }
}

#[derive(Serialize)]
struct HttpConnectorPolicyJson {
    timeout_millis: Option<u64>,
    retry_max_attempts: Option<u8>,
    requests_per_minute: Option<u16>,
    network_allowlist: Vec<String>,
    data_egress_disclosure: Option<String>,
    credential_purpose: Option<&'static str>,
    response_sensitivity: Option<&'static str>,
}

#[derive(Serialize)]
struct WorkflowStepJson {
    id: String,
    tool_name: String,
    depends_on: Vec<String>,
    on_failure: String,
    compensation_for: Option<String>,
}

#[derive(Serialize)]
struct ApprovalProtocolRequestJson {
    approval_id: String,
    run_id: String,
    tool_call_entry_id: String,
    message: String,
    requires_local_authentication: bool,
    scope: crate::security::ApprovalProtocolScope,
}

impl ApprovalProtocolRequestJson {
    fn from_request(request: &ApprovalProtocolRequest) -> Self {
        Self {
            approval_id: request.approval_id.clone(),
            run_id: request.run_id.0.clone(),
            tool_call_entry_id: request.tool_call_entry_id.0.clone(),
            message: request.message.clone(),
            requires_local_authentication: request.requires_local_authentication,
            scope: request.scope.clone(),
        }
    }
}

fn to_json<T: Serialize>(value: &T) -> Result<String, AgentError> {
    serde_json::to_string(value).map_err(|error| AgentError::Ffi(error.to_string()))
}

fn from_json<T: for<'de> Deserialize<'de>>(json: &str) -> Result<T, AgentError> {
    serde_json::from_str(json).map_err(|error| AgentError::Ffi(error.to_string()))
}

fn debug_archive_from_trace(trace: &RuntimeExecutionDebugTrace) -> RunDebugArchiveJson {
    let events = trace
        .event_codes()
        .into_iter()
        .enumerate()
        .map(|(index, code)| RunDebugEventJson {
            id: format!("event_{}", index + 1),
            title: debug_title_for_event(&code),
            code,
        })
        .collect::<Vec<_>>();
    let archives = trace
        .archives()
        .iter()
        .map(|archive| DebugArchiveJson {
            id: archive.archive_id().to_string(),
            kind: archive.kind().to_string(),
            title: archive.title().to_string(),
            redacted_payload: archive.redacted_payload().to_string(),
            source_links: archive
                .source_links()
                .iter()
                .map(|source| DebugArchiveSourceLinkJson {
                    kind: source.kind().to_string(),
                    target_id: source.target_id().to_string(),
                })
                .collect(),
        })
        .collect();
    let checkpoints = if events
        .iter()
        .any(|event| event.code == "checkpoint.committed")
    {
        vec![CheckpointJson {
            id: "checkpoint_1".to_string(),
            title: "Checkpoint committed".to_string(),
            can_resume: true,
        }]
    } else {
        Vec::new()
    };
    RunDebugArchiveJson {
        run_id: trace.run_id().to_string(),
        state: trace.state().to_string(),
        events,
        archives,
        checkpoints,
    }
}

fn debug_title_for_event(code: &str) -> String {
    code.split(['.', '_'])
        .filter(|segment| !segment.is_empty())
        .map(|segment| {
            let mut chars = segment.chars();
            match chars.next() {
                Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
                None => String::new(),
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
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

fn tool_recipe_kind_json(kind: ToolRecipeKind) -> &'static str {
    match kind {
        ToolRecipeKind::HttpConnector => "http_connector",
        ToolRecipeKind::PureTransform => "pure_transform",
        ToolRecipeKind::Alias => "alias",
        ToolRecipeKind::Workflow => "workflow",
    }
}

fn credential_purpose_json(purpose: CredentialPurpose) -> &'static str {
    match purpose {
        CredentialPurpose::RemoteProvider => "remote_provider",
        CredentialPurpose::RemoteInference => "remote_inference",
        CredentialPurpose::HttpTool => "http_tool",
        CredentialPurpose::ExternalMemory => "external_memory",
    }
}

fn http_response_sensitivity_json(sensitivity: HttpResponseSensitivity) -> &'static str {
    match sensitivity {
        HttpResponseSensitivity::Public => "public",
        HttpResponseSensitivity::Private => "private",
        HttpResponseSensitivity::Secret => "secret",
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
