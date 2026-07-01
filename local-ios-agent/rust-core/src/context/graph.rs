use std::collections::BTreeSet;
use std::fmt;

use crate::context::ContextSegment;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ContextGraph {
    segments: Vec<ContextSegment>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ContextGraphError {
    message: String,
}

impl ContextGraph {
    pub fn from_segments(mut segments: Vec<ContextSegment>) -> Result<Self, ContextGraphError> {
        reject_duplicate_segment_ids(&segments)?;
        segments.sort_by(|left, right| {
            right
                .priority()
                .cmp(&left.priority())
                .then_with(|| left.source().rank().cmp(&right.source().rank()))
                .then_with(|| left.id().as_str().cmp(right.id().as_str()))
        });
        Ok(Self { segments })
    }

    pub fn ordered_segments(&self) -> &[ContextSegment] {
        &self.segments
    }

    pub fn segment_ids(&self) -> Vec<String> {
        self.segments
            .iter()
            .map(|segment| segment.id().as_str().to_string())
            .collect()
    }

    pub fn segment(&self, id: &str) -> Option<&ContextSegment> {
        self.segments
            .iter()
            .find(|segment| segment.id().as_str() == id)
    }

    pub(crate) fn from_kept_segments(
        segments: Vec<ContextSegment>,
    ) -> Result<Self, ContextGraphError> {
        Self::from_segments(segments)
    }
}

impl ContextGraphError {
    fn duplicate_segment_id(id: &str) -> Self {
        Self {
            message: format!("context.duplicate_segment_id: {id}"),
        }
    }
}

impl fmt::Display for ContextGraphError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for ContextGraphError {}

fn reject_duplicate_segment_ids(segments: &[ContextSegment]) -> Result<(), ContextGraphError> {
    let mut seen = BTreeSet::new();
    for segment in segments {
        if !seen.insert(segment.id().as_str()) {
            return Err(ContextGraphError::duplicate_segment_id(
                segment.id().as_str(),
            ));
        }
    }
    Ok(())
}
