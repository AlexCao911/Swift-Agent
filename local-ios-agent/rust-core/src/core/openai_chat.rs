use serde_json::{json, Value};

use crate::context::{PromptFrame, PromptMessage};
use crate::core::{AgentError, ModelProviderOutput};

pub fn build_openai_chat_request(model: &str, frame: &PromptFrame) -> Value {
    let mut messages = Vec::with_capacity(frame.messages.len() + 1);
    messages.push(json!({
        "role": "system",
        "content": system_content(frame),
    }));

    for message in &frame.messages {
        messages.push(match message {
            PromptMessage::User(content) => json!({
                "role": "user",
                "content": content,
            }),
            PromptMessage::UserWithBlobRefs { content, .. } => json!({
                "role": "user",
                "content": content,
            }),
            PromptMessage::Assistant(content) | PromptMessage::Summary(content) => json!({
                "role": "assistant",
                "content": content,
            }),
            PromptMessage::ToolResult(content) => json!({
                "role": "user",
                "content": format!("Tool result:\n{content}"),
            }),
        });
    }

    json!({
        "model": model,
        "stream": false,
        "messages": messages,
    })
}

pub fn parse_openai_chat_response(
    response_json: &str,
) -> Result<Vec<ModelProviderOutput>, AgentError> {
    let value: Value = serde_json::from_str(response_json)
        .map_err(|error| AgentError::Provider(format!("invalid OpenAI chat response: {error}")))?;
    let content = value
        .get("choices")
        .and_then(Value::as_array)
        .and_then(|choices| choices.first())
        .and_then(|choice| choice.get("message"))
        .and_then(|message| message.get("content"))
        .and_then(Value::as_str)
        .ok_or_else(|| AgentError::Provider("missing assistant content".into()))?;

    Ok(vec![ModelProviderOutput::Completed(content.to_string())])
}

fn system_content(frame: &PromptFrame) -> String {
    let mut sections = vec![frame.system_prompt.clone(), frame.runtime_policy.clone()];
    if !frame.tool_schemas.is_empty() {
        sections.push(format!(
            "Available tools:\n{}",
            frame.tool_schemas.join("\n")
        ));
    }
    sections
        .into_iter()
        .filter(|section| !section.is_empty())
        .collect::<Vec<_>>()
        .join("\n")
}
