#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AuditRow {
    pub session_id: String,
    pub event_id: String,
    pub summary: String,
}
