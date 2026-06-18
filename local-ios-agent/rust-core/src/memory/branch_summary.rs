#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BranchSummaryRecord {
    pub session_id: String,
    pub leaf_id: String,
    pub summary: String,
}
