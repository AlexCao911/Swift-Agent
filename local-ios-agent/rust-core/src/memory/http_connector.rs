use crate::{
    core::AgentError,
    security::{
        ApprovalGrant, CredentialRef, DataEgressDecision, DataEgressRequest, EgressDestination,
    },
};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HttpMemoryConnectorSpec {
    endpoint: String,
    can_query: bool,
    write_configured: bool,
    write_authorized: bool,
    credential_ref: Option<CredentialRef>,
    safety_disclosure: Option<String>,
}

impl HttpMemoryConnectorSpec {
    pub fn query_only(endpoint: impl Into<String>) -> Self {
        Self {
            endpoint: endpoint.into(),
            can_query: true,
            write_configured: false,
            write_authorized: false,
            credential_ref: None,
            safety_disclosure: None,
        }
    }

    pub fn with_credential_ref(mut self, credential_ref: CredentialRef) -> Self {
        self.credential_ref = Some(credential_ref);
        self
    }

    pub fn endpoint(&self) -> &str {
        &self.endpoint
    }

    pub fn can_query(&self) -> bool {
        self.can_query
    }

    pub fn write_configured(&self) -> bool {
        self.write_configured
    }

    pub fn can_write(&self) -> bool {
        self.write_authorized
    }

    pub fn with_external_write_configured(
        self,
        safety_disclosure: impl Into<String>,
    ) -> Result<Self, AgentError> {
        let safety_disclosure = safety_disclosure.into();
        self.try_configure_external_write(Some(safety_disclosure.as_str()))
    }

    pub fn try_configure_external_write(
        mut self,
        safety_disclosure: Option<&str>,
    ) -> Result<Self, AgentError> {
        let safety_disclosure = safety_disclosure
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .ok_or_else(|| {
                AgentError::PolicyDenied(
                    "external memory write requires safety disclosure".to_string(),
                )
            })?;

        if self.credential_ref.is_none() {
            return Err(AgentError::PolicyDenied(
                "external memory write requires credential ref".to_string(),
            ));
        }

        self.safety_disclosure = Some(safety_disclosure.to_string());
        self.write_configured = true;
        self.write_authorized = false;
        Ok(self)
    }

    pub fn external_write_egress_request(&self) -> Result<DataEgressRequest, AgentError> {
        if !self.write_configured {
            return Err(AgentError::PolicyDenied(
                "external memory write is not configured".to_string(),
            ));
        }

        Ok(DataEgressRequest::external_memory_write(
            endpoint_origin(&self.endpoint)?.as_str(),
        ))
    }

    pub fn authorize_external_write(
        mut self,
        decision: &DataEgressDecision,
        grant: &ApprovalGrant,
    ) -> Result<Self, AgentError> {
        if !self.write_configured {
            return Err(AgentError::PolicyDenied(
                "external memory write is not configured".to_string(),
            ));
        }
        if decision.operation().as_str() != "external.memory.write" {
            return Err(AgentError::PolicyDenied(format!(
                "external memory write requires external.memory.write egress decision, got {}",
                decision.operation().as_str()
            )));
        }
        if decision.policy().destination() != &endpoint_origin(&self.endpoint)? {
            return Err(AgentError::PolicyDenied(
                "external memory write egress destination does not match connector endpoint"
                    .to_string(),
            ));
        }
        if !decision.allowlist_result().is_allowed() {
            return Err(AgentError::PolicyDenied(
                "external memory write egress destination is not allowlisted".to_string(),
            ));
        }
        if !grant.matches_egress(decision.operation(), decision) {
            return Err(AgentError::PolicyDenied(
                "external memory write requires matching approval grant".to_string(),
            ));
        }

        self.write_authorized = true;
        Ok(self)
    }
}

fn endpoint_origin(endpoint: &str) -> Result<EgressDestination, AgentError> {
    EgressDestination::https_origin_from_endpoint(endpoint).ok_or_else(|| {
        AgentError::PolicyDenied(format!(
            "external memory connector endpoint must be a valid https URL: {endpoint}"
        ))
    })
}
