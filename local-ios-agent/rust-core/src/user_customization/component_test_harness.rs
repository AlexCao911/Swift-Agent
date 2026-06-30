use crate::user_customization::{ComponentContent, ComponentValidationReport, ComponentValidator};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ComponentDryRunReport {
    pub validation: ComponentValidationReport,
    pub runtime_effects: Vec<String>,
    pub boundary: String,
}

#[derive(Clone, Debug, Default)]
pub struct ComponentTestHarness {
    validator: ComponentValidator,
}

impl ComponentTestHarness {
    pub fn dry_run(&self, content: &ComponentContent) -> ComponentDryRunReport {
        ComponentDryRunReport {
            validation: self.validator.validate(content),
            runtime_effects: Vec::new(),
            boundary: "schema_only".to_string(),
        }
    }
}
