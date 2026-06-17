use std::collections::HashMap;

use crate::core::AgentError;
use crate::tool::ToolSchema;

#[derive(Clone, Debug, Default)]
pub struct ToolRegistry {
    schemas: HashMap<String, ToolSchema>,
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

    pub fn schema(&self, name: &str) -> Option<&ToolSchema> {
        self.schemas.get(name)
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
