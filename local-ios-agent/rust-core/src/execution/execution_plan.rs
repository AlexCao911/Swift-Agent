use crate::execution::{ExecutionBudgets, TraceConfig};
use crate::run_snapshot::RunSnapshotId;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ExecutionPlan {
    snapshot_id: RunSnapshotId,
    steps: Vec<ExecutionStep>,
    budgets: ExecutionBudgets,
    trace_config: TraceConfig,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ExecutionStep {
    kind: ExecutionStepKind,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ExecutionStepKind(String);

impl ExecutionPlan {
    pub(crate) fn new(
        snapshot_id: RunSnapshotId,
        steps: Vec<ExecutionStep>,
        budgets: ExecutionBudgets,
        trace_config: TraceConfig,
    ) -> Self {
        Self {
            snapshot_id,
            steps,
            budgets,
            trace_config,
        }
    }

    pub fn for_snapshot(snapshot_id: RunSnapshotId) -> Self {
        Self::new(
            snapshot_id,
            vec![
                ExecutionStep::new("context.assemble"),
                ExecutionStep::new("inference.generate"),
            ],
            ExecutionBudgets::default_chat(),
            TraceConfig::capture_archives(),
        )
    }

    pub fn with_steps(mut self, steps: Vec<ExecutionStep>) -> Self {
        self.steps = steps;
        self
    }

    pub fn without_archive_capture(mut self) -> Self {
        self.trace_config = TraceConfig::disabled();
        self
    }

    pub fn with_budgets(mut self, budgets: ExecutionBudgets) -> Self {
        self.budgets = budgets;
        self
    }

    pub fn snapshot_id(&self) -> RunSnapshotId {
        self.snapshot_id
    }

    pub fn steps(&self) -> &[ExecutionStep] {
        &self.steps
    }

    pub fn budgets(&self) -> &ExecutionBudgets {
        &self.budgets
    }

    pub fn trace_config(&self) -> &TraceConfig {
        &self.trace_config
    }
}

impl ExecutionStep {
    pub fn new(kind: impl Into<String>) -> Self {
        Self {
            kind: ExecutionStepKind(kind.into()),
        }
    }

    pub fn kind(&self) -> &ExecutionStepKind {
        &self.kind
    }
}

impl ExecutionStepKind {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}
