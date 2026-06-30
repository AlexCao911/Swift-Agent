use crate::user_customization::ComponentContent;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ComponentValidationIssue {
    pub code: String,
    pub message: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ComponentValidationReport {
    pub is_valid: bool,
    pub issues: Vec<ComponentValidationIssue>,
}

impl ComponentValidationReport {
    pub fn valid() -> Self {
        Self {
            is_valid: true,
            issues: Vec::new(),
        }
    }

    pub fn invalid(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            is_valid: false,
            issues: vec![ComponentValidationIssue {
                code: code.into(),
                message: message.into(),
            }],
        }
    }
}

#[derive(Clone, Debug, Default)]
pub struct ComponentValidator;

impl ComponentValidator {
    pub fn validate(&self, content: &ComponentContent) -> ComponentValidationReport {
        match content {
            ComponentContent::Prompt(prompt) if prompt.text.trim().is_empty() => {
                ComponentValidationReport::invalid("prompt.empty", "Prompt text cannot be empty")
            }
            ComponentContent::Persona(persona) if persona.name.trim().is_empty() => {
                ComponentValidationReport::invalid("persona.empty", "Persona name cannot be empty")
            }
            ComponentContent::ToolRecipe(recipe) if recipe.name.trim().is_empty() => {
                ComponentValidationReport::invalid(
                    "tool_recipe.name.empty",
                    "Tool recipe name cannot be empty",
                )
            }
            _ => ComponentValidationReport::valid(),
        }
    }
}
