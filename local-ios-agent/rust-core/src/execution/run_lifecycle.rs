use std::fmt;

use crate::conversation::ConversationRunFrameRef;
use crate::execution::ExecutionEventLog;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StartExecutionRequest {
    run_id: String,
    agent_profile_id: String,
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

impl StartExecutionRequest {
    pub fn new(
        run_id: impl Into<String>,
        agent_profile_id: impl Into<String>,
        user_intent: impl Into<String>,
        conversation_run_frame_ref: ConversationRunFrameRef,
    ) -> Self {
        Self {
            run_id: run_id.into(),
            agent_profile_id: agent_profile_id.into(),
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
