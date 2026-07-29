use std::fmt;
use std::sync::Arc;

use serde::{Deserialize, Serialize};

use crate::canonical_digest::CanonicalDigestV1;
use crate::migration::LegacyAgentProfileTranslator;
use crate::storage::{RuntimeStateError, UnifiedRuntimeStateRepository};
use crate::user_customization::{AgentProfileId, AgentProfileVersion};

use super::{AgentLLMRequirements, HostBindingActivationConfirmation};

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct BeginLegacyProfileMigration {
    attempt_id: String,
    profile_id: String,
    profile_revision: u64,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct LegacyProfileMigrationRecord {
    source_profile_id: AgentProfileId,
    source_revision: AgentProfileVersion,
    source_digest: String,
    state: LegacyProfileMigrationState,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum LegacyProfileMigrationState {
    Pending {
        #[serde(skip_serializing_if = "Option::is_none")]
        attempt: Option<LegacyProfileMigrationAttempt>,
    },
    Migrated {
        successor: LegacyProfileSuccessorSubject,
    },
    Archived,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct LegacyProfileMigrationAttempt {
    attempt_id: String,
    successor: LegacyProfileSuccessorSubject,
    host_binding_operation_id: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct LegacyProfileSuccessorSubject {
    profile_id: String,
    profile_revision: u64,
    llm_slot_id: String,
    requirements_hash: String,
    host_binding_operation_id: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct LegacyMigrationAction {
    migration_subject: String,
    source_digest: String,
    display_name: String,
    requirements: AgentLLMRequirements,
    #[serde(skip_serializing_if = "Option::is_none")]
    redacted_model_hint: Option<String>,
    state: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    successor: Option<LegacyProfileSuccessorSubject>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LegacyProfileMigrationError {
    code: String,
    message: String,
}

#[derive(Clone)]
pub struct LegacyProfileMigrationService {
    repository: Arc<dyn UnifiedRuntimeStateRepository>,
}

impl BeginLegacyProfileMigration {
    pub fn new(
        attempt_id: impl Into<String>,
        profile_id: impl Into<String>,
        profile_revision: u64,
    ) -> Self {
        Self {
            attempt_id: attempt_id.into(),
            profile_id: profile_id.into(),
            profile_revision,
        }
    }

    pub fn attempt_id(&self) -> &str {
        &self.attempt_id
    }

    pub fn profile_id(&self) -> &str {
        &self.profile_id
    }

    pub fn profile_revision(&self) -> u64 {
        self.profile_revision
    }
}

impl LegacyProfileMigrationRecord {
    pub fn pending_source(
        source_profile_id: AgentProfileId,
        source_revision: AgentProfileVersion,
        source_digest: impl Into<String>,
    ) -> Self {
        Self {
            source_profile_id,
            source_revision,
            source_digest: source_digest.into(),
            state: LegacyProfileMigrationState::Pending { attempt: None },
        }
    }

    pub fn new_pending(
        source_profile_id: AgentProfileId,
        source_revision: AgentProfileVersion,
        source_digest: impl Into<String>,
        attempt: LegacyProfileMigrationAttempt,
    ) -> Self {
        Self {
            source_profile_id,
            source_revision,
            source_digest: source_digest.into(),
            state: LegacyProfileMigrationState::Pending {
                attempt: Some(attempt),
            },
        }
    }

    pub fn source_profile_id(&self) -> &AgentProfileId {
        &self.source_profile_id
    }

    pub fn source_revision(&self) -> AgentProfileVersion {
        self.source_revision
    }

    pub fn source_digest(&self) -> &str {
        &self.source_digest
    }

    pub fn state(&self) -> &LegacyProfileMigrationState {
        &self.state
    }

    pub(crate) fn with_state(mut self, state: LegacyProfileMigrationState) -> Self {
        self.state = state;
        self
    }
}

impl LegacyProfileMigrationAttempt {
    pub fn new(
        attempt_id: impl Into<String>,
        successor: LegacyProfileSuccessorSubject,
        host_binding_operation_id: impl Into<String>,
    ) -> Self {
        Self {
            attempt_id: attempt_id.into(),
            successor,
            host_binding_operation_id: host_binding_operation_id.into(),
        }
    }

    pub fn attempt_id(&self) -> &str {
        &self.attempt_id
    }

    pub fn successor(&self) -> &LegacyProfileSuccessorSubject {
        &self.successor
    }

    pub fn host_binding_operation_id(&self) -> &str {
        &self.host_binding_operation_id
    }
}

impl LegacyProfileSuccessorSubject {
    pub fn new(
        profile_id: impl Into<String>,
        profile_revision: u64,
        llm_slot_id: impl Into<String>,
        requirements_hash: impl Into<String>,
        host_binding_operation_id: impl Into<String>,
    ) -> Self {
        Self {
            profile_id: profile_id.into(),
            profile_revision,
            llm_slot_id: llm_slot_id.into(),
            requirements_hash: requirements_hash.into(),
            host_binding_operation_id: host_binding_operation_id.into(),
        }
    }

    pub fn profile_id(&self) -> &str {
        &self.profile_id
    }
    pub fn profile_revision(&self) -> u64 {
        self.profile_revision
    }
    pub fn llm_slot_id(&self) -> &str {
        &self.llm_slot_id
    }
    pub fn requirements_hash(&self) -> &str {
        &self.requirements_hash
    }
    pub fn host_binding_operation_id(&self) -> &str {
        &self.host_binding_operation_id
    }
}

impl LegacyMigrationAction {
    pub fn migration_subject(&self) -> &str {
        &self.migration_subject
    }

    pub fn source_digest(&self) -> &str {
        &self.source_digest
    }

    pub fn display_name(&self) -> &str {
        &self.display_name
    }

    pub fn redacted_model_hint(&self) -> Option<&str> {
        self.redacted_model_hint.as_deref()
    }

    pub fn successor(&self) -> Option<&LegacyProfileSuccessorSubject> {
        self.successor.as_ref()
    }
}

impl LegacyProfileMigrationService {
    pub fn new(repository: Arc<dyn UnifiedRuntimeStateRepository>) -> Self {
        Self { repository }
    }

    pub fn begin(
        &self,
        request: BeginLegacyProfileMigration,
    ) -> Result<LegacyMigrationAction, LegacyProfileMigrationError> {
        if request.attempt_id.trim().is_empty() {
            return Err(error(
                "legacy_profile.attempt_invalid",
                "migration attempt ID is empty",
            ));
        }
        let source_json = self
            .repository
            .legacy_agent_profile_record(
                &AgentProfileId::new(request.profile_id()),
                AgentProfileVersion::new(request.profile_revision()),
            )
            .map_err(storage_error)?
            .ok_or_else(|| {
                error(
                    "legacy_profile.source_missing",
                    "legacy migration source Profile does not exist",
                )
            })?;
        let translated = LegacyAgentProfileTranslator::translate_record(&source_json)
            .map_err(translation_error)?;
        let source_digest =
            LegacyAgentProfileTranslator::source_digest(&source_json).map_err(translation_error)?;
        let requirements = translated.llm_slot().requirements().clone();
        if let Some(existing) = self
            .repository
            .legacy_profile_migration_record(&source_digest)
            .map_err(storage_error)?
        {
            match existing.state() {
                LegacyProfileMigrationState::Pending {
                    attempt: Some(attempt),
                } if attempt.attempt_id() == request.attempt_id() => {
                    return Ok(action_from_record(&existing, &translated, &requirements));
                }
                LegacyProfileMigrationState::Migrated { .. }
                | LegacyProfileMigrationState::Archived => {
                    return Ok(action_from_record(&existing, &translated, &requirements));
                }
                LegacyProfileMigrationState::Pending { attempt: Some(_) } => {
                    return Err(error(
                        "legacy_profile.attempt_conflict",
                        "legacy source already has a different active migration attempt",
                    ));
                }
                LegacyProfileMigrationState::Pending { attempt: None } => {}
            }
        }
        let requirements_hash = CanonicalDigestV1::digest("agent-requirements:v1", &requirements)
            .map_err(|digest| {
                error(
                    "legacy_profile.requirements_digest_failed",
                    digest.to_string(),
                )
            })?
            .as_str()
            .to_string();
        let operation_id = format!("legacy-migration.{}", request.attempt_id());
        let successor = translated.successor().clone();
        let subject = LegacyProfileSuccessorSubject::new(
            successor.id().as_str(),
            successor.version().as_u64(),
            requirements.slot_id(),
            requirements_hash,
            &operation_id,
        );
        let attempt = LegacyProfileMigrationAttempt::new(
            request.attempt_id(),
            subject.clone(),
            &operation_id,
        );
        let record = LegacyProfileMigrationRecord::new_pending(
            translated.source_profile_id().clone(),
            translated.source_revision(),
            &source_digest,
            attempt,
        );
        let components = translated
            .component_bindings()
            .iter()
            .map(|binding| {
                self.repository
                    .agent_component_exact(binding.component_version_id())
                    .map_err(storage_error)?
                    .ok_or_else(|| {
                        error(
                            "legacy_profile.component_missing",
                            "legacy source references a missing component revision",
                        )
                    })
            })
            .collect::<Result<Vec<_>, _>>()?;
        let record = self
            .repository
            .begin_legacy_profile_migration(record, successor, components)
            .map_err(storage_error)?;
        Ok(action_from_record(&record, &translated, &requirements))
    }

    pub fn complete(
        &self,
        confirmation: HostBindingActivationConfirmation,
    ) -> Result<LegacyProfileMigrationRecord, LegacyProfileMigrationError> {
        self.repository
            .complete_legacy_profile_migration(confirmation)
            .map_err(storage_error)
    }

    pub fn records(
        &self,
    ) -> Result<Vec<LegacyProfileMigrationRecord>, LegacyProfileMigrationError> {
        for source_json in self
            .repository
            .legacy_agent_profile_records()
            .map_err(storage_error)?
        {
            let source = LegacyAgentProfileTranslator::translate_record(&source_json)
                .map_err(translation_error)?;
            let source_digest = LegacyAgentProfileTranslator::source_digest(&source_json)
                .map_err(translation_error)?;
            self.repository
                .ensure_legacy_profile_migration_record(
                    LegacyProfileMigrationRecord::pending_source(
                        source.source_profile_id().clone(),
                        source.source_revision(),
                        source_digest,
                    ),
                )
                .map_err(storage_error)?;
        }
        self.repository
            .legacy_profile_migration_records()
            .map_err(storage_error)
    }

    pub fn actions(&self) -> Result<Vec<LegacyMigrationAction>, LegacyProfileMigrationError> {
        self.records()?
            .into_iter()
            .map(|record| {
                let source_json = self
                    .repository
                    .legacy_agent_profile_record(
                        record.source_profile_id(),
                        record.source_revision(),
                    )
                    .map_err(storage_error)?
                    .ok_or_else(|| {
                        error(
                            "legacy_profile.source_missing",
                            "legacy migration source Profile does not exist",
                        )
                    })?;
                let translated = LegacyAgentProfileTranslator::translate_record(&source_json)
                    .map_err(translation_error)?;
                Ok(action_from_record(
                    &record,
                    &translated,
                    translated.llm_slot().requirements(),
                ))
            })
            .collect()
    }

    pub fn record(
        &self,
        source_digest: &str,
    ) -> Result<Option<LegacyProfileMigrationRecord>, LegacyProfileMigrationError> {
        self.repository
            .legacy_profile_migration_record(source_digest)
            .map_err(storage_error)
    }

    pub fn abandon(
        &self,
        source_digest: &str,
        attempt_id: &str,
    ) -> Result<LegacyProfileMigrationRecord, LegacyProfileMigrationError> {
        self.repository
            .abandon_legacy_profile_migration(source_digest, attempt_id)
            .map_err(storage_error)
    }

    pub fn archive(
        &self,
        source_digest: &str,
    ) -> Result<LegacyProfileMigrationRecord, LegacyProfileMigrationError> {
        self.repository
            .archive_legacy_profile_migration(source_digest)
            .map_err(storage_error)
    }
}

impl LegacyProfileMigrationError {
    pub fn code(&self) -> &str {
        &self.code
    }
}

impl fmt::Display for LegacyProfileMigrationError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for LegacyProfileMigrationError {}

fn action_from_record(
    record: &LegacyProfileMigrationRecord,
    source: &crate::migration::PortableLegacyAgentProfileDraft,
    requirements: &AgentLLMRequirements,
) -> LegacyMigrationAction {
    let successor = match record.state() {
        LegacyProfileMigrationState::Pending { attempt } => {
            attempt.as_ref().map(|attempt| attempt.successor().clone())
        }
        LegacyProfileMigrationState::Migrated { successor } => Some(successor.clone()),
        LegacyProfileMigrationState::Archived => None,
    };
    let state = match record.state() {
        LegacyProfileMigrationState::Pending { .. } => "pending",
        LegacyProfileMigrationState::Migrated { .. } => "migrated",
        LegacyProfileMigrationState::Archived => "archived",
    };
    LegacyMigrationAction {
        migration_subject: format!(
            "{}:{}",
            record.source_profile_id().as_str(),
            record.source_revision().as_u64()
        ),
        source_digest: record.source_digest().to_string(),
        display_name: source.display_name().to_string(),
        requirements: requirements.clone(),
        redacted_model_hint: source.redacted_model_hint().map(str::to_string),
        state: state.to_string(),
        successor,
    }
}

fn storage_error(storage: RuntimeStateError) -> LegacyProfileMigrationError {
    error(storage.code(), storage.to_string())
}

fn translation_error(
    translation: crate::migration::LegacyProfileTranslationError,
) -> LegacyProfileMigrationError {
    error(translation.code(), translation.to_string())
}

fn error(code: impl Into<String>, message: impl Into<String>) -> LegacyProfileMigrationError {
    LegacyProfileMigrationError {
        code: code.into(),
        message: message.into(),
    }
}
