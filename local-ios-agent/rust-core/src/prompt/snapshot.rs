use crate::agent_input::PromptDocumentSnapshot;
use crate::prompt::{
    CompiledPrompt, PromptDocumentVersionId, PromptSourceMap, PromptSourceMapEntry,
};

pub fn compile_prompt_documents(documents: &[PromptDocumentSnapshot]) -> CompiledPrompt {
    let mut text = String::new();
    let mut entries = Vec::with_capacity(documents.len());

    for (index, document) in documents.iter().enumerate() {
        if !text.is_empty() {
            text.push_str("\n\n");
        }
        let start = text.len();
        text.push_str(&document.markdown);
        entries.push(PromptSourceMapEntry {
            slot: document.source.clone(),
            document_id: document.id.clone(),
            version_id: PromptDocumentVersionId::new_for_fixture((index + 1) as u64),
            start,
            end: text.len(),
        });
    }

    CompiledPrompt {
        text,
        source_map: PromptSourceMap {
            entries,
            variables: Vec::new(),
        },
    }
}
