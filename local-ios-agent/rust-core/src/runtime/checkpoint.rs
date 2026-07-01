#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CheckpointRecord {
    checkpoint_id: String,
    can_resume: bool,
}

impl CheckpointRecord {
    pub fn new(checkpoint_id: impl Into<String>, can_resume: bool) -> Self {
        Self {
            checkpoint_id: checkpoint_id.into(),
            can_resume,
        }
    }

    pub fn checkpoint_id(&self) -> &str {
        &self.checkpoint_id
    }

    pub fn can_resume(&self) -> bool {
        self.can_resume
    }
}
