use crate::context::ContextSegment;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ContextContribution {
    source_id: String,
    segment: ContextSegment,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ContextContributionBundle {
    contributions: Vec<ContextContribution>,
}

impl ContextContribution {
    pub fn new(source_id: impl Into<String>, segment: ContextSegment) -> Self {
        Self {
            source_id: source_id.into(),
            segment,
        }
    }

    pub fn source_id(&self) -> &str {
        &self.source_id
    }

    pub fn segment(&self) -> &ContextSegment {
        &self.segment
    }
}

impl ContextContributionBundle {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_contribution(mut self, contribution: ContextContribution) -> Self {
        self.contributions.push(contribution);
        self
    }

    pub fn segments(&self) -> Vec<ContextSegment> {
        self.contributions
            .iter()
            .map(|contribution| contribution.segment.clone())
            .collect()
    }

    pub fn contributions(&self) -> &[ContextContribution] {
        &self.contributions
    }
}
