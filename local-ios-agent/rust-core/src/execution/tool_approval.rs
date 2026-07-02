#[derive(Clone, Debug, Default)]
pub struct ToolApprovalService;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ApprovalDecision {
    approved: bool,
    reason: Option<String>,
}

impl ToolApprovalService {
    pub fn approve_tool(
        &self,
        _id: impl Into<String>,
        _decision: ApprovalDecision,
    ) -> Result<(), String> {
        Ok(())
    }
}

impl ApprovalDecision {
    pub fn new(approved: bool, reason: Option<String>) -> Self {
        Self { approved, reason }
    }

    pub fn approved(&self) -> bool {
        self.approved
    }

    pub fn reason(&self) -> Option<&str> {
        self.reason.as_deref()
    }
}
