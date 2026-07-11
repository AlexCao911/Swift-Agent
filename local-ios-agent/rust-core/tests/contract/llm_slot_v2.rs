use local_ios_agent_runtime::canonical_digest::CanonicalDigestV1;
use local_ios_agent_runtime::llm_contracts::{
    AgentLLMRequirements, LLMBindingSchema, LLMCapabilityRequirement, LLMInputModality, LLMSlotV2,
    LLMToolCallingMode,
};
use local_ios_agent_runtime::model::{
    ModelBindingCatalog, ModelBindingId, ModelCatalogVersion, ModelSelection,
};
use local_ios_agent_runtime::storage::InMemoryTransactionRunner;
use local_ios_agent_runtime::user_customization::{
    AgentProfileDraft, AgentProfileId, AgentProfileLLMBinding, AgentProfileModelBinding,
    AgentProfilePublisher, AgentSlotKind, AgentTemplate, ComponentBinding, ComponentCatalogService,
    ComponentContent, InMemoryAgentProfileRepository,
};
use serde_json::{json, Value};

fn requirements_with_insertion_order(
    slot_id: impl Into<String>,
    reverse: bool,
) -> AgentLLMRequirements {
    let mut requirements =
        AgentLLMRequirements::new(slot_id, 8_192, true, LLMToolCallingMode::Required);
    let capabilities = if reverse {
        ["tool_calling", "multimodal.image"]
    } else {
        ["multimodal.image", "tool_calling"]
    };
    for capability in capabilities {
        requirements = requirements.requiring_capability(LLMCapabilityRequirement::new(capability));
    }
    let modalities = if reverse {
        [LLMInputModality::Image, LLMInputModality::Text]
    } else {
        [LLMInputModality::Text, LLMInputModality::Image]
    };
    for modality in modalities {
        requirements = requirements.requiring_input_modality(modality);
    }
    requirements
}

fn assert_object_has_no_keys(value: &Value, forbidden: &[&str]) {
    match value {
        Value::Array(values) => {
            for value in values {
                assert_object_has_no_keys(value, forbidden);
            }
        }
        Value::Object(object) => {
            for key in object.keys() {
                assert!(!forbidden.contains(&key.as_str()), "forbidden key {key}");
            }
            for value in object.values() {
                assert_object_has_no_keys(value, forbidden);
            }
        }
        _ => {}
    }
}

#[test]
fn v2_requirements_are_portable_sorted_and_secret_free() {
    let slot = LLMSlotV2::new(requirements_with_insertion_order("llm.primary", true))
        .with_model_family_hint("gemma")
        .with_model_id_hint("gemma-3-4b-it");

    let value = serde_json::to_value(&slot).unwrap();
    let requirements = &value["requirements"];
    assert_eq!(requirements["slot_id"], "llm.primary");
    assert_eq!(requirements["context_budget"], "8192");
    assert_eq!(
        requirements["capabilities"],
        json!(["multimodal.image", "tool_calling"])
    );
    assert_eq!(requirements["input_modalities"], json!(["text", "image"]));
    assert_eq!(requirements["streaming_required"], true);
    assert_eq!(requirements["tool_calling_mode"], "required");
    assert_eq!(value["model_family_hint"], "gemma");
    assert_eq!(value["model_id_hint"], "gemma-3-4b-it");
    assert_object_has_no_keys(
        requirements,
        &[
            "provider_id",
            "provider_profile_id",
            "model_id",
            "model_path",
            "local_path",
            "credential_ref",
            "api_key",
            "base_url",
            "installation_id",
        ],
    );
}

#[test]
fn requirements_digest_is_stable_under_set_insertion_order() {
    let forward = requirements_with_insertion_order("llm.primary", false);
    let reverse = requirements_with_insertion_order("llm.primary", true);

    assert_eq!(
        CanonicalDigestV1::canonicalize(&forward).unwrap(),
        CanonicalDigestV1::canonicalize(&reverse).unwrap()
    );
    assert_eq!(
        CanonicalDigestV1::digest("agent-requirements:v1", &forward).unwrap(),
        CanonicalDigestV1::digest("agent-requirements:v1", &reverse).unwrap()
    );
}

#[test]
fn requirements_reject_non_canonical_decimal_context_budget() {
    let base = json!({
        "slot_id": "llm.primary",
        "capabilities": [],
        "input_modalities": ["text"],
        "streaming_required": true,
        "tool_calling_mode": "required"
    });

    for invalid in ["", "08", "8k", "-1", "18446744073709551616"] {
        let mut value = base.clone();
        value["context_budget"] = json!(invalid);
        assert!(
            serde_json::from_value::<AgentLLMRequirements>(value).is_err(),
            "invalid context budget must be rejected: {invalid}"
        );
    }
}

#[test]
fn published_profile_contains_one_tagged_llm_binding() {
    let template = AgentTemplate::assistant_default();
    let catalog = ComponentCatalogService::default();
    let persona_id = catalog.create_draft(ComponentContent::persona("Portable persona"));
    let persona_version = catalog.publish(persona_id).unwrap();
    let persona_binding = || {
        ComponentBinding::persona(
            template
                .slot_id_for_kind(AgentSlotKind::Persona)
                .unwrap()
                .clone(),
            persona_version,
        )
    };

    let v2_repository = InMemoryAgentProfileRepository::default();
    let v2_publisher = AgentProfilePublisher::new(
        Box::new(InMemoryTransactionRunner::default()),
        v2_repository.clone(),
    );
    let model_slot_id = template
        .slot_id_for_kind(AgentSlotKind::Model)
        .unwrap()
        .as_str()
        .to_string();
    let slot = LLMSlotV2::new(requirements_with_insertion_order(model_slot_id, false));
    let v2_reference = v2_publisher
        .publish(
            AgentProfileDraft::new(
                AgentProfileId::new("profile.host-slot-v2"),
                template.id().clone(),
                "Host Slot V2",
            )
            .bind(persona_binding())
            .with_llm_slot(slot.clone()),
            &template,
            &catalog,
            &ModelBindingCatalog::default(),
        )
        .unwrap();
    let v2_profile = v2_repository.profile(&v2_reference).unwrap();
    assert_eq!(
        v2_profile.llm_binding_schema(),
        Some(LLMBindingSchema::HostSlotV2)
    );
    assert!(matches!(
        v2_profile.llm_binding(),
        Some(AgentProfileLLMBinding::HostSlotV2(actual)) if actual == &slot
    ));
    assert_eq!(v2_profile.llm_slot(), Some(&slot));
    assert!(v2_profile.model_binding().is_none());

    let selection = ModelSelection::new(
        ModelBindingId::new("model_binding.primary"),
        "account.openai.default",
        "provider.openai",
        "gpt-4.1-mini",
        ModelCatalogVersion::new(7),
    );
    let model_catalog = ModelBindingCatalog::default().with_selection(selection.clone());
    let legacy_repository = InMemoryAgentProfileRepository::default();
    let legacy_publisher = AgentProfilePublisher::new(
        Box::new(InMemoryTransactionRunner::default()),
        legacy_repository.clone(),
    );
    let legacy_reference = legacy_publisher
        .publish(
            AgentProfileDraft::new(
                AgentProfileId::new("profile.legacy-v1"),
                template.id().clone(),
                "Legacy V1",
            )
            .bind(persona_binding())
            .with_model_binding(AgentProfileModelBinding::new(
                template
                    .slot_id_for_kind(AgentSlotKind::Model)
                    .unwrap()
                    .clone(),
                selection,
            )),
            &template,
            &catalog,
            &model_catalog,
        )
        .unwrap();
    let legacy_profile = legacy_repository.profile(&legacy_reference).unwrap();
    assert_eq!(
        legacy_profile.llm_binding_schema(),
        Some(LLMBindingSchema::LegacyV1)
    );
    assert!(matches!(
        legacy_profile.llm_binding(),
        Some(AgentProfileLLMBinding::LegacyV1(_))
    ));
    assert!(legacy_profile.llm_slot().is_none());
    assert!(legacy_profile.model_binding().is_some());
}
