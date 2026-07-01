use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use crate::model::{ModelDescriptor, ModelFormat};
use crate::security::{
    ApprovalGrant, ApprovalRequirement, DataEgressDecision, OperationDescriptor,
};
use crate::storage::{PendingStoreWrite, StorageError, StorageResult, UnitOfWork};

#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct ModelBindingId(String);

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct ModelCatalogVersion(u64);

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ModelSelection {
    binding_id: ModelBindingId,
    provider_account_id: String,
    provider_id: String,
    model_id: String,
    catalog_version: ModelCatalogVersion,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ModelBindingCatalog {
    selections: BTreeMap<ModelBindingId, ModelSelection>,
}

#[derive(Clone, Debug, Default)]
pub struct InMemoryModelBindingCatalog {
    inner: Arc<Mutex<ModelBindingCatalog>>,
}

struct PendingModelBindingSelectionWrite {
    catalog: InMemoryModelBindingCatalog,
    selection: ModelSelection,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ModelBindingError {
    code: String,
    message: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ResolvedModelBinding {
    model: ModelDescriptor,
    egress_decision: Option<DataEgressDecision>,
    approval_grant: Option<ApprovalGrant>,
}

pub type ModelBindingResult<T> = Result<T, ModelBindingError>;

impl ModelBindingId {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl ModelCatalogVersion {
    pub fn new(value: u64) -> Self {
        Self(value)
    }

    pub fn as_u64(&self) -> u64 {
        self.0
    }

    pub fn is_published(&self) -> bool {
        self.0 > 0
    }
}

impl ModelSelection {
    pub fn new(
        binding_id: ModelBindingId,
        provider_account_id: impl Into<String>,
        provider_id: impl Into<String>,
        model_id: impl Into<String>,
        catalog_version: ModelCatalogVersion,
    ) -> Self {
        Self {
            binding_id,
            provider_account_id: provider_account_id.into(),
            provider_id: provider_id.into(),
            model_id: model_id.into(),
            catalog_version,
        }
    }

    pub fn binding_id(&self) -> &ModelBindingId {
        &self.binding_id
    }

    pub fn provider_account_id(&self) -> &str {
        &self.provider_account_id
    }

    pub fn provider_id(&self) -> &str {
        &self.provider_id
    }

    pub fn model_id(&self) -> &str {
        &self.model_id
    }

    pub fn catalog_version(&self) -> ModelCatalogVersion {
        self.catalog_version
    }

    pub fn is_pinnable(&self) -> bool {
        !self.binding_id.as_str().trim().is_empty()
            && !self.provider_account_id.trim().is_empty()
            && !self.provider_id.trim().is_empty()
            && !self.model_id.trim().is_empty()
            && self.catalog_version.is_published()
    }
}

impl ModelBindingCatalog {
    pub fn try_with_selection(mut self, selection: ModelSelection) -> ModelBindingResult<Self> {
        if !selection.is_pinnable() {
            return Err(ModelBindingError::new(
                "model_binding_catalog.selection_not_pinnable",
                "model binding catalog selections must include provider account, provider, model id, and published catalog version",
            ));
        }
        if self.selections.contains_key(selection.binding_id()) {
            return Err(ModelBindingError::new(
                "model_binding_catalog.duplicate_binding_id",
                "model binding catalog cannot contain duplicate binding ids",
            ));
        }
        self.selections
            .insert(selection.binding_id().clone(), selection);
        Ok(self)
    }

    pub fn with_selection(mut self, selection: ModelSelection) -> Self {
        if !selection.is_pinnable() {
            panic!("model binding catalog selections must be pinnable");
        }
        if self.selections.contains_key(selection.binding_id()) {
            panic!("model binding catalog cannot contain duplicate binding ids");
        }
        self.selections
            .insert(selection.binding_id().clone(), selection);
        self
    }

    pub fn selection(&self, binding_id: &ModelBindingId) -> Option<&ModelSelection> {
        self.selections.get(binding_id)
    }

    pub fn contains_exact_selection(&self, selection: &ModelSelection) -> bool {
        self.selection(selection.binding_id())
            .map(|registered| registered == selection)
            .unwrap_or(false)
    }
}

impl InMemoryModelBindingCatalog {
    pub fn stage(&self, tx: &mut UnitOfWork, selection: ModelSelection) -> StorageResult<()> {
        tx.push_store_write(Box::new(PendingModelBindingSelectionWrite {
            catalog: self.clone(),
            selection,
        }));
        Ok(())
    }

    pub fn selection(&self, binding_id: &ModelBindingId) -> Option<ModelSelection> {
        self.inner
            .lock()
            .expect("model binding catalog mutex poisoned")
            .selection(binding_id)
            .cloned()
    }

    pub fn contains_exact_selection(&self, selection: &ModelSelection) -> bool {
        self.inner
            .lock()
            .expect("model binding catalog mutex poisoned")
            .contains_exact_selection(selection)
    }

    fn validate_selection(&self, selection: &ModelSelection) -> StorageResult<()> {
        if !selection.is_pinnable() {
            return Err(StorageError::new(
                "model_binding_catalog.selection_not_pinnable",
                "model binding catalog selections must include provider account, provider, model id, and published catalog version",
            ));
        }
        let inner = self
            .inner
            .lock()
            .expect("model binding catalog mutex poisoned");
        if inner.selection(selection.binding_id()).is_some() {
            return Err(StorageError::new(
                "model_binding_catalog.duplicate_binding_id",
                "model binding catalog cannot contain duplicate binding ids",
            ));
        }
        Ok(())
    }

    fn commit_selection(&self, selection: ModelSelection) {
        let mut inner = self
            .inner
            .lock()
            .expect("model binding catalog mutex poisoned");
        inner
            .selections
            .insert(selection.binding_id().clone(), selection);
    }
}

impl PendingStoreWrite for PendingModelBindingSelectionWrite {
    fn validate(&self) -> StorageResult<()> {
        self.catalog.validate_selection(&self.selection)
    }

    fn commit(self: Box<Self>) {
        self.catalog.commit_selection(self.selection);
    }
}

impl ModelBindingError {
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }

    pub fn code(&self) -> &str {
        &self.code
    }

    pub fn message(&self) -> &str {
        &self.message
    }
}

impl ResolvedModelBinding {
    pub fn local(model: ModelDescriptor) -> Self {
        Self {
            model,
            egress_decision: None,
            approval_grant: None,
        }
    }

    pub fn remote(
        model: ModelDescriptor,
        destination: impl AsRef<str>,
        egress_decision: DataEgressDecision,
        approval_grant: Option<ApprovalGrant>,
    ) -> ModelBindingResult<Self> {
        validate_remote_binding(
            &model,
            destination.as_ref(),
            &egress_decision,
            approval_grant.as_ref(),
        )?;

        Ok(Self {
            model,
            egress_decision: Some(egress_decision),
            approval_grant,
        })
    }

    pub fn model(&self) -> &ModelDescriptor {
        &self.model
    }

    pub fn egress_decision(&self) -> Option<&DataEgressDecision> {
        self.egress_decision.as_ref()
    }

    pub fn approval_grant(&self) -> Option<&ApprovalGrant> {
        self.approval_grant.as_ref()
    }
}

fn validate_remote_binding(
    model: &ModelDescriptor,
    destination: &str,
    decision: &DataEgressDecision,
    grant: Option<&ApprovalGrant>,
) -> ModelBindingResult<()> {
    if !model
        .supported_formats
        .iter()
        .any(|format| *format == ModelFormat::RemoteChat)
    {
        return Err(ModelBindingError::new(
            "model_binding.remote_model_required",
            "remote resolved model binding requires a remote chat model",
        ));
    }

    let operation = OperationDescriptor::new("remote.inference.generate");
    if decision.operation() != &operation
        || !decision.allowlist_result().is_allowed()
        || decision.policy().destination().as_str() != destination
    {
        return Err(ModelBindingError::new(
            "model_binding.egress_mismatch",
            "remote resolved model binding egress decision does not match operation or destination",
        ));
    }

    if decision.approval_requirement() == ApprovalRequirement::Required
        && !grant
            .map(|grant| grant.matches_egress(&operation, decision))
            .unwrap_or(false)
    {
        return Err(ModelBindingError::new(
            "model_binding.approval_required",
            "remote resolved model binding requires a matching approval grant",
        ));
    }

    Ok(())
}
