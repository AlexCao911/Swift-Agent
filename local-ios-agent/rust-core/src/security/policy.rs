use crate::security::permission::PermissionState;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum RiskLevel {
    ReadOnly,
    Confirm,
    Destructive,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PolicyDecision {
    Allow,
    RequireApproval(String),
    Deny(String),
}

#[derive(Clone, Debug, Default)]
pub struct PolicyEngine;

impl PolicyEngine {
    pub fn decide(&self, risk_level: &RiskLevel, tool_name: &str) -> PolicyDecision {
        match risk_level {
            RiskLevel::ReadOnly => PolicyDecision::Allow,
            RiskLevel::Confirm => {
                PolicyDecision::RequireApproval(format!("Allow tool `{tool_name}` to run?"))
            }
            RiskLevel::Destructive => PolicyDecision::Deny(format!(
                "Tool `{tool_name}` is destructive and disabled in MVP"
            )),
        }
    }

    pub fn decide_with_permission(
        &self,
        risk_level: &RiskLevel,
        tool_name: &str,
        permission_state: PermissionState,
    ) -> PolicyDecision {
        match permission_state {
            PermissionState::Denied | PermissionState::Restricted => PolicyDecision::Deny(format!(
                "Tool `{tool_name}` requires a permission that is not available"
            )),
            PermissionState::NotDetermined => PolicyDecision::RequireApproval(format!(
                "Allow tool `{tool_name}` to request permission?"
            )),
            PermissionState::Granted => self.decide(risk_level, tool_name),
        }
    }
}
