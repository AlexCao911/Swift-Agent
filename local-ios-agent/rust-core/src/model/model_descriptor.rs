#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ModelFormat {
    RemoteChat,
    Gguf,
    LocalWeights,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ModelCapabilities {
    pub supports_chat: bool,
    pub supports_temperature: bool,
    pub supports_top_p: bool,
    pub supports_max_output_tokens: bool,
    pub supports_reasoning_effort: bool,
}

impl ModelCapabilities {
    pub fn chat() -> Self {
        Self {
            supports_chat: true,
            supports_temperature: false,
            supports_top_p: false,
            supports_max_output_tokens: false,
            supports_reasoning_effort: false,
        }
    }

    pub fn with_temperature(mut self) -> Self {
        self.supports_temperature = true;
        self
    }

    pub fn with_top_p(mut self) -> Self {
        self.supports_top_p = true;
        self
    }

    pub fn with_max_output_tokens(mut self) -> Self {
        self.supports_max_output_tokens = true;
        self
    }

    pub fn with_reasoning_effort(mut self) -> Self {
        self.supports_reasoning_effort = true;
        self
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ModelDescriptor {
    pub id: String,
    pub provider_id: String,
    pub supported_formats: Vec<ModelFormat>,
    pub capabilities: ModelCapabilities,
}

impl ModelDescriptor {
    pub fn new(id: impl Into<String>, provider_id: impl Into<String>, format: ModelFormat) -> Self {
        Self {
            id: id.into(),
            provider_id: provider_id.into(),
            supported_formats: vec![format],
            capabilities: ModelCapabilities::chat(),
        }
    }

    pub fn with_capabilities(mut self, capabilities: ModelCapabilities) -> Self {
        self.capabilities = capabilities;
        self
    }
}
