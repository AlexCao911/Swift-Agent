use std::collections::HashMap;

use serde_json::json;

use crate::core::AgentError;
use crate::security::{ApprovalRequirement, RiskLevel};
use crate::tool::{CompiledToolRecipe, ToolRecipeKind, ToolSchema};

#[derive(Clone, Debug, Default)]
pub struct ToolRegistry {
    schemas: HashMap<String, ToolSchema>,
    compiled_recipes: HashMap<String, CompiledToolRecipe>,
}

impl ToolRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn register(&mut self, schema: ToolSchema) -> Result<(), AgentError> {
        if self.schemas.contains_key(&schema.name) {
            return Err(AgentError::ToolValidation(format!(
                "tool already registered: {}",
                schema.name
            )));
        }
        self.schemas.insert(schema.name.clone(), schema);
        Ok(())
    }

    pub fn register_compiled_recipe(
        &mut self,
        recipe: CompiledToolRecipe,
    ) -> Result<(), AgentError> {
        let schema = compiled_recipe_schema(&recipe);
        self.register(schema)?;
        self.compiled_recipes.insert(recipe.name.clone(), recipe);
        Ok(())
    }

    pub fn schema(&self, name: &str) -> Option<&ToolSchema> {
        self.schemas.get(name)
    }

    pub fn compiled_recipe(&self, name: &str) -> Option<&CompiledToolRecipe> {
        self.compiled_recipes.get(name)
    }

    pub fn prompt_schemas(&self) -> Vec<String> {
        let mut schemas: Vec<_> = self
            .schemas
            .values()
            .map(|schema| {
                format!(
                    "{}: {} params={}",
                    schema.name, schema.description, schema.parameters_json_schema
                )
            })
            .collect();
        schemas.sort();
        schemas
    }
}

fn compiled_recipe_schema(recipe: &CompiledToolRecipe) -> ToolSchema {
    ToolSchema {
        name: recipe.name.clone(),
        description: compiled_recipe_description(recipe.kind),
        parameters_json_schema: r#"{"type":"object","additionalProperties":true}"#.to_string(),
        risk_level: risk_level_for_approval(recipe.approval_requirement.clone()),
        metadata_json: Some(
            json!({
                "compiled_tool_recipe": true,
                "recipe_kind": compiled_recipe_kind(recipe.kind),
                "approval_requirement": approval_requirement_name(recipe.approval_requirement.clone()),
                "has_side_effects": recipe.has_side_effects,
                "base_tools": recipe.base_tools,
            })
            .to_string(),
        ),
    }
}

fn compiled_recipe_description(kind: ToolRecipeKind) -> String {
    match kind {
        ToolRecipeKind::HttpConnector => "Compiled HTTP connector recipe.".to_string(),
        ToolRecipeKind::PureTransform => "Compiled pure transform recipe.".to_string(),
        ToolRecipeKind::Alias => "Compiled tool alias recipe.".to_string(),
        ToolRecipeKind::Workflow => "Compiled workflow recipe.".to_string(),
    }
}

fn risk_level_for_approval(approval: ApprovalRequirement) -> RiskLevel {
    match approval {
        ApprovalRequirement::Required => RiskLevel::Confirm,
        ApprovalRequirement::NotRequired => RiskLevel::ReadOnly,
    }
}

fn compiled_recipe_kind(kind: ToolRecipeKind) -> &'static str {
    match kind {
        ToolRecipeKind::HttpConnector => "http_connector",
        ToolRecipeKind::PureTransform => "pure_transform",
        ToolRecipeKind::Alias => "alias",
        ToolRecipeKind::Workflow => "workflow",
    }
}

fn approval_requirement_name(approval: ApprovalRequirement) -> &'static str {
    match approval {
        ApprovalRequirement::Required => "required",
        ApprovalRequirement::NotRequired => "not_required",
    }
}
