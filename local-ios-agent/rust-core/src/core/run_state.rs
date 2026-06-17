use crate::core::{AgentError, RunId, SessionId};

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum RunState {
    Running,
    WaitingTool,
    Suspended,
    Failed,
    Cancelled,
    Completed,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RunRecord {
    pub run_id: RunId,
    pub session_id: SessionId,
    pub state: RunState,
}

impl RunRecord {
    pub fn new(run_id: RunId, session_id: SessionId) -> Self {
        Self {
            run_id,
            session_id,
            state: RunState::Running,
        }
    }

    pub fn mark_running(&mut self) -> Result<(), AgentError> {
        self.ensure_not_terminal()?;
        self.state = RunState::Running;
        Ok(())
    }

    pub fn mark_waiting_tool(&mut self) -> Result<(), AgentError> {
        self.ensure_not_terminal()?;
        self.state = RunState::WaitingTool;
        Ok(())
    }

    pub fn mark_suspended(&mut self) -> Result<(), AgentError> {
        self.ensure_not_terminal()?;
        self.state = RunState::Suspended;
        Ok(())
    }

    pub fn mark_failed(&mut self) -> Result<(), AgentError> {
        self.ensure_not_terminal()?;
        self.state = RunState::Failed;
        Ok(())
    }

    pub fn mark_completed(&mut self) -> Result<(), AgentError> {
        self.ensure_not_terminal()?;
        self.state = RunState::Completed;
        Ok(())
    }

    pub fn cancel(&mut self) -> Result<(), AgentError> {
        self.ensure_not_terminal()?;
        self.state = RunState::Cancelled;
        Ok(())
    }

    fn ensure_not_terminal(&self) -> Result<(), AgentError> {
        match self.state {
            RunState::Failed | RunState::Cancelled | RunState::Completed => Err(
                AgentError::Cancelled(format!("run already terminal: {:?}", self.state)),
            ),
            RunState::Running | RunState::WaitingTool | RunState::Suspended => Ok(()),
        }
    }
}
