#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CompactionCandidate {
    messages: Vec<String>,
}

impl CompactionCandidate {
    pub fn new(messages: Vec<String>) -> Self {
        Self { messages }
    }

    pub fn summary_text(&self) -> String {
        self.messages.join("\n")
    }
}
