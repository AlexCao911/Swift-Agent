use std::collections::{BTreeMap, BTreeSet};

use crate::user_customization::{ComponentKind, UserComponentVersionId};

#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct ComponentNodeId(String);

#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct UserFacingCapabilityId(String);

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ComponentNode {
    id: ComponentNodeId,
    kind: ComponentKind,
    version_id: UserComponentVersionId,
    required_capabilities: BTreeSet<UserFacingCapabilityId>,
    provided_capabilities: BTreeSet<UserFacingCapabilityId>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ComponentDependencyEdge {
    from: ComponentNodeId,
    to: ComponentNodeId,
    capability: UserFacingCapabilityId,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ComponentGraph {
    nodes: Vec<ComponentNode>,
    edges: Vec<ComponentDependencyEdge>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ComponentGraphBuilder {
    nodes: Vec<ComponentNode>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct CapabilityValidationReport {
    missing_capabilities: Vec<MissingCapability>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MissingCapability {
    node_id: ComponentNodeId,
    capability: UserFacingCapabilityId,
}

impl ComponentNodeId {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl UserFacingCapabilityId {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl ComponentNode {
    pub fn skill(id: impl Into<String>, version_id: u64) -> Self {
        Self::new(id, ComponentKind::Skill, version_id)
    }

    pub fn tool_recipe(id: impl Into<String>, version_id: u64) -> Self {
        Self::new(id, ComponentKind::ToolRecipe, version_id)
    }

    pub fn new(id: impl Into<String>, kind: ComponentKind, version_id: u64) -> Self {
        Self {
            id: ComponentNodeId::new(id),
            kind,
            version_id: UserComponentVersionId::new(version_id),
            required_capabilities: BTreeSet::new(),
            provided_capabilities: BTreeSet::new(),
        }
    }

    pub fn requires(mut self, capability: UserFacingCapabilityId) -> Self {
        self.required_capabilities.insert(capability);
        self
    }

    pub fn provides(mut self, capability: UserFacingCapabilityId) -> Self {
        self.provided_capabilities.insert(capability);
        self
    }

    pub fn id(&self) -> &ComponentNodeId {
        &self.id
    }

    pub fn kind(&self) -> ComponentKind {
        self.kind
    }

    pub fn version_id(&self) -> UserComponentVersionId {
        self.version_id
    }
}

impl ComponentDependencyEdge {
    pub fn from(&self) -> &ComponentNodeId {
        &self.from
    }

    pub fn to(&self) -> &ComponentNodeId {
        &self.to
    }

    pub fn capability(&self) -> &UserFacingCapabilityId {
        &self.capability
    }
}

impl ComponentGraph {
    pub fn empty() -> Self {
        Self::default()
    }

    pub fn edges(&self) -> &[ComponentDependencyEdge] {
        &self.edges
    }

    pub fn nodes(&self) -> &[ComponentNode] {
        &self.nodes
    }

    pub fn has_node(&self, node_id: &str) -> bool {
        self.nodes.iter().any(|node| node.id().as_str() == node_id)
    }

    pub fn validate_capabilities(&self) -> CapabilityValidationReport {
        let providers = capability_providers(&self.nodes);
        let mut report = CapabilityValidationReport::default();

        for node in &self.nodes {
            for capability in &node.required_capabilities {
                if !providers.contains_key(capability) {
                    report.missing_capabilities.push(MissingCapability {
                        node_id: node.id.clone(),
                        capability: capability.clone(),
                    });
                }
            }
        }

        report
    }

    pub fn fixture_missing_model() -> Self {
        Self::empty()
    }
}

impl ComponentGraphBuilder {
    pub fn add_node(mut self, node: ComponentNode) -> Self {
        self.nodes.push(node);
        self
    }

    pub fn build(self) -> ComponentGraph {
        let providers = capability_providers(&self.nodes);
        let mut edges = Vec::new();
        for node in &self.nodes {
            for capability in &node.required_capabilities {
                if let Some(provider) = providers.get(capability) {
                    edges.push(ComponentDependencyEdge {
                        from: node.id.clone(),
                        to: (*provider).clone(),
                        capability: capability.clone(),
                    });
                }
            }
        }

        ComponentGraph {
            nodes: self.nodes,
            edges,
        }
    }
}

impl CapabilityValidationReport {
    pub fn is_ready(&self) -> bool {
        self.missing_capabilities.is_empty()
    }

    pub fn has_missing_capability(&self, node_id: &str, capability: &str) -> bool {
        self.missing_capabilities.iter().any(|missing| {
            missing.node_id.as_str() == node_id && missing.capability.as_str() == capability
        })
    }

    pub fn blocking_issue_codes(&self) -> Vec<&'static str> {
        if self.missing_capabilities.is_empty() {
            Vec::new()
        } else {
            vec!["capability.required.missing"]
        }
    }
}

fn capability_providers(
    nodes: &[ComponentNode],
) -> BTreeMap<&UserFacingCapabilityId, ComponentNodeId> {
    let mut providers = BTreeMap::new();
    for node in nodes {
        for capability in &node.provided_capabilities {
            providers.insert(capability, node.id.clone());
        }
    }
    providers
}
