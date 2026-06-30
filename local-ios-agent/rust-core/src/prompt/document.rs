use std::fmt;

use serde::Serialize;

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Serialize)]
pub struct PromptDocumentVersionId(u64);

impl PromptDocumentVersionId {
    pub(crate) fn new_for_fixture(value: u64) -> Self {
        Self(value)
    }

    pub fn as_u64(&self) -> u64 {
        self.0
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PromptDocumentVersion {
    pub id: PromptDocumentVersionId,
    pub document_id: String,
    pub body: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PromptDocument {
    id: String,
    draft: String,
    versions: Vec<PromptDocumentVersion>,
    next_version: u64,
}

impl PromptDocument {
    pub fn new(id: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            draft: String::new(),
            versions: Vec::new(),
            next_version: 1,
        }
    }

    pub fn update_draft(&mut self, body: impl Into<String>) -> Result<(), PromptError> {
        self.draft = body.into();
        Ok(())
    }

    pub fn publish(
        &mut self,
        body: impl Into<String>,
    ) -> Result<PromptDocumentVersionId, PromptError> {
        let id = PromptDocumentVersionId(self.next_version);
        self.next_version += 1;
        self.versions.push(PromptDocumentVersion {
            id,
            document_id: self.id.clone(),
            body: body.into(),
        });
        Ok(id)
    }

    pub fn version(&self, id: PromptDocumentVersionId) -> Option<&PromptDocumentVersion> {
        self.versions.iter().find(|version| version.id == id)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PromptError {
    message: String,
}

impl PromptError {
    pub fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }
}

impl fmt::Display for PromptError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}", self.message)
    }
}

impl std::error::Error for PromptError {}
