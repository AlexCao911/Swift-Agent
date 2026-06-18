use crate::context::PromptMessage;

pub struct ContextBudget<'a> {
    max_message_tokens: usize,
    count_text: Box<dyn Fn(&str) -> usize + 'a>,
}

impl ContextBudget<'static> {
    pub fn new(max_message_tokens: usize) -> Self {
        Self::with_token_counter(max_message_tokens, |text| text.split_whitespace().count())
    }
}

impl<'a> ContextBudget<'a> {
    pub fn with_token_counter(
        max_message_tokens: usize,
        count_text: impl Fn(&str) -> usize + 'a,
    ) -> Self {
        Self {
            max_message_tokens,
            count_text: Box::new(count_text),
        }
    }

    pub fn fit_messages(&self, messages: Vec<PromptMessage>) -> Vec<PromptMessage> {
        let mut kept = Vec::new();
        let mut total = 0;
        for message in messages.into_iter().rev() {
            let count = (self.count_text)(message.content());
            if total + count > self.max_message_tokens {
                break;
            }
            total += count;
            kept.push(message);
        }
        kept.reverse();
        kept
    }
}
