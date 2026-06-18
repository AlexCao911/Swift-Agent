#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BlobRecord {
    pub id: String,
    pub path: String,
    pub mime_type: String,
    pub byte_count: u64,
}
