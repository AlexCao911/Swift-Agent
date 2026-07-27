use std::fmt;

use serde::Serialize;
use serde_json::Value;

use crate::canonical_digest::CanonicalDigestV1;
use crate::llm_contracts::{
    AgentLLMRequirements, LLMBindingSchema, LLMInputModality, LLMSlotV2, LLMToolCallingMode,
};
use crate::user_customization::{
    AgentProfile, AgentProfileId, AgentProfileVersion, AgentSlotKind, ComponentBinding,
};

const LEGACY_PROFILE_RECORD_SCHEMA: &str = "agent-profile:v2";
const LEGACY_PROFILE_SOURCE_SCHEMA_VERSION: u32 = 2;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PortableLegacyAgentProfileDraft {
    source_profile_id: AgentProfileId,
    source_revision: AgentProfileVersion,
    component_bindings: Vec<ComponentBinding>,
    llm_slot: LLMSlotV2,
    successor: AgentProfile,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LegacyProfileTranslationError {
    code: &'static str,
    message: String,
}

#[derive(Serialize)]
struct LegacyProfileSourceV1<'a> {
    source_profile_id: &'a str,
    source_revision: u64,
    source_schema_version: u32,
    source_record: &'a Value,
}

pub struct LegacyAgentProfileTranslator;

impl LegacyAgentProfileTranslator {
    pub fn translate_known_profile(
        source: &AgentProfile,
    ) -> Result<PortableLegacyAgentProfileDraft, LegacyProfileTranslationError> {
        if source.llm_binding_schema() != Some(LLMBindingSchema::LegacyV1) {
            return Err(error(
                "legacy_profile.source_not_legacy",
                "migration source is not a legacy V1 Profile",
            ));
        }
        let legacy_binding = source.model_binding().ok_or_else(|| {
            error(
                "legacy_profile.binding_missing",
                "legacy V1 Profile has no concrete model binding",
            )
        })?;
        let tool_calling_mode = if source
            .bindings()
            .iter()
            .any(|binding| binding.slot_kind() == AgentSlotKind::Toolset)
        {
            LLMToolCallingMode::Allowed
        } else {
            LLMToolCallingMode::Disabled
        };
        let requirements = AgentLLMRequirements::new(
            legacy_binding.slot_id().as_str(),
            4096,
            true,
            tool_calling_mode,
        )
        .requiring_input_modality(LLMInputModality::Text);
        let llm_slot = LLMSlotV2::new(requirements)
            .with_model_family_hint(legacy_binding.selection().provider_id())
            .with_model_id_hint(legacy_binding.selection().model_id());
        let successor = AgentProfile::legacy_migration_successor(source, llm_slot.clone());
        Ok(PortableLegacyAgentProfileDraft {
            source_profile_id: source.id().clone(),
            source_revision: source.version(),
            component_bindings: source.bindings().to_vec(),
            llm_slot,
            successor,
        })
    }

    pub fn source_digest(source: &AgentProfile) -> Result<String, LegacyProfileTranslationError> {
        if source.llm_binding_schema() != Some(LLMBindingSchema::LegacyV1) {
            return Err(error(
                "legacy_profile.source_not_legacy",
                "migration source is not a legacy V1 Profile",
            ));
        }
        let source_record = serde_json::to_value(source).map_err(|serialization| {
            error(
                "legacy_profile.source_serialization_failed",
                serialization.to_string(),
            )
        })?;
        let document = LegacyProfileSourceV1 {
            source_profile_id: source.id().as_str(),
            source_revision: source.version().as_u64(),
            source_schema_version: LEGACY_PROFILE_SOURCE_SCHEMA_VERSION,
            source_record: &source_record,
        };
        CanonicalDigestV1::digest("legacy-profile-source:v1", &document)
            .map(|digest| digest.as_str().to_string())
            .map_err(|digest| error("legacy_profile.source_digest_failed", digest.to_string()))
    }

    pub fn record_schema() -> &'static str {
        LEGACY_PROFILE_RECORD_SCHEMA
    }
}

impl PortableLegacyAgentProfileDraft {
    pub fn source_profile_id(&self) -> &AgentProfileId {
        &self.source_profile_id
    }

    pub fn source_revision(&self) -> AgentProfileVersion {
        self.source_revision
    }

    pub fn component_bindings(&self) -> &[ComponentBinding] {
        &self.component_bindings
    }

    pub fn has_component_kind(&self, kind: AgentSlotKind) -> bool {
        self.component_bindings
            .iter()
            .any(|binding| binding.slot_kind() == kind)
    }

    pub fn llm_slot(&self) -> &LLMSlotV2 {
        &self.llm_slot
    }

    pub fn successor(&self) -> &AgentProfile {
        &self.successor
    }
}

impl LegacyProfileTranslationError {
    pub fn code(&self) -> &str {
        self.code
    }
}

impl fmt::Display for LegacyProfileTranslationError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for LegacyProfileTranslationError {}

fn error(code: &'static str, message: impl Into<String>) -> LegacyProfileTranslationError {
    LegacyProfileTranslationError {
        code,
        message: message.into(),
    }
}
