#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ApprovalProtocolRequest {
    pub approval_id: String,
    pub message: String,
    pub requires_local_authentication: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ApprovalProtocolResponse {
    pub approval_id: String,
    pub approved: bool,
    pub reason: Option<String>,
}
