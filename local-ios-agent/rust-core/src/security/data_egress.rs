use std::collections::{BTreeMap, BTreeSet};

use crate::security::{
    ApprovalRequirement, CapabilityRequirement, OperationDescriptor, PermissionReadinessReport,
    PermissionState,
};

#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct EgressDestination(String);

impl EgressDestination {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct DataFieldClass(String);

impl DataFieldClass {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum SensitivityLevel {
    Public,
    UserData,
    Sensitive,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DataEgressDisclosureId(String);

impl DataEgressDisclosureId {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum AllowlistResult {
    Allowed,
    Denied { reason: String },
}

impl AllowlistResult {
    pub fn is_allowed(&self) -> bool {
        matches!(self, Self::Allowed)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DataEgressPolicy {
    destination: EgressDestination,
    allowed_fields: Vec<DataFieldClass>,
    requires_disclosure: bool,
    requires_approval: bool,
}

impl DataEgressPolicy {
    pub fn destination(&self) -> &EgressDestination {
        &self.destination
    }

    pub fn allowed_fields(&self) -> &[DataFieldClass] {
        &self.allowed_fields
    }

    pub fn requires_disclosure(&self) -> bool {
        self.requires_disclosure
    }

    pub fn requires_approval(&self) -> bool {
        self.requires_approval
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DataEgressRequest {
    operation: String,
    destination: EgressDestination,
    data_classes: Vec<DataFieldClass>,
    sensitivity: SensitivityLevel,
}

impl DataEgressRequest {
    pub fn remote_provider_list(destination: impl Into<String>) -> Self {
        Self::new(
            "remote.provider.list_models",
            destination,
            vec!["provider.account.metadata"],
            SensitivityLevel::UserData,
        )
    }

    pub fn remote_provider_validation(destination: impl Into<String>) -> Self {
        Self::new(
            "remote.provider.validate_account",
            destination,
            vec!["provider.account.metadata"],
            SensitivityLevel::UserData,
        )
    }

    pub fn remote_inference(destination: impl Into<String>) -> Self {
        Self::new(
            "remote.inference.generate",
            destination,
            vec!["conversation.content"],
            SensitivityLevel::Sensitive,
        )
    }

    pub fn http_tool(destination: impl Into<String>) -> Self {
        Self::new(
            "http.tool.request",
            destination,
            vec!["tool.request.payload"],
            SensitivityLevel::Sensitive,
        )
    }

    pub fn external_memory_write(destination: impl Into<String>) -> Self {
        Self::new(
            "external.memory.write",
            destination,
            vec!["memory.content"],
            SensitivityLevel::Sensitive,
        )
    }

    fn new(
        operation: impl Into<String>,
        destination: impl Into<String>,
        data_classes: Vec<&str>,
        sensitivity: SensitivityLevel,
    ) -> Self {
        Self {
            operation: operation.into(),
            destination: EgressDestination::new(destination),
            data_classes: data_classes.into_iter().map(DataFieldClass::new).collect(),
            sensitivity,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DataEgressDecision {
    operation: OperationDescriptor,
    disclosure_id: DataEgressDisclosureId,
    allowlist_result: AllowlistResult,
    approval_requirement: ApprovalRequirement,
    policy: DataEgressPolicy,
}

impl DataEgressDecision {
    pub fn operation(&self) -> &OperationDescriptor {
        &self.operation
    }

    pub fn disclosure_id(&self) -> &DataEgressDisclosureId {
        &self.disclosure_id
    }

    pub fn allowlist_result(&self) -> &AllowlistResult {
        &self.allowlist_result
    }

    pub fn approval_requirement(&self) -> ApprovalRequirement {
        self.approval_requirement.clone()
    }

    pub fn policy(&self) -> &DataEgressPolicy {
        &self.policy
    }
}

pub trait DataEgressEvaluator: Send + Sync {
    fn evaluate(&self, request: DataEgressRequest) -> DataEgressDecision;
}

pub trait SecurityPermissionService: Send + Sync {
    fn permission_state(&self, requirements: &[CapabilityRequirement]) -> PermissionState;
    fn permission_readiness(
        &self,
        requirements: &[CapabilityRequirement],
    ) -> PermissionReadinessReport;
    fn evaluate_egress(&self, request: DataEgressRequest) -> DataEgressDecision;
    fn required_approval(&self, operation: &OperationDescriptor) -> ApprovalRequirement;
}

#[derive(Clone, Debug, Default)]
pub struct StaticSecurityPermissionService {
    allowed_destinations: BTreeSet<EgressDestination>,
    permissions: BTreeMap<CapabilityRequirement, PermissionState>,
    external_memory_write_enabled: bool,
}

impl StaticSecurityPermissionService {
    pub fn allow_destination(mut self, destination: EgressDestination) -> Self {
        self.allowed_destinations.insert(destination);
        self
    }

    pub fn with_permission(
        mut self,
        capability: impl Into<String>,
        state: PermissionState,
    ) -> Self {
        self.permissions
            .insert(CapabilityRequirement::new(capability), state);
        self
    }

    pub fn with_external_memory_write_enabled(mut self, enabled: bool) -> Self {
        self.external_memory_write_enabled = enabled;
        self
    }

    fn allowlist_result(&self, destination: &EgressDestination) -> AllowlistResult {
        if self.allowed_destinations.contains(destination) {
            AllowlistResult::Allowed
        } else {
            AllowlistResult::Denied {
                reason: format!("destination not allowlisted: {}", destination.as_str()),
            }
        }
    }

    fn egress_gate_result(&self, request: &DataEgressRequest) -> AllowlistResult {
        if request.operation == "external.memory.write" && !self.external_memory_write_enabled {
            return AllowlistResult::Denied {
                reason: "external memory writes are disabled".to_string(),
            };
        }

        self.allowlist_result(&request.destination)
    }
}

impl DataEgressEvaluator for StaticSecurityPermissionService {
    fn evaluate(&self, request: DataEgressRequest) -> DataEgressDecision {
        let allowlist_result = self.egress_gate_result(&request);
        let requires_approval = matches!(
            request.sensitivity,
            SensitivityLevel::UserData | SensitivityLevel::Sensitive
        );

        DataEgressDecision {
            operation: OperationDescriptor::new(request.operation.clone()),
            disclosure_id: DataEgressDisclosureId::new(format!(
                "egress:{}:{}",
                request.operation,
                request.destination.as_str()
            )),
            allowlist_result,
            approval_requirement: if requires_approval {
                ApprovalRequirement::Required
            } else {
                ApprovalRequirement::NotRequired
            },
            policy: DataEgressPolicy {
                destination: request.destination,
                allowed_fields: request.data_classes,
                requires_disclosure: true,
                requires_approval,
            },
        }
    }
}

impl SecurityPermissionService for StaticSecurityPermissionService {
    fn permission_state(&self, requirements: &[CapabilityRequirement]) -> PermissionState {
        let mut aggregate = PermissionState::Granted;

        for requirement in requirements {
            match self
                .permissions
                .get(requirement)
                .cloned()
                .unwrap_or(PermissionState::NotDetermined)
            {
                PermissionState::Denied => return PermissionState::Denied,
                PermissionState::Restricted => aggregate = PermissionState::Restricted,
                PermissionState::NotDetermined => {
                    if aggregate == PermissionState::Granted {
                        aggregate = PermissionState::NotDetermined;
                    }
                }
                PermissionState::Granted => {}
            }
        }

        aggregate
    }

    fn permission_readiness(
        &self,
        requirements: &[CapabilityRequirement],
    ) -> PermissionReadinessReport {
        let states = requirements
            .iter()
            .map(|requirement| {
                (
                    requirement.clone(),
                    self.permissions
                        .get(requirement)
                        .cloned()
                        .unwrap_or(PermissionState::NotDetermined),
                )
            })
            .collect();
        PermissionReadinessReport::new(states)
    }

    fn evaluate_egress(&self, request: DataEgressRequest) -> DataEgressDecision {
        self.evaluate(request)
    }

    fn required_approval(&self, operation: &OperationDescriptor) -> ApprovalRequirement {
        approval_requirement_for_operation(operation)
    }
}

pub(crate) fn approval_requirement_for_operation(
    _operation: &OperationDescriptor,
) -> ApprovalRequirement {
    ApprovalRequirement::Required
}
