use crate::prompt::PromptDocumentVersionId;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PromptStackEntry {
    pub slot: String,
    pub document_id: String,
    pub version_id: PromptDocumentVersionId,
    pub body: String,
}

impl PromptStackEntry {
    pub fn new(
        slot: impl Into<String>,
        document_id: impl Into<String>,
        version_id: PromptDocumentVersionId,
        body: impl Into<String>,
    ) -> Self {
        Self {
            slot: slot.into(),
            document_id: document_id.into(),
            version_id,
            body: body.into(),
        }
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct PromptStack {
    entries: Vec<PromptStackEntry>,
    variables: Vec<PromptVariableBinding>,
}

impl PromptStack {
    pub fn new(entries: Vec<PromptStackEntry>) -> Self {
        Self {
            entries,
            variables: Vec::new(),
        }
    }

    pub fn fixture_identity_persona() -> Self {
        Self::new(vec![
            PromptStackEntry::new(
                "identity",
                "identity",
                PromptDocumentVersionId::new_for_fixture(1),
                "You are concise.",
            ),
            PromptStackEntry::new(
                "persona",
                "persona",
                PromptDocumentVersionId::new_for_fixture(1),
                "You are calm.",
            ),
        ])
    }

    pub fn fixture_with_variable(name: &str, value: &str) -> Self {
        Self::new(vec![PromptStackEntry::new(
            "identity",
            "identity",
            PromptDocumentVersionId::new_for_fixture(1),
            format!("Use {{{{{name}}}}}."),
        )])
        .with_variable(PromptVariableBinding::new(
            name,
            value,
            "fixture.prompt.variable",
        ))
    }

    pub fn with_variable(mut self, variable: PromptVariableBinding) -> Self {
        self.variables.push(variable);
        self
    }

    pub fn entries(&self) -> &[PromptStackEntry] {
        &self.entries
    }

    pub fn variables(&self) -> &[PromptVariableBinding] {
        &self.variables
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PromptVariableBinding {
    pub name: String,
    pub value: String,
    pub provenance: String,
}

impl PromptVariableBinding {
    pub fn new(
        name: impl Into<String>,
        value: impl Into<String>,
        provenance: impl Into<String>,
    ) -> Self {
        Self {
            name: name.into(),
            value: value.into(),
            provenance: provenance.into(),
        }
    }
}
