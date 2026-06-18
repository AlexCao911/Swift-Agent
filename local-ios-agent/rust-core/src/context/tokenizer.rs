use crate::context::PromptFrame;

pub trait TokenizerAdapter: Send + Sync {
    fn provider_id(&self) -> &str;
    fn max_context_tokens(&self) -> usize;
    fn safety_margin_tokens(&self) -> usize;
    fn count_text(&self, text: &str) -> usize;
    fn count_prompt_frame(&self, frame: &PromptFrame) -> usize;
    fn boxed_clone(&self) -> Box<dyn TokenizerAdapter>;
}

#[derive(Clone, Debug)]
pub struct MockTokenizer {
    max_context_tokens: usize,
}

impl MockTokenizer {
    pub fn new(max_context_tokens: usize) -> Self {
        Self { max_context_tokens }
    }
}

impl TokenizerAdapter for MockTokenizer {
    fn provider_id(&self) -> &str {
        "mock"
    }

    fn max_context_tokens(&self) -> usize {
        self.max_context_tokens
    }

    fn safety_margin_tokens(&self) -> usize {
        8
    }

    fn count_text(&self, text: &str) -> usize {
        text.split_whitespace().count()
    }

    fn count_prompt_frame(&self, frame: &PromptFrame) -> usize {
        let mut count = self.count_text(&frame.system_prompt);
        count += self.count_text(&frame.runtime_policy);
        count += frame
            .tool_schemas
            .iter()
            .map(|tool| self.count_text(tool))
            .sum::<usize>();
        count += frame
            .messages
            .iter()
            .map(|message| self.count_text(message.content()))
            .sum::<usize>();
        count
    }

    fn boxed_clone(&self) -> Box<dyn TokenizerAdapter> {
        Box::new(self.clone())
    }
}
