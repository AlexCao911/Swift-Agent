use std::collections::BTreeMap;

use crate::context::SegmentSource;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ContextPolicy {
    global_budget_tokens: Option<usize>,
    source_budget_tokens: BTreeMap<SegmentSource, usize>,
    exclude_secret_segments: bool,
}

impl ContextPolicy {
    pub fn new() -> Self {
        Self {
            global_budget_tokens: None,
            source_budget_tokens: BTreeMap::new(),
            exclude_secret_segments: true,
        }
    }

    pub fn with_global_budget(mut self, tokens: usize) -> Self {
        self.global_budget_tokens = Some(tokens);
        self
    }

    pub fn with_source_budget(mut self, source: SegmentSource, tokens: usize) -> Self {
        self.source_budget_tokens.insert(source, tokens);
        self
    }

    pub fn global_budget_tokens(&self) -> Option<usize> {
        self.global_budget_tokens
    }

    pub fn source_budget_tokens(&self, source: SegmentSource) -> Option<usize> {
        self.source_budget_tokens.get(&source).copied()
    }

    pub fn excludes_secret_segments(&self) -> bool {
        self.exclude_secret_segments
    }
}

impl Default for ContextPolicy {
    fn default() -> Self {
        Self::new()
    }
}
