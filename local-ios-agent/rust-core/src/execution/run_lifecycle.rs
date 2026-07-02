use crate::execution::ExecutionEventLog;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RunHandle {
    run_id: String,
    replay_from_sequence: Option<u64>,
}

#[derive(Clone, Debug)]
pub struct RunLifecycleService {
    event_log: ExecutionEventLog,
}

impl RunLifecycleService {
    pub fn new(event_log: ExecutionEventLog) -> Self {
        Self { event_log }
    }

    pub fn start_run(&self, run_id: impl Into<String>) -> RunHandle {
        let run_id = run_id.into();
        self.event_log.append(run_id.clone(), "run.started");
        RunHandle::new(run_id, Some(0))
    }
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
