#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PromptLayers {
    pub system: String,
    pub policy: String,
    pub memory: Vec<String>,
}

impl PromptLayers {
    pub fn render_system_prompt(&self) -> String {
        let mut rendered = self.system.clone();
        if !self.memory.is_empty() {
            rendered.push_str("\n\nMemory:\n");
            rendered.push_str(&self.memory.join("\n"));
        }
        rendered
    }
}
