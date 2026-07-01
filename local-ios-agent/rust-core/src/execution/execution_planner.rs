use std::fmt;

use crate::execution::{ExecutionBudgets, ExecutionPlan, ExecutionStep, TraceConfig};
use crate::run_snapshot::ResolvedRunSnapshot;

pub type ExecutionPlanningResult<T> = Result<T, ExecutionPlanningError>;

#[derive(Clone, Debug, Default)]
pub struct ExecutionPlanner;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ExecutionPlanningError {
    code: String,
    message: String,
}

impl ExecutionPlanner {
    pub fn plan(&self, snapshot: ResolvedRunSnapshot) -> ExecutionPlanningResult<ExecutionPlan> {
        if !snapshot.readiness_report().is_ready() {
            return Err(ExecutionPlanningError::new(
                "execution.snapshot_not_ready",
                "execution planner requires a ready resolved run snapshot",
            ));
        }

        Ok(ExecutionPlan::new(
            snapshot.snapshot_id(),
            vec![
                ExecutionStep::new("context.assemble"),
                ExecutionStep::new("inference.generate"),
            ],
            ExecutionBudgets::default_chat(),
            TraceConfig::capture_archives(),
        ))
    }
}

impl ExecutionPlanningError {
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

impl fmt::Display for ExecutionPlanningError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for ExecutionPlanningError {}
