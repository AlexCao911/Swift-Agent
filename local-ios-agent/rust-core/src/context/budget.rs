use crate::context::PromptMessage;

pub struct ContextBudget {
    max_message_words: usize,
}

impl ContextBudget {
    pub fn new(max_message_words: usize) -> Self {
        Self { max_message_words }
    }

    pub fn fit_messages(&self, messages: Vec<PromptMessage>) -> Vec<PromptMessage> {
        let mut kept = Vec::new();
        let mut total = 0;
        for message in messages.into_iter().rev() {
            let count = message.content().split_whitespace().count();
            if total + count > self.max_message_words {
                break;
            }
            total += count;
            kept.push(message);
        }
        kept.reverse();
        kept
    }
}
