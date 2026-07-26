use serde::{Deserialize, Serialize};

use super::{GenerationDisclosureDocument, HostCommandPayload, HostToolResult};

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum HostExecutionPhase {
    AwaitingStartCommandAck,
    AwaitingGenerationStarted,
    ConsumingLlmTurn,
    ExecutingToolBatch,
    SuspendedForToolApproval,
    AwaitingIncrementalEgressApproval,
    AwaitingResumeCommandAck,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum LogicalRunOutcome {
    Pending,
    Succeeded { finish_reason: String },
    Failed { code: String },
    Cancelled,
    Interrupted { code: String },
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum HostSessionCloseDisposition {
    Closed,
    Cancelled,
    EpochEnded,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum ResourceLifecycle {
    Registered,
    Generating,
    AwaitingCancelCommandAck,
    AwaitingCancelledTerminal,
    AwaitingCloseCommandAck,
    AwaitingSessionClosed,
    Quarantined {
        code: String,
    },
    Closed {
        disposition: HostSessionCloseDisposition,
    },
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum HostWatchdogKind {
    StartCommandAck,
    GenerationStart,
    StreamIdle,
    ToolBatch,
    ResumeCommandAck,
    CancelCommandAck,
    CancelTerminal,
    CloseCommandAck,
    SessionClose,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct HostWorkerRecord {
    schema_version: u32,
    run_id: String,
    session_handle: String,
    host_process_epoch: String,
    revision: u64,
    execution_phase: Option<HostExecutionPhase>,
    logical_outcome: LogicalRunOutcome,
    resource_lifecycle: ResourceLifecycle,
    expected_command_sequence: u64,
    expected_event_sequence: u64,
    generation_turn_id: Option<String>,
    watchdog_kind: Option<HostWatchdogKind>,
    watchdog_deadline_millis: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    generation_payload: Option<HostCommandPayload>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    generation_disclosure: Option<GenerationDisclosureDocument>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    tool_results: Vec<HostToolResult>,
}

impl HostWorkerRecord {
    pub fn new(
        run_id: impl Into<String>,
        session_handle: impl Into<String>,
        host_process_epoch: impl Into<String>,
    ) -> Self {
        Self {
            schema_version: 1,
            run_id: run_id.into(),
            session_handle: session_handle.into(),
            host_process_epoch: host_process_epoch.into(),
            revision: 0,
            execution_phase: None,
            logical_outcome: LogicalRunOutcome::Pending,
            resource_lifecycle: ResourceLifecycle::Registered,
            expected_command_sequence: 1,
            expected_event_sequence: 1,
            generation_turn_id: None,
            watchdog_kind: None,
            watchdog_deadline_millis: None,
            generation_payload: None,
            generation_disclosure: None,
            tool_results: Vec::new(),
        }
    }

    pub fn run_id(&self) -> &str {
        &self.run_id
    }
    pub fn session_handle(&self) -> &str {
        &self.session_handle
    }
    pub fn host_process_epoch(&self) -> &str {
        &self.host_process_epoch
    }
    pub fn revision(&self) -> u64 {
        self.revision
    }
    pub fn execution_phase(&self) -> Option<HostExecutionPhase> {
        self.execution_phase
    }
    pub fn logical_outcome(&self) -> &LogicalRunOutcome {
        &self.logical_outcome
    }
    pub fn resource_lifecycle(&self) -> &ResourceLifecycle {
        &self.resource_lifecycle
    }
    pub fn expected_command_sequence(&self) -> u64 {
        self.expected_command_sequence
    }
    pub fn expected_event_sequence(&self) -> u64 {
        self.expected_event_sequence
    }
    pub fn generation_turn_id(&self) -> Option<&str> {
        self.generation_turn_id.as_deref()
    }
    pub fn is_fully_terminal(&self) -> bool {
        !matches!(self.logical_outcome, LogicalRunOutcome::Pending)
            && matches!(self.resource_lifecycle, ResourceLifecycle::Closed { .. })
    }
    pub fn generation_payload(&self) -> Option<&HostCommandPayload> {
        self.generation_payload.as_ref()
    }
    pub fn generation_disclosure(&self) -> Option<&GenerationDisclosureDocument> {
        self.generation_disclosure.as_ref()
    }
    pub fn tool_results(&self) -> &[HostToolResult] {
        &self.tool_results
    }

    pub fn with_revision(mut self, revision: u64) -> Self {
        self.revision = revision;
        self
    }
    pub fn with_execution_phase(mut self, phase: Option<HostExecutionPhase>) -> Self {
        self.execution_phase = phase;
        self
    }
    pub fn with_logical_outcome(mut self, outcome: LogicalRunOutcome) -> Self {
        self.logical_outcome = outcome;
        self
    }
    pub fn with_resource_lifecycle(mut self, lifecycle: ResourceLifecycle) -> Self {
        self.resource_lifecycle = lifecycle;
        self
    }
    pub fn with_expected_command_sequence(mut self, sequence: u64) -> Self {
        self.expected_command_sequence = sequence;
        self
    }
    pub fn with_expected_event_sequence(mut self, sequence: u64) -> Self {
        self.expected_event_sequence = sequence;
        self
    }
    pub fn with_generation_turn_id(mut self, generation_turn_id: Option<String>) -> Self {
        self.generation_turn_id = generation_turn_id;
        self
    }
    pub fn with_watchdog(
        mut self,
        kind: Option<HostWatchdogKind>,
        deadline_millis: Option<u64>,
    ) -> Self {
        self.watchdog_kind = kind;
        self.watchdog_deadline_millis = deadline_millis;
        self
    }
    pub fn with_generation_request(
        mut self,
        payload: HostCommandPayload,
        disclosure: GenerationDisclosureDocument,
    ) -> Self {
        self.generation_payload = Some(payload);
        self.generation_disclosure = Some(disclosure);
        self
    }
    pub fn with_tool_results(mut self, results: Vec<HostToolResult>) -> Self {
        self.tool_results = results;
        self
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct HostSessionRecord {
    schema_version: u32,
    run_id: String,
    session_handle: String,
    host_process_epoch: String,
    binding_id: String,
    binding_revision: u64,
    binding_hash: String,
    resource_lifecycle: ResourceLifecycle,
}

impl HostSessionRecord {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        run_id: impl Into<String>,
        session_handle: impl Into<String>,
        host_process_epoch: impl Into<String>,
        binding_id: impl Into<String>,
        binding_revision: u64,
        binding_hash: impl Into<String>,
    ) -> Self {
        Self {
            schema_version: 1,
            run_id: run_id.into(),
            session_handle: session_handle.into(),
            host_process_epoch: host_process_epoch.into(),
            binding_id: binding_id.into(),
            binding_revision,
            binding_hash: binding_hash.into(),
            resource_lifecycle: ResourceLifecycle::Registered,
        }
    }

    pub fn run_id(&self) -> &str {
        &self.run_id
    }
    pub fn session_handle(&self) -> &str {
        &self.session_handle
    }
    pub fn host_process_epoch(&self) -> &str {
        &self.host_process_epoch
    }
    pub fn binding_id(&self) -> &str {
        &self.binding_id
    }
    pub fn binding_revision(&self) -> u64 {
        self.binding_revision
    }
    pub fn binding_hash(&self) -> &str {
        &self.binding_hash
    }
    pub fn resource_lifecycle(&self) -> &ResourceLifecycle {
        &self.resource_lifecycle
    }
    pub fn with_resource_lifecycle(mut self, lifecycle: ResourceLifecycle) -> Self {
        self.resource_lifecycle = lifecycle;
        self
    }
}
