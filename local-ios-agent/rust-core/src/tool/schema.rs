use crate::security::RiskLevel;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ToolSchema {
    pub name: String,
    pub description: String,
    pub parameters_json_schema: String,
    pub risk_level: RiskLevel,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ToolCall {
    pub id: String,
    pub name: String,
    pub arguments_json: String,
}
