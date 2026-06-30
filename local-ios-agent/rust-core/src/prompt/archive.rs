use std::time::{SystemTime, UNIX_EPOCH};

use serde::Serialize;

use crate::prompt::{CompiledPrompt, PromptError, PromptSourceMap};
use crate::storage::ArchiveRecord;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CompiledPromptArchive {
    pub run_id: String,
    pub compiled_text: String,
    pub redacted_text: String,
    pub source_map: PromptSourceMap,
    pub created_at_millis: u64,
}

impl CompiledPromptArchive {
    pub fn from_compiled(
        run_id: impl Into<String>,
        compiled: CompiledPrompt,
    ) -> Result<Self, PromptError> {
        let redacted_text = redact_compiled_prompt(&compiled)?;
        Ok(Self {
            run_id: run_id.into(),
            compiled_text: redacted_text.clone(),
            redacted_text,
            source_map: compiled.source_map,
            created_at_millis: now_millis(),
        })
    }

    pub fn to_archive_record(&self) -> ArchiveRecord {
        let payload = serde_json::to_string(&PromptArchivePayload {
            redacted_text: &self.redacted_text,
            source_map: &self.source_map,
            created_at_millis: self.created_at_millis,
        })
        .expect("prompt archive payload serializes");
        ArchiveRecord::with_payload(self.run_id.clone(), "prompt_archive", payload)
    }
}

#[derive(Serialize)]
struct PromptArchivePayload<'a> {
    redacted_text: &'a str,
    source_map: &'a PromptSourceMap,
    created_at_millis: u64,
}

pub(crate) fn redact_compiled_prompt(compiled: &CompiledPrompt) -> Result<String, PromptError> {
    let mut redacted = compiled.text.as_bytes().to_vec();

    for variable in &compiled.source_map.variables {
        if is_sensitive_variable(&variable.name, &variable.provenance) {
            for span in &variable.spans {
                mask_range(&mut redacted, &compiled.text, span.start, span.end)?;
            }
        }
    }

    for (start, end) in secret_like_token_ranges(&compiled.text) {
        mask_range(&mut redacted, &compiled.text, start, end)?;
    }

    String::from_utf8(redacted)
        .map_err(|_| PromptError::new("invalid prompt variable span produced invalid utf-8"))
}

fn secret_like_token_ranges(text: &str) -> Vec<(usize, usize)> {
    let mut ranges = Vec::new();
    let mut token_start = None;

    for (index, character) in text.char_indices() {
        if character.is_whitespace() {
            if let Some(start) = token_start.take() {
                push_secret_like_token_range(text, start, index, &mut ranges);
            }
        } else if token_start.is_none() {
            token_start = Some(index);
        }
    }

    if let Some(start) = token_start {
        push_secret_like_token_range(text, start, text.len(), &mut ranges);
    }

    ranges
}

fn push_secret_like_token_range(
    text: &str,
    start: usize,
    end: usize,
    ranges: &mut Vec<(usize, usize)>,
) {
    if is_secret_like(&text[start..end]) {
        ranges.push((start, end));
    }
}

pub(crate) fn redacted_variable_value(name: &str, provenance: &str, value: &str) -> String {
    if is_sensitive_variable(name, provenance) || is_secret_like(value) {
        mask_value(value)
    } else {
        value.to_string()
    }
}

fn mask_value(value: &str) -> String {
    "*".repeat(value.len())
}

fn mask_range(bytes: &mut [u8], text: &str, start: usize, end: usize) -> Result<(), PromptError> {
    if start > end
        || end > bytes.len()
        || !text.is_char_boundary(start)
        || !text.is_char_boundary(end)
    {
        return Err(PromptError::new("invalid prompt variable span"));
    }

    for byte in &mut bytes[start..end] {
        *byte = b'*';
    }
    Ok(())
}

pub(crate) fn is_secret_like(value: &str) -> bool {
    let trimmed = value.trim_matches(|character: char| {
        character == '.' || character == ',' || character == ';' || character == ':'
    });
    trimmed.starts_with("sk-")
        || trimmed.contains("api_key")
        || trimmed.contains("secret")
        || trimmed.contains("token")
}

pub(crate) fn is_sensitive_variable(name: &str, provenance: &str) -> bool {
    let name = name.to_ascii_lowercase();
    let provenance = provenance.to_ascii_lowercase();
    [
        "api_key",
        "secret",
        "token",
        "password",
        "credential",
        "bearer",
    ]
    .iter()
    .any(|needle| name.contains(needle) || provenance.contains(needle))
}

fn now_millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as u64)
        .unwrap_or(0)
}
