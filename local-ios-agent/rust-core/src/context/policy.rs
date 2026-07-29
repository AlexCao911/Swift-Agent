use std::collections::BTreeMap;
use std::fmt;

use crate::context::SegmentSource;

const DEFAULT_AUTO_COMPACT_RATIO_PERCENT: usize = 70;

#[derive(Clone, Copy, Debug, Eq, PartialEq, serde::Deserialize, serde::Serialize)]
pub struct ModelContextWindow {
    pub context_window_tokens: usize,
    pub max_output_tokens: usize,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ContextWindowPolicy {
    model: ModelContextWindow,
    auto_compact_ratio_percent: usize,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ContextWindowPolicyError(&'static str);

impl ContextWindowPolicy {
    pub fn for_model(model: ModelContextWindow) -> Result<Self, ContextWindowPolicyError> {
        if model.context_window_tokens == 0
            || model.max_output_tokens >= model.context_window_tokens
        {
            return Err(ContextWindowPolicyError(
                "model context window must exceed its output reservation",
            ));
        }
        Ok(Self {
            model,
            auto_compact_ratio_percent: DEFAULT_AUTO_COMPACT_RATIO_PERCENT,
        })
    }

    pub fn with_auto_compact_ratio_percent(
        mut self,
        percent: usize,
    ) -> Result<Self, ContextWindowPolicyError> {
        if !(1..=100).contains(&percent) {
            return Err(ContextWindowPolicyError(
                "auto compaction ratio must be between 1 and 100",
            ));
        }
        self.auto_compact_ratio_percent = percent;
        Ok(self)
    }

    pub fn auto_compact_threshold_tokens(&self) -> usize {
        (self.model.context_window_tokens / 100)
            .saturating_mul(self.auto_compact_ratio_percent)
            .min(self.model_input_limit_tokens())
    }

    pub fn model_input_limit_tokens(&self) -> usize {
        self.model
            .context_window_tokens
            .saturating_sub(self.model.max_output_tokens)
    }
}

impl fmt::Display for ContextWindowPolicyError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.0)
    }
}

impl std::error::Error for ContextWindowPolicyError {}

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
