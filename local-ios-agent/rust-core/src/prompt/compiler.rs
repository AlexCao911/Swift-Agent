use std::collections::BTreeMap;

use serde::Serialize;

use crate::prompt::{
    archive::{redact_compiled_prompt, redacted_variable_value},
    PromptDocumentVersionId, PromptError, PromptStack,
};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CompiledPrompt {
    pub text: String,
    pub source_map: PromptSourceMap,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PromptPreview {
    pub redacted_text: String,
    pub source_map: PromptSourceMap,
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize)]
pub struct PromptSourceMap {
    pub entries: Vec<PromptSourceMapEntry>,
    pub variables: Vec<PromptVariableSourceMapEntry>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct PromptSourceMapEntry {
    pub slot: String,
    pub document_id: String,
    pub version_id: PromptDocumentVersionId,
    pub start: usize,
    pub end: usize,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct PromptVariableSourceMapEntry {
    pub name: String,
    pub provenance: String,
    pub redacted_value: String,
    pub spans: Vec<PromptVariableSpan>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct PromptVariableSpan {
    pub start: usize,
    pub end: usize,
}

#[derive(Clone, Debug, Default)]
pub struct PromptCompiler;

impl PromptCompiler {
    pub fn compile(&self, stack: PromptStack) -> Result<CompiledPrompt, PromptError> {
        let mut entries = stack.entries().to_vec();
        entries.sort_by(|left, right| {
            slot_rank(&left.slot)
                .cmp(&slot_rank(&right.slot))
                .then_with(|| left.slot.cmp(&right.slot))
                .then_with(|| left.document_id.cmp(&right.document_id))
                .then_with(|| left.version_id.as_u64().cmp(&right.version_id.as_u64()))
        });

        let mut text = String::new();
        let mut source_entries = Vec::with_capacity(entries.len());
        let mut variable_spans: BTreeMap<String, Vec<PromptVariableSpan>> = BTreeMap::new();
        for entry in entries {
            if !text.is_empty() {
                text.push_str("\n\n");
            }
            let start = text.len();
            let bound = bind_variables(&entry.body, stack.variables(), start, &mut variable_spans);
            text.push_str(&bound);
            let end = text.len();
            source_entries.push(PromptSourceMapEntry {
                slot: entry.slot,
                document_id: entry.document_id,
                version_id: entry.version_id,
                start,
                end,
            });
        }

        Ok(CompiledPrompt {
            text,
            source_map: PromptSourceMap {
                entries: source_entries,
                variables: stack
                    .variables()
                    .iter()
                    .map(|variable| PromptVariableSourceMapEntry {
                        name: variable.name.clone(),
                        provenance: variable.provenance.clone(),
                        redacted_value: "[redacted]".to_string(),
                        spans: variable_spans
                            .remove(&variable.name)
                            .unwrap_or_else(Vec::new),
                    })
                    .collect(),
            },
        })
    }

    pub fn preview(&self, stack: PromptStack) -> Result<PromptPreview, PromptError> {
        let compiled = self.compile(stack)?;
        Ok(PromptPreview {
            redacted_text: redact_compiled_prompt(&compiled)?,
            source_map: compiled.source_map,
        })
    }
}

fn bind_variables(
    body: &str,
    variables: &[crate::prompt::PromptVariableBinding],
    absolute_output_offset: usize,
    variable_spans: &mut BTreeMap<String, Vec<PromptVariableSpan>>,
) -> String {
    let mut bound = String::new();
    let mut cursor = 0;

    while let Some(open_offset) = body[cursor..].find("{{") {
        let open = cursor + open_offset;
        let name_start = open + 2;
        let Some(close_offset) = body[name_start..].find("}}") else {
            break;
        };
        let close = name_start + close_offset;
        let name = body[name_start..close].trim();

        bound.push_str(&body[cursor..open]);
        if let Some(variable) = variables.iter().find(|variable| variable.name == name) {
            let start = absolute_output_offset + bound.len();
            bound.push_str(&redacted_variable_value(
                &variable.name,
                &variable.provenance,
                &variable.value,
            ));
            let end = absolute_output_offset + bound.len();
            variable_spans
                .entry(variable.name.clone())
                .or_default()
                .push(PromptVariableSpan { start, end });
        } else {
            bound.push_str(&body[open..close + 2]);
        }

        cursor = close + 2;
    }

    bound.push_str(&body[cursor..]);
    bound
}

fn slot_rank(slot: &str) -> usize {
    match slot {
        "identity" => 0,
        "persona" => 1,
        "constitution" => 2,
        "instructions" => 3,
        _ => 4,
    }
}
