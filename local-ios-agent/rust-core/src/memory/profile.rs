use crate::core::AgentError;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MemoryProfile {
    id: String,
    retention: Option<RetentionPolicy>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RetentionPolicy {
    days: u16,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MemoryAuditEvent {
    pub code: String,
    pub profile_id: String,
    pub subject_id: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MemoryExternalWriteFailedEvent {
    pub audit: MemoryAuditEvent,
    pub reason: String,
    pub rollback_run_output: bool,
}

impl MemoryProfile {
    pub fn new(id: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            retention: None,
        }
    }

    pub fn with_retention(mut self, retention: RetentionPolicy) -> Self {
        self.retention = Some(retention);
        self
    }

    pub fn delete_memory(
        &mut self,
        memory_id: impl Into<String>,
    ) -> Result<MemoryAuditEvent, AgentError> {
        let memory_id = memory_id.into();
        if memory_id.trim().is_empty() {
            return Err(AgentError::Storage(
                "memory delete requires subject id".to_string(),
            ));
        }

        Ok(MemoryAuditEvent {
            code: "memory.deleted".to_string(),
            profile_id: self.id.clone(),
            subject_id: memory_id,
        })
    }

    pub fn retention(&self) -> Option<&RetentionPolicy> {
        self.retention.as_ref()
    }

    pub fn external_write_failed(
        &self,
        provider_id: impl Into<String>,
        reason: impl Into<String>,
    ) -> MemoryExternalWriteFailedEvent {
        MemoryExternalWriteFailedEvent {
            audit: MemoryAuditEvent {
                code: "memory.external_write_failed".to_string(),
                profile_id: self.id.clone(),
                subject_id: provider_id.into(),
            },
            reason: reason.into(),
            rollback_run_output: false,
        }
    }
}

impl RetentionPolicy {
    pub fn days(days: u16) -> Self {
        Self { days }
    }

    pub fn day_count(&self) -> u16 {
        self.days
    }
}
