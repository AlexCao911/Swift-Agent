#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ExecutionBudgets {
    max_model_input_tokens: usize,
}

impl ExecutionBudgets {
    pub fn new(max_model_input_tokens: usize) -> Self {
        Self {
            max_model_input_tokens,
        }
    }

    pub fn default_chat() -> Self {
        Self {
            max_model_input_tokens: 4096,
        }
    }

    pub fn max_model_input_tokens(&self) -> usize {
        self.max_model_input_tokens
    }
}
