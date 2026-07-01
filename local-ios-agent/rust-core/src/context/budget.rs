use crate::context::PromptMessage;

pub struct ContextBudget<'a> {
    max_message_tokens: usize,
    tokenizer_source: String,
    count_text: Box<dyn Fn(&str) -> usize + 'a>,
}

impl ContextBudget<'static> {
    pub fn new(max_message_tokens: usize) -> Self {
        Self::with_token_counter_named(max_message_tokens, "context_budget.whitespace", |text| {
            text.split_whitespace().count()
        })
    }

    pub fn tokens(max_message_tokens: usize) -> Self {
        Self::new(max_message_tokens)
    }
}

impl<'a> ContextBudget<'a> {
    pub fn with_token_counter(
        max_message_tokens: usize,
        count_text: impl Fn(&str) -> usize + 'a,
    ) -> Self {
        Self::with_token_counter_named(max_message_tokens, "context_budget.custom", count_text)
    }

    pub fn with_token_counter_named(
        max_message_tokens: usize,
        tokenizer_source: impl Into<String>,
        count_text: impl Fn(&str) -> usize + 'a,
    ) -> Self {
        Self {
            max_message_tokens,
            tokenizer_source: tokenizer_source.into(),
            count_text: Box::new(count_text),
        }
    }

    pub fn fit_messages(&self, messages: Vec<PromptMessage>) -> Vec<PromptMessage> {
        let mut kept = Vec::new();
        let mut total = 0;
        for message in messages.into_iter().rev() {
            let count = self.count_text(message.content());
            if total + count > self.max_message_tokens {
                break;
            }
            total += count;
            kept.push(message);
        }
        kept.reverse();
        kept
    }

    pub fn max_tokens(&self) -> usize {
        self.max_message_tokens
    }

    pub fn count_text(&self, text: &str) -> usize {
        (self.count_text)(text)
    }

    pub fn tokenizer_source(&self) -> &str {
        &self.tokenizer_source
    }
}
