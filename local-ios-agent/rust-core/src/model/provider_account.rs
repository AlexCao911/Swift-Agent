use crate::security::{
    ApprovalGrant, ApprovalRequirement, CredentialPurpose, CredentialRef, DataEgressDecision,
    OperationDescriptor,
};

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ProviderAccountKind {
    Local,
    Remote,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProviderAccount {
    pub id: String,
    pub provider_id: String,
    kind: ProviderAccountKind,
    destination: Option<String>,
    credential_ref: Option<CredentialRef>,
}

impl ProviderAccount {
    pub fn local(id: impl Into<String>, provider_id: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            provider_id: provider_id.into(),
            kind: ProviderAccountKind::Local,
            destination: None,
            credential_ref: None,
        }
    }

    pub fn remote(
        id: impl Into<String>,
        provider_id: impl Into<String>,
        destination: impl Into<String>,
        credential_ref: CredentialRef,
    ) -> Self {
        Self {
            id: id.into(),
            provider_id: provider_id.into(),
            kind: ProviderAccountKind::Remote,
            destination: Some(destination.into()),
            credential_ref: Some(credential_ref),
        }
    }

    pub fn destination(&self) -> Option<&str> {
        self.destination.as_deref()
    }

    pub fn credential_ref(&self) -> Option<&CredentialRef> {
        self.credential_ref.as_ref()
    }

    pub fn kind(&self) -> &ProviderAccountKind {
        &self.kind
    }

    pub fn is_remote(&self) -> bool {
        self.kind == ProviderAccountKind::Remote
    }

    pub fn is_local(&self) -> bool {
        self.kind == ProviderAccountKind::Local
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ModelProviderIssue {
    pub code: String,
    pub message: String,
}

impl ModelProviderIssue {
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }
}

pub type ModelProviderResult<T> = Result<T, ModelProviderIssue>;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProviderAccountValidation {
    pub is_valid: bool,
    pub issues: Vec<ModelProviderIssue>,
}

impl ProviderAccountValidation {
    pub fn valid() -> Self {
        Self {
            is_valid: true,
            issues: Vec::new(),
        }
    }

    pub fn from_egress_gate(is_approved: bool) -> Self {
        if is_approved {
            return Self::valid();
        }

        Self {
            is_valid: false,
            issues: vec![ModelProviderIssue::new(
                "model.egress_approval_required",
                "remote provider operation requires matching egress approval",
            )],
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProviderAccountValidationRequest {
    kind: ProviderAccountValidationRequestKind,
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum ProviderAccountValidationRequestKind {
    Local { account: ProviderAccount },
    Remote(RemoteProviderRequest),
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct RemoteProviderRequest {
    account: ProviderAccount,
    egress_decision: DataEgressDecision,
    approval_grant: Option<ApprovalGrant>,
    credential_purpose: CredentialPurpose,
}

impl ProviderAccountValidationRequest {
    const REMOTE_OPERATION: &'static str = "remote.provider.validate_account";

    pub fn local(account: ProviderAccount) -> ModelProviderResult<Self> {
        ensure_local_account(&account)?;
        Ok(Self {
            kind: ProviderAccountValidationRequestKind::Local { account },
        })
    }

    pub fn remote(
        account: ProviderAccount,
        egress_decision: DataEgressDecision,
        approval_grant: Option<ApprovalGrant>,
        credential_purpose: CredentialPurpose,
    ) -> ModelProviderResult<Self> {
        ensure_remote_account(&account)?;
        Ok(Self {
            kind: ProviderAccountValidationRequestKind::Remote(RemoteProviderRequest {
                account,
                egress_decision,
                approval_grant,
                credential_purpose,
            }),
        })
    }

    pub fn remote_operation() -> OperationDescriptor {
        OperationDescriptor::new(Self::REMOTE_OPERATION)
    }

    pub fn account(&self) -> &ProviderAccount {
        match &self.kind {
            ProviderAccountValidationRequestKind::Local { account } => account,
            ProviderAccountValidationRequestKind::Remote(request) => &request.account,
        }
    }

    pub fn egress_decision(&self) -> Option<&DataEgressDecision> {
        match &self.kind {
            ProviderAccountValidationRequestKind::Local { .. } => None,
            ProviderAccountValidationRequestKind::Remote(request) => Some(&request.egress_decision),
        }
    }

    pub fn remote_egress_is_approved(&self) -> bool {
        match &self.kind {
            ProviderAccountValidationRequestKind::Local { .. } => false,
            ProviderAccountValidationRequestKind::Remote(request) => remote_egress_is_approved(
                &request.account,
                &request.egress_decision,
                request.approval_grant.as_ref(),
                request.credential_purpose,
                &Self::remote_operation(),
            ),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ModelListRequest {
    kind: ModelListRequestKind,
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum ModelListRequestKind {
    Local { account: ProviderAccount },
    Remote(RemoteProviderRequest),
}

impl ModelListRequest {
    const REMOTE_OPERATION: &'static str = "remote.provider.list_models";

    pub fn local(account: ProviderAccount) -> ModelProviderResult<Self> {
        ensure_local_account(&account)?;
        Ok(Self {
            kind: ModelListRequestKind::Local { account },
        })
    }

    pub fn remote(
        account: ProviderAccount,
        egress_decision: DataEgressDecision,
        approval_grant: Option<ApprovalGrant>,
        credential_purpose: CredentialPurpose,
    ) -> ModelProviderResult<Self> {
        ensure_remote_account(&account)?;
        Ok(Self {
            kind: ModelListRequestKind::Remote(RemoteProviderRequest {
                account,
                egress_decision,
                approval_grant,
                credential_purpose,
            }),
        })
    }

    pub fn remote_operation() -> OperationDescriptor {
        OperationDescriptor::new(Self::REMOTE_OPERATION)
    }

    pub fn account(&self) -> &ProviderAccount {
        match &self.kind {
            ModelListRequestKind::Local { account } => account,
            ModelListRequestKind::Remote(request) => &request.account,
        }
    }

    pub fn egress_decision(&self) -> Option<&DataEgressDecision> {
        match &self.kind {
            ModelListRequestKind::Local { .. } => None,
            ModelListRequestKind::Remote(request) => Some(&request.egress_decision),
        }
    }

    pub fn remote_egress_is_approved(&self) -> bool {
        match &self.kind {
            ModelListRequestKind::Local { .. } => false,
            ModelListRequestKind::Remote(request) => remote_egress_is_approved(
                &request.account,
                &request.egress_decision,
                request.approval_grant.as_ref(),
                request.credential_purpose,
                &Self::remote_operation(),
            ),
        }
    }
}

fn remote_egress_is_approved(
    account: &ProviderAccount,
    decision: &DataEgressDecision,
    grant: Option<&ApprovalGrant>,
    credential_purpose: CredentialPurpose,
    operation: &OperationDescriptor,
) -> bool {
    let Some(destination) = account.destination() else {
        return false;
    };
    if !account.is_remote()
        || credential_purpose != CredentialPurpose::RemoteProvider
        || decision.operation() != operation
        || decision.policy().destination().as_str() != destination
        || !decision.allowlist_result().is_allowed()
    {
        return false;
    }

    match decision.approval_requirement() {
        ApprovalRequirement::NotRequired => true,
        ApprovalRequirement::Required => grant
            .map(|grant| grant.matches_egress(operation, decision))
            .unwrap_or(false),
    }
}

fn ensure_local_account(account: &ProviderAccount) -> ModelProviderResult<()> {
    if account.is_local() {
        return Ok(());
    }

    Err(ModelProviderIssue::new(
        "model.provider_account.kind_mismatch",
        "local provider request requires a local provider account",
    ))
}

fn ensure_remote_account(account: &ProviderAccount) -> ModelProviderResult<()> {
    if account.is_remote() && account.destination().is_some() && account.credential_ref().is_some()
    {
        return Ok(());
    }

    Err(ModelProviderIssue::new(
        "model.provider_account.kind_mismatch",
        "remote provider request requires a remote provider account",
    ))
}
