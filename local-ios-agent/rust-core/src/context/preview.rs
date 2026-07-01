use crate::context::ContextAssemblyTrace;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ContextPreview {
    segment_ids: Vec<String>,
    trace: ContextAssemblyTrace,
}

impl ContextPreview {
    pub(crate) fn new(segment_ids: Vec<String>, trace: ContextAssemblyTrace) -> Self {
        Self { segment_ids, trace }
    }

    pub fn segment_ids(&self) -> Vec<String> {
        self.segment_ids.clone()
    }

    pub fn trace(&self) -> &ContextAssemblyTrace {
        &self.trace
    }
}
