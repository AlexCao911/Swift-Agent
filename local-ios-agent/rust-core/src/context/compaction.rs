use crate::context::PromptMessage;
use serde::{Deserialize, Serialize};

const OMITTED_TOOL_OUTPUT: &str = "[Earlier tool output omitted from active context]";

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ContextCompactionCheckpoint {
    pub summary: String,
    pub covered_through_sequence: u64,
    pub preserved_event_ids: Vec<String>,
}

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

    pub fn bounded_summary_text(&self, max_tokens: usize) -> String {
        truncate_middle(&self.summary_text(), max_tokens.saturating_mul(4))
    }
}

pub fn approximate_token_count(text: &str) -> usize {
    let (ascii, non_ascii) = text.chars().fold((0usize, 0usize), |counts, character| {
        if character.is_ascii() {
            (counts.0 + 1, counts.1)
        } else {
            (counts.0, counts.1 + 1)
        }
    });
    ascii.div_ceil(4).saturating_add(non_ascii)
}

pub fn compact_tool_results_for_context(
    mut messages: Vec<PromptMessage>,
    max_context_tokens: usize,
) -> Vec<PromptMessage> {
    let Some(latest_tool_index) = messages
        .iter()
        .rposition(|message| matches!(message, PromptMessage::ToolResult(_)))
    else {
        return messages;
    };

    let mut latest_block_start = latest_tool_index;
    while latest_block_start > 0
        && matches!(
            messages[latest_block_start - 1],
            PromptMessage::ToolResult(_)
        )
    {
        latest_block_start -= 1;
    }

    for message in &mut messages[..latest_block_start] {
        if matches!(message, PromptMessage::ToolResult(_)) {
            *message = PromptMessage::ToolResult(OMITTED_TOOL_OUTPUT.into());
        }
    }

    let non_latest_tokens = messages
        .iter()
        .enumerate()
        .filter(|(index, message)| {
            *index < latest_block_start || !matches!(message, PromptMessage::ToolResult(_))
        })
        .map(|(_, message)| approximate_token_count(message.content()))
        .sum::<usize>();
    let latest_count = latest_tool_index - latest_block_start + 1;
    let per_result_tokens = max_context_tokens
        .saturating_sub(non_latest_tokens)
        .checked_div(latest_count)
        .unwrap_or(0);
    let per_result_bytes = per_result_tokens.saturating_mul(4);

    for message in &mut messages[latest_block_start..=latest_tool_index] {
        if let PromptMessage::ToolResult(content) = message {
            *content = truncate_middle(content, per_result_bytes);
        }
    }

    messages
}

fn truncate_middle(text: &str, max_bytes: usize) -> String {
    if text.len() <= max_bytes {
        return text.to_string();
    }
    const MARKER: &str = "\n… tool output truncated …\n";
    if max_bytes <= MARKER.len() {
        return MARKER[..max_bytes.min(MARKER.len())].to_string();
    }
    let available = max_bytes - MARKER.len();
    let head_end = nearest_char_boundary(text, available.div_ceil(2));
    let tail_start = nearest_char_boundary(text, text.len().saturating_sub(available / 2));
    format!("{}{}{}", &text[..head_end], MARKER, &text[tail_start..])
}

fn nearest_char_boundary(text: &str, mut index: usize) -> usize {
    index = index.min(text.len());
    while index > 0 && !text.is_char_boundary(index) {
        index -= 1;
    }
    index
}
