use std::collections::BTreeMap;
use std::fmt;
use std::sync::{Arc, Mutex};

use crate::conversation::ConversationRunFrameRef;
use crate::execution::ExecutionEventLog;
use crate::storage::agent_os_state::SharedAgentOSStateStore;
use crate::user_customization::AgentProfileVersion;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StartExecutionRequest {
    run_id: String,
    agent_profile_id: String,
    profile_revision_id: AgentProfileVersion,
    user_intent: String,
    conversation_run_frame_ref: ConversationRunFrameRef,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ExecutionStartError {
    code: String,
    message: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RunHandle {
    run_id: String,
    replay_from_sequence: Option<u64>,
}

#[derive(Clone)]
pub struct RunLifecycleService {
    event_log: ExecutionEventLog,
    state_store: SharedAgentOSStateStore,
    host_process_epoch: String,
    owned_generations: Arc<Mutex<BTreeMap<String, u64>>>,
}

impl RunLifecycleService {
    pub fn new(event_log: ExecutionEventLog) -> Self {
        Self::with_agent_os_state(
            event_log,
            SharedAgentOSStateStore::in_memory(),
            default_host_process_epoch(),
        )
    }

    pub fn with_agent_os_state(
        event_log: ExecutionEventLog,
        state_store: SharedAgentOSStateStore,
        host_process_epoch: impl Into<String>,
    ) -> Self {
        Self {
            event_log,
            state_store,
            host_process_epoch: host_process_epoch.into(),
            owned_generations: Arc::new(Mutex::new(BTreeMap::new())),
        }
    }

    pub fn acquire_legacy(&self, run_id: &str) -> Result<(), ExecutionStartError> {
        let lease = self
            .state_store
            .with_mut(|store| store.acquire_legacy(run_id, &self.host_process_epoch))
            .map_err(lease_error)?;
        self.owned_generations
            .lock()
            .map_err(|_| lifecycle_poisoned())?
            .insert(run_id.to_string(), lease.generation());
        Ok(())
    }

    pub fn start_run(&self, run_id: impl Into<String>) -> RunHandle {
        let run_id = run_id.into();
        self.event_log.append(run_id.clone(), "run.started");
        RunHandle::new(run_id, Some(0))
    }

    pub fn release_run(&self, run_id: &str) -> Result<(), ExecutionStartError> {
        let generation = self
            .owned_generations
            .lock()
            .map_err(|_| lifecycle_poisoned())?
            .get(run_id)
            .copied();
        let Some(generation) = generation else {
            return Ok(());
        };
        self.state_store
            .with_mut(|store| {
                store.begin_release(generation, run_id, &self.host_process_epoch)?;
                store.complete_release(generation, &self.host_process_epoch)
            })
            .map_err(lease_error)?;
        self.owned_generations
            .lock()
            .map_err(|_| lifecycle_poisoned())?
            .remove(run_id);
        Ok(())
    }

    pub fn release_if_terminal(
        &self,
        run_id: &str,
        event_code: &str,
    ) -> Result<bool, ExecutionStartError> {
        if !matches!(event_code, "run.completed" | "run.failed" | "run.cancelled") {
            return Ok(false);
        }
        self.release_run(run_id)?;
        Ok(true)
    }
}

fn lease_error(error: crate::llm_contracts::GlobalRunLeaseError) -> ExecutionStartError {
    ExecutionStartError::new(error.code(), error.to_string())
}

fn lifecycle_poisoned() -> ExecutionStartError {
    ExecutionStartError::new(
        "execution.global_run_lease_registry_poisoned",
        "global run lease ownership registry is poisoned",
    )
}

fn default_host_process_epoch() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static NEXT_EPOCH: AtomicU64 = AtomicU64::new(1);
    format!(
        "process-{}-{}",
        std::process::id(),
        NEXT_EPOCH.fetch_add(1, Ordering::Relaxed)
    )
}

impl RunHandle {
    pub fn new(run_id: impl Into<String>, replay_from_sequence: Option<u64>) -> Self {
        Self {
            run_id: run_id.into(),
            replay_from_sequence,
        }
    }

    pub fn run_id(&self) -> &str {
        &self.run_id
    }

    pub fn replay_from_sequence(&self) -> Option<u64> {
        self.replay_from_sequence
    }
}

impl StartExecutionRequest {
    pub fn new(
        run_id: impl Into<String>,
        agent_profile_id: impl Into<String>,
        profile_revision_id: AgentProfileVersion,
        user_intent: impl Into<String>,
        conversation_run_frame_ref: ConversationRunFrameRef,
    ) -> Self {
        Self {
            run_id: run_id.into(),
            agent_profile_id: agent_profile_id.into(),
            profile_revision_id,
            user_intent: user_intent.into(),
            conversation_run_frame_ref,
        }
    }

    pub fn run_id(&self) -> &str {
        &self.run_id
    }

    pub fn agent_profile_id(&self) -> &str {
        &self.agent_profile_id
    }

    pub fn profile_revision_id(&self) -> AgentProfileVersion {
        self.profile_revision_id
    }

    pub fn user_intent(&self) -> &str {
        &self.user_intent
    }

    pub fn conversation_run_frame_ref(&self) -> &ConversationRunFrameRef {
        &self.conversation_run_frame_ref
    }
}

impl ExecutionStartError {
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }

    pub fn code(&self) -> &str {
        &self.code
    }
}

impl fmt::Display for ExecutionStartError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for ExecutionStartError {}
