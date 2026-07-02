use std::sync::{Arc, Mutex};

#[derive(Clone, Debug, Default)]
pub struct InferenceSettingsService {
    runtime_options: Arc<Mutex<Option<RuntimeOptions>>>,
}

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

    pub fn update_runtime_options(&self, options: RuntimeOptions) -> Result<(), String> {
        *self
            .runtime_options
            .lock()
            .map_err(|_| "inference settings lock poisoned".to_string())? = Some(options);
        Ok(())
    }

    pub fn runtime_options(&self) -> Option<RuntimeOptions> {
        self.runtime_options
            .lock()
            .expect("inference settings lock poisoned")
            .clone()
    }
}
