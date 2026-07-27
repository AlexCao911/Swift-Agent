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

use crate::app_service::{
    AgentBuilderCardDraftInput, AgentOSApplicationService, AgentOSApplicationServiceConfig,
};
use crate::context::{
    ContextAssembler, ContextSegment, InferenceOptions, ModelInputMessages, PromptFrame,
    TokenizerAdapter,
};
use crate::conversation::{
    ConversationCommitError, ConversationCommitService, ConversationFrameId,
    ConversationFrameMessage, ConversationFrameRepository, ConversationRunFrame,
    ConversationRunFrameRef, ConversationService, InMemoryConversationFrameRepository,
    PrepareUserTurnRequest, PreparedUserTurn, RuntimeBranchEventReader,
};
use crate::core::{
    register_desktop_minicpm_provider, AgentError, AgentRuntime, AgentRuntimeConfig,
    AgentTurnResult, CAbiV2LocalInferenceBackend, DesktopMiniCPMSettings, EntryId, EventKind,
    LocalLLMProvider, ProviderBundle, ProviderCancellationRegistry, ProviderKind, ProviderProfile,
    ProviderRegistry, RunId, RunState, RuntimeEvent, SendMessageInput, SessionId,
};
use crate::execution::{
    CompletedRunRecord, CompletedRunRegistry, ExecutionEvent, ExecutionEventLog,
    ExecutionModelClient, ExecutionModelTurn, ExecutionPlanner, ExecutionService,
    ExecutionStartError, ExecutionToolCall, ExecutionToolExecutor, ExecutionToolObservation,
    ExecutionToolOutcome, ExecutionWorkerDependencies, HostLLMDispatcherConfig,
    HostLLMDispatcherRuntime, HostToolBatchExecutor, LocalAgentLLMHostVTable, RunHandle,
    RuntimeOptions, StartExecutionRequest,
};
use crate::llm_contracts::{
    AgentHostBindingService, HostAttestation, HostBindingActivationConfirmation, HostBindingCommit,
    HostBindingSubjectCatalog, HostCommandAcknowledgement, HostToolResult, LLMBindingSchema,
    LLMEventEnvelope, LLMEventKind, LLMEventSubmissionResult, PackageBindingPreparation,
    PreparationAbortReason, PreparedSessionCleanupAcknowledgement, PreparedSessionClosedReceipt,
    PreparedSessionRegistration, ProfilePublishPreparation,
};
use crate::memory::{EventStore, InMemoryEventStore, SqliteEventStore};
use crate::run_snapshot::{
    PersistedResolvedRunSnapshotV2, ResolvedRunSnapshot, RunPreparationService, StartRunRequest,
};
use crate::security::{
    ApprovalProtocolRequest, ApprovalProtocolResponse, CredentialPurpose, PermissionScope,
    PermissionState, RiskLevel,
};
use crate::storage::agent_os_state::SharedAgentOSStateStore;
use crate::storage::{
    InMemoryRuntimeStateStore, SqliteRuntimeStateStore, UnifiedRuntimeStateRepository,
};
use crate::tool::{
    CompiledToolRecipe, CompiledToolRecipeContent, HttpResponseSensitivity, RetentionPolicy,
    Sensitivity, ToolCall, ToolExecutionRequest, ToolRecipeKind, ToolResult, ToolSchema,
};
use crate::user_customization::{AgentProfile, AgentProfileId, AgentProfileVersion};

pub type RuntimeEventCallback =
    Option<unsafe extern "C" fn(event_json: *const c_char, user_data: *mut c_void) -> c_int>;

fn execution_start_agent_error(error: ExecutionStartError) -> AgentError {
    AgentError::Storage(format!("{}: {error}", error.code()))
}

fn host_binding_agent_error(error: crate::llm_contracts::HostBindingError) -> AgentError {
    AgentError::Storage(format!("{}: {error}", error.code()))
}

fn runtime_state_agent_error(error: crate::storage::RuntimeStateError) -> AgentError {
    AgentError::Storage(format!("{}: {error}", error.code()))
}

fn preparation_agent_error(error: crate::llm_contracts::PreparationError) -> AgentError {
    AgentError::Storage(format!("{}: {error}", error.code()))
}

const TEST_HOST_PROCESS_EPOCH: &str = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";

fn validate_host_process_epoch(value: &str) -> Result<(), AgentError> {
    const CANONICAL_LAST_CHARS: &str = "AEIMQUYcgkosw048";
    let is_base64url = value
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'));
    if value.len() != 43
        || !is_base64url
        || !value
            .as_bytes()
            .last()
            .is_some_and(|byte| CANONICAL_LAST_CHARS.as_bytes().contains(byte))
    {
        return Err(AgentError::Ffi(
            "host_process_epoch must be canonical unpadded base64url for exactly 32 bytes".into(),
        ));
    }
    Ok(())
}

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

#[derive(Clone)]
struct BridgeHostToolBatchExecutor<S: EventStore + Send + 'static> {
    runtime: Arc<Mutex<AgentRuntime<S>>>,
    runtime_state: Arc<dyn UnifiedRuntimeStateRepository>,
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

impl<S: EventStore + Send + 'static> HostToolBatchExecutor for BridgeHostToolBatchExecutor<S> {
    fn execute_tool(
        &self,
        run_id: &str,
        call: &ExecutionToolCall,
    ) -> Result<ExecutionToolOutcome, String> {
        let snapshot_json = self
            .runtime_state
            .run_snapshot_json(run_id)
            .map_err(|error| format!("{}: {error}", error.code()))?
            .ok_or_else(|| "host run snapshot is missing".to_string())?;
        let persisted: PersistedResolvedRunSnapshotV2 =
            serde_json::from_str(&snapshot_json).map_err(|error| error.to_string())?;
        let snapshot =
            ResolvedRunSnapshot::try_from(persisted).map_err(|error| error.to_string())?;
        self.runtime
            .lock()
            .map_err(|_| "runtime bridge mutex poisoned".to_string())?
            .route_execution_tool_call(
                &RunId(run_id.to_string()),
                snapshot.conversation_run_frame_ref().session_id(),
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
    host_binding: AgentHostBindingService,
    run_preparation: RunPreparationService,
    host_llm_dispatcher: HostLLMDispatcherRuntime,
    runtime_state: Arc<dyn UnifiedRuntimeStateRepository>,
    ffi_tainted: AtomicBool,
}

impl<S: EventStore + Send + 'static> BridgeRuntime<S> {
    fn new(runtime: AgentRuntime<S>, app_services: AgentOSApplicationService) -> Self {
        let runtime_state = InMemoryRuntimeStateStore::new();
        let event_log = ExecutionEventLog::new(runtime_state.clone());
        let runtime_state_authority: Arc<dyn UnifiedRuntimeStateRepository> =
            Arc::new(runtime_state.clone());
        Self::try_new(
            runtime,
            app_services,
            runtime_state.agent_os_state(),
            TEST_HOST_PROCESS_EPOCH.to_string(),
            event_log,
            runtime_state_authority,
            false,
        )
        .expect("in-memory Agent OS state initialization must succeed")
    }

    fn try_new(
        runtime: AgentRuntime<S>,
        app_services: AgentOSApplicationService,
        agent_os_state: SharedAgentOSStateStore,
        host_process_epoch: String,
        event_log: ExecutionEventLog,
        runtime_state: Arc<dyn UnifiedRuntimeStateRepository>,
        replay_provider_independent_state: bool,
    ) -> Result<Self, AgentError> {
        agent_os_state
            .with_preparation_mut(|store| {
                store.recover_preparations_for_new_epoch(&host_process_epoch)
            })
            .map_err(|error| AgentError::Storage(format!("{}: {error}", error.code())))?;
        let mut runtime = runtime;
        if replay_provider_independent_state {
            runtime.replay_provider_independent_state()?;
        }
        let frames = InMemoryConversationFrameRepository::default();
        let cancellations = runtime.provider_cancellation_registry();
        let runtime = Arc::new(Mutex::new(runtime));
        let branch_reader = RuntimeBranchEventReader::new(runtime.clone());
        let completed_runs = CompletedRunRegistry::default();
        let snapshot_service = app_services.snapshot_service();
        let execution_tools = Arc::new(BridgeExecutionToolExecutor::new(runtime.clone()));
        let worker_dependencies = ExecutionWorkerDependencies::new(
            Arc::new(BridgeExecutionModelClient::new(runtime.clone())),
            execution_tools,
        );
        let completion_event_log = event_log.clone();
        let execution = ExecutionService::with_runtime_parts_and_agent_os_state(
            frames.clone(),
            snapshot_service.clone(),
            ExecutionPlanner,
            event_log,
            completed_runs.clone(),
            worker_dependencies,
            agent_os_state.clone(),
            host_process_epoch.clone(),
        );
        let host_tools = Arc::new(BridgeHostToolBatchExecutor {
            runtime: runtime.clone(),
            runtime_state: runtime_state.clone(),
        });
        let host_llm_dispatcher = HostLLMDispatcherRuntime::new_with_preparations_and_tools(
            runtime_state.clone(),
            Some(agent_os_state.clone()),
            Some(host_tools),
            HostLLMDispatcherConfig::default(),
        );
        let run_preparation = RunPreparationService::with_host_runtime(
            agent_os_state.clone(),
            host_process_epoch,
            snapshot_service,
            runtime_state.clone(),
        );
        let conversation = ConversationService::new(frames.clone(), branch_reader);
        let completion_runtime_state = runtime_state.clone();
        let conversation_commits = ConversationCommitService::with_recovery(
            completed_runs,
            Arc::new(move |run_id, final_message_id| {
                recover_host_completed_run(
                    completion_runtime_state.as_ref(),
                    &completion_event_log,
                    run_id,
                    final_message_id,
                )
            }),
        );
        let host_binding = AgentHostBindingService::new(
            agent_os_state.clone(),
            HostBindingSubjectCatalog::new(app_services.profile_repository()),
        );
        let bridge = Self {
            runtime,
            cancellations,
            debug_archives: Mutex::new(BTreeMap::new()),
            next_agent_os_run_id: Mutex::new(1),
            frames,
            conversation,
            execution,
            app_services,
            conversation_commits,
            host_binding,
            run_preparation,
            host_llm_dispatcher,
            runtime_state,
            ffi_tainted: AtomicBool::new(false),
        };
        bridge.consume_host_events()?;
        Ok(bridge)
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

    fn install_llm_host(&self, vtable: LocalAgentLLMHostVTable) -> Result<(), AgentError> {
        self.host_llm_dispatcher
            .install(vtable)
            .map_err(|error| AgentError::Ffi(format!("{}: {error}", error.code())))
    }

    fn uninstall_llm_host(&self) -> Result<(), AgentError> {
        self.host_llm_dispatcher
            .uninstall()
            .map_err(|error| AgentError::Ffi(format!("{}: {error}", error.code())))
    }

    fn suspend_llm_host(&self) -> Result<(), AgentError> {
        self.host_llm_dispatcher
            .suspend()
            .map_err(|error| AgentError::Ffi(format!("{}: {error}", error.code())))
    }

    fn resume_llm_host(&self) -> Result<(), AgentError> {
        self.host_llm_dispatcher
            .resume()
            .map_err(|error| AgentError::Ffi(format!("{}: {error}", error.code())))
    }

    fn drive_llm_host(&self) -> Result<(), AgentError> {
        self.host_llm_dispatcher
            .drive_once()
            .map_err(|error| AgentError::Ffi(format!("{}: {error}", error.code())))
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

    fn profile_execution_route_json(&self, request_json: &str) -> Result<String, AgentError> {
        let request: ProfileExecutionRouteRequestJson = from_json(request_json)?;
        let route = self
            .app_services
            .snapshot_service()
            .profile_execution_route(
                &AgentProfileId::new(request.profile_id),
                AgentProfileVersion::new(request.profile_revision),
            )
            .map_err(|error| AgentError::Storage(format!("{}: {error}", error.code())))?;
        to_json(&route)
    }

    fn build_agent_json(&self, request_json: &str) -> Result<String, AgentError> {
        let request: BuildAgentRequestJson = from_json(request_json)?;
        let profile = self
            .app_services
            .build_agent_from_template(
                request.profile_id.as_deref(),
                &request.template_id,
                request.card_draft_input(),
            )
            .map_err(|error| AgentError::Storage(format!("{}: {error}", error.code())))?;
        to_json(&AgentProfileJson::from(&profile))
    }

    fn preview_context_json(&self, request_json: &str) -> Result<String, AgentError> {
        let request: BuilderContextPreviewRequestJson = from_json(request_json)?;
        let preview = BuilderContextPreviewJson::from_request(request)
            .map_err(|error| AgentError::Storage(format!("context.preview_failed: {error}")))?;
        to_json(&preview)
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
        let route = self
            .app_services
            .snapshot_service()
            .profile_execution_route(
                &AgentProfileId::new(&request.agent_profile_id),
                AgentProfileVersion::new(request.profile_revision_id),
            )
            .map_err(|error| AgentError::Storage(format!("{}: {error}", error.code())))?;
        if route.llm_binding_schema() == LLMBindingSchema::HostSlotV2 {
            return Err(AgentError::Storage(
                "execution.host_slot_v2_requires_preparation: host-backed LLM slots must enter through authoritative preparation".into(),
            ));
        }
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

    fn prepare_profile_publish_json(&self, request_json: &str) -> Result<String, AgentError> {
        let request: ProfilePublishPreparation = from_json(request_json)?;
        let operation = self
            .host_binding
            .prepare_profile_publish(request)
            .map_err(host_binding_agent_error)?;
        to_json(&operation)
    }

    fn commit_profile_publish_json(&self, request_json: &str) -> Result<String, AgentError> {
        let request: HostBindingCommit = from_json(request_json)?;
        let cross_link = self
            .host_binding
            .commit_profile_publish(request)
            .map_err(host_binding_agent_error)?;
        to_json(&cross_link)
    }

    fn begin_package_binding_json(&self, request_json: &str) -> Result<String, AgentError> {
        let request: PackageBindingPreparation = from_json(request_json)?;
        let operation = self
            .host_binding
            .begin_package_binding(request)
            .map_err(host_binding_agent_error)?;
        to_json(&operation)
    }

    fn attach_host_binding_json(&self, request_json: &str) -> Result<String, AgentError> {
        let request: HostBindingCommit = from_json(request_json)?;
        let cross_link = self
            .host_binding
            .attach_host_binding(request)
            .map_err(host_binding_agent_error)?;
        to_json(&cross_link)
    }

    fn confirm_host_binding_activation_json(
        &self,
        request_json: &str,
    ) -> Result<String, AgentError> {
        let request: HostBindingActivationConfirmation = from_json(request_json)?;
        let cross_link = self
            .host_binding
            .confirm_activation(request)
            .map_err(host_binding_agent_error)?;
        to_json(&cross_link)
    }

    fn preview_run_preparation_json(&self, request_json: &str) -> Result<String, AgentError> {
        let request: PreviewRunPreparationJson = from_json(request_json)?;
        let frame_ref = request
            .start_request
            .conversation_run_frame_ref
            .clone()
            .into_domain();
        let frame = self.frames.get(&frame_ref).ok_or_else(|| {
            AgentError::Storage(
                "preparation.frame_ref_untrusted: conversation frame ref was not issued by Rust"
                    .to_string(),
            )
        })?;
        let start_request = StartRunRequest::new(
            request.start_request.agent_profile_id,
            AgentProfileVersion::new(request.start_request.profile_revision_id),
            request.start_request.user_intent,
            frame_ref,
        );
        let preview = self
            .run_preparation
            .preview_authoritative(
                request.idempotency_key,
                request.preparation_id,
                request.proposed_run_id,
                start_request,
                &frame,
                request.now_millis,
            )
            .map_err(preparation_agent_error)?;
        to_json(&preview)
    }

    fn renew_run_preparation_json(&self, request_json: &str) -> Result<String, AgentError> {
        let request: RenewRunPreparationJson = from_json(request_json)?;
        let preview = self
            .run_preparation
            .renew_preparation(
                &request.token,
                &request.binding_digest,
                &request.idempotency_key,
                request.now_millis,
            )
            .map_err(preparation_agent_error)?;
        to_json(&preview)
    }

    fn register_prepared_session_json(&self, request_json: &str) -> Result<String, AgentError> {
        let request: RegisterPreparedSessionJson = from_json(request_json)?;
        let record = self
            .run_preparation
            .register_prepared_session(&request.token, request.registration, request.now_millis)
            .map_err(preparation_agent_error)?;
        to_json(&record)
    }

    fn commit_prepared_start_json(&self, request_json: &str) -> Result<String, AgentError> {
        let request: CommitPreparedStartJson = from_json(request_json)?;
        let handle = self
            .run_preparation
            .commit_start(&request.token, request.attestation, request.now_millis)
            .map_err(preparation_agent_error)?;
        self.host_llm_dispatcher.wake();
        to_json(&handle)
    }

    fn reconcile_preparation_json(&self, request_json: &str) -> Result<String, AgentError> {
        let request: ReconcilePreparationJson = from_json(request_json)?;
        let outcome = self
            .run_preparation
            .reconcile_preparation(
                &request.preparation_id,
                &request.proposed_run_id,
                &request.token_digest,
            )
            .map_err(preparation_agent_error)?;
        to_json(&outcome)
    }

    fn begin_abort_preparation_json(&self, request_json: &str) -> Result<String, AgentError> {
        let request: BeginAbortPreparationJson = from_json(request_json)?;
        let record = self
            .run_preparation
            .begin_abort_preparation(
                &request.preparation_id,
                request.token.as_deref(),
                &request.idempotency_key,
                request.reason,
            )
            .map_err(preparation_agent_error)?;
        self.host_llm_dispatcher.wake();
        to_json(&record)
    }

    fn confirm_prepared_session_closed_json(
        &self,
        request_json: &str,
    ) -> Result<String, AgentError> {
        let receipt: PreparedSessionClosedReceipt = from_json(request_json)?;
        let record = self
            .run_preparation
            .confirm_prepared_session_closed(receipt)
            .map_err(preparation_agent_error)?;
        to_json(&record)
    }

    fn ack_prepared_session_cleanup_json(&self, request_json: &str) -> Result<String, AgentError> {
        let acknowledgement: PreparedSessionCleanupAcknowledgement = from_json(request_json)?;
        let record = self
            .run_preparation
            .ack_prepared_session_cleanup(acknowledgement)
            .map_err(preparation_agent_error)?;
        self.host_llm_dispatcher.wake();
        to_json(&record)
    }

    fn acknowledge_llm_command_json(&self, request_json: &str) -> Result<String, AgentError> {
        let acknowledgement: HostCommandAcknowledgement = from_json(request_json)?;
        let row = self
            .host_llm_dispatcher
            .acknowledge_command(&acknowledgement)
            .map_err(|error| AgentError::Storage(format!("{}: {error}", error.code())))?;
        to_json(&row)
    }

    fn submit_llm_event_json(&self, request_json: &str) -> Result<String, AgentError> {
        let event: LLMEventEnvelope = from_json(request_json)?;
        let receipt = self
            .host_llm_dispatcher
            .submit_event(&event)
            .map_err(|error| AgentError::Storage(format!("{}: {error}", error.code())))?;
        if matches!(
            receipt,
            LLMEventSubmissionResult::Accepted | LLMEventSubmissionResult::Duplicate
        ) {
            self.consume_host_events()?;
        }
        to_json(&receipt)
    }

    fn consume_host_events(&self) -> Result<(), AgentError> {
        for event in self
            .runtime_state
            .pending_inbound_events(usize::MAX)
            .map_err(runtime_state_agent_error)?
        {
            if self.host_event_projection_exists(&event) {
                self.runtime_state
                    .acknowledge_inbound_event_projection(&event)
                    .map_err(runtime_state_agent_error)?;
                continue;
            }
            let message_id = format!(
                "assistant:{}:{}",
                event.run_id(),
                event.generation_turn_id.as_deref().unwrap_or("unknown")
            );
            match event.kind() {
                LLMEventKind::GenerationStarted => self
                    .execution()
                    .record_external_event(
                        event.run_id(),
                        "assistant_message_started",
                        json!({
                            "host_event_id": event.event_id(),
                            "message_id": message_id,
                        })
                        .to_string(),
                    )
                    .map_err(execution_start_agent_error)?,
                LLMEventKind::TextDelta => self
                    .execution()
                    .record_external_event(
                        event.run_id(),
                        "assistant_text_delta",
                        json!({
                            "host_event_id": event.event_id(),
                            "message_id": message_id,
                            "text": event.payload.text.as_deref().unwrap_or_default(),
                        })
                        .to_string(),
                    )
                    .map_err(execution_start_agent_error)?,
                LLMEventKind::GenerationCompleted
                    if event
                        .payload
                        .completion
                        .as_ref()
                        .is_some_and(|completion| completion.outcome == "final_response") =>
                {
                    let turn_id = event.generation_turn_id.as_deref().ok_or_else(|| {
                        AgentError::Storage("host completion is missing turn identity".into())
                    })?;
                    let text = self
                        .runtime_state
                        .turn_accumulator_events(event.session_handle(), turn_id)
                        .map_err(runtime_state_agent_error)?
                        .into_iter()
                        .filter(|item| item.kind() == LLMEventKind::TextDelta)
                        .filter_map(|item| item.payload.text)
                        .collect::<String>();
                    let snapshot_json = self
                        .runtime_state
                        .run_snapshot_json(event.run_id())
                        .map_err(runtime_state_agent_error)?
                        .ok_or_else(|| {
                            AgentError::Storage("host run snapshot is missing".into())
                        })?;
                    let persisted: PersistedResolvedRunSnapshotV2 =
                        serde_json::from_str(&snapshot_json)
                            .map_err(|error| AgentError::Storage(error.to_string()))?;
                    let snapshot = ResolvedRunSnapshot::try_from(persisted)
                        .map_err(|error| AgentError::Storage(error.to_string()))?;
                    let finish_reason = event
                        .payload
                        .completion
                        .as_ref()
                        .map(|completion| completion.finish_reason.as_str())
                        .unwrap_or("other");
                    self.execution()
                        .record_external_completed(
                            event.run_id(),
                            snapshot.conversation_run_frame_ref().clone(),
                            event.event_id(),
                            &message_id,
                            &text,
                            finish_reason,
                        )
                        .map_err(execution_start_agent_error)?;
                }
                LLMEventKind::Failed => self
                    .execution()
                    .record_external_event(
                        event.run_id(),
                        "run.failed",
                        json!({
                            "host_event_id": event.event_id(),
                            "message": event
                                .payload
                                .failure_code
                                .as_deref()
                                .unwrap_or("llm.generation.failed"),
                        })
                        .to_string(),
                    )
                    .map_err(execution_start_agent_error)?,
                LLMEventKind::Cancelled => self
                    .execution()
                    .record_external_event(
                        event.run_id(),
                        "run.cancelled",
                        json!({ "host_event_id": event.event_id() }).to_string(),
                    )
                    .map_err(execution_start_agent_error)?,
                _ => {}
            }
            self.runtime_state
                .acknowledge_inbound_event_projection(&event)
                .map_err(runtime_state_agent_error)?;
        }
        Ok(())
    }

    fn host_event_projection_exists(&self, event: &LLMEventEnvelope) -> bool {
        let Some(code) = host_event_projection_code(event) else {
            return false;
        };
        self.execution
            .observe_events(event.run_id(), None)
            .iter()
            .any(|projected| {
                projected.code() == code
                    && serde_json::from_str::<Value>(projected.payload())
                        .ok()
                        .and_then(|payload| {
                            payload
                                .get("host_event_id")
                                .and_then(Value::as_str)
                                .map(str::to_string)
                        })
                        .as_deref()
                        == Some(event.event_id())
            })
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
        let is_host_run = self
            .runtime_state
            .host_worker(&resolved.run_id.0)
            .map_err(runtime_state_agent_error)?
            .is_some();
        if let Some(call_id) = resolved.approved_tool_call_id {
            self.execution()
                .record_external_event(
                    &resolved.run_id.0,
                    "tool_call_approved",
                    json!({ "call_id": call_id.clone() }).to_string(),
                )
                .map_err(execution_start_agent_error)?;
            self.execution()
                .record_external_event(
                    &resolved.run_id.0,
                    "run.waiting_tool",
                    json!({ "call_id": call_id }).to_string(),
                )
                .map_err(execution_start_agent_error)?;
        } else if !resolved.approved {
            self.execution()
                .record_external_event(
                    &resolved.run_id.0,
                    "tool_call_rejected",
                    json!({ "message": resolved.message.clone() }).to_string(),
                )
                .map_err(execution_start_agent_error)?;
            if is_host_run {
                self.host_llm_dispatcher
                    .reject_tool_batch(&resolved.run_id.0, &resolved.message)
                    .map_err(runtime_state_agent_error)?;
            } else {
                self.execution()
                    .record_external_event(
                        &resolved.run_id.0,
                        "run.failed",
                        json!({
                            "message": format!("tool approval rejected: {}", resolved.message)
                        })
                        .to_string(),
                    )
                    .map_err(execution_start_agent_error)?;
            }
        }
        to_json(&EmptyAgentOSResponseJson {})
    }

    fn cancel_run_json(&self, request_json: &str) -> Result<String, AgentError> {
        let request: CancelRunRequestJson = from_json(request_json)?;
        let run_id = request.run_id;
        if self
            .runtime_state
            .host_worker(&run_id)
            .map_err(runtime_state_agent_error)?
            .is_some()
        {
            self.host_llm_dispatcher
                .cancel_run(&run_id)
                .map_err(runtime_state_agent_error)?;
            self.execution()
                .record_external_event(&run_id, "run.cancel_requested", r#"{"state":"cancelling"}"#)
                .map_err(execution_start_agent_error)?;
            let event = self
                .execution()
                .observe_events(&run_id, None)
                .into_iter()
                .last()
                .ok_or_else(|| AgentError::Storage("cancel event is missing".into()))?;
            return to_json(&RuntimeEventJson::from_execution_event(&event));
        }
        let event = self.lock()?.cancel(run_id.clone())?;
        self.execution()
            .record_external_event(&run_id, "run.cancelled", "{}")
            .map_err(execution_start_agent_error)?;
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

        if self
            .runtime_state
            .host_worker(run_id)
            .map_err(runtime_state_agent_error)?
            .is_some()
        {
            let request = self
                .lock()?
                .consume_execution_pending_tool_request(&RunId(run_id.to_string()))?;
            if matches!(result.provenance.as_str(), "" | "swift.tool_result") {
                result.provenance = format!("tool.{}", request.tool_name());
            }
            let before_sequence = self
                .execution()
                .observe_events(run_id, None)
                .iter()
                .map(ExecutionEvent::sequence)
                .max()
                .unwrap_or(0);
            self.execution()
                .record_external_event(
                    run_id,
                    "tool_result_message",
                    json!({
                        "call_id": request.tool_call_id(),
                        "model_text": &result.model_text,
                        "provenance": &result.provenance,
                        "is_error": result.is_error,
                    })
                    .to_string(),
                )
                .map_err(execution_start_agent_error)?;
            self.host_llm_dispatcher
                .resume_tool_batch(
                    run_id,
                    HostToolResult {
                        call_id: request.tool_call_id().to_string(),
                        tool_name: request.tool_name().to_string(),
                        result: json!({
                            "model_text": result.model_text,
                            "structured_json": result.structured_json,
                        }),
                        is_error: result.is_error,
                        data_classes: vec!["unknown_data".into()],
                        highest_sensitivity: host_tool_result_sensitivity(result.sensitivity)
                            .into(),
                    },
                )
                .map_err(runtime_state_agent_error)?;
            let events = self
                .execution()
                .observe_events(run_id, Some(before_sequence));
            return to_json(&AgentTurnResultJson::from_execution_events(run_id, &events));
        }

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

    pub fn new_development_seeded(runtime: AgentRuntime<InMemoryEventStore>) -> Self {
        let app_services = AgentOSApplicationService::from_config(
            AgentOSApplicationServiceConfig::new().with_seed_development_profile(true),
        )
        .expect("development Agent OS seed must be valid");
        Self::InMemory(BridgeRuntime::new(runtime, app_services))
    }

    pub fn from_config_json(config_json: &str) -> Result<Self, AgentError> {
        let config: RuntimeBridgeConfigJson = from_json(config_json)?;
        validate_host_process_epoch(&config.host_process_epoch)?;
        let registry = config.provider_registry()?;
        let runtime_config = config.runtime_config(&registry)?;
        let app_services = AgentOSApplicationService::from_config(config.agent_os.into())
            .map_err(|error| AgentError::Storage(error.to_string()))?;
        let host_process_epoch = config.host_process_epoch.clone();
        match config.store {
            StoreConfigJson::InMemory { .. } => {
                let runtime_state = InMemoryRuntimeStateStore::new();
                runtime_state
                    .reconcile_for_host_epoch(&host_process_epoch)
                    .map_err(|error| AgentError::Storage(error.to_string()))?;
                let event_log = ExecutionEventLog::new(runtime_state.clone());
                let runtime_state_authority: Arc<dyn UnifiedRuntimeStateRepository> =
                    Arc::new(runtime_state.clone());
                Ok(Self::InMemory(BridgeRuntime::try_new(
                    AgentRuntime::open_without_replay(
                        runtime_config,
                        InMemoryEventStore::new(),
                        registry,
                    )?,
                    app_services,
                    runtime_state.agent_os_state(),
                    host_process_epoch,
                    event_log,
                    runtime_state_authority,
                    true,
                )?))
            }
            StoreConfigJson::Sqlite { path, .. } => {
                let runtime_state = SqliteRuntimeStateStore::open(&path)
                    .map_err(|error| AgentError::Storage(error.to_string()))?;
                runtime_state
                    .reconcile_for_host_epoch(&host_process_epoch)
                    .map_err(|error| AgentError::Storage(error.to_string()))?;
                let agent_os_state = runtime_state.agent_os_state();
                let conversation_event_store = runtime_state.conversation_event_store()?;
                let event_log = ExecutionEventLog::new(runtime_state.clone());
                let runtime_state_authority: Arc<dyn UnifiedRuntimeStateRepository> =
                    Arc::new(runtime_state.clone());
                Ok(Self::Sqlite(BridgeRuntime::try_new(
                    AgentRuntime::open_without_replay(
                        runtime_config,
                        conversation_event_store,
                        registry,
                    )?,
                    app_services,
                    agent_os_state,
                    host_process_epoch,
                    event_log,
                    runtime_state_authority,
                    true,
                )?))
            }
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

    fn install_llm_host(&self, vtable: LocalAgentLLMHostVTable) -> Result<(), AgentError> {
        match self {
            Self::InMemory(runtime) => runtime.install_llm_host(vtable),
            Self::Sqlite(runtime) => runtime.install_llm_host(vtable),
        }
    }

    fn uninstall_llm_host(&self) -> Result<(), AgentError> {
        match self {
            Self::InMemory(runtime) => runtime.uninstall_llm_host(),
            Self::Sqlite(runtime) => runtime.uninstall_llm_host(),
        }
    }

    fn suspend_llm_host(&self) -> Result<(), AgentError> {
        match self {
            Self::InMemory(runtime) => runtime.suspend_llm_host(),
            Self::Sqlite(runtime) => runtime.suspend_llm_host(),
        }
    }

    fn resume_llm_host(&self) -> Result<(), AgentError> {
        match self {
            Self::InMemory(runtime) => runtime.resume_llm_host(),
            Self::Sqlite(runtime) => runtime.resume_llm_host(),
        }
    }

    fn drive_llm_host(&self) -> Result<(), AgentError> {
        match self {
            Self::InMemory(runtime) => runtime.drive_llm_host(),
            Self::Sqlite(runtime) => runtime.drive_llm_host(),
        }
    }

    fn acknowledge_llm_command_json(&self, request_json: &str) -> Result<String, AgentError> {
        match self {
            Self::InMemory(runtime) => runtime.acknowledge_llm_command_json(request_json),
            Self::Sqlite(runtime) => runtime.acknowledge_llm_command_json(request_json),
        }
    }

    fn submit_llm_event_json(&self, request_json: &str) -> Result<String, AgentError> {
        match self {
            Self::InMemory(runtime) => runtime.submit_llm_event_json(request_json),
            Self::Sqlite(runtime) => runtime.submit_llm_event_json(request_json),
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

    pub fn profile_execution_route_json(&self, request_json: &str) -> Result<String, AgentError> {
        match self {
            Self::InMemory(runtime) => runtime.profile_execution_route_json(request_json),
            Self::Sqlite(runtime) => runtime.profile_execution_route_json(request_json),
        }
    }

    pub fn prepare_profile_publish_json(&self, request_json: &str) -> Result<String, AgentError> {
        match self {
            Self::InMemory(runtime) => runtime.prepare_profile_publish_json(request_json),
            Self::Sqlite(runtime) => runtime.prepare_profile_publish_json(request_json),
        }
    }
    pub fn commit_profile_publish_json(&self, request_json: &str) -> Result<String, AgentError> {
        match self {
            Self::InMemory(runtime) => runtime.commit_profile_publish_json(request_json),
            Self::Sqlite(runtime) => runtime.commit_profile_publish_json(request_json),
        }
    }
    pub fn begin_package_binding_json(&self, request_json: &str) -> Result<String, AgentError> {
        match self {
            Self::InMemory(runtime) => runtime.begin_package_binding_json(request_json),
            Self::Sqlite(runtime) => runtime.begin_package_binding_json(request_json),
        }
    }
    pub fn attach_host_binding_json(&self, request_json: &str) -> Result<String, AgentError> {
        match self {
            Self::InMemory(runtime) => runtime.attach_host_binding_json(request_json),
            Self::Sqlite(runtime) => runtime.attach_host_binding_json(request_json),
        }
    }
    pub fn confirm_host_binding_activation_json(
        &self,
        request_json: &str,
    ) -> Result<String, AgentError> {
        match self {
            Self::InMemory(runtime) => runtime.confirm_host_binding_activation_json(request_json),
            Self::Sqlite(runtime) => runtime.confirm_host_binding_activation_json(request_json),
        }
    }
    pub fn preview_run_preparation_json(&self, request_json: &str) -> Result<String, AgentError> {
        match self {
            Self::InMemory(runtime) => runtime.preview_run_preparation_json(request_json),
            Self::Sqlite(runtime) => runtime.preview_run_preparation_json(request_json),
        }
    }
    pub fn renew_run_preparation_json(&self, request_json: &str) -> Result<String, AgentError> {
        match self {
            Self::InMemory(runtime) => runtime.renew_run_preparation_json(request_json),
            Self::Sqlite(runtime) => runtime.renew_run_preparation_json(request_json),
        }
    }
    pub fn register_prepared_session_json(&self, request_json: &str) -> Result<String, AgentError> {
        match self {
            Self::InMemory(runtime) => runtime.register_prepared_session_json(request_json),
            Self::Sqlite(runtime) => runtime.register_prepared_session_json(request_json),
        }
    }
    pub fn commit_prepared_start_json(&self, request_json: &str) -> Result<String, AgentError> {
        match self {
            Self::InMemory(runtime) => runtime.commit_prepared_start_json(request_json),
            Self::Sqlite(runtime) => runtime.commit_prepared_start_json(request_json),
        }
    }
    pub fn reconcile_preparation_json(&self, request_json: &str) -> Result<String, AgentError> {
        match self {
            Self::InMemory(runtime) => runtime.reconcile_preparation_json(request_json),
            Self::Sqlite(runtime) => runtime.reconcile_preparation_json(request_json),
        }
    }
    pub fn begin_abort_preparation_json(&self, request_json: &str) -> Result<String, AgentError> {
        match self {
            Self::InMemory(runtime) => runtime.begin_abort_preparation_json(request_json),
            Self::Sqlite(runtime) => runtime.begin_abort_preparation_json(request_json),
        }
    }
    pub fn confirm_prepared_session_closed_json(
        &self,
        request_json: &str,
    ) -> Result<String, AgentError> {
        match self {
            Self::InMemory(runtime) => runtime.confirm_prepared_session_closed_json(request_json),
            Self::Sqlite(runtime) => runtime.confirm_prepared_session_closed_json(request_json),
        }
    }
    pub fn ack_prepared_session_cleanup_json(
        &self,
        request_json: &str,
    ) -> Result<String, AgentError> {
        match self {
            Self::InMemory(runtime) => runtime.ack_prepared_session_cleanup_json(request_json),
            Self::Sqlite(runtime) => runtime.ack_prepared_session_cleanup_json(request_json),
        }
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

    pub fn preview_context_json(&self, request_json: &str) -> Result<String, AgentError> {
        match self {
            Self::InMemory(runtime) => runtime.preview_context_json(request_json),
            Self::Sqlite(runtime) => runtime.preview_context_json(request_json),
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
pub unsafe extern "C" fn local_agent_runtime_bridge_install_llm_host(
    runtime: *mut RuntimeJsonBridge,
    vtable: *const LocalAgentLLMHostVTable,
) -> c_int {
    c_runtime_status(runtime, || {
        let vtable = vtable
            .as_ref()
            .copied()
            .ok_or_else(|| AgentError::Ffi("LLM host vtable must not be null".into()))?;
        bridge_ref(runtime)?.install_llm_host(vtable)
    })
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_uninstall_llm_host(
    runtime: *mut RuntimeJsonBridge,
) -> c_int {
    c_runtime_status(runtime, || bridge_ref(runtime)?.uninstall_llm_host())
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_suspend_llm_host(
    runtime: *mut RuntimeJsonBridge,
) -> c_int {
    c_runtime_status(runtime, || bridge_ref(runtime)?.suspend_llm_host())
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_resume_llm_host(
    runtime: *mut RuntimeJsonBridge,
) -> c_int {
    c_runtime_status(runtime, || bridge_ref(runtime)?.resume_llm_host())
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_drive_llm_host(
    runtime: *mut RuntimeJsonBridge,
) -> c_int {
    c_runtime_status(runtime, || bridge_ref(runtime)?.drive_llm_host())
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_submit_llm_command_ack(
    runtime: *mut RuntimeJsonBridge,
    acknowledgement_json: *const c_char,
) -> *mut c_char {
    c_runtime_result(runtime, || {
        let acknowledgement_json = c_str_arg(acknowledgement_json, "acknowledgement_json")?;
        bridge_ref(runtime)?.acknowledge_llm_command_json(acknowledgement_json)
    })
}

#[no_mangle]
pub unsafe extern "C" fn local_agent_runtime_bridge_submit_llm_event(
    runtime: *mut RuntimeJsonBridge,
    event_json: *const c_char,
) -> *mut c_char {
    c_runtime_result(runtime, || {
        let event_json = c_str_arg(event_json, "event_json")?;
        bridge_ref(runtime)?.submit_llm_event_json(event_json)
    })
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

macro_rules! json_bridge_function {
    ($name:ident, $method:ident) => {
        #[no_mangle]
        pub unsafe extern "C" fn $name(
            runtime: *mut RuntimeJsonBridge,
            request_json: *const c_char,
        ) -> *mut c_char {
            c_runtime_result(runtime, || {
                let request_json = c_str_arg(request_json, "request_json")?;
                bridge_ref(runtime)?.$method(request_json)
            })
        }
    };
}

json_bridge_function!(
    local_agent_runtime_bridge_prepare_profile_publish,
    prepare_profile_publish_json
);
json_bridge_function!(
    local_agent_runtime_bridge_commit_profile_publish,
    commit_profile_publish_json
);
json_bridge_function!(
    local_agent_runtime_bridge_begin_package_binding,
    begin_package_binding_json
);
json_bridge_function!(
    local_agent_runtime_bridge_attach_host_binding,
    attach_host_binding_json
);
json_bridge_function!(
    local_agent_runtime_bridge_confirm_host_binding_activation,
    confirm_host_binding_activation_json
);
json_bridge_function!(
    local_agent_runtime_bridge_profile_execution_route,
    profile_execution_route_json
);
json_bridge_function!(
    local_agent_runtime_bridge_preview_run_preparation,
    preview_run_preparation_json
);
json_bridge_function!(
    local_agent_runtime_bridge_renew_run_preparation,
    renew_run_preparation_json
);
json_bridge_function!(
    local_agent_runtime_bridge_register_prepared_session,
    register_prepared_session_json
);
json_bridge_function!(
    local_agent_runtime_bridge_commit_prepared_start,
    commit_prepared_start_json
);
json_bridge_function!(
    local_agent_runtime_bridge_reconcile_preparation,
    reconcile_preparation_json
);
json_bridge_function!(
    local_agent_runtime_bridge_begin_abort_preparation,
    begin_abort_preparation_json
);
json_bridge_function!(
    local_agent_runtime_bridge_ack_prepared_session_cleanup,
    ack_prepared_session_cleanup_json
);
json_bridge_function!(
    local_agent_runtime_bridge_confirm_prepared_session_closed,
    confirm_prepared_session_closed_json
);

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
pub unsafe extern "C" fn local_agent_runtime_bridge_preview_context(
    runtime: *mut RuntimeJsonBridge,
    request_json: *const c_char,
) -> *mut c_char {
    c_runtime_result(runtime, || {
        let request_json = c_str_arg(request_json, "request_json")?;
        bridge_ref(runtime)?.preview_context_json(request_json)
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
    profile_id: Option<String>,
    template_id: String,
    display_name: Option<String>,
    system_prompt: Option<String>,
    persona: Option<String>,
    response_style: Option<String>,
    #[serde(default)]
    selected_tool_ids: Vec<String>,
    #[serde(default)]
    context_step_ids: Vec<String>,
}

impl BuildAgentRequestJson {
    fn card_draft_input(&self) -> AgentBuilderCardDraftInput {
        AgentBuilderCardDraftInput {
            display_name: self.display_name.clone(),
            system_prompt: self.system_prompt.clone(),
            persona: self.persona.clone(),
            response_style: self.response_style.clone(),
            selected_tool_ids: self.selected_tool_ids.clone(),
            context_step_ids: self.context_step_ids.clone(),
        }
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct BuilderContextPreviewRequestJson {
    draft: BuildAgentRequestJson,
    sample_user_message: String,
}

#[derive(Serialize)]
struct BuilderContextPreviewJson {
    is_preview_only: bool,
    segments: Vec<BuilderContextPreviewSegmentJson>,
    token_estimate: usize,
    warnings: Vec<String>,
    missing_inputs: Vec<String>,
}

#[derive(Serialize)]
struct BuilderContextPreviewSegmentJson {
    id: String,
    title: String,
    source_label: String,
    trust_level: String,
    is_enabled: bool,
    preview_text: String,
}

impl BuilderContextPreviewJson {
    fn from_request(request: BuilderContextPreviewRequestJson) -> Result<Self, String> {
        let mut assembler = ContextAssembler::new();
        let mut segments = Vec::new();
        for step_id in cleaned_preview_steps(&request.draft.context_step_ids) {
            if let Some(segment) = preview_segment_for_step(&step_id, &request) {
                assembler = assembler.with_segment(segment.context_segment);
                segments.push(segment.dto);
            }
        }
        let preview = assembler.preview().map_err(|error| error.to_string())?;
        let token_estimate = preview
            .trace()
            .kept_token_entries()
            .iter()
            .map(|(_, tokens)| *tokens)
            .sum();

        Ok(Self {
            is_preview_only: false,
            segments,
            token_estimate,
            warnings: vec![
                "Rust preview: execution still assembles the final model input at run time."
                    .to_string(),
            ],
            missing_inputs: Vec::new(),
        })
    }
}

struct BuilderContextPreviewSegmentBuild {
    dto: BuilderContextPreviewSegmentJson,
    context_segment: ContextSegment,
}

fn cleaned_preview_steps(values: &[String]) -> Vec<String> {
    let cleaned = preview_cleaned_list(values);
    if cleaned.is_empty() {
        vec!["system_prompt".into(), "conversation_history".into()]
    } else {
        cleaned
    }
}

fn preview_segment_for_step(
    step_id: &str,
    request: &BuilderContextPreviewRequestJson,
) -> Option<BuilderContextPreviewSegmentBuild> {
    match step_id {
        "system_prompt" => preview_non_empty_trimmed(&request.draft.system_prompt).map(|text| {
            preview_segment(
                "system_prompt",
                "System Prompt",
                "prompt",
                "trusted_app_policy",
                text.clone(),
                ContextSegment::prompt("system_prompt", text)
                    .with_provenance("builder.system_prompt")
                    .required_for_model_input(),
            )
        }),
        "conversation_history" => {
            let text = format!(
                "Sample user message on the active conversation branch: {}",
                request.sample_user_message.trim()
            );
            Some(preview_segment(
                "conversation_history",
                "Conversation History",
                "conversation",
                "user_instruction",
                text.clone(),
                ContextSegment::conversation("conversation_history", text)
                    .with_provenance("builder.sample_user_message")
                    .required_for_model_input(),
            ))
        }
        "tool_results" => {
            let selected_tools = preview_cleaned_list(&request.draft.selected_tool_ids);
            let text = if selected_tools.is_empty() {
                "No tool observations in this preview.".to_string()
            } else {
                format!(
                    "Selected tools available for future tool observations: {}",
                    selected_tools.join(", ")
                )
            };
            Some(preview_segment(
                "tool_results",
                "Tool Results",
                "tool_result",
                "runtime_dependent_tool_result",
                text.clone(),
                ContextSegment::tool_result("tool_results", text)
                    .with_provenance("builder.tool_results_preview"),
            ))
        }
        _ => None,
    }
}

fn preview_non_empty_trimmed(value: &Option<String>) -> Option<String> {
    value
        .as_ref()
        .map(|value| value.trim())
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
}

fn preview_cleaned_list(values: &[String]) -> Vec<String> {
    values
        .iter()
        .map(|value| value.trim())
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
        .collect()
}

fn preview_segment(
    id: &str,
    title: &str,
    source_label: &str,
    trust_level: &str,
    preview_text: String,
    context_segment: ContextSegment,
) -> BuilderContextPreviewSegmentBuild {
    BuilderContextPreviewSegmentBuild {
        dto: BuilderContextPreviewSegmentJson {
            id: id.to_string(),
            title: title.to_string(),
            source_label: source_label.to_string(),
            trust_level: trust_level.to_string(),
            is_enabled: true,
            preview_text,
        },
        context_segment,
    }
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

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ProfileExecutionRouteRequestJson {
    profile_id: String,
    profile_revision: u64,
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
    host_process_epoch: String,
    #[serde(default)]
    providers: Vec<RuntimeProviderConfigJson>,
    store: StoreConfigJson,
    #[serde(default)]
    agent_os: RuntimeAgentOSConfigJson,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PreviewRunPreparationJson {
    idempotency_key: String,
    preparation_id: String,
    proposed_run_id: String,
    start_request: AuthoritativePreparationStartJson,
    now_millis: u64,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct AuthoritativePreparationStartJson {
    agent_profile_id: String,
    profile_revision_id: u64,
    user_intent: String,
    conversation_run_frame_ref: ConversationRunFrameRefJson,
}

#[derive(Deserialize)]
struct RenewRunPreparationJson {
    token: String,
    binding_digest: String,
    idempotency_key: String,
    now_millis: u64,
}

#[derive(Deserialize)]
struct RegisterPreparedSessionJson {
    token: String,
    registration: PreparedSessionRegistration,
    now_millis: u64,
}

#[derive(Deserialize)]
struct CommitPreparedStartJson {
    token: String,
    attestation: HostAttestation,
    now_millis: u64,
}

#[derive(Deserialize)]
struct ReconcilePreparationJson {
    preparation_id: String,
    proposed_run_id: String,
    token_digest: String,
}

#[derive(Deserialize)]
struct BeginAbortPreparationJson {
    preparation_id: String,
    token: Option<String>,
    idempotency_key: String,
    reason: PreparationAbortReason,
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
        #[serde(default)]
        provider_id: Option<String>,
        #[serde(default)]
        display_name: Option<String>,
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
                provider_id,
                display_name,
                model,
                model_config_json,
                max_context_tokens,
            } => {
                let provider_id = provider_id
                    .clone()
                    .unwrap_or_else(|| "local_llm".to_string());
                let display_name = display_name
                    .clone()
                    .unwrap_or_else(|| "Local LLM".to_string());
                let model = model.clone();
                let model_config_json = model_config_json.clone();
                let max_context_tokens = *max_context_tokens;
                let engine_id = local_engine_id(&model_config_json, &provider_id)?;
                let tokenizer_id = provider_id.clone();
                let provider_factory_id = provider_id.clone();
                registry.register_fallible_factory(
                    ProviderProfile {
                        id: provider_id,
                        display_name,
                        kind: ProviderKind::LocalLlm,
                        max_context_tokens,
                    },
                    move || {
                        Ok(ProviderBundle {
                            provider: Box::new(LocalLLMProvider::with_provider_id(
                                provider_factory_id.clone(),
                                model.clone(),
                                model_config_json.clone(),
                                Box::new(CAbiV2LocalInferenceBackend::new(engine_id.clone())?),
                            )),
                            tokenizer: Box::new(BridgeWhitespaceTokenizer::new(
                                tokenizer_id.clone(),
                                max_context_tokens,
                            )),
                        })
                    },
                )
            }
        }
    }
}

fn local_engine_id(model_config_json: &str, provider_id: &str) -> Result<String, AgentError> {
    let value: Value = serde_json::from_str(model_config_json).map_err(|error| {
        AgentError::Provider(format!("invalid local model config JSON: {error}"))
    })?;
    if let Some(engine) = value.get("engine").and_then(Value::as_str) {
        if !engine.trim().is_empty() {
            return Ok(engine.to_string());
        }
    }
    if let Some(backend) = value.get("backend").and_then(Value::as_str) {
        if !backend.trim().is_empty() {
            return Ok(backend.to_string());
        }
    }
    if let Some(engine) = provider_id.strip_prefix("local_llm.") {
        if !engine.trim().is_empty() {
            return Ok(engine.to_string());
        }
    }
    Err(AgentError::Provider(format!(
        "local provider {provider_id} missing engine/backend in model_config_json"
    )))
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
        "assistant_message_completed"
            | "run.completed"
            | "run.failed"
            | "run.cancelled"
            | "run.waiting_tool"
            | "run.suspended"
    )
}

fn host_event_projection_code(event: &LLMEventEnvelope) -> Option<&'static str> {
    match event.kind() {
        LLMEventKind::GenerationStarted => Some("assistant_message_started"),
        LLMEventKind::TextDelta => Some("assistant_text_delta"),
        LLMEventKind::GenerationCompleted
            if event
                .payload
                .completion
                .as_ref()
                .is_some_and(|completion| completion.outcome == "final_response") =>
        {
            Some("assistant_message_completed")
        }
        LLMEventKind::Failed => Some("run.failed"),
        LLMEventKind::Cancelled => Some("run.cancelled"),
        _ => None,
    }
}

fn host_tool_result_sensitivity(sensitivity: Sensitivity) -> &'static str {
    match sensitivity {
        Sensitivity::Public => "routine",
        Sensitivity::Private => "private",
        Sensitivity::Secret => "highly_sensitive",
    }
}

fn recover_host_completed_run(
    runtime_state: &dyn UnifiedRuntimeStateRepository,
    event_log: &ExecutionEventLog,
    run_id: &str,
    final_message_id: &str,
) -> Result<Option<CompletedRunRecord>, ConversationCommitError> {
    let Some(snapshot_json) = runtime_state.run_snapshot_json(run_id).map_err(|error| {
        ConversationCommitError::new(
            "conversation_commit.recovery_failed",
            format!("{}: {error}", error.code()),
        )
    })?
    else {
        return Ok(None);
    };
    let output = event_log
        .replay(run_id, None)
        .into_iter()
        .filter(|event| event.code() == "assistant.output")
        .find_map(|event| {
            let payload = serde_json::from_str::<Value>(event.payload()).ok()?;
            (payload["message_id"].as_str() == Some(final_message_id)).then_some(payload)
        });
    let Some(output) = output else {
        return Ok(None);
    };
    let persisted: PersistedResolvedRunSnapshotV2 =
        serde_json::from_str(&snapshot_json).map_err(|error| {
            ConversationCommitError::new("conversation_commit.recovery_failed", error.to_string())
        })?;
    let snapshot = ResolvedRunSnapshot::try_from(persisted).map_err(|error| {
        ConversationCommitError::new("conversation_commit.recovery_failed", error.to_string())
    })?;
    let text = output["text"].as_str().ok_or_else(|| {
        ConversationCommitError::new(
            "conversation_commit.recovery_failed",
            "persisted assistant output is missing text",
        )
    })?;
    Ok(Some(CompletedRunRecord::restored(
        run_id,
        final_message_id,
        snapshot.conversation_run_frame_ref().clone(),
        text,
    )))
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

unsafe fn c_runtime_status(
    runtime: *mut RuntimeJsonBridge,
    run: impl FnOnce() -> Result<(), AgentError>,
) -> c_int {
    match catch_unwind(AssertUnwindSafe(|| {
        let bridge = bridge_ref(runtime)?;
        bridge.ensure_ffi_usable()?;
        run()
    })) {
        Ok(Ok(())) => 0,
        Ok(Err(_)) => -1,
        Err(_) => {
            if let Some(bridge) = runtime.as_ref() {
                bridge.mark_ffi_tainted();
            }
            -1
        }
    }
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
    fn tool_result_sensitivity_uses_swift_host_contract_values() {
        assert_eq!(host_tool_result_sensitivity(Sensitivity::Public), "routine");
        assert_eq!(
            host_tool_result_sensitivity(Sensitivity::Private),
            "private"
        );
        assert_eq!(
            host_tool_result_sensitivity(Sensitivity::Secret),
            "highly_sensitive"
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
    use std::sync::mpsc;
    use std::time::Duration;

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

    #[test]
    fn accepted_host_delta_is_consumed_and_wakes_the_execution_stream() {
        let bridge = BridgeRuntime::new(
            AgentRuntime::new(AgentRuntimeConfig {
                system_prompt: "system".into(),
                runtime_policy: "policy".into(),
                tool_schemas: Vec::new(),
                tokenizer: Box::new(crate::context::MockTokenizer::new(100)),
                provider: Box::new(crate::core::MockStreamingProvider::new()),
                tool_router: None,
            }),
            AgentOSApplicationService::empty(),
        );
        bridge
            .runtime_state
            .insert_worker_and_session(
                crate::llm_contracts::HostWorkerRecord::new(
                    "run-host",
                    "session-host",
                    TEST_HOST_PROCESS_EPOCH,
                )
                .with_execution_phase(Some(
                    crate::llm_contracts::HostExecutionPhase::ConsumingLlmTurn,
                ))
                .with_generation_turn_id(Some("turn-host".into()))
                .with_resource_lifecycle(crate::llm_contracts::ResourceLifecycle::Generating),
                crate::llm_contracts::HostSessionRecord::new(
                    "run-host",
                    "session-host",
                    TEST_HOST_PROCESS_EPOCH,
                    "binding-host",
                    1,
                    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                ),
            )
            .unwrap();

        let mut stream = bridge.execution.observe_event_stream("run-host", None);
        let (sender, receiver) = mpsc::channel();
        std::thread::spawn(move || {
            sender
                .send(
                    stream
                        .next_live()
                        .map(|event| (event.code().to_string(), event.payload().to_string())),
                )
                .unwrap();
        });

        let mut event = LLMEventEnvelope {
            schema_version: 1,
            event_id: "delta-host".into(),
            run_id: "run-host".into(),
            session_handle: "session-host".into(),
            host_process_epoch: TEST_HOST_PROCESS_EPOCH.into(),
            generation_turn_id: Some("turn-host".into()),
            event_sequence: 1,
            kind: crate::llm_contracts::LLMEventKind::TextDelta,
            payload: crate::llm_contracts::LLMEventPayload {
                text: Some("hello".into()),
                ..Default::default()
            },
            event_envelope_digest: String::new(),
        };
        event.event_envelope_digest = event.expected_digest().unwrap();
        assert_eq!(
            bridge
                .submit_llm_event_json(&serde_json::to_string(&event).unwrap())
                .unwrap(),
            "\"accepted\""
        );

        let live = receiver
            .recv_timeout(Duration::from_millis(100))
            .expect("accepted host event must wake the live execution stream")
            .unwrap();
        assert_eq!(live.0, "assistant_text_delta");
        assert_eq!(
            serde_json::from_str::<Value>(&live.1).unwrap()["text"],
            "hello"
        );
        assert_eq!(
            bridge
                .runtime_state
                .event_queue_usage("session-host")
                .unwrap()
                .event_count,
            0
        );
    }

    #[test]
    fn duplicate_host_event_recovers_a_pending_execution_projection() {
        let bridge = BridgeRuntime::new(
            AgentRuntime::new(AgentRuntimeConfig {
                system_prompt: "system".into(),
                runtime_policy: "policy".into(),
                tool_schemas: Vec::new(),
                tokenizer: Box::new(crate::context::MockTokenizer::new(100)),
                provider: Box::new(crate::core::MockStreamingProvider::new()),
                tool_router: None,
            }),
            AgentOSApplicationService::empty(),
        );
        bridge
            .runtime_state
            .insert_worker_and_session(
                crate::llm_contracts::HostWorkerRecord::new(
                    "run-host",
                    "session-host",
                    TEST_HOST_PROCESS_EPOCH,
                )
                .with_execution_phase(Some(
                    crate::llm_contracts::HostExecutionPhase::ConsumingLlmTurn,
                ))
                .with_generation_turn_id(Some("turn-host".into()))
                .with_resource_lifecycle(crate::llm_contracts::ResourceLifecycle::Generating),
                crate::llm_contracts::HostSessionRecord::new(
                    "run-host",
                    "session-host",
                    TEST_HOST_PROCESS_EPOCH,
                    "binding-host",
                    1,
                    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                ),
            )
            .unwrap();
        let mut event = LLMEventEnvelope {
            schema_version: 1,
            event_id: "delta-host".into(),
            run_id: "run-host".into(),
            session_handle: "session-host".into(),
            host_process_epoch: TEST_HOST_PROCESS_EPOCH.into(),
            generation_turn_id: Some("turn-host".into()),
            event_sequence: 1,
            kind: crate::llm_contracts::LLMEventKind::TextDelta,
            payload: crate::llm_contracts::LLMEventPayload {
                text: Some("hello".into()),
                ..Default::default()
            },
            event_envelope_digest: String::new(),
        };
        event.event_envelope_digest = event.expected_digest().unwrap();

        assert_eq!(
            bridge.host_llm_dispatcher.submit_event(&event).unwrap(),
            LLMEventSubmissionResult::Accepted
        );
        assert_eq!(
            bridge
                .runtime_state
                .event_queue_usage("session-host")
                .unwrap()
                .event_count,
            1
        );

        assert_eq!(
            bridge
                .submit_llm_event_json(&serde_json::to_string(&event).unwrap())
                .unwrap(),
            "\"duplicate\""
        );
        assert_eq!(
            bridge
                .execution
                .observe_events("run-host", None)
                .iter()
                .filter(|event| event.code() == "assistant_text_delta")
                .count(),
            1
        );
        assert_eq!(
            bridge
                .runtime_state
                .event_queue_usage("session-host")
                .unwrap()
                .event_count,
            0
        );
    }

    #[test]
    fn duplicate_host_event_does_not_repeat_an_already_persisted_projection() {
        let bridge = BridgeRuntime::new(
            AgentRuntime::new(AgentRuntimeConfig {
                system_prompt: "system".into(),
                runtime_policy: "policy".into(),
                tool_schemas: Vec::new(),
                tokenizer: Box::new(crate::context::MockTokenizer::new(100)),
                provider: Box::new(crate::core::MockStreamingProvider::new()),
                tool_router: None,
            }),
            AgentOSApplicationService::empty(),
        );
        bridge
            .runtime_state
            .insert_worker_and_session(
                crate::llm_contracts::HostWorkerRecord::new(
                    "run-host",
                    "session-host",
                    TEST_HOST_PROCESS_EPOCH,
                )
                .with_execution_phase(Some(
                    crate::llm_contracts::HostExecutionPhase::ConsumingLlmTurn,
                ))
                .with_generation_turn_id(Some("turn-host".into()))
                .with_resource_lifecycle(crate::llm_contracts::ResourceLifecycle::Generating),
                crate::llm_contracts::HostSessionRecord::new(
                    "run-host",
                    "session-host",
                    TEST_HOST_PROCESS_EPOCH,
                    "binding-host",
                    1,
                    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                ),
            )
            .unwrap();
        let mut event = LLMEventEnvelope {
            schema_version: 1,
            event_id: "delta-host".into(),
            run_id: "run-host".into(),
            session_handle: "session-host".into(),
            host_process_epoch: TEST_HOST_PROCESS_EPOCH.into(),
            generation_turn_id: Some("turn-host".into()),
            event_sequence: 1,
            kind: crate::llm_contracts::LLMEventKind::TextDelta,
            payload: crate::llm_contracts::LLMEventPayload {
                text: Some("hello".into()),
                ..Default::default()
            },
            event_envelope_digest: String::new(),
        };
        event.event_envelope_digest = event.expected_digest().unwrap();
        assert_eq!(
            bridge.host_llm_dispatcher.submit_event(&event).unwrap(),
            LLMEventSubmissionResult::Accepted
        );
        bridge
            .execution
            .record_external_event(
                "run-host",
                "assistant_text_delta",
                json!({
                    "host_event_id": "delta-host",
                    "message_id": "assistant:run-host:turn-host",
                    "text": "hello",
                })
                .to_string(),
            )
            .unwrap();

        assert_eq!(
            bridge
                .submit_llm_event_json(&serde_json::to_string(&event).unwrap())
                .unwrap(),
            "\"duplicate\""
        );
        assert_eq!(
            bridge
                .execution
                .observe_events("run-host", None)
                .iter()
                .filter(|event| event.code() == "assistant_text_delta")
                .count(),
            1
        );
        assert_eq!(
            bridge
                .runtime_state
                .event_queue_usage("session-host")
                .unwrap()
                .event_count,
            0
        );
    }

    #[test]
    fn bridge_initialization_recovers_pending_host_event_projections() {
        let store = crate::storage::InMemoryRuntimeStateStore::new();
        store
            .insert_worker_and_session(
                crate::llm_contracts::HostWorkerRecord::new(
                    "run-host",
                    "session-host",
                    TEST_HOST_PROCESS_EPOCH,
                )
                .with_execution_phase(Some(
                    crate::llm_contracts::HostExecutionPhase::ConsumingLlmTurn,
                ))
                .with_generation_turn_id(Some("turn-host".into()))
                .with_resource_lifecycle(crate::llm_contracts::ResourceLifecycle::Generating),
                crate::llm_contracts::HostSessionRecord::new(
                    "run-host",
                    "session-host",
                    TEST_HOST_PROCESS_EPOCH,
                    "binding-host",
                    1,
                    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                ),
            )
            .unwrap();
        let mut event = LLMEventEnvelope {
            schema_version: 1,
            event_id: "delta-host".into(),
            run_id: "run-host".into(),
            session_handle: "session-host".into(),
            host_process_epoch: TEST_HOST_PROCESS_EPOCH.into(),
            generation_turn_id: Some("turn-host".into()),
            event_sequence: 1,
            kind: crate::llm_contracts::LLMEventKind::TextDelta,
            payload: crate::llm_contracts::LLMEventPayload {
                text: Some("hello".into()),
                ..Default::default()
            },
            event_envelope_digest: String::new(),
        };
        event.event_envelope_digest = event.expected_digest().unwrap();
        crate::execution::HostLLMWorkerService::new(Arc::new(store.clone()))
            .submit_event(&event)
            .unwrap();

        let bridge = BridgeRuntime::try_new(
            AgentRuntime::new(AgentRuntimeConfig {
                system_prompt: "system".into(),
                runtime_policy: "policy".into(),
                tool_schemas: Vec::new(),
                tokenizer: Box::new(crate::context::MockTokenizer::new(100)),
                provider: Box::new(crate::core::MockStreamingProvider::new()),
                tool_router: None,
            }),
            AgentOSApplicationService::empty(),
            store.agent_os_state(),
            TEST_HOST_PROCESS_EPOCH.into(),
            ExecutionEventLog::new(store.clone()),
            Arc::new(store.clone()),
            false,
        )
        .unwrap();

        assert_eq!(
            bridge
                .execution
                .observe_events("run-host", None)
                .iter()
                .filter(|event| event.code() == "assistant_text_delta")
                .count(),
            1
        );
        assert_eq!(
            bridge
                .runtime_state
                .event_queue_usage("session-host")
                .unwrap()
                .event_count,
            0
        );
    }

    #[test]
    fn approving_a_host_tool_waits_for_the_granted_pending_request_result() {
        let bridge = BridgeRuntime::new(
            AgentRuntime::new(AgentRuntimeConfig {
                system_prompt: "system".into(),
                runtime_policy: "policy".into(),
                tool_schemas: Vec::new(),
                tokenizer: Box::new(crate::context::MockTokenizer::new(100)),
                provider: Box::new(crate::core::MockStreamingProvider::new()),
                tool_router: Some(crate::tool::ToolRouter::new(
                    crate::tool::ToolRegistry::new(),
                )),
            }),
            AgentOSApplicationService::from_config(
                AgentOSApplicationServiceConfig::new().with_seed_development_profile(true),
            )
            .unwrap(),
        );
        let schema: ToolSchemaJson = from_json(
            r#"{"name":"debug.echo","description":"Echo","parameters_json_schema":"{\"type\":\"object\"}","risk_level":"confirm"}"#,
        )
        .unwrap();
        bridge
            .lock()
            .unwrap()
            .register_tool(schema.into_tool_schema().unwrap())
            .unwrap();
        let prepared: Value = serde_json::from_str(
            &bridge
                .prepare_user_turn_json(
                    r#"{"session_id":null,"parent_event_id":null,"text":"use tool debug.echo","blob_refs":[]}"#,
                )
                .unwrap(),
        )
        .unwrap();
        let run: Value = serde_json::from_str(
            &bridge
                .start_run_json(
                    &json!({
                        "agent_profile_id": "profile_1",
                        "profile_revision_id": 1,
                        "user_intent": "use tool debug.echo",
                        "conversation_run_frame_ref": prepared["conversation_run_frame_ref"],
                        "options": {},
                    })
                    .to_string(),
                )
                .unwrap(),
        )
        .unwrap();
        let run_id = run["run_id"].as_str().unwrap();
        let approval_id = bridge.lock().unwrap().pending_approval_requests()[0]
            .approval_id
            .clone();
        bridge
            .runtime_state
            .insert_worker_and_session(
                crate::llm_contracts::HostWorkerRecord::new(
                    run_id,
                    "session-host",
                    TEST_HOST_PROCESS_EPOCH,
                )
                .with_execution_phase(Some(
                    crate::llm_contracts::HostExecutionPhase::SuspendedForToolApproval,
                ))
                .with_generation_turn_id(Some("turn-host".into()))
                .with_resource_lifecycle(crate::llm_contracts::ResourceLifecycle::Generating),
                crate::llm_contracts::HostSessionRecord::new(
                    run_id,
                    "session-host",
                    TEST_HOST_PROCESS_EPOCH,
                    "binding-host",
                    1,
                    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                ),
            )
            .unwrap();

        bridge
            .approve_tool_json(
                &json!({
                    "id": approval_id,
                    "decision": {"approved": true, "reason": null},
                })
                .to_string(),
            )
            .unwrap();

        assert_eq!(bridge.lock().unwrap().pending_tool_requests().len(), 1);
        assert_eq!(
            bridge
                .runtime_state
                .host_worker(run_id)
                .unwrap()
                .unwrap()
                .execution_phase(),
            Some(crate::llm_contracts::HostExecutionPhase::SuspendedForToolApproval)
        );
    }

    #[test]
    fn cancel_run_routes_v2_to_the_durable_host_outbox() {
        let bridge = BridgeRuntime::new(
            AgentRuntime::new(AgentRuntimeConfig {
                system_prompt: "system".into(),
                runtime_policy: "policy".into(),
                tool_schemas: Vec::new(),
                tokenizer: Box::new(crate::context::MockTokenizer::new(100)),
                provider: Box::new(crate::core::MockStreamingProvider::new()),
                tool_router: None,
            }),
            AgentOSApplicationService::empty(),
        );
        bridge
            .runtime_state
            .insert_worker_and_session(
                crate::llm_contracts::HostWorkerRecord::new(
                    "run-host",
                    "session-host",
                    TEST_HOST_PROCESS_EPOCH,
                )
                .with_execution_phase(Some(
                    crate::llm_contracts::HostExecutionPhase::ConsumingLlmTurn,
                ))
                .with_generation_turn_id(Some("turn-host".into()))
                .with_resource_lifecycle(crate::llm_contracts::ResourceLifecycle::Generating),
                crate::llm_contracts::HostSessionRecord::new(
                    "run-host",
                    "session-host",
                    TEST_HOST_PROCESS_EPOCH,
                    "binding-host",
                    1,
                    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                ),
            )
            .unwrap();

        let response = bridge.cancel_run_json(r#"{"run_id":"run-host"}"#).unwrap();
        assert_eq!(
            serde_json::from_str::<Value>(&response).unwrap()["payload"],
            r#"{"state":"cancelling"}"#
        );
        let pending = bridge.runtime_state.pending_host_commands().unwrap();
        assert_eq!(pending.len(), 1);
        assert_eq!(
            pending[0].payload().unwrap().kind(),
            crate::llm_contracts::HostCommandKind::CancelGeneration
        );
    }
}
