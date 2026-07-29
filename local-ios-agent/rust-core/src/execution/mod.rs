mod budget;
mod completed_run_registry;
mod context_input;
mod debug_store;
mod event_log;
mod execution_plan;
mod execution_planner;
mod execution_service;
mod host_llm_dispatcher;
mod host_llm_worker;
mod run_lifecycle;
mod tool_approval;
mod tool_contract;
mod tool_loop;
mod trace;

pub use budget::ExecutionBudgets;
pub use completed_run_registry::{idempotency_key, CompletedRunRecord, CompletedRunRegistry};
pub use context_input::{ExecutionContextInputAssembler, ExecutionContextInputError};
pub use debug_store::RunDebugStore;
pub use event_log::{
    ExecutionEvent, ExecutionEventLog, ExecutionEventRepository, ExecutionEventStream,
    InMemoryExecutionEventRepository,
};
pub use execution_plan::{ExecutionPlan, ExecutionStep, ExecutionStepKind};
pub use execution_planner::{ExecutionPlanner, ExecutionPlanningError, ExecutionPlanningResult};
pub use execution_service::ExecutionService;
pub use host_llm_dispatcher::{
    HostLLMDispatcherConfig, HostLLMDispatcherRuntime, LocalAgentLLMHostCommandFn,
    LocalAgentLLMHostCopyReceipt, LocalAgentLLMHostReleaseContextFn, LocalAgentLLMHostVTable,
    LOCAL_AGENT_LLM_HOST_ABI_VERSION,
};
pub use host_llm_worker::{
    HostLLMWorkerService, HostLLMWorkerServiceConfig, HostToolBatchExecutor,
};
pub use run_lifecycle::{
    ExecutionStartError, RunHandle, RunLifecycleService, StartExecutionRequest,
};
pub use tool_approval::{ApprovalDecision, ToolApprovalService};
pub use tool_contract::{ExecutionToolCall, ExecutionToolObservation, ExecutionToolOutcome};
pub use tool_loop::{ToolLoopService, ToolLoopStartError, ToolLoopStartRequest};
pub use trace::TraceConfig;
