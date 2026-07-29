use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use super::AgentLoopError;

#[derive(Clone, Debug, Default)]
pub struct CancellationToken {
    cancelled: Arc<AtomicBool>,
}

#[derive(Debug)]
pub struct RunCancellationRecord {
    pub run_id: String,
    pub token: CancellationToken,
    gate: Mutex<RunCancellationGate>,
}

#[derive(Debug, Default)]
struct RunCancellationGate {
    active_batch_id: Option<String>,
}

impl CancellationToken {
    pub fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::Acquire)
    }

    fn cancel(&self) {
        self.cancelled.store(true, Ordering::Release);
    }
}

impl RunCancellationRecord {
    pub fn new(run_id: impl Into<String>) -> Self {
        Self {
            run_id: run_id.into(),
            token: CancellationToken::default(),
            gate: Mutex::new(RunCancellationGate::default()),
        }
    }

    pub fn check(&self) -> Result<(), AgentLoopError> {
        if self.token.is_cancelled() {
            Err(AgentLoopError::cancelled())
        } else {
            Ok(())
        }
    }

    pub fn request_cancel(&self) -> Option<String> {
        let gate = self
            .gate
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        self.token.cancel();
        gate.active_batch_id.clone()
    }

    pub fn begin_batch(&self, batch_id: &str) -> Result<(), AgentLoopError> {
        let mut gate = self
            .gate
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if self.token.is_cancelled() {
            return Err(AgentLoopError::cancelled());
        }
        gate.active_batch_id = Some(batch_id.to_string());
        Ok(())
    }

    pub fn finish_batch(&self, batch_id: &str) {
        let mut gate = self
            .gate
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if gate.active_batch_id.as_deref() == Some(batch_id) {
            gate.active_batch_id = None;
        }
    }

    pub fn commit_if_active<T>(
        &self,
        commit: impl FnOnce() -> Result<T, AgentLoopError>,
    ) -> Result<T, AgentLoopError> {
        let _gate = self
            .gate
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        self.check()?;
        commit()
    }
}
