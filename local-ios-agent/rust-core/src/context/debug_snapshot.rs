use crate::context::PromptFrame;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PromptDebugSnapshot {
    pub rendered_text: String,
}

impl PromptDebugSnapshot {
    pub fn from_frame(frame: &PromptFrame) -> Self {
        Self {
            rendered_text: format!(
                "{}\n{}\n{}\n{}",
                frame.system_prompt,
                frame.runtime_policy,
                frame.tool_schemas.join("\n"),
                frame
                    .messages
                    .iter()
                    .map(|message| message.content())
                    .collect::<Vec<_>>()
                    .join("\n")
            ),
        }
    }
}
