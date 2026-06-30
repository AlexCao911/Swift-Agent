use std::collections::HashMap;

use serde::Deserialize;

use crate::core::{AgentError, EntryId, RunId, SessionId};
use crate::security::{
    ApprovalDecision, ApprovalProtocolRequest, ApprovalProtocolResponse, ApprovalRequest,
    ApprovalScope, DataEgressRequest, EgressDestination, OperationDescriptor, PermissionScope,
    PolicyDecision, SecurityManager, SecurityPermissionService, StaticSecurityPermissionService,
};
use crate::tool::{
    CompiledToolRecipe, CompiledToolRecipeContent, RetentionPolicy, Sensitivity, ToolCall,
    ToolExecutionRequest, ToolRegistry, ToolResult, ToolSchema,
};

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ToolRouteOutcome {
    ExecuteInSwift(ToolExecutionRequest),
    ApprovalRequired {
        request: ToolExecutionRequest,
        approval: ApprovalProtocolRequest,
        reason: String,
    },
    Denied(ToolResult),
}

#[derive(Clone, Debug)]
pub struct ToolRouter {
    registry: ToolRegistry,
    security: SecurityManager,
    suspended_tool_requests: HashMap<String, ToolExecutionRequest>,
}

impl ToolRouter {
    pub fn new(registry: ToolRegistry) -> Self {
        Self::with_security_manager(registry, SecurityManager::new())
    }

    pub fn with_security_manager(registry: ToolRegistry, security: SecurityManager) -> Self {
        Self {
            registry,
            security,
            suspended_tool_requests: HashMap::new(),
        }
    }

    pub fn route(
        &mut self,
        run_id: &RunId,
        session_id: &SessionId,
        tool_call_entry_id: &EntryId,
        call: ToolCall,
    ) -> Result<ToolRouteOutcome, AgentError> {
        call.validate_shape()?;
        let schema =
            self.registry.schema(&call.name).cloned().ok_or_else(|| {
                AgentError::ToolValidation(format!("unknown tool: {}", call.name))
            })?;
        let compiled_recipe = self.registry.compiled_recipe(&call.name).cloned();
        let request = ToolExecutionRequest::new(
            run_id.clone(),
            session_id.clone(),
            tool_call_entry_id.clone(),
            call,
        )
        .with_compiled_recipe(compiled_recipe);

        if let Some(outcome) =
            self.route_compiled_recipe_approval(run_id, tool_call_entry_id, &schema, &request)?
        {
            return Ok(outcome);
        }

        match self.security.decide_tool(&schema.risk_level, &schema.name) {
            PolicyDecision::Allow => Ok(ToolRouteOutcome::ExecuteInSwift(request)),
            PolicyDecision::RequireApproval(reason) => {
                let approval = self.security.request_approval(
                    format!("approval_{}", tool_call_entry_id.0),
                    run_id.clone(),
                    tool_call_entry_id.clone(),
                    reason.clone(),
                    true,
                    ApprovalScope::operation(OperationDescriptor::new(format!(
                        "tool.{}",
                        schema.name
                    ))),
                )?;
                self.suspended_tool_requests
                    .insert(approval.approval_id.clone(), request.clone());
                Ok(ToolRouteOutcome::ApprovalRequired {
                    request,
                    approval,
                    reason,
                })
            }
            PolicyDecision::Deny(reason) => Ok(ToolRouteOutcome::Denied(ToolResult {
                display_text: reason.clone(),
                model_text: reason.clone(),
                structured_json: "{}".into(),
                audit_text: reason,
                sensitivity: Sensitivity::Public,
                retention: RetentionPolicy::RunOnly,
                provenance: "tool.router.policy".into(),
                is_error: true,
            })),
        }
    }

    pub fn register(&mut self, schema: ToolSchema) -> Result<(), AgentError> {
        if let Some(scope_name) = native_permission_scope(&schema.metadata_json)? {
            self.security
                .set_tool_permission_scope(schema.name.clone(), scope_name);
        }
        self.registry.register(schema)
    }

    pub fn register_compiled_recipe(
        &mut self,
        recipe: CompiledToolRecipe,
    ) -> Result<(), AgentError> {
        self.registry.register_compiled_recipe(recipe)
    }

    pub fn set_permission(&mut self, permission: PermissionScope) {
        self.security.set_permission(permission);
    }

    pub fn prompt_schemas(&self) -> Vec<String> {
        self.registry.prompt_schemas()
    }

    pub fn pending_approvals(&self) -> Vec<ApprovalRequest> {
        self.security.pending_approvals()
    }

    pub fn pending_approval_requests(&self) -> Vec<ApprovalProtocolRequest> {
        self.security.pending_approval_requests()
    }

    pub fn resolve_approval(
        &mut self,
        response: ApprovalProtocolResponse,
    ) -> Result<
        (
            ApprovalRequest,
            ApprovalDecision,
            Option<ToolExecutionRequest>,
        ),
        AgentError,
    > {
        let (request, decision) = self.security.resolve_approval(response)?;
        let tool_request = self.suspended_tool_requests.remove(&request.approval_id);

        Ok((request, decision, tool_request))
    }

    fn route_compiled_recipe_approval(
        &mut self,
        run_id: &RunId,
        tool_call_entry_id: &EntryId,
        schema: &ToolSchema,
        request: &ToolExecutionRequest,
    ) -> Result<Option<ToolRouteOutcome>, AgentError> {
        let Some(compiled_recipe) = request.compiled_recipe.as_ref() else {
            return Ok(None);
        };
        let CompiledToolRecipeContent::HttpConnector {
            endpoint,
            policy,
            credential_ref,
        } = &compiled_recipe.content
        else {
            return Ok(None);
        };

        let destination = http_connector_destination(endpoint)?;
        if !policy
            .network_allowlist
            .iter()
            .any(|allowed| allowed.eq_ignore_ascii_case(destination.as_str()))
        {
            return Err(AgentError::PolicyDenied(format!(
                "http connector destination is not allowlisted: {destination}"
            )));
        }

        let service = StaticSecurityPermissionService::default()
            .allow_destination(EgressDestination::new(destination.clone()));
        let egress_request = if credential_ref.is_some() {
            DataEgressRequest::http_tool_with_credential(destination)
        } else {
            DataEgressRequest::http_tool(destination)
        };
        let decision = service.evaluate_egress(egress_request);
        let operation = OperationDescriptor::new(format!("tool.{}", schema.name));
        let approval = self.security.request_approval(
            format!("approval_{}", tool_call_entry_id.0),
            run_id.clone(),
            tool_call_entry_id.clone(),
            "Allow HTTP connector egress?",
            true,
            ApprovalScope::egress(operation, &decision)?,
        )?;
        self.suspended_tool_requests
            .insert(approval.approval_id.clone(), request.clone());

        Ok(Some(ToolRouteOutcome::ApprovalRequired {
            request: request.clone(),
            reason: approval.message.clone(),
            approval,
        }))
    }
}

fn http_connector_destination(endpoint: &str) -> Result<String, AgentError> {
    EgressDestination::https_origin_from_endpoint(endpoint)
        .map(|destination| destination.as_str().to_string())
        .ok_or_else(|| {
            AgentError::ToolValidation(format!("invalid http connector endpoint: {endpoint}"))
        })
}

#[derive(Deserialize)]
struct NativeToolMetadata {
    native_permission_scope: Option<String>,
}

fn native_permission_scope(metadata_json: &Option<String>) -> Result<Option<String>, AgentError> {
    let Some(metadata_json) = metadata_json else {
        return Ok(None);
    };
    let metadata: NativeToolMetadata = serde_json::from_str(metadata_json).map_err(|error| {
        AgentError::ToolValidation(format!("invalid tool metadata_json: {error}"))
    })?;
    Ok(metadata.native_permission_scope)
}
