use local_ios_agent_runtime::canonical_digest::CanonicalDigestV1;
use local_ios_agent_runtime::llm_contracts::{
    AgentLLMRequirements, LLMCapabilityRequirement, LLMInputModality, LLMSlotV2, LLMToolCallingMode,
};
use serde_json::{json, Value};

fn requirements(reverse: bool) -> AgentLLMRequirements {
    let mut value =
        AgentLLMRequirements::new("llm.primary", 8_192, true, LLMToolCallingMode::Required);
    let capabilities = if reverse {
        ["tool_calling", "multimodal.image"]
    } else {
        ["multimodal.image", "tool_calling"]
    };
    for capability in capabilities {
        value = value.requiring_capability(LLMCapabilityRequirement::new(capability));
    }
    let modalities = if reverse {
        [LLMInputModality::Image, LLMInputModality::Text]
    } else {
        [LLMInputModality::Text, LLMInputModality::Image]
    };
    for modality in modalities {
        value = value.requiring_input_modality(modality);
    }
    value
}

fn assert_no_forbidden_keys(value: &Value) {
    match value {
        Value::Array(values) => values.iter().for_each(assert_no_forbidden_keys),
        Value::Object(object) => {
            for key in object.keys() {
                assert!(
                    !["provider_id", "model_path", "local_path", "installation_id"]
                        .contains(&key.as_str())
                );
            }
            object.values().for_each(assert_no_forbidden_keys);
        }
        _ => {}
    }
}

#[test]
fn v2_requirements_are_sorted_and_portable() {
    let slot = LLMSlotV2::new(requirements(true))
        .with_model_family_hint("gemma")
        .with_model_id_hint("gemma-3-4b-it");
    let value = serde_json::to_value(&slot).unwrap();

    assert_eq!(
        value["requirements"]["capabilities"],
        json!(["multimodal.image", "tool_calling"])
    );
    assert_eq!(
        value["requirements"]["input_modalities"],
        json!(["text", "image"])
    );
    assert_no_forbidden_keys(&value);
}

#[test]
fn requirements_digest_is_stable_under_set_insertion_order() {
    assert_eq!(
        CanonicalDigestV1::digest("agent-requirements:v1", &requirements(false)).unwrap(),
        CanonicalDigestV1::digest("agent-requirements:v1", &requirements(true)).unwrap()
    );
}

#[test]
fn context_budget_rejects_non_canonical_decimal_strings() {
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
        assert!(serde_json::from_value::<AgentLLMRequirements>(value).is_err());
    }
}
