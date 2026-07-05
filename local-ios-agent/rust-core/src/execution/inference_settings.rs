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
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::thread;

    fn options() -> RuntimeOptions {
        RuntimeOptions {
            system_prompt: "system".to_string(),
            runtime_policy: "policy".to_string(),
            temperature: Some(0.2),
            top_p: Some(0.9),
        }
    }

    #[test]
    fn runtime_options_recovers_after_poisoned_lock() {
        let settings = InferenceSettingsService::default();
        settings.update_runtime_options(options()).unwrap();

        let poisoned = settings.clone();
        let _ = thread::spawn(move || {
            let _guard = poisoned
                .runtime_options
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            panic!("poison inference settings");
        })
        .join();

        assert_eq!(settings.runtime_options(), Some(options()));
    }
}
