#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct MemoryExtractionPolicy {
    source_event_kinds: Vec<String>,
    extract_kinds: Vec<String>,
    requires_review: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MemorySelectionPolicy {
    query_sources: Vec<String>,
    max_results: usize,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MemoryInjectionPolicy {
    segment_source: String,
    budget_tokens: Option<usize>,
    requires_reviewed_memories: bool,
}

impl MemoryExtractionPolicy {
    pub fn review_required() -> Self {
        Self {
            source_event_kinds: Vec::new(),
            extract_kinds: Vec::new(),
            requires_review: true,
        }
    }

    pub fn from_event_kind(mut self, event_kind: impl Into<String>) -> Self {
        self.source_event_kinds.push(event_kind.into());
        self
    }

    pub fn extract_kind(mut self, extract_kind: impl Into<String>) -> Self {
        self.extract_kinds.push(extract_kind.into());
        self
    }

    pub fn source_event_kinds(&self) -> &[String] {
        &self.source_event_kinds
    }

    pub fn extract_kinds(&self) -> &[String] {
        &self.extract_kinds
    }

    pub fn requires_review(&self) -> bool {
        self.requires_review
    }
}

impl MemorySelectionPolicy {
    pub fn new() -> Self {
        Self {
            query_sources: Vec::new(),
            max_results: 4,
        }
    }

    pub fn with_query_source(mut self, query_source: impl Into<String>) -> Self {
        self.query_sources.push(query_source.into());
        self
    }

    pub fn with_max_results(mut self, max_results: usize) -> Self {
        self.max_results = max_results;
        self
    }

    pub fn query_sources(&self) -> &[String] {
        &self.query_sources
    }

    pub fn max_results(&self) -> usize {
        self.max_results
    }
}

impl Default for MemorySelectionPolicy {
    fn default() -> Self {
        Self::new()
    }
}

impl MemoryInjectionPolicy {
    pub fn new() -> Self {
        Self {
            segment_source: "memory.selected".to_string(),
            budget_tokens: None,
            requires_reviewed_memories: false,
        }
    }

    pub fn as_segment_source(mut self, segment_source: impl Into<String>) -> Self {
        self.segment_source = segment_source.into();
        self
    }

    pub fn with_budget_tokens(mut self, budget_tokens: usize) -> Self {
        self.budget_tokens = Some(budget_tokens);
        self
    }

    pub fn require_reviewed_memories(mut self) -> Self {
        self.requires_reviewed_memories = true;
        self
    }

    pub fn segment_source(&self) -> &str {
        &self.segment_source
    }

    pub fn budget_tokens(&self) -> Option<usize> {
        self.budget_tokens
    }

    pub fn requires_reviewed_memories(&self) -> bool {
        self.requires_reviewed_memories
    }
}

impl Default for MemoryInjectionPolicy {
    fn default() -> Self {
        Self::new()
    }
}
