use std::fmt;

use serde::{Deserialize, Serialize};

use super::LLMBindingSchema;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum GlobalRunLeaseState {
    Preparing,
    Active,
    Releasing,
}

impl GlobalRunLeaseState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Preparing => "preparing",
            Self::Active => "active",
            Self::Releasing => "releasing",
        }
    }

    #[allow(clippy::should_implement_trait)]
    pub fn from_str(value: &str) -> Result<Self, GlobalRunLeaseError> {
        match value {
            "preparing" => Ok(Self::Preparing),
            "active" => Ok(Self::Active),
            "releasing" => Ok(Self::Releasing),
            _ => Err(GlobalRunLeaseError::new(
                "execution.global_run_lease_invalid",
                format!("unknown global run lease state: {value}"),
            )),
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct GlobalRunLease {
    generation: u64,
    owner_run_id: Option<String>,
    preparation_id: Option<String>,
    binding_schema: LLMBindingSchema,
    host_process_epoch: String,
    state: GlobalRunLeaseState,
    preparation_expiration: Option<u64>,
}

impl GlobalRunLease {
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn new(
        generation: u64,
        owner_run_id: Option<String>,
        preparation_id: Option<String>,
        binding_schema: LLMBindingSchema,
        host_process_epoch: String,
        state: GlobalRunLeaseState,
        preparation_expiration: Option<u64>,
    ) -> Self {
        Self {
            generation,
            owner_run_id,
            preparation_id,
            binding_schema,
            host_process_epoch,
            state,
            preparation_expiration,
        }
    }

    pub fn generation(&self) -> u64 {
        self.generation
    }
    pub fn owner_run_id(&self) -> Option<&str> {
        self.owner_run_id.as_deref()
    }
    pub fn preparation_id(&self) -> Option<&str> {
        self.preparation_id.as_deref()
    }
    pub fn binding_schema(&self) -> LLMBindingSchema {
        self.binding_schema
    }
    pub fn host_process_epoch(&self) -> &str {
        &self.host_process_epoch
    }
    pub fn state(&self) -> GlobalRunLeaseState {
        self.state
    }
    pub fn preparation_expiration(&self) -> Option<u64> {
        self.preparation_expiration
    }

    pub(crate) fn promoted(mut self, run_id: String) -> Self {
        self.owner_run_id = Some(run_id);
        self.state = GlobalRunLeaseState::Active;
        self.preparation_expiration = None;
        self
    }
    pub(crate) fn releasing(mut self) -> Self {
        self.state = GlobalRunLeaseState::Releasing;
        self
    }
    pub(crate) fn renewed(mut self, expiration: u64) -> Self {
        self.preparation_expiration = Some(expiration);
        self
    }
    pub(crate) fn owner_matches(&self, owner_id: &str) -> bool {
        self.owner_run_id.as_deref() == Some(owner_id)
            || self.preparation_id.as_deref() == Some(owner_id)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct GlobalRunLeaseError {
    code: &'static str,
    message: String,
}

impl GlobalRunLeaseError {
    pub fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
    pub fn code(&self) -> &str {
        self.code
    }
}
impl fmt::Display for GlobalRunLeaseError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}
impl std::error::Error for GlobalRunLeaseError {}
