#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ExecutionToolCall {
    pub call_id: String,
    pub name: String,
    pub arguments_json: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ExecutionToolObservation {
    pub call_id: String,
    pub model_text: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ExecutionToolOutcome {
    Observation(ExecutionToolObservation),
    PendingHostTool { call_id: String },
    ApprovalRequired { call_id: String, reason: String },
}
