#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LongTermMemoryRecord {
    pub id: String,
    pub text: String,
    pub keywords: Vec<String>,
    pub confirmed: bool,
}
