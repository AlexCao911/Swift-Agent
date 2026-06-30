use crate::memory::{
    MemoryContribution, MemoryProvider, MemoryQuery, MemoryReadinessIssue, MemoryRetrievalTrace,
};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MemoryResolverInput {
    pub query: MemoryQuery,
}

#[derive(Clone, Debug, PartialEq)]
pub struct MemoryResolverResult {
    pub contributions: Vec<MemoryContribution>,
    pub traces: Vec<MemoryRetrievalTrace>,
    pub readiness_issues: Vec<MemoryReadinessIssue>,
}

pub trait MemoryResolver {
    fn resolve(&self, input: MemoryResolverInput) -> MemoryResolverResult;
}

#[derive(Debug, Default)]
pub struct StaticMemoryResolver {
    providers: Vec<Box<dyn MemoryProvider>>,
}

impl StaticMemoryResolver {
    pub fn new(providers: Vec<Box<dyn MemoryProvider>>) -> Self {
        Self { providers }
    }
}

impl MemoryResolver for StaticMemoryResolver {
    fn resolve(&self, input: MemoryResolverInput) -> MemoryResolverResult {
        let mut contributions = Vec::new();
        let mut traces = Vec::new();
        let mut readiness_issues = Vec::new();
        for provider in &self.providers {
            let result = provider.query(&input.query);
            contributions.extend(result.contributions);
            traces.push(result.trace);
            readiness_issues.extend(result.readiness_issues);
        }
        MemoryResolverResult {
            contributions,
            traces,
            readiness_issues,
        }
    }
}
