#[derive(Clone, Debug, Default)]
pub struct InferenceSettingsService;

#[derive(Clone, Debug, PartialEq)]
pub struct RuntimeOptions {
    pub system_prompt: String,
    pub runtime_policy: String,
    pub temperature: Option<f64>,
    pub top_p: Option<f64>,
}

impl InferenceSettingsService {
    pub fn active_provider_id(&self) -> Option<&str> {
        None
    }

    pub fn update_runtime_options(&self, _options: RuntimeOptions) -> Result<(), String> {
        Ok(())
    }
}
