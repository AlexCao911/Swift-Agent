use crate::security::{ApprovalRequirement, CredentialPurpose, CredentialRef};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ToolRecipeKind {
    HttpConnector,
    PureTransform,
    Alias,
    Workflow,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ToolRecipe {
    name: String,
    kind: ToolRecipeKind,
    content: ToolRecipeContent,
    requested_approval: Option<ApprovalRequirement>,
    credential_ref: Option<CredentialRef>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ToolRecipeContent {
    HttpConnector {
        endpoint: String,
        policy: HttpConnectorPolicy,
    },
    PureTransform {
        expression: String,
    },
    Alias {
        base_tool_name: String,
    },
    Workflow {
        steps: Vec<WorkflowStep>,
    },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HttpConnectorPolicy {
    pub timeout_millis: Option<u64>,
    pub retry_policy: Option<HttpRetryPolicy>,
    pub rate_limit_policy: Option<HttpRateLimitPolicy>,
    pub network_allowlist: Vec<String>,
    pub data_egress_disclosure: Option<String>,
    pub credential_purpose: Option<CredentialPurpose>,
    pub response_sensitivity: Option<HttpResponseSensitivity>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HttpRetryPolicy {
    pub max_attempts: u8,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HttpRateLimitPolicy {
    pub requests_per_minute: u16,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum HttpResponseSensitivity {
    Public,
    Private,
    Secret,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkflowStep {
    pub id: String,
    pub tool_name: String,
    pub depends_on: Vec<String>,
    pub on_failure: WorkflowFailureStrategy,
    pub compensation_for: Option<String>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WorkflowFailureStrategy {
    Stop,
    Continue,
    Compensate,
}

impl WorkflowStep {
    pub fn new<I, D>(
        id: impl Into<String>,
        tool_name: impl Into<String>,
        depends_on: I,
        on_failure: WorkflowFailureStrategy,
    ) -> Self
    where
        I: IntoIterator<Item = D>,
        D: Into<String>,
    {
        Self {
            id: id.into(),
            tool_name: tool_name.into(),
            depends_on: depends_on.into_iter().map(Into::into).collect(),
            on_failure,
            compensation_for: None,
        }
    }

    pub fn compensation(
        id: impl Into<String>,
        tool_name: impl Into<String>,
        compensation_for: impl Into<String>,
        on_failure: WorkflowFailureStrategy,
    ) -> Self {
        let compensation_for = compensation_for.into();
        Self {
            id: id.into(),
            tool_name: tool_name.into(),
            depends_on: vec![compensation_for.clone()],
            on_failure,
            compensation_for: Some(compensation_for),
        }
    }
}

impl ToolRecipe {
    pub fn http_connector(name: impl Into<String>, endpoint: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            kind: ToolRecipeKind::HttpConnector,
            content: ToolRecipeContent::HttpConnector {
                endpoint: endpoint.into(),
                policy: HttpConnectorPolicy::default(),
            },
            requested_approval: None,
            credential_ref: None,
        }
    }

    pub fn pure_transform(name: impl Into<String>, expression: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            kind: ToolRecipeKind::PureTransform,
            content: ToolRecipeContent::PureTransform {
                expression: expression.into(),
            },
            requested_approval: None,
            credential_ref: None,
        }
    }

    pub fn alias(name: impl Into<String>, base_tool_name: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            kind: ToolRecipeKind::Alias,
            content: ToolRecipeContent::Alias {
                base_tool_name: base_tool_name.into(),
            },
            requested_approval: None,
            credential_ref: None,
        }
    }

    pub fn workflow(name: impl Into<String>, steps: Vec<WorkflowStep>) -> Self {
        Self {
            name: name.into(),
            kind: ToolRecipeKind::Workflow,
            content: ToolRecipeContent::Workflow { steps },
            requested_approval: None,
            credential_ref: None,
        }
    }

    pub fn kind(&self) -> ToolRecipeKind {
        self.kind
    }

    pub fn name(&self) -> &str {
        &self.name
    }

    pub fn content(&self) -> &ToolRecipeContent {
        &self.content
    }

    pub fn requested_approval(&self) -> Option<ApprovalRequirement> {
        self.requested_approval.clone()
    }

    pub fn credential_ref(&self) -> Option<&CredentialRef> {
        self.credential_ref.as_ref()
    }

    pub fn with_requested_approval(mut self, approval: ApprovalRequirement) -> Self {
        self.requested_approval = Some(approval);
        self
    }

    pub fn with_credential_ref(mut self, credential_ref: CredentialRef) -> Self {
        self.credential_ref = Some(credential_ref);
        self
    }

    pub fn with_policy(mut self, policy: HttpConnectorPolicy) -> Self {
        if let ToolRecipeContent::HttpConnector {
            policy: existing, ..
        } = &mut self.content
        {
            *existing = policy;
        }
        self
    }
}

impl Default for HttpConnectorPolicy {
    fn default() -> Self {
        Self {
            timeout_millis: None,
            retry_policy: None,
            rate_limit_policy: None,
            network_allowlist: Vec::new(),
            data_egress_disclosure: None,
            credential_purpose: None,
            response_sensitivity: None,
        }
    }
}

impl HttpConnectorPolicy {
    pub fn complete_for_test() -> Self {
        Self {
            timeout_millis: Some(30_000),
            retry_policy: Some(HttpRetryPolicy { max_attempts: 2 }),
            rate_limit_policy: Some(HttpRateLimitPolicy {
                requests_per_minute: 60,
            }),
            network_allowlist: vec!["api.example.com".to_string()],
            data_egress_disclosure: Some("Remote lookup sends query data".to_string()),
            credential_purpose: Some(CredentialPurpose::HttpTool),
            response_sensitivity: Some(HttpResponseSensitivity::Private),
        }
    }

    pub fn missing_timeout_for_test() -> Self {
        Self::default()
    }

    pub fn without_credential_purpose_for_test(mut self) -> Self {
        self.credential_purpose = None;
        self
    }

    pub fn with_network_allowlist_for_test<I, S>(mut self, allowlist: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        self.network_allowlist = allowlist.into_iter().map(Into::into).collect();
        self
    }
}
