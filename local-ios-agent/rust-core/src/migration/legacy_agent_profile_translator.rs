use std::fmt;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::canonical_digest::CanonicalDigestV1;
use crate::llm_contracts::{AgentLLMRequirements, LLMInputModality, LLMSlotV2, LLMToolCallingMode};
use crate::user_customization::{
    AgentProfile, AgentProfileId, AgentProfileVersion, AgentSlotId, AgentSlotKind, AgentTemplateId,
    ComponentBinding,
};

const LEGACY_PROFILE_RECORD_SCHEMA: &str = "agent-profile:v2";
const LEGACY_PROFILE_SOURCE_SCHEMA_VERSION: u32 = 2;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PortableLegacyAgentProfileDraft {
    source_profile_id: AgentProfileId,
    source_revision: AgentProfileVersion,
    display_name: String,
    redacted_model_hint: Option<String>,
    component_bindings: Vec<ComponentBinding>,
    llm_slot: LLMSlotV2,
    successor: AgentProfile,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LegacyProfileTranslationError {
    code: &'static str,
    message: String,
}

#[derive(Deserialize)]
struct HistoricalProfileWire {
    id: AgentProfileId,
    version: AgentProfileVersion,
    template_id: AgentTemplateId,
    name: String,
    bindings: Vec<ComponentBinding>,
    llm_binding: Option<HistoricalLLMWire>,
}

#[derive(Deserialize)]
#[serde(tag = "schema", content = "binding", rename_all = "snake_case")]
enum HistoricalLLMWire {
    LegacyV1(HistoricalBrainWire),
    HostSlotV2(#[allow(dead_code)] Value),
}

#[derive(Deserialize)]
struct HistoricalBrainWire {
    slot_id: AgentSlotId,
    selection: HistoricalSelectionWire,
}

#[derive(Deserialize)]
struct HistoricalSelectionWire {
    provider_id: String,
    model_id: String,
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
    pub fn translate_record(
        source_json: &str,
    ) -> Result<PortableLegacyAgentProfileDraft, LegacyProfileTranslationError> {
        let source: HistoricalProfileWire = serde_json::from_str(source_json).map_err(|error| {
            translation_error(
                "legacy_profile.source_unreadable",
                format!("legacy Profile is unreadable: {error}"),
            )
        })?;
        let Some(HistoricalLLMWire::LegacyV1(binding)) = source.llm_binding else {
            return Err(translation_error(
                "legacy_profile.source_not_legacy",
                "migration source is not a recognized legacy Profile",
            ));
        };
        let tool_calling_mode = if source
            .bindings
            .iter()
            .any(|binding| binding.slot_kind() == AgentSlotKind::Toolset)
        {
            LLMToolCallingMode::Allowed
        } else {
            LLMToolCallingMode::Disabled
        };
        let requirements =
            AgentLLMRequirements::new(binding.slot_id.as_str(), 4096, true, tool_calling_mode)
                .requiring_input_modality(LLMInputModality::Text);
        let llm_slot = LLMSlotV2::new(requirements)
            .with_model_family_hint(binding.selection.provider_id)
            .with_model_id_hint(binding.selection.model_id.clone());
        let successor = AgentProfile::migrated_host_slot_profile(
            source.id.clone(),
            AgentProfileVersion::new(source.version.as_u64() + 1),
            source.template_id,
            source.name.clone(),
            source.bindings.clone(),
            llm_slot.clone(),
        );
        Ok(PortableLegacyAgentProfileDraft {
            source_profile_id: source.id,
            source_revision: source.version,
            display_name: source.name,
            redacted_model_hint: Some(binding.selection.model_id),
            component_bindings: source.bindings,
            llm_slot,
            successor,
        })
    }

    pub fn source_digest(source_json: &str) -> Result<String, LegacyProfileTranslationError> {
        let source_record: Value = serde_json::from_str(source_json).map_err(|error| {
            translation_error(
                "legacy_profile.source_unreadable",
                format!("legacy Profile is unreadable: {error}"),
            )
        })?;
        let translated = Self::translate_record(source_json)?;
        let document = LegacyProfileSourceV1 {
            source_profile_id: translated.source_profile_id().as_str(),
            source_revision: translated.source_revision().as_u64(),
            source_schema_version: LEGACY_PROFILE_SOURCE_SCHEMA_VERSION,
            source_record: &source_record,
        };
        CanonicalDigestV1::digest("legacy-profile-source:v1", &document)
            .map(|digest| digest.as_str().to_string())
            .map_err(|error| {
                translation_error("legacy_profile.source_digest_failed", error.to_string())
            })
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

    pub fn display_name(&self) -> &str {
        &self.display_name
    }

    pub fn redacted_model_hint(&self) -> Option<&str> {
        self.redacted_model_hint.as_deref()
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

fn translation_error(
    code: &'static str,
    message: impl Into<String>,
) -> LegacyProfileTranslationError {
    LegacyProfileTranslationError {
        code,
        message: message.into(),
    }
}
