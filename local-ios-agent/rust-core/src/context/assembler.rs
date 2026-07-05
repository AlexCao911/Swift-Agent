use std::collections::BTreeMap;
use std::fmt;

use crate::context::{
    ContextArchive, ContextBudget, ContextContributionBundle, ContextGraph, ContextPolicy,
    ContextPreview, ContextSegment, ContextSensitivity, ModelInputMessage, ModelInputMessages,
    ModelInputRole, PromptMessage, SegmentSource,
};
use crate::memory::{
    MemoryContribution, ProvenanceSourceKind, SensitivityLevel as MemorySensitivity,
};
use crate::prompt::CompiledPrompt;
use crate::tool::{RetentionPolicy, Sensitivity as ToolSensitivity, ToolResult};

#[derive(Clone, Debug, Default)]
pub struct ContextAssembler {
    segments: Vec<ContextSegment>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ContextAssemblyResult {
    graph: ContextGraph,
    trace: ContextAssemblyTrace,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ContextAssemblyTrace {
    dropped_segments: Vec<ContextDroppedSegment>,
    kept_tokens_by_source: BTreeMap<SegmentSource, usize>,
    tokens_by_segment: BTreeMap<String, usize>,
    tokenizer_source: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ContextDroppedSegment {
    segment_id: String,
    source: SegmentSource,
    reason: String,
    tokens: usize,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ContextAssemblyError {
    message: String,
}

pub type ContextAssemblyResultValue<T> = Result<T, ContextAssemblyError>;

impl ContextAssembler {
    pub fn new() -> Self {
        Self {
            segments: Vec::new(),
        }
    }

    pub fn with_segment(mut self, segment: ContextSegment) -> Self {
        self.segments.push(segment);
        self
    }

    pub fn with_contributions(mut self, bundle: ContextContributionBundle) -> Self {
        self.segments.extend(bundle.segments());
        self
    }

    pub fn with_compiled_prompt(self, prompt: CompiledPrompt) -> Self {
        let source_map = prompt.source_map;
        let mut segment = ContextSegment::prompt("prompt.compiled", prompt.text)
            .with_provenance("prompt.compiled");
        for entry in &source_map.entries {
            segment = segment.with_source_link(
                "prompt_document",
                format!(
                    "{}:{}@{}",
                    entry.slot,
                    entry.document_id,
                    entry.version_id.as_u64()
                ),
            );
        }
        self.with_segment(segment.with_prompt_source_map(source_map))
    }

    pub fn with_memory_contribution(self, contribution: MemoryContribution) -> Self {
        let source_kind = match contribution.provenance.source_kind() {
            ProvenanceSourceKind::Local => "memory.local",
            ProvenanceSourceKind::External => "memory.external",
        };
        self.with_segment(
            ContextSegment::memory(contribution.id.as_str(), contribution.content)
                .with_provenance(format!(
                    "{}:{}",
                    source_kind,
                    contribution.provenance.source_id()
                ))
                .with_source_link("memory_contribution", contribution.id.as_str())
                .with_sensitivity(memory_sensitivity(contribution.sensitivity)),
        )
    }

    pub fn with_tool_result(self, id: impl Into<String>, result: ToolResult) -> Self {
        let id = id.into();
        let mut segment = ContextSegment::tool_result(id.clone(), result.model_text)
            .with_provenance(result.provenance)
            .with_source_link("tool_result", &id)
            .with_sensitivity(tool_sensitivity(result.sensitivity));
        if result.retention == RetentionPolicy::AuditOnly {
            segment = segment.with_sensitivity(ContextSensitivity::Secret);
        }
        self.with_segment(segment)
    }

    pub fn with_conversation_messages(mut self, messages: Vec<PromptMessage>) -> Self {
        for (index, message) in messages.into_iter().enumerate() {
            let role = model_role_for_prompt_message(&message);
            let blob_refs = message.blob_refs().to_vec();
            self.segments.push(
                ContextSegment::conversation(
                    format!("conversation.{index:04}"),
                    message.content().to_string(),
                )
                .with_model_role(role)
                .with_blob_refs(blob_refs)
                .with_provenance(format!("conversation.{index:04}")),
            );
        }
        self
    }

    pub fn assemble(
        &self,
        budget: ContextBudget<'_>,
    ) -> ContextAssemblyResultValue<ContextAssemblyResult> {
        self.assemble_internal(
            &ContextPolicy::new().with_global_budget(budget.max_tokens()),
            &|text| budget.count_text(text),
            budget.tokenizer_source(),
        )
    }

    pub fn assemble_with_policy(
        &self,
        policy: ContextPolicy,
    ) -> ContextAssemblyResultValue<ContextAssemblyResult> {
        self.assemble_internal(&policy, &default_count_text, "context_policy.whitespace")
    }

    pub fn assemble_default(&self) -> ContextAssemblyResultValue<ContextAssemblyResult> {
        self.assemble_with_policy(ContextPolicy::new())
    }

    pub fn preview(&self) -> ContextAssemblyResultValue<ContextPreview> {
        let result = self.assemble_default()?;
        Ok(ContextPreview::new(
            result.segment_ids(),
            result.trace().clone(),
        ))
    }

    fn assemble_internal(
        &self,
        policy: &ContextPolicy,
        count_text: &dyn Fn(&str) -> usize,
        tokenizer_source: &str,
    ) -> ContextAssemblyResultValue<ContextAssemblyResult> {
        let graph = ContextGraph::from_segments(self.segments.clone())
            .map_err(|error| ContextAssemblyError::new(error.to_string()))?;
        let mut trace = ContextAssemblyTrace::new(tokenizer_source);
        let mut kept = Vec::new();
        let mut total_tokens = 0usize;
        let mut conversation_window_closed = false;

        let mut budget_order = graph.ordered_segments().iter().collect::<Vec<_>>();
        budget_order.sort_by(|left, right| {
            right
                .budget_priority()
                .cmp(&left.budget_priority())
                .then_with(|| left.source().rank().cmp(&right.source().rank()))
                .then_with(|| budget_id_order(left, right))
        });

        for segment in budget_order {
            let tokens = count_text(segment.content());
            trace.record_segment_tokens(segment.id().as_str(), tokens);

            if policy.excludes_secret_segments()
                && segment.sensitivity() == ContextSensitivity::Secret
            {
                if segment.is_required_for_model_input() {
                    return Err(required_segment_error(
                        segment,
                        "context.required_segment_excluded",
                    ));
                }
                trace.drop_segment(segment, "sensitivity.excluded", tokens);
                if segment.source() == SegmentSource::Conversation {
                    conversation_window_closed = true;
                }
                continue;
            }

            if segment.source() == SegmentSource::Conversation && conversation_window_closed {
                trace.drop_segment(segment, "conversation.window_closed", tokens);
                continue;
            }

            if let Some(source_budget) = policy.source_budget_tokens(segment.source()) {
                if trace.kept_tokens_for(segment.source()) + tokens > source_budget {
                    if segment.is_required_for_model_input() {
                        return Err(required_segment_error(
                            segment,
                            "context.required_segment_exceeds_budget",
                        ));
                    }
                    trace.drop_segment(segment, "budget.exceeded", tokens);
                    if segment.source() == SegmentSource::Conversation {
                        conversation_window_closed = true;
                    }
                    continue;
                }
            }

            if let Some(global_budget) = policy.global_budget_tokens() {
                if total_tokens + tokens > global_budget {
                    if segment.is_required_for_model_input() {
                        return Err(required_segment_error(
                            segment,
                            "context.required_segment_exceeds_budget",
                        ));
                    }
                    trace.drop_segment(segment, "budget.exceeded", tokens);
                    if segment.source() == SegmentSource::Conversation {
                        conversation_window_closed = true;
                    }
                    continue;
                }
            }

            total_tokens += tokens;
            trace.keep_segment(segment.source(), tokens);
            kept.push(segment.clone());
        }

        Ok(ContextAssemblyResult {
            graph: ContextGraph::from_kept_segments(kept)
                .map_err(|error| ContextAssemblyError::new(error.to_string()))?,
            trace,
        })
    }
}

impl ContextAssemblyResult {
    pub fn graph(&self) -> &ContextGraph {
        &self.graph
    }

    pub fn trace(&self) -> &ContextAssemblyTrace {
        &self.trace
    }

    pub fn segment_ids(&self) -> Vec<String> {
        self.graph.segment_ids()
    }

    pub fn model_input_text(&self) -> String {
        self.graph
            .ordered_segments()
            .iter()
            .map(|segment| segment.content().to_string())
            .collect::<Vec<_>>()
            .join("\n\n")
    }

    pub fn model_input_messages(&self) -> ModelInputMessages {
        ModelInputMessages::new(
            self.graph
                .ordered_segments()
                .iter()
                .map(|segment| {
                    ModelInputMessage::new(
                        segment.model_role(),
                        segment.content().to_string(),
                        segment.blob_refs().to_vec(),
                        segment.id().clone(),
                    )
                })
                .collect(),
        )
    }

    pub fn archive(&self, run_id: impl Into<String>) -> ContextArchive {
        ContextArchive::from_graph(run_id, &self.graph, self.trace.clone())
    }
}

impl ContextAssemblyTrace {
    pub fn new(tokenizer_source: impl Into<String>) -> Self {
        Self {
            dropped_segments: Vec::new(),
            kept_tokens_by_source: BTreeMap::new(),
            tokens_by_segment: BTreeMap::new(),
            tokenizer_source: tokenizer_source.into(),
        }
    }

    pub fn dropped_segments(&self) -> &[ContextDroppedSegment] {
        &self.dropped_segments
    }

    pub fn dropped_segment_ids(&self) -> Vec<String> {
        self.dropped_segments
            .iter()
            .map(|segment| segment.segment_id.clone())
            .collect()
    }

    pub fn kept_tokens_for(&self, source: SegmentSource) -> usize {
        self.kept_tokens_by_source
            .get(&source)
            .copied()
            .unwrap_or(0)
    }

    pub(crate) fn kept_token_entries(&self) -> Vec<(SegmentSource, usize)> {
        self.kept_tokens_by_source
            .iter()
            .map(|(source, tokens)| (*source, *tokens))
            .collect()
    }

    pub(crate) fn tokens_for_segment(&self, segment_id: &str) -> Option<usize> {
        self.tokens_by_segment.get(segment_id).copied()
    }

    pub(crate) fn tokenizer_source(&self) -> &str {
        &self.tokenizer_source
    }

    fn keep_segment(&mut self, source: SegmentSource, tokens: usize) {
        *self.kept_tokens_by_source.entry(source).or_insert(0) += tokens;
    }

    fn drop_segment(&mut self, segment: &ContextSegment, reason: &str, tokens: usize) {
        self.dropped_segments.push(ContextDroppedSegment {
            segment_id: segment.id().as_str().to_string(),
            source: segment.source(),
            reason: reason.to_string(),
            tokens,
        });
    }

    fn record_segment_tokens(&mut self, segment_id: &str, tokens: usize) {
        self.tokens_by_segment
            .insert(segment_id.to_string(), tokens);
    }
}

impl Default for ContextAssemblyTrace {
    fn default() -> Self {
        Self::new("unknown")
    }
}

impl ContextDroppedSegment {
    pub fn segment_id(&self) -> &str {
        &self.segment_id
    }

    pub fn source(&self) -> SegmentSource {
        self.source
    }

    pub fn reason(&self) -> &str {
        &self.reason
    }

    pub fn tokens(&self) -> usize {
        self.tokens
    }
}

impl ContextAssemblyError {
    pub fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }
}

impl fmt::Display for ContextAssemblyError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for ContextAssemblyError {}

fn default_count_text(text: &str) -> usize {
    text.split_whitespace().count()
}

fn memory_sensitivity(sensitivity: MemorySensitivity) -> ContextSensitivity {
    match sensitivity {
        MemorySensitivity::Public => ContextSensitivity::Public,
        MemorySensitivity::Normal => ContextSensitivity::Normal,
        MemorySensitivity::Sensitive => ContextSensitivity::Sensitive,
        MemorySensitivity::Secret => ContextSensitivity::Secret,
    }
}

fn tool_sensitivity(sensitivity: ToolSensitivity) -> ContextSensitivity {
    match sensitivity {
        ToolSensitivity::Public => ContextSensitivity::Public,
        ToolSensitivity::Private => ContextSensitivity::Sensitive,
        ToolSensitivity::Secret => ContextSensitivity::Secret,
    }
}

fn budget_id_order(left: &ContextSegment, right: &ContextSegment) -> std::cmp::Ordering {
    if left.source() == SegmentSource::Conversation && right.source() == SegmentSource::Conversation
    {
        return right.id().as_str().cmp(left.id().as_str());
    }
    left.id().as_str().cmp(right.id().as_str())
}

fn model_role_for_prompt_message(message: &PromptMessage) -> ModelInputRole {
    match message {
        PromptMessage::User(_) | PromptMessage::UserWithBlobRefs { .. } => ModelInputRole::User,
        PromptMessage::Assistant(_) => ModelInputRole::Assistant,
        PromptMessage::ToolResult(_) => ModelInputRole::Tool,
        PromptMessage::Summary(_) => ModelInputRole::Summary,
    }
}

fn required_segment_error(segment: &ContextSegment, code: &str) -> ContextAssemblyError {
    ContextAssemblyError::new(format!("{}: {}", code, segment.id().as_str()))
}
