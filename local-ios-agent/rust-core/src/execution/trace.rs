#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TraceConfig {
    capture_context_archive: bool,
    capture_prompt_archive: bool,
}

impl TraceConfig {
    pub fn capture_archives() -> Self {
        Self {
            capture_context_archive: true,
            capture_prompt_archive: true,
        }
    }

    pub fn disabled() -> Self {
        Self {
            capture_context_archive: false,
            capture_prompt_archive: false,
        }
    }

    pub fn capture_context_archive(&self) -> bool {
        self.capture_context_archive
    }

    pub fn capture_prompt_archive(&self) -> bool {
        self.capture_prompt_archive
    }
}
