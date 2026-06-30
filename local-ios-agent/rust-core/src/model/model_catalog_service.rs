use crate::model::{
    ModelDescriptor, ModelProviderIssue, ProviderAccount, ProviderAccountValidation,
    ProviderAccountValidationRequest, ProviderDefinition,
};
use crate::security::{DataEgressDecision, DataEgressRequest, SecurityPermissionService};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ModelListResult {
    pub models: Vec<ModelDescriptor>,
    pub issues: Vec<ModelProviderIssue>,
}

impl ModelListResult {
    pub fn valid(models: Vec<ModelDescriptor>) -> Self {
        Self {
            models,
            issues: Vec::new(),
        }
    }

    pub fn egress_denied() -> Self {
        Self {
            models: Vec::new(),
            issues: vec![ModelProviderIssue::new(
                "model.egress_approval_required",
                "remote model list requires matching egress approval",
            )],
        }
    }

    pub fn is_valid(&self) -> bool {
        self.issues.is_empty()
    }
}

pub trait ModelProviderAdapter: Send + Sync {
    fn provider_definition(&self) -> ProviderDefinition;
    fn validate_account(
        &self,
        request: ProviderAccountValidationRequest,
    ) -> ProviderAccountValidation;
    fn list_models(&self, request: crate::model::ModelListRequest) -> ModelListResult;
}

pub struct ModelCatalogService {
    security: Box<dyn SecurityPermissionService>,
}

impl ModelCatalogService {
    pub fn new(security: impl SecurityPermissionService + 'static) -> Self {
        Self {
            security: Box::new(security),
        }
    }

    pub fn evaluate_account_validation_egress(
        &self,
        account: &ProviderAccount,
    ) -> DataEgressDecision {
        self.security
            .evaluate_egress(DataEgressRequest::remote_provider_validation(
                account.destination().unwrap_or(""),
            ))
    }

    pub fn evaluate_model_list_egress(&self, account: &ProviderAccount) -> DataEgressDecision {
        self.security
            .evaluate_egress(DataEgressRequest::remote_provider_list(
                account.destination().unwrap_or(""),
            ))
    }
}
