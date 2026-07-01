use std::time::{SystemTime, UNIX_EPOCH};

use serde::Serialize;

use crate::context::{
    ContextAssemblyTrace, ContextGraph, ContextSensitivity, ContextSourceLink, SegmentProvenance,
    SegmentSource,
};
use crate::prompt::PromptSourceMap;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ContextArchive {
    archive_id: String,
    run_id: String,
    segments: Vec<ContextArchiveSegment>,
    trace: ContextAssemblyTrace,
    created_at_millis: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ContextArchiveSegment {
    id: String,
    source: SegmentSource,
    redacted_content: String,
    provenance: SegmentProvenance,
    sensitivity: ContextSensitivity,
    tokens: usize,
    source_links: Vec<ContextSourceLink>,
    prompt_source_map: Option<PromptSourceMap>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct ContextArchiveDebugSummary {
    pub archive_id: String,
    pub run_id: String,
    pub segment_ids: Vec<String>,
    pub segments: Vec<ContextArchiveSegmentDebugSummary>,
    pub trace: ContextAssemblyTraceDebugSummary,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct ContextArchiveSegmentDebugSummary {
    pub id: String,
    pub source: String,
    pub redacted_content: String,
    pub provenance: String,
    pub sensitivity: ContextSensitivity,
    pub tokens: usize,
    pub source_links: Vec<ContextSourceLinkDebugSummary>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct ContextSourceLinkDebugSummary {
    pub kind: String,
    pub id: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct ContextAssemblyTraceDebugSummary {
    pub dropped_segment_ids: Vec<String>,
    pub dropped_segments: Vec<ContextDroppedSegmentDebugSummary>,
    pub kept_tokens: Vec<ContextTraceTokenSummary>,
    pub tokenizer_source: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct ContextDroppedSegmentDebugSummary {
    pub id: String,
    pub source: String,
    pub reason: String,
    pub tokens: usize,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct ContextTraceTokenSummary {
    pub source: String,
    pub tokens: usize,
}

impl ContextArchive {
    pub(crate) fn from_graph(
        run_id: impl Into<String>,
        graph: &ContextGraph,
        trace: ContextAssemblyTrace,
    ) -> Self {
        let segments: Vec<ContextArchiveSegment> = graph
            .ordered_segments()
            .iter()
            .map(|segment| {
                let tokens = trace.tokens_for_segment(segment.id().as_str()).unwrap_or(0);
                ContextArchiveSegment {
                    id: segment.id().as_str().to_string(),
                    source: segment.source(),
                    redacted_content: archive_content(segment.sensitivity(), segment.content()),
                    provenance: segment.provenance().clone(),
                    sensitivity: segment.sensitivity(),
                    tokens,
                    source_links: segment.source_links().to_vec(),
                    prompt_source_map: segment.prompt_source_map().cloned(),
                }
            })
            .collect();

        let run_id = run_id.into();
        let fingerprint = context_archive_fingerprint(&segments, &trace);
        Self {
            archive_id: format!("context_archive:{run_id}:{fingerprint}"),
            run_id,
            segments,
            trace,
            created_at_millis: now_millis(),
        }
    }

    pub fn archive_id(&self) -> &str {
        &self.archive_id
    }

    pub fn run_id(&self) -> &str {
        &self.run_id
    }

    pub fn created_at_millis(&self) -> u64 {
        self.created_at_millis
    }

    pub fn segment_ids(&self) -> Vec<String> {
        self.segments
            .iter()
            .map(|segment| segment.id.clone())
            .collect()
    }

    pub fn segment(&self, id: &str) -> Option<&ContextArchiveSegment> {
        self.segments.iter().find(|segment| segment.id == id)
    }

    pub fn trace(&self) -> &ContextAssemblyTrace {
        &self.trace
    }

    pub fn debug_summary(&self) -> ContextArchiveDebugSummary {
        ContextArchiveDebugSummary {
            archive_id: self.archive_id.clone(),
            run_id: self.run_id.clone(),
            segment_ids: self.segment_ids(),
            segments: self
                .segments
                .iter()
                .map(ContextArchiveSegment::debug_summary)
                .collect(),
            trace: self.trace.debug_summary(),
        }
    }
}

impl ContextArchiveSegment {
    pub fn redacted_content(&self) -> &str {
        &self.redacted_content
    }

    pub fn provenance(&self) -> &SegmentProvenance {
        &self.provenance
    }

    pub fn source_links(&self) -> &[ContextSourceLink] {
        &self.source_links
    }

    pub fn prompt_source_map(&self) -> Option<&PromptSourceMap> {
        self.prompt_source_map.as_ref()
    }

    fn debug_summary(&self) -> ContextArchiveSegmentDebugSummary {
        ContextArchiveSegmentDebugSummary {
            id: self.id.clone(),
            source: self.source.as_str().to_string(),
            redacted_content: self.redacted_content.clone(),
            provenance: self.provenance.as_str().to_string(),
            sensitivity: self.sensitivity,
            tokens: self.tokens,
            source_links: self
                .source_links
                .iter()
                .map(|link| ContextSourceLinkDebugSummary {
                    kind: link.kind().to_string(),
                    id: link.id().to_string(),
                })
                .collect(),
        }
    }
}

impl ContextAssemblyTrace {
    pub(crate) fn debug_summary(&self) -> ContextAssemblyTraceDebugSummary {
        let mut kept_tokens = self
            .kept_token_entries()
            .into_iter()
            .map(|(source, tokens)| ContextTraceTokenSummary {
                source: source.as_str().to_string(),
                tokens,
            })
            .collect::<Vec<_>>();
        kept_tokens.sort_by(|left, right| left.source.cmp(&right.source));

        ContextAssemblyTraceDebugSummary {
            dropped_segment_ids: self.dropped_segment_ids(),
            dropped_segments: self
                .dropped_segments()
                .iter()
                .map(|drop| ContextDroppedSegmentDebugSummary {
                    id: drop.segment_id().to_string(),
                    source: drop.source().as_str().to_string(),
                    reason: drop.reason().to_string(),
                    tokens: drop.tokens(),
                })
                .collect(),
            kept_tokens,
            tokenizer_source: self.tokenizer_source().to_string(),
        }
    }
}

fn archive_content(sensitivity: ContextSensitivity, content: &str) -> String {
    match sensitivity {
        ContextSensitivity::Sensitive | ContextSensitivity::Secret => "[redacted]".to_string(),
        ContextSensitivity::Public | ContextSensitivity::Normal => content.to_string(),
    }
}

fn now_millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as u64)
        .unwrap_or(0)
}

fn context_archive_fingerprint(
    segments: &[ContextArchiveSegment],
    trace: &ContextAssemblyTrace,
) -> String {
    let mut hash = 0xcbf29ce484222325u64;
    for segment in segments {
        hash_str(&mut hash, &segment.id);
        hash_str(&mut hash, segment.source.as_str());
        hash_str(&mut hash, &segment.redacted_content);
        hash_str(&mut hash, segment.provenance.as_str());
        hash_str(&mut hash, sensitivity_label(segment.sensitivity));
        hash_usize(&mut hash, segment.tokens);
        for link in &segment.source_links {
            hash_str(&mut hash, link.kind());
            hash_str(&mut hash, link.id());
        }
    }
    for dropped in trace.dropped_segments() {
        hash_str(&mut hash, dropped.segment_id());
        hash_str(&mut hash, dropped.source().as_str());
        hash_str(&mut hash, dropped.reason());
        hash_usize(&mut hash, dropped.tokens());
    }
    format!("{hash:016x}")
}

fn hash_str(hash: &mut u64, value: &str) {
    hash_usize(hash, value.len());
    for byte in value.as_bytes() {
        *hash ^= u64::from(*byte);
        *hash = hash.wrapping_mul(0x100000001b3);
    }
}

fn hash_usize(hash: &mut u64, value: usize) {
    for byte in value.to_le_bytes() {
        *hash ^= u64::from(byte);
        *hash = hash.wrapping_mul(0x100000001b3);
    }
}

fn sensitivity_label(sensitivity: ContextSensitivity) -> &'static str {
    match sensitivity {
        ContextSensitivity::Public => "public",
        ContextSensitivity::Normal => "normal",
        ContextSensitivity::Sensitive => "sensitive",
        ContextSensitivity::Secret => "secret",
    }
}
