use crate::canonical_digest::CanonicalDigestV1;

use super::{
    HostAttestation, HostBindingCrossLink, LLMToolCallingMode, PreparationError,
    PreparedSessionRegistration, RunPreparationRecord, RunPreparationRequest,
};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ValidatedPreparedStart {
    preparation_id: String,
    registration_digest: String,
    binding_hash: String,
}

impl ValidatedPreparedStart {
    pub fn preparation_id(&self) -> &str {
        &self.preparation_id
    }
    pub fn registration_digest(&self) -> &str {
        &self.registration_digest
    }
    pub fn binding_hash(&self) -> &str {
        &self.binding_hash
    }
}

pub struct PreparedStartValidator;

impl PreparedStartValidator {
    pub fn validate(
        record: &RunPreparationRecord,
        attestation: &HostAttestation,
        cross_link: Option<&HostBindingCrossLink>,
        frozen_model_input: Option<&[u8]>,
        now_millis: u64,
    ) -> Result<ValidatedPreparedStart, PreparationError> {
        let frozen_request = RunPreparationRequest::new(
            record.idempotency_key(),
            record.preview().preparation_id(),
            record.preview().proposed_run_id(),
            record.preview().binding().clone(),
        );
        let expected_binding_digest =
            CanonicalDigestV1::digest("preparation-binding:v1", &frozen_request).map_err(
                |digest_error| {
                    error(
                        "preparation.binding_digest_failed",
                        digest_error.to_string(),
                    )
                },
            )?;
        if !constant_time_text_eq(
            expected_binding_digest.as_str(),
            record.preview().binding_digest(),
        ) {
            return Err(error(
                "preparation.binding_digest_mismatch",
                "persisted preparation fields no longer match the Rust-frozen binding digest",
            ));
        }
        let registration = record.registration().ok_or_else(|| {
            error(
                "preparation.session_not_registered",
                "commit requires an exact prepared-session registration",
            )
        })?;
        validate_registration(registration)?;
        if attestation.registration() != registration
            || attestation.preparation_binding_digest() != record.preview().binding_digest()
            || attestation.expiration_millis() < now_millis
        {
            return Err(error(
                "preparation.host_attestation_mismatch",
                "host attestation does not match the registered prepared session",
            ));
        }

        let binding = record.preview().binding();
        let requirements = binding.requirements().ok_or_else(|| {
            error(
                "preparation.frozen_requirements_missing",
                "preparation does not contain Rust-frozen LLM requirements",
            )
        })?;

        let expected_egress_digest = attestation.expected_egress_digest()?;
        let attested_data_classes: std::collections::BTreeSet<_> =
            attestation.data_classes().map(str::to_string).collect();
        if attestation.disclosure_digest() != binding.initial_disclosure_digest()
            || attested_data_classes != *binding.initial_data_classes()
            || attestation.highest_sensitivity() != binding.initial_highest_sensitivity()
            || attestation.disclosure_grant_id().is_empty()
            || attestation.opaque_subject_digest().is_empty()
            || !constant_time_text_eq(
                attestation.egress_attestation_digest(),
                &expected_egress_digest,
            )
        {
            return Err(error(
                "preparation.egress_attestation_digest_mismatch",
                "egress attestation does not match the Rust-frozen disclosure and public fields",
            ));
        }

        let capability = attestation.capability_attestation().ok_or_else(|| {
            error(
                "preparation.capability_attestation_missing",
                "commit requires a provider-neutral capability attestation",
            )
        })?;
        let expected_capability_digest = capability.expected_digest()?;
        if !constant_time_text_eq(capability.attestation_digest(), &expected_capability_digest) {
            return Err(error(
                "preparation.capability_attestation_digest_mismatch",
                "capability attestation digest does not match its public claims",
            ));
        }
        let context_length = capability.context_length().parse::<u64>().map_err(|_| {
            error(
                "preparation.capability_attestation_mismatch",
                "capability context length is not a canonical unsigned integer",
            )
        })?;
        let required_context = requirements.context_budget().parse::<u64>().map_err(|_| {
            error(
                "preparation.frozen_requirements_invalid",
                "frozen context budget is invalid",
            )
        })?;
        let capabilities_satisfied =
            requirements
                .capability_requirements()
                .iter()
                .all(|required| {
                    capability
                        .supported_capabilities()
                        .contains(required.as_str())
                });
        let modalities_satisfied = requirements
            .input_modalities()
            .is_subset(capability.input_modalities());
        let tools_satisfied = requirements.tool_calling_mode() == LLMToolCallingMode::Disabled
            || capability.tool_calling();
        if capability.expiration_millis() < now_millis
            || context_length < required_context
            || (requirements.streaming_required() && !capability.streaming())
            || !tools_satisfied
            || !capabilities_satisfied
            || !modalities_satisfied
        {
            return Err(error(
                "preparation.capability_attestation_mismatch",
                "capability claims do not satisfy the frozen provider-neutral requirements",
            ));
        }

        let link = cross_link.ok_or_else(|| {
            error(
                "preparation.host_binding_cross_link_missing",
                "no exact host-binding cross-link exists for the prepared session",
            )
        })?;
        if link.agent_profile_id() != binding.agent_profile_id()
            || link.agent_profile_revision() != binding.agent_profile_revision()
            || link.llm_slot_id() != requirements.slot_id()
            || link.requirements_hash() != binding.requirements_hash()
            || link.binding().binding_id() != registration.binding_id()
            || link.binding().binding_revision() != registration.binding_revision()
            || link.binding().binding_hash() != registration.binding_hash()
        {
            return Err(error(
                "preparation.host_binding_cross_link_mismatch",
                "host-binding cross-link does not match the frozen Profile, slot, requirements, and binding tuple",
            ));
        }

        let frozen_model_input = frozen_model_input.ok_or_else(|| {
            error(
                "preparation.frozen_model_input_missing",
                "Rust-frozen model input is unavailable",
            )
        })?;
        let document: serde_json::Value =
            serde_json::from_slice(frozen_model_input).map_err(|_| {
                error(
                    "preparation.frozen_model_input_invalid",
                    "Rust-frozen model input is not canonical JSON",
                )
            })?;
        let rehashed =
            CanonicalDigestV1::digest("agent-input:v1", &document).map_err(|digest_error| {
                error(
                    "preparation.frozen_model_input_invalid",
                    digest_error.to_string(),
                )
            })?;
        if !constant_time_text_eq(rehashed.as_str(), binding.model_input_digest()) {
            return Err(error(
                "preparation.frozen_model_input_digest_mismatch",
                "Rust-frozen model input bytes no longer match the preparation binding",
            ));
        }

        Ok(ValidatedPreparedStart {
            preparation_id: record.preview().preparation_id().to_string(),
            registration_digest: registration.registration_digest().to_string(),
            binding_hash: registration.binding_hash().to_string(),
        })
    }
}

fn validate_registration(
    registration: &PreparedSessionRegistration,
) -> Result<(), PreparationError> {
    let expected = registration.expected_digest()?;
    if constant_time_text_eq(registration.registration_digest(), &expected) {
        Ok(())
    } else {
        Err(error(
            "preparation.registration_digest_mismatch",
            "prepared-session registration digest does not match its public fields",
        ))
    }
}

fn constant_time_text_eq(left: &str, right: &str) -> bool {
    let left = left.as_bytes();
    let right = right.as_bytes();
    let mut difference = left.len() ^ right.len();
    let width = left.len().max(right.len());
    for index in 0..width {
        difference |= usize::from(
            left.get(index).copied().unwrap_or(0) ^ right.get(index).copied().unwrap_or(0),
        );
    }
    difference == 0
}

fn error(code: &'static str, message: impl Into<String>) -> PreparationError {
    PreparationError::new(code, message)
}
