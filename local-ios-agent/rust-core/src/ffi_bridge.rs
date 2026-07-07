use std::any::Any;
use std::collections::BTreeMap;
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int, c_void};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Mutex, MutexGuard,
};

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::app_service::{AgentOSApplicationService, AgentOSApplicationServiceConfig};
use crate::context::{InferenceOptions, ModelInputMessages, PromptFrame, TokenizerAdapter};
use crate::conversation::{
    ConversationCommitError, ConversationCommitService, ConversationFrameId,
    ConversationFrameMessage, ConversationFrameRepository, ConversationRunFrame,
    ConversationRunFrameRef, ConversationService, InMemoryConversationFrameRepository,
    PrepareUserTurnRequest, PreparedUserTurn, RuntimeBranchEventReader,
};
use crate::core::{
    register_desktop_minicpm_provider, AgentError, AgentRuntime, AgentRuntimeConfig,
    AgentTurnResult, CAbiLocalInferenceBackend, DesktopMiniCPMSettings, EntryId, EventKind,
    LocalLLMProvider, ProviderBundle, ProviderCancellationRegistry, ProviderKind, ProviderProfile,
    ProviderRegistry, RunId, RunState, RuntimeEvent, SendMessageInput, SessionId,
};
use crate::execution::{
    CompletedRunRegistry, ExecutionEvent, ExecutionEventLog, ExecutionModelClient,
    ExecutionModelTurn, ExecutionPlanner, ExecutionService, ExecutionToolCall,
    ExecutionToolExecutor, ExecutionToolObservation, ExecutionToolOutcome,
    ExecutionWorkerDependencies, RunHandle, RuntimeOptions, StartExecutionRequest,
};
use crate::memory::{EventStore, InMemoryEventStore, SqliteEventStore};
use crate::security::{
    ApprovalProtocolRequest, ApprovalProtocolResponse, CredentialPurpose, PermissionScope,
    PermissionState, RiskLevel,
};
use crate::tool::{
    CompiledToolRecipe, CompiledToolRecipeContent, HttpResponseSensitivity, RetentionPolicy,
    Sensitivity, ToolCall, ToolExecutionRequest, ToolRecipeKind, ToolResult, ToolSchema,
};
use crate::user_customization::{AgentProfile, AgentProfileVersion};

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

#[derive(Clone)]
struct BridgeExecutionModelClient<S: EventStore + Send + 'static> {
    runtime: Arc<Mutex<AgentRuntime<S>>>,
}

#[derive(Clone)]
struct BridgeExecutionToolExecutor<S: EventStore + Send + 'static> {
    runtime: Arc<Mutex<AgentRuntime<S>>>,
}

impl<S: EventStore + Send + 'static> BridgeExecutionModelClient<S> {
    fn new(runtime: Arc<Mutex<AgentRuntime<S>>>) -> Self {
        Self { runtime }
    }
}

impl<S: EventStore + Send + 'static> BridgeExecutionToolExecutor<S> {
    fn new(runtime: Arc<Mutex<AgentRuntime<S>>>) -> Self {
        Self { runtime }
    }
}

impl<S: EventStore + Send + 'static> ExecutionModelClient for BridgeExecutionModelClient<S> {
    fn next_turn(
        &self,
        run_id: &str,
        input: &ModelInputMessages,
    ) -> Result<ExecutionModelTurn, String> {
        self.runtime
            .lock()
            .map_err(|_| "runtime bridge mutex poisoned".to_string())?
            .next_execution_model_turn(&RunId(run_id.to_string()), input)
            .map_err(|error| error.to_string())
    }
}

impl<S: EventStore + Send + 'static> ExecutionToolExecutor for BridgeExecutionToolExecutor<S> {
    fn execute_tool(
        &self,
        run_id: &str,
        frame_ref: &ConversationRunFrameRef,
        call: &ExecutionToolCall,
    ) -> Result<ExecutionToolOutcome, String> {
        self.runtime
            .lock()
            .map_err(|_| "runtime bridge mutex poisoned".to_string())?
            .route_execution_tool_call(
                &RunId(run_id.to_string()),
                frame_ref.session_id(),
                ToolCall {
                    id: call.call_id.clone(),
                    name: call.name.clone(),
                    arguments_json: call.arguments_json.clone(),
                },
            )
            .map_err(|error| error.to_string())
    }
}

pub enum RuntimeJsonBridge {
    InMemory(BridgeRuntime<InMemoryEventStore>),
    Sqlite(BridgeRuntime<SqliteEventStore>),
}

pub struct BridgeRuntime<S: EventStore + Send + 'static> {
    runtime: Arc<Mutex<AgentRuntime<S>>>,
    cancellations: ProviderCancellationRegistry,
    debug_archives: Mutex<BTreeMap<String, RunDebugArchiveJson>>,
    next_agent_os_run_id: Mutex<u64>,
    frames: InMemoryConversationFrameRepository,
    conversation:
        ConversationService<InMemoryConversationFrameRepository, RuntimeBranchEventReader<S>>,
    execution: ExecutionService<InMemoryConversationFrameRepository>,
    app_services: AgentOSApplicationService,
    conversation_commits: ConversationCommitService,
    ffi_tainted: AtomicBool,
}

impl<S: EventStore + Send + 'static> BridgeRuntime<S> {
    fn new(runtime: AgentRuntime<S>, app_services: AgentOSApplicationService) -> Self {
        let frames = InMemoryConversationFrameRepository::default();
        let cancellations = runtime.provider_cancellation_registry();
        let runtime = Arc::new(Mutex::new(runtime));
        let branch_reader = RuntimeBranchEventReader::new(runtime.clone());
        let event_log = ExecutionEventLog::default();
        let completed_runs = CompletedRunRegistry::default();
        let snapshot_service = app_services.snapshot_service();
        let worker_dependencies = ExecutionWorkerDependencies::new(
            Arc::new(BridgeExecutionModelClient::new(runtime.clone())),
            Arc::new(BridgeExecutionToolExecutor::new(runtime.clone())),
        );
        let execution = ExecutionService::with_runtime_parts(
            frames.clone(),
            snapshot_service,
            ExecutionPlanner,
            event_log,
            completed_runs.clone(),
            worker_dependencies,
        );
        let conversation = ConversationService::new(frames.clone(), branch_reader);
        let conversation_commits = ConversationCommitService::new(completed_runs);
        Self {
            runtime,
            cancellations,
            debug_archives: Mutex::new(BTreeMap::new()),
            next_agent_os_run_id: Mutex::new(1),
            frames,
            conversation,
            execution,
            app_services,
            conversation_commits,
            ffi_tainted: AtomicBool::new(false),
        }
    }

    fn mark_ffi_tainted(&self) {
        self.ffi_tainted.store(true, Ordering::SeqCst);
    }

    fn ensure_ffi_usable(&self) -> Result<(), AgentError> {
        if self.ffi_tainted.load(Ordering::SeqCst) {
            Err(AgentError::Ffi(
                "runtime bridge is tainted after a caught Rust panic; recreate the runtime".into(),
            ))
        } else {
            Ok(())
        }
    }

    fn lock(&self) -> Result<MutexGuard<'_, AgentRuntime<S>>, AgentError> {
        self.runtime
            .lock()
            .map_err(|_| AgentError::Ffi("runtime bridge mutex poisoned".into()))
    }

    fn conversation(
        &self,
    ) -> &ConversationService<InMemoryConversationFrameRepository, RuntimeBranchEventReader<S>>
    {
        &self.conversation
    }

    fn execution(&self) -> &ExecutionService<InMemoryConversationFrameRepository> {
        &self.execution
    }

    fn conversation_commits(&self) -> &ConversationCommitService {
        &self.conversation_commits
    }

    fn frames(&self) -> &InMemoryConversationFrameRepository {
        &self.frames
    }

    fn signal_provider_cancellation(&self, run_id: &RunId) {
        self.cancellations.signal(run_id);
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

    fn list_agent_profiles_json(&self, request_json: &str) -> Result<String, AgentError> {
        let _: EmptyAgentOSRequestJson = from_json(request_json)?;
        let profiles: Vec<_> = self
            .app_services
            .list_agent_profiles()
            .iter()
            .map(AgentProfileJson::from)
            .collect();
        to_json(&profiles)
    }

    fn build_agent_json(&self, request_json: &str) -> Result<String, AgentError> {
        let request: BuildAgentRequestJson = from_json(request_json)?;
        let profile = self
            .app_services
            .build_agent_from_template(&request.template_id)
            .map_err(|error| AgentError::Storage(format!("{}: {error}", error.code())))?;
        to_json(&AgentProfileJson::from(&profile))
    }

    fn prepare_user_turn_json(&self, request_json: &str) -> Result<String, AgentError> {
        let request: PrepareUserTurnRequestJson = from_json(request_json)?;
        let text = request.text;
        let blob_refs = request.blob_refs;
        let persisted_user_turn = self.lock()?.prepare_conversation_user_turn(
            request.session_id.map(SessionId),
            request.parent_event_id.map(EntryId),
            text.clone(),
            blob_refs.clone(),
        )?;
        let prepared = self
            .conversation()
            .prepare_user_turn(
                PrepareUserTurnRequest::new(
                    Some(persisted_user_turn.session_id),
                    persisted_user_turn.parent_event_id,
                    text,
                    blob_refs,
                )
                .with_persisted_user_turn_id(persisted_user_turn.user_turn_id),
            )
            .map_err(|error| AgentError::Storage(format!("{}: {error}", error.code())))?;
        let frame_preview = self
            .frames()
            .get(prepared.conversation_run_frame_ref())
            .as_ref()
            .map(ConversationRunFrameJson::from);
        to_json(&PreparedUserTurnJson::from_prepared(
            prepared,
            frame_preview,
        ))
    }

    fn start_run_json(&self, request_json: &str) -> Result<String, AgentError> {
        let request: StartRunRequestJson = from_json(request_json)?;
        let options = self.runtime_options_for_start_run(request.options)?;
        self.execution()
            .update_runtime_options(options)
            .map_err(|error| AgentError::Storage(format!("{}: {error}", error.code())))?;
        let frame_ref = request.conversation_run_frame_ref.into_domain();
        let run_id = self.reserve_agent_os_run_id()?;
        let handle = self
            .execution()
            .start_run(StartExecutionRequest::new(
                run_id,
                request.agent_profile_id,
                AgentProfileVersion::new(request.profile_revision_id),
                request.user_intent,
                frame_ref,
            ))
            .map_err(|error| AgentError::Storage(format!("{}: {error}", error.code())))?;
        to_json(&RunHandleJson::from(handle))
    }

    fn runtime_options_for_start_run(&self, options: Value) -> Result<RuntimeOptions, AgentError> {
        let start_options = StartRunOptionsJson::from_value(options)?;
        let defaults = self
            .execution()
            .runtime_options()
            .map(Ok)
            .unwrap_or_else(|| {
                let (system_prompt, runtime_policy) = self.lock()?.runtime_prompt_defaults();
                Ok(RuntimeOptions {
                    system_prompt,
                    runtime_policy,
                    temperature: None,
                    top_p: None,
                })
            })?;
        Ok(start_options.into_domain(defaults))
    }

    fn observe_events_stream_json<F>(
        &self,
        request_json: &str,
        mut emit: F,
    ) -> Result<(), AgentError>
    where
        F: FnMut(String) -> Result<(), AgentError>,
    {
        let request: ObserveExecutionEventsRequestJson = from_json(request_json)?;
        let mut stream = self
            .execution()
            .observe_event_stream(&request.run_id, Some(request.from_sequence));
        let mut last_sequence = request.from_sequence;
        let mut boundary_observed = false;

        for event in stream.replay() {
            if event.sequence() <= last_sequence {
                continue;
            }
            boundary_observed |= is_execution_stream_boundary(event);
            last_sequence = event.sequence();
            emit(to_json(&RuntimeEventJson::from_execution_event(event))?)?;
        }

        if boundary_observed {
            return Ok(());
        }

        while let Some(event) = stream.next_live() {
            if event.sequence() <= last_sequence {
                continue;
            }
            let boundary = is_execution_stream_boundary(&event);
            last_sequence = event.sequence();
            emit(to_json(&RuntimeEventJson::from_execution_event(&event))?)?;
            if boundary {
                break;
            }
        }

        Ok(())
    }

    fn observe_events_json(&self, request_json: &str) -> Result<String, AgentError> {
        let request: ObserveExecutionEventsRequestJson = from_json(request_json)?;
        let events = self
            .execution()
            .observe_events(&request.run_id, Some(request.from_sequence));
        to_json(
            &events
                .iter()
                .map(RuntimeEventJson::from_execution_event)
                .collect::<Vec<_>>(),
        )
    }

    fn commit_assistant_result_json(&self, request_json: &str) -> Result<String, AgentError> {
        let request: CommitAssistantResultRequestJson = from_json(request_json)?;
        let frame_ref = request.conversation_run_frame_ref.into_domain();
        let record = self
            .conversation_commits()
            .commit_assistant_result_with_persist(
                &request.run_id,
                &request.final_message_id,
                &frame_ref,
                |completed| {
                    self.lock()
                        .and_then(|mut runtime| {
                            runtime.commit_conversation_assistant_result(
                                completed.conversation_run_frame_ref(),
                                completed.run_id(),
                                completed.final_text(),
                            )
                        })
                        .map(|entry_id| entry_id.0)
                        .map_err(|error| {
                            ConversationCommitError::new(
                                "conversation_commit.persist_failed",
                                error.to_string(),
                            )
                        })
                },
            )
            .map_err(|error| AgentError::Storage(format!("{}: {error}", error.code())))?;
        to_json(&ConversationCommitResultJson {
            committed_message_id: record.assistant_message_id().to_string(),
            already_committed: record.already_committed(),
        })
    }

    fn approve_tool_json(&self, request_json: &str) -> Result<String, AgentError> {
        let request: ApproveToolRequestJson = from_json(request_json)?;
        let resolved = self
            .lock()?
            .approve_execution_tool_request(ApprovalProtocolResponse {
                approval_id: request.id,
                approved: request.decision.approved,
                reason: request.decision.reason,
            })?;
        if let Some(call_id) = resolved.approved_tool_call_id {
            self.execution().record_external_event(
                &resolved.run_id.0,
                "tool_call_approved",
                json!({ "call_id": call_id.clone() }).to_string(),
            );
            self.execution().record_external_event(
                &resolved.run_id.0,
                "run.waiting_tool",
                json!({ "call_id": call_id }).to_string(),
            );
        } else if !resolved.approved {
            self.execution().record_external_event(
                &resolved.run_id.0,
                "tool_call_rejected",
                json!({ "message": resolved.message.clone() }).to_string(),
            );
            self.execution().record_external_event(
                &resolved.run_id.0,
                "run.failed",
                json!({
                    "message": format!("tool approval rejected: {}", resolved.message)
                })
                .to_string(),
            );
        }
        to_json(&EmptyAgentOSResponseJson {})
    }

    fn cancel_run_json(&self, request_json: &str) -> Result<String, AgentError> {
        let request: CancelRunRequestJson = from_json(request_json)?;
        let event = self.lock()?.cancel(request.run_id)?;
        to_json(&RuntimeEventJson::from_event(&event))
    }

    fn update_execution_runtime_options_json(
        &self,
        request_json: &str,
    ) -> Result<String, AgentError> {
        let request: RuntimeOptionsJson = from_json(request_json)?;
        self.execution()
            .update_runtime_options(request.into_domain())
            .map_err(|error| AgentError::Storage(format!("{}: {error}", error.code())))?;
        to_json(&EmptyAgentOSResponseJson {})
    }

    fn submit_tool_result_json(
        &self,
        run_id: &str,
        result_json: &str,
    ) -> Result<String, AgentError> {
        let result: ToolResultJson = from_json(result_json)?;
        let mut result = result.into_tool_result()?;

        if self.execution().has_active_run(run_id) {
            let run_id_key = RunId(run_id.to_string());
            let request = self
                .lock()?
                .consume_execution_pending_tool_request(&run_id_key)?;
            if matches!(result.provenance.as_str(), "" | "swift.tool_result") {
                result.provenance = format!("tool.{}", request.tool_name());
            }
            let events = self
                .execution()
                .submit_tool_observation(
                    run_id,
                    ExecutionToolObservation {
                        call_id: request.tool_call_id().to_string(),
                        model_text: result.model_text,
                    },
                )
                .map_err(|error| AgentError::Storage(format!("{}: {error}", error.code())))?;
            return to_json(&AgentTurnResultJson::from_execution_events(run_id, &events));
        }

        let turn = self
            .lock()?
            .submit_tool_result(run_id.to_string(), result)?;
        to_json(&AgentTurnResultJson::from_result(&turn))
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

    fn mark_ffi_tainted(&self) {
        match self {
            Self::InMemory(runtime) => runtime.mark_ffi_tainted(),
            Self::Sqlite(runtime) => runtime.mark_ffi_tainted(),
        }
    }

    fn ensure_ffi_usable(&self) -> Result<(), AgentError> {
        match self {
            Self::InMemory(runtime) => runtime.ensure_ffi_usable(),
            Self::Sqlite(runtime) => runtime.ensure_ffi_usable(),
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
        match self {
            Self::InMemory(runtime) => {
                runtime.update_execution_runtime_options_json(options_json)?;
            }
            Self::Sqlite(runtime) => {
                runtime.update_execution_runtime_options_json(options_json)?;
            }
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
        match self {
            Self::InMemory(runtime) => runtime.submit_tool_result_json(run_id, result_json),
            Self::Sqlite(runtime) => runtime.submit_tool_result_json(run_id, result_json),
        }
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
        let handle = match self {
            Self::InMemory(runtime) => runtime.start_run_json(request_json),
            Self::Sqlite(runtime) => runtime.start_run_json(request_json),
        }?;
        Ok(handle)
    }

    pub fn list_agent_profiles_json(&self, request_json: &str) -> Result<String, AgentError> {
        match self {
            Self::InMemory(runtime) => runtime.list_agent_profiles_json(request_json),
            Self::Sqlite(runtime) => runtime.list_agent_profiles_json(request_json),
        }
    }

    pub fn build_agent_json(&self, request_json: &str) -> Result<String, AgentError> {
        match self {
            Self::InMemory(runtime) => runtime.build_agent_json(request_json),
            Self::Sqlite(runtime) => runtime.build_agent_json(request_json),
        }
    }

    pub fn prepare_user_turn_json(&self, request_json: &str) -> Result<String, AgentError> {
        match self {
            Self::InMemory(runtime) => runtime.prepare_user_turn_json(request_json),
            Self::Sqlite(runtime) => runtime.prepare_user_turn_json(request_json),
        }
    }

    pub fn observe_events_stream_json<F>(
        &self,
        request_json: &str,
        mut emit: F,
    ) -> Result<(), AgentError>
    where
        F: FnMut(String) -> Result<(), AgentError>,
    {
        match self {
            Self::InMemory(runtime) => runtime.observe_events_stream_json(request_json, &mut emit),
            Self::Sqlite(runtime) => runtime.observe_events_stream_json(request_json, &mut emit),
        }
    }

    pub fn observe_events_json(&self, request_json: &str) -> Result<String, AgentError> {
        match self {
            Self::InMemory(runtime) => runtime.observe_events_json(request_json),
            Self::Sqlite(runtime) => runtime.observe_events_json(request_json),
        }
    }

    pub fn commit_assistant_result_json(&self, request_json: &str) -> Result<String, AgentError> {
        match self {
            Self::InMemory(runtime) => runtime.commit_assistant_result_json(request_json),
            Self::Sqlite(runtime) => runtime.commit_assistant_result_json(request_json),
        }
    }

    pub fn approve_tool_json(&self, request_json: &str) -> Result<String, AgentError> {
        match self {
            Self::InMemory(runtime) => runtime.approve_tool_json(request_json),
            Self::Sqlite(runtime) => runtime.approve_tool_json(request_json),
        }
    }

    pub fn cancel_run_json(&self, request_json: &str) -> Result<String, AgentError> {
        match self {
            Self::InMemory(runtime) => runtime.cancel_run_json(request_json),
            Self::Sqlite(runtime) => runtime.cancel_run_json(request_json),
        }
    }

    pub fn load_debug_archive_json(&self, run_id: &str) -> Result<String, AgentError> {
        let archive = match self {
            Self::InMemory(runtime) => runtime.load_debug_archive(run_id),
            Self::Sqlite(runtime) => runtime.load_debug_archive(run_id),
        }?;
        to_json(&archive)
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
    match catch_unwind(AssertUnwindSafe(|| {
        let config_json = c_str_arg(config_json, "config_json")?;
        RuntimeJsonBridge::from_config_json(config_json)
            .map(|bridge| Box::into_raw(Box::new(bridge)))
    })) {
        Ok(Ok(runtime)) => runtime,
        Ok(Err(_)) | Err(_) => std::ptr::null_mut(),
    }
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_free(runtime: *mut RuntimeJsonBridge) {
    c_void_boundary(AssertUnwindSafe(|| {
        if !runtime.is_null() {
            drop(Box::from_raw(runtime));
        }
    }));
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_string_free(value: *mut c_char) {
    c_void_boundary(AssertUnwindSafe(|| {
        if !value.is_null() {
            drop(CString::from_raw(value));
        }
    }));
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_create_session(
    runtime: *mut RuntimeJsonBridge,
) -> *mut c_char {
    c_runtime_result(runtime, || bridge_ref(runtime)?.create_session_json())
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_session_ids(
    runtime: *mut RuntimeJsonBridge,
) -> *mut c_char {
    c_runtime_result(runtime, || bridge_ref(runtime)?.session_ids_json())
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_conversation_summaries(
    runtime: *mut RuntimeJsonBridge,
) -> *mut c_char {
    c_runtime_result(runtime, || {
        bridge_ref(runtime)?.conversation_summaries_json()
    })
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_fork_session(
    runtime: *mut RuntimeJsonBridge,
    session_id: *const c_char,
    leaf_id: *const c_char,
) -> *mut c_char {
    c_runtime_result(runtime, || {
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
    c_runtime_result(runtime, || {
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
    c_runtime_result(runtime, || {
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
    c_runtime_result(runtime, || {
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
    c_runtime_result(runtime, || {
        let options_json = c_str_arg(options_json, "options_json")?;
        bridge_ref(runtime)?.update_runtime_options_json(options_json)
    })
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_delete_session(
    runtime: *mut RuntimeJsonBridge,
    session_id: *const c_char,
) -> *mut c_char {
    c_runtime_result(runtime, || {
        let session_id = c_str_arg(session_id, "session_id")?;
        bridge_ref(runtime)?.delete_session_json(session_id)
    })
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_register_tool_schema(
    runtime: *mut RuntimeJsonBridge,
    schema_json: *const c_char,
) -> *mut c_char {
    c_runtime_result(runtime, || {
        let schema_json = c_str_arg(schema_json, "schema_json")?;
        bridge_ref(runtime)?.register_tool_schema_json(schema_json)
    })
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_set_permission_state(
    runtime: *mut RuntimeJsonBridge,
    state_json: *const c_char,
) -> *mut c_char {
    c_runtime_result(runtime, || {
        let state_json = c_str_arg(state_json, "state_json")?;
        bridge_ref(runtime)?.set_permission_state_json(state_json)
    })
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_send_message(
    runtime: *mut RuntimeJsonBridge,
    input_json: *const c_char,
) -> *mut c_char {
    c_runtime_result(runtime, || {
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
    c_runtime_result(runtime, || {
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
    c_runtime_result(runtime, || {
        bridge_ref(runtime)?.pending_tool_requests_json()
    })
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_pending_approval_requests(
    runtime: *mut RuntimeJsonBridge,
) -> *mut c_char {
    c_runtime_result(runtime, || {
        bridge_ref(runtime)?.pending_approval_requests_json()
    })
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_submit_tool_result(
    runtime: *mut RuntimeJsonBridge,
    run_id: *const c_char,
    result_json: *const c_char,
) -> *mut c_char {
    c_runtime_result(runtime, || {
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
    c_runtime_result(runtime, || {
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
    c_runtime_result(runtime, || {
        let response_json = c_str_arg(response_json, "response_json")?;
        bridge_ref(runtime)?.submit_approval_response_json(response_json)
    })
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_cancel(
    runtime: *mut RuntimeJsonBridge,
    run_id: *const c_char,
) -> *mut c_char {
    c_runtime_result(runtime, || {
        let run_id = c_str_arg(run_id, "run_id")?;
        bridge_ref(runtime)?.cancel_json(run_id)
    })
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_latest_prompt_debug_snapshot(
    runtime: *mut RuntimeJsonBridge,
) -> *mut c_char {
    c_runtime_result(runtime, || {
        bridge_ref(runtime)?.latest_prompt_debug_snapshot_json()
    })
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_provider_profiles(
    runtime: *mut RuntimeJsonBridge,
) -> *mut c_char {
    c_runtime_result(runtime, || bridge_ref(runtime)?.provider_profiles_json())
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_active_provider(
    runtime: *mut RuntimeJsonBridge,
) -> *mut c_char {
    c_runtime_result(runtime, || bridge_ref(runtime)?.active_provider_json())
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_set_provider(
    runtime: *mut RuntimeJsonBridge,
    request_json: *const c_char,
) -> *mut c_char {
    c_runtime_result(runtime, || {
        let request_json = c_str_arg(request_json, "request_json")?;
        bridge_ref(runtime)?.set_provider_json(request_json)
    })
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_start_run(
    runtime: *mut RuntimeJsonBridge,
    request_json: *const c_char,
) -> *mut c_char {
    c_runtime_result(runtime, || {
        let request_json = c_str_arg(request_json, "request_json")?;
        bridge_ref(runtime)?.start_run_json(request_json)
    })
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_list_agent_profiles(
    runtime: *mut RuntimeJsonBridge,
    request_json: *const c_char,
) -> *mut c_char {
    c_runtime_result(runtime, || {
        let request_json = c_str_arg(request_json, "request_json")?;
        bridge_ref(runtime)?.list_agent_profiles_json(request_json)
    })
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_build_agent(
    runtime: *mut RuntimeJsonBridge,
    request_json: *const c_char,
) -> *mut c_char {
    c_runtime_result(runtime, || {
        let request_json = c_str_arg(request_json, "request_json")?;
        bridge_ref(runtime)?.build_agent_json(request_json)
    })
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_prepare_user_turn(
    runtime: *mut RuntimeJsonBridge,
    request_json: *const c_char,
) -> *mut c_char {
    c_runtime_result(runtime, || {
        let request_json = c_str_arg(request_json, "request_json")?;
        bridge_ref(runtime)?.prepare_user_turn_json(request_json)
    })
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_observe_events(
    runtime: *mut RuntimeJsonBridge,
    request_json: *const c_char,
) -> *mut c_char {
    c_runtime_result(runtime, || {
        let request_json = c_str_arg(request_json, "request_json")?;
        bridge_ref(runtime)?.observe_events_json(request_json)
    })
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_observe_events_streaming(
    runtime: *mut RuntimeJsonBridge,
    request_json: *const c_char,
    on_event: RuntimeEventCallback,
    user_data: *mut c_void,
) -> *mut c_char {
    c_runtime_result(runtime, || {
        let request_json = c_str_arg(request_json, "request_json")?;
        bridge_ref(runtime)?.observe_events_stream_json(request_json, |event_json| {
            dispatch_stream_event(on_event, user_data, &event_json)
        })?;
        Ok("null".to_string())
    })
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_commit_assistant_result(
    runtime: *mut RuntimeJsonBridge,
    request_json: *const c_char,
) -> *mut c_char {
    c_runtime_result(runtime, || {
        let request_json = c_str_arg(request_json, "request_json")?;
        bridge_ref(runtime)?.commit_assistant_result_json(request_json)
    })
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_approve_tool(
    runtime: *mut RuntimeJsonBridge,
    request_json: *const c_char,
) -> *mut c_char {
    c_runtime_result(runtime, || {
        let request_json = c_str_arg(request_json, "request_json")?;
        bridge_ref(runtime)?.approve_tool_json(request_json)
    })
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_cancel_run(
    runtime: *mut RuntimeJsonBridge,
    request_json: *const c_char,
) -> *mut c_char {
    c_runtime_result(runtime, || {
        let request_json = c_str_arg(request_json, "request_json")?;
        bridge_ref(runtime)?.cancel_run_json(request_json)
    })
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_load_debug_archive(
    runtime: *mut RuntimeJsonBridge,
    run_id: *const c_char,
) -> *mut c_char {
    c_runtime_result(runtime, || {
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
struct EmptyAgentOSRequestJson {}

#[derive(Serialize)]
struct EmptyAgentOSResponseJson {}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct BuildAgentRequestJson {
    template_id: String,
}

#[derive(Serialize)]
struct AgentProfileJson {
    profile_id: String,
    profile_revision_id: u64,
    display_name: String,
}

impl From<&AgentProfile> for AgentProfileJson {
    fn from(profile: &AgentProfile) -> Self {
        Self {
            profile_id: profile.id().as_str().to_string(),
            profile_revision_id: profile.version().as_u64(),
            display_name: profile.name().to_string(),
        }
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ApprovalDecisionJson {
    approved: bool,
    reason: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ApproveToolRequestJson {
    id: String,
    decision: ApprovalDecisionJson,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CancelRunRequestJson {
    run_id: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PrepareUserTurnRequestJson {
    session_id: Option<String>,
    parent_event_id: Option<String>,
    text: String,
    #[serde(default)]
    blob_refs: Vec<String>,
}

#[derive(Serialize)]
struct PreparedUserTurnJson {
    session_id: String,
    user_message_id: String,
    conversation_run_frame_ref: ConversationRunFrameRefJson,
    frame_preview: Option<ConversationRunFrameJson>,
}

#[derive(Serialize)]
struct ConversationRunFrameJson {
    frame_ref: ConversationRunFrameRefJson,
    messages: Vec<ConversationFrameMessageJson>,
    attachment_refs: Vec<String>,
}

#[derive(Serialize)]
struct ConversationFrameMessageJson {
    event_id: String,
    role: String,
    content: String,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct ConversationRunFrameRefJson {
    frame_id: String,
    session_id: String,
    branch_head_id: String,
    user_turn_id: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct StartRunRequestJson {
    agent_profile_id: String,
    profile_revision_id: u64,
    user_intent: String,
    conversation_run_frame_ref: ConversationRunFrameRefJson,
    #[serde(default)]
    options: Value,
}

#[derive(Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct StartRunOptionsJson {
    model_id: Option<String>,
    system_prompt: Option<String>,
    runtime_policy: Option<String>,
    temperature: Option<f32>,
    top_p: Option<f32>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ObserveExecutionEventsRequestJson {
    run_id: String,
    from_sequence: u64,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CommitAssistantResultRequestJson {
    run_id: String,
    final_message_id: String,
    conversation_run_frame_ref: ConversationRunFrameRefJson,
}

#[derive(Serialize)]
struct ConversationCommitResultJson {
    committed_message_id: String,
    already_committed: bool,
}

#[derive(Serialize)]
struct RunHandleJson {
    run_id: String,
    replay_from_sequence: Option<u64>,
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

    fn from_execution_events(run_id: &str, events: &[ExecutionEvent]) -> Self {
        let state = execution_turn_state_json(events);
        Self {
            run_id: run_id.to_string(),
            state,
            events: events
                .iter()
                .map(RuntimeEventJson::from_execution_event)
                .collect(),
            pending_tool_call_id: if matches!(state, "waiting_tool" | "suspended") {
                execution_pending_tool_call_id(events)
            } else {
                None
            },
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

    fn from_execution_event(event: &ExecutionEvent) -> Self {
        Self {
            id: format!("{}.{}", event.run_id(), event.sequence()),
            session_id: String::new(),
            parent_id: None,
            run_id: Some(event.run_id().to_string()),
            sequence: event.sequence(),
            created_at_millis: 0,
            depth: 0,
            kind: execution_event_kind_json(event.code()),
            payload: event.payload().to_string(),
            blob_refs: Vec::new(),
        }
    }
}

impl ConversationRunFrameRefJson {
    fn into_domain(self) -> ConversationRunFrameRef {
        ConversationRunFrameRef::new(
            ConversationFrameId::new(self.frame_id),
            SessionId(self.session_id),
            EntryId(self.branch_head_id),
            EntryId(self.user_turn_id),
        )
    }
}

impl From<&ConversationRunFrameRef> for ConversationRunFrameRefJson {
    fn from(frame_ref: &ConversationRunFrameRef) -> Self {
        Self {
            frame_id: frame_ref.frame_id().as_str().to_string(),
            session_id: frame_ref.session_id().0.clone(),
            branch_head_id: frame_ref.branch_head_id().0.clone(),
            user_turn_id: frame_ref.user_turn_id().0.clone(),
        }
    }
}

impl From<PreparedUserTurn> for PreparedUserTurnJson {
    fn from(prepared: PreparedUserTurn) -> Self {
        Self::from_prepared(prepared, None)
    }
}

impl PreparedUserTurnJson {
    fn from_prepared(
        prepared: PreparedUserTurn,
        frame_preview: Option<ConversationRunFrameJson>,
    ) -> Self {
        Self {
            session_id: prepared.session_id().0.clone(),
            user_message_id: prepared.user_message_id().0.clone(),
            conversation_run_frame_ref: ConversationRunFrameRefJson::from(
                prepared.conversation_run_frame_ref(),
            ),
            frame_preview,
        }
    }
}

impl From<&ConversationRunFrame> for ConversationRunFrameJson {
    fn from(frame: &ConversationRunFrame) -> Self {
        Self {
            frame_ref: ConversationRunFrameRefJson::from(frame.frame_ref()),
            messages: frame
                .messages()
                .iter()
                .map(ConversationFrameMessageJson::from)
                .collect(),
            attachment_refs: frame
                .attachment_refs()
                .iter()
                .map(|attachment| attachment.as_str().to_string())
                .collect(),
        }
    }
}

impl From<&ConversationFrameMessage> for ConversationFrameMessageJson {
    fn from(message: &ConversationFrameMessage) -> Self {
        Self {
            event_id: message.event_id().0.clone(),
            role: message.role().to_string(),
            content: message.content().to_string(),
        }
    }
}

impl From<RunHandle> for RunHandleJson {
    fn from(handle: RunHandle) -> Self {
        Self {
            run_id: handle.run_id().to_string(),
            replay_from_sequence: handle.replay_from_sequence(),
        }
    }
}

impl RuntimeOptionsJson {
    fn into_domain(self) -> RuntimeOptions {
        RuntimeOptions {
            system_prompt: self.system_prompt,
            runtime_policy: self.runtime_policy,
            temperature: self.temperature.map(f64::from),
            top_p: self.top_p.map(f64::from),
        }
    }
}

impl StartRunOptionsJson {
    fn from_value(value: Value) -> Result<Self, AgentError> {
        if value.is_null() {
            return Ok(Self::default());
        }
        serde_json::from_value(value)
            .map_err(|error| AgentError::Ffi(format!("invalid start run options: {error}")))
    }

    fn into_domain(self, defaults: RuntimeOptions) -> RuntimeOptions {
        let _model_id = self.model_id;
        RuntimeOptions {
            system_prompt: self.system_prompt.unwrap_or(defaults.system_prompt),
            runtime_policy: self.runtime_policy.unwrap_or(defaults.runtime_policy),
            temperature: self.temperature.map(f64::from).or(defaults.temperature),
            top_p: self.top_p.map(f64::from).or(defaults.top_p),
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

#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
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

fn is_execution_stream_boundary(event: &ExecutionEvent) -> bool {
    matches!(
        event.code(),
        "run.completed" | "run.failed" | "run.cancelled" | "run.waiting_tool" | "run.suspended"
    )
}

fn execution_event_kind_json(code: &str) -> &'static str {
    match code {
        "assistant_message_completed" => "assistant_message_completed",
        "assistant_text_delta" => "assistant_text_delta",
        "assistant_message_started" => "assistant_message_started",
        "tool_call_requested" => "tool_call_requested",
        "tool_call_approved" => "tool_call_approved",
        "tool_call_rejected" => "tool_call_rejected",
        "tool_result_message" => "tool_result_message",
        "run.suspended" => "run_suspended",
        "run.waiting_tool" => "run_waiting_tool",
        "run.cancelled" => "run_cancelled",
        "run.failed" => "run_failed",
        _ => "execution.event",
    }
}

#[cfg(test)]
fn c_result(run: impl FnOnce() -> Result<String, AgentError>) -> *mut c_char {
    let json = match catch_unwind(AssertUnwindSafe(run)) {
        Ok(Ok(json)) => json,
        Ok(Err(error)) => error_payload(&error),
        Err(payload) => error_payload(&panic_agent_error(payload.as_ref())),
    };
    into_c_string(json)
}

unsafe fn c_runtime_result(
    runtime: *const RuntimeJsonBridge,
    run: impl FnOnce() -> Result<String, AgentError>,
) -> *mut c_char {
    let json = match catch_unwind(AssertUnwindSafe(|| {
        let bridge = bridge_ref(runtime)?;
        bridge.ensure_ffi_usable()?;
        run()
    })) {
        Ok(Ok(json)) => json,
        Ok(Err(error)) => error_payload(&error),
        Err(payload) => {
            if let Some(bridge) = runtime.as_ref() {
                bridge.mark_ffi_tainted();
            }
            error_payload(&panic_agent_error(payload.as_ref()))
        }
    };
    into_c_string(json)
}

fn c_void_boundary(run: impl FnOnce()) {
    let _ = catch_unwind(AssertUnwindSafe(run));
}

fn panic_agent_error(payload: &(dyn Any + Send)) -> AgentError {
    #[cfg(debug_assertions)]
    {
        AgentError::Ffi(format!(
            "rust ffi panic: {}",
            panic_payload_message(payload)
        ))
    }

    #[cfg(not(debug_assertions))]
    {
        let _ = payload;
        AgentError::Ffi("rust ffi panic".into())
    }
}

fn panic_payload_message(payload: &(dyn Any + Send)) -> String {
    if let Some(value) = payload.downcast_ref::<String>() {
        return value.clone();
    }
    if let Some(value) = payload.downcast_ref::<&'static str>() {
        return (*value).to_string();
    }
    "non-string panic payload".to_string()
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
        AgentError::Ffi(message) if message.starts_with("rust ffi panic") => "panic",
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

fn execution_turn_state_json(events: &[ExecutionEvent]) -> &'static str {
    for event in events.iter().rev() {
        match event.code() {
            "run.completed" => return "completed",
            "run.failed" => return "failed",
            "run.cancelled" => return "cancelled",
            "run.waiting_tool" => return "waiting_tool",
            "run.suspended" => return "suspended",
            _ => {}
        }
    }
    "running"
}

fn execution_pending_tool_call_id(events: &[ExecutionEvent]) -> Option<String> {
    for event in events.iter().rev() {
        if !matches!(event.code(), "run.waiting_tool" | "run.suspended") {
            continue;
        }
        let payload: Value = serde_json::from_str(event.payload()).ok()?;
        return payload
            .get("call_id")
            .and_then(Value::as_str)
            .map(ToString::to_string);
    }
    None
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
mod ffi_boundary_tests {
    use super::*;
    use serde_json::Value;
    use std::ffi::CStr;

    unsafe fn take_c_string(ptr: *mut c_char) -> String {
        assert!(!ptr.is_null());
        let value = CStr::from_ptr(ptr).to_string_lossy().into_owned();
        local_agent_runtime_bridge_string_free(ptr);
        value
    }

    #[test]
    fn c_result_converts_panic_to_error_envelope() {
        let json = unsafe {
            take_c_string(c_result(|| -> Result<String, AgentError> {
                panic!("ffi test panic");
            }))
        };
        let value: Value = serde_json::from_str(&json).unwrap();

        assert_eq!(value["error"]["kind"], "panic");
        assert!(value["error"]["message"]
            .as_str()
            .unwrap()
            .contains("rust ffi panic"));
    }

    #[test]
    fn panic_payload_message_handles_string_str_and_non_string_payloads() {
        let string_payload = Box::new(String::from("owned panic"));
        let str_payload = Box::new("borrowed panic");
        let non_string_payload = Box::new(42_u32);

        assert_eq!(
            panic_payload_message(string_payload.as_ref()),
            "owned panic"
        );
        assert_eq!(
            panic_payload_message(str_payload.as_ref()),
            "borrowed panic"
        );
        assert_eq!(
            panic_payload_message(non_string_payload.as_ref()),
            "non-string panic payload"
        );
    }

    #[test]
    fn caught_panic_taints_runtime_and_follow_up_call_returns_stable_error() {
        let runtime = Box::into_raw(Box::new(RuntimeJsonBridge::new(AgentRuntime::new(
            AgentRuntimeConfig {
                system_prompt: "system".into(),
                runtime_policy: "policy".into(),
                tool_schemas: Vec::new(),
                tokenizer: Box::new(crate::context::MockTokenizer::new(100)),
                provider: Box::new(crate::core::MockStreamingProvider::new()),
                tool_router: None,
            },
        ))));

        unsafe {
            let panic_json = take_c_string(c_runtime_result(
                runtime,
                || -> Result<String, AgentError> {
                    panic!("taint this runtime");
                },
            ));
            let panic_value: Value = serde_json::from_str(&panic_json).unwrap();
            assert_eq!(panic_value["error"]["kind"], "panic");

            let follow_up_json = take_c_string(local_agent_runtime_bridge_session_ids(runtime));
            let follow_up_value: Value = serde_json::from_str(&follow_up_json).unwrap();
            assert_eq!(follow_up_value["error"]["kind"], "ffi");
            assert!(follow_up_value["error"]["message"]
                .as_str()
                .unwrap()
                .contains("tainted"));

            local_agent_runtime_bridge_free(runtime);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn execution_stream_boundary_includes_paused_tool_states() {
        let log = ExecutionEventLog::default();
        let waiting = log.append("run_1", "run.waiting_tool");
        let suspended = log.append("run_2", "run.suspended");

        assert!(is_execution_stream_boundary(&waiting));
        assert!(is_execution_stream_boundary(&suspended));
    }

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
