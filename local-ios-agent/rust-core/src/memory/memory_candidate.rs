#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MemoryCandidate {
    pub text: String,
    pub confirmed: bool,
}

impl MemoryCandidate {
    pub fn new(text: impl Into<String>) -> Self {
        Self {
            text: text.into(),
            confirmed: false,
        }
    }

    pub fn confirm(mut self) -> Self {
        self.confirmed = true;
        self
    }
}
