use crate::model::{
    ModelDescriptor, ModelProviderIssue, ModelProviderResult, ProviderAccount,
    ProviderAccountValidation, ProviderAccountValidationRequest, ProviderDefinition,
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
    ) -> ModelProviderResult<DataEgressDecision> {
        let destination = remote_destination(account)?;
        Ok(self
            .security
            .evaluate_egress(DataEgressRequest::remote_provider_validation(destination)))
    }

    pub fn evaluate_model_list_egress(
        &self,
        account: &ProviderAccount,
    ) -> ModelProviderResult<DataEgressDecision> {
        let destination = remote_destination(account)?;
        Ok(self
            .security
            .evaluate_egress(DataEgressRequest::remote_provider_list(destination)))
    }
}

fn remote_destination(account: &ProviderAccount) -> ModelProviderResult<&str> {
    if !account.is_remote() {
        return Err(ModelProviderIssue::new(
            "model.egress.remote_account_required",
            "provider egress evaluation requires a remote provider account",
        ));
    }

    account.destination().ok_or_else(|| {
        ModelProviderIssue::new(
            "model.egress.remote_destination_missing",
            "remote provider account is missing an egress destination",
        )
    })
}
