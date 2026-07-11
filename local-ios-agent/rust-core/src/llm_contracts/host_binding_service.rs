use crate::agent_package::{InMemoryPackageInstallStore, PackageHostBindingState};
use crate::canonical_digest::CanonicalDigestV1;
use crate::storage::agent_os_state::SharedAgentOSStateStore;
use crate::user_customization::{
    AgentProfile, AgentProfileHostBindingState, AgentProfileId, AgentProfileReference,
    AgentProfileVersion, InMemoryAgentProfileRepository,
};

use super::{
    HostBindingActivationConfirmation, HostBindingCommit, HostBindingCrossLink, HostBindingError,
    HostBindingKind, HostBindingOperation, PackageBindingPreparation, ProfilePublishPreparation,
};

#[derive(Clone)]
pub struct HostBindingSubjectCatalog {
    profiles: InMemoryAgentProfileRepository,
    packages: Option<InMemoryPackageInstallStore>,
}

impl HostBindingSubjectCatalog {
    pub fn new(profiles: InMemoryAgentProfileRepository) -> Self {
        Self {
            profiles,
            packages: None,
        }
    }

    pub fn with_package_store(mut self, packages: InMemoryPackageInstallStore) -> Self {
        self.packages = Some(packages);
        self
    }

    pub fn profiles(&self) -> &InMemoryAgentProfileRepository {
        &self.profiles
    }
}

#[derive(Clone)]
pub struct AgentHostBindingService {
    state: SharedAgentOSStateStore,
    subjects: HostBindingSubjectCatalog,
}

impl AgentHostBindingService {
    pub fn new(state: SharedAgentOSStateStore, subjects: HostBindingSubjectCatalog) -> Self {
        Self { state, subjects }
    }

    pub fn prepare_profile_publish(
        &self,
        request: ProfilePublishPreparation,
    ) -> Result<HostBindingOperation, HostBindingError> {
        let profile =
            self.exact_profile(request.agent_profile_id(), request.agent_profile_revision())?;
        validate_profile_subject(&profile, request.llm_slot_id(), request.requirements_hash())?;
        if profile.host_binding_state() != AgentProfileHostBindingState::PendingHostBinding {
            return Err(error(
                "host_binding.profile_state_invalid",
                "profile revision is not pending host binding",
            ));
        }
        self.state
            .with_host_binding_mut(|store| store.prepare_profile_publish(request))
    }

    pub fn commit_profile_publish(
        &self,
        request: HostBindingCommit,
    ) -> Result<HostBindingCrossLink, HostBindingError> {
        let link = self
            .state
            .with_host_binding_mut(|store| store.commit_profile_publish(request))?;
        if link.kind() != HostBindingKind::ProfilePublish {
            return Err(error(
                "host_binding.operation_kind_mismatch",
                "profile publish commit produced the wrong cross-link kind",
            ));
        }
        self.transition_profile_to_host_unbound(&link)?;
        Ok(link)
    }

    pub fn begin_package_binding(
        &self,
        request: PackageBindingPreparation,
    ) -> Result<HostBindingOperation, HostBindingError> {
        let packages = self.subjects.packages.as_ref().ok_or_else(|| {
            error(
                "host_binding.package_catalog_unavailable",
                "package binding requires the actual package installation catalog",
            )
        })?;
        let installation = packages
            .installation(request.installation_id())
            .ok_or_else(|| {
                error(
                    "host_binding.package_installation_not_found",
                    "package installation does not exist",
                )
            })?;
        if installation.host_binding_state != PackageHostBindingState::NeedsLLMBinding {
            return Err(error(
                "host_binding.package_state_invalid",
                "package installation is not awaiting an LLM binding",
            ));
        }
        let installed_profile = packages
            .installed_profile(request.installation_id())
            .ok_or_else(|| {
                error(
                    "host_binding.package_profile_missing",
                    "package installation has no actual Profile revision",
                )
            })?;
        if installed_profile.profile().profile_id().as_str() != request.agent_profile_id()
            || installed_profile
                .profile()
                .profile_version()
                .is_none_or(|version| version.as_u64() != request.agent_profile_revision())
        {
            return Err(error(
                "host_binding.package_profile_mismatch",
                "package binding request does not match the installed Profile revision",
            ));
        }
        let profile =
            self.exact_profile(request.agent_profile_id(), request.agent_profile_revision())?;
        validate_profile_subject(&profile, request.llm_slot_id(), request.requirements_hash())?;
        self.state
            .with_host_binding_mut(|store| store.begin_package_binding(request))
    }

    pub fn attach_host_binding(
        &self,
        request: HostBindingCommit,
    ) -> Result<HostBindingCrossLink, HostBindingError> {
        let link = self
            .state
            .with_host_binding_mut(|store| store.attach_host_binding(request))?;
        let packages = self.subjects.packages.as_ref().ok_or_else(|| {
            error(
                "host_binding.package_catalog_unavailable",
                "package binding requires the actual package installation catalog",
            )
        })?;
        transition_package(
            packages,
            link.subject_id(),
            PackageHostBindingState::NeedsLLMBinding,
            PackageHostBindingState::HostUnbound,
        )?;
        self.transition_profile_to_host_unbound(&link)?;
        Ok(link)
    }

    pub fn confirm_activation(
        &self,
        confirmation: HostBindingActivationConfirmation,
    ) -> Result<HostBindingCrossLink, HostBindingError> {
        let link = self
            .state
            .with_host_binding_mut(|store| store.activate_matching_cross_link(&confirmation))?;
        self.transition_profile_to_active(&link)?;
        if link.kind() == HostBindingKind::PackageBinding {
            let packages = self.subjects.packages.as_ref().ok_or_else(|| {
                error(
                    "host_binding.package_catalog_unavailable",
                    "package activation requires the actual installation catalog",
                )
            })?;
            transition_package(
                packages,
                link.subject_id(),
                PackageHostBindingState::HostUnbound,
                PackageHostBindingState::Ready,
            )?;
        }
        Ok(link)
    }

    fn exact_profile(&self, id: &str, revision: u64) -> Result<AgentProfile, HostBindingError> {
        self.subjects
            .profiles
            .profile(&AgentProfileReference::pinned(
                AgentProfileId::new(id),
                AgentProfileVersion::new(revision),
            ))
            .ok_or_else(|| {
                error(
                    "host_binding.profile_revision_not_found",
                    "agent Profile revision does not exist",
                )
            })
    }

    fn transition_profile_to_host_unbound(
        &self,
        link: &HostBindingCrossLink,
    ) -> Result<(), HostBindingError> {
        transition_profile(
            &self.subjects.profiles,
            link,
            AgentProfileHostBindingState::PendingHostBinding,
            AgentProfileHostBindingState::HostUnbound,
        )
    }

    fn transition_profile_to_active(
        &self,
        link: &HostBindingCrossLink,
    ) -> Result<(), HostBindingError> {
        transition_profile(
            &self.subjects.profiles,
            link,
            AgentProfileHostBindingState::HostUnbound,
            AgentProfileHostBindingState::Active,
        )
    }
}

fn validate_profile_subject(
    profile: &AgentProfile,
    slot_id: &str,
    requirements_hash: &str,
) -> Result<(), HostBindingError> {
    let slot = profile.llm_slot().ok_or_else(|| {
        error(
            "host_binding.profile_not_v2",
            "agent Profile revision does not contain LLMSlotV2",
        )
    })?;
    let expected_hash = CanonicalDigestV1::digest("agent-requirements:v1", slot.requirements())
        .map_err(|digest_error| {
            error(
                "host_binding.requirements_digest_failed",
                digest_error.to_string(),
            )
        })?;
    if slot.requirements().slot_id() != slot_id || expected_hash.as_str() != requirements_hash {
        return Err(error(
            "host_binding.profile_requirements_mismatch",
            "host-binding request does not match the Profile slot and requirements",
        ));
    }
    Ok(())
}

fn transition_profile(
    profiles: &InMemoryAgentProfileRepository,
    link: &HostBindingCrossLink,
    expected: AgentProfileHostBindingState,
    next: AgentProfileHostBindingState,
) -> Result<(), HostBindingError> {
    let current = profiles
        .profile(&AgentProfileReference::pinned(
            AgentProfileId::new(link.agent_profile_id()),
            AgentProfileVersion::new(link.agent_profile_revision()),
        ))
        .ok_or_else(|| {
            error(
                "host_binding.profile_revision_not_found",
                "cross-link Profile revision no longer exists",
            )
        })?;
    if current.host_binding_state() == next {
        return Ok(());
    }
    profiles
        .transition_host_binding_state(current.id(), current.version(), expected, next)
        .map(|_| ())
        .map_err(|storage_error| {
            error(
                "host_binding.profile_transition_failed",
                storage_error.to_string(),
            )
        })
}

fn transition_package(
    packages: &InMemoryPackageInstallStore,
    installation_id: &str,
    expected: PackageHostBindingState,
    next: PackageHostBindingState,
) -> Result<(), HostBindingError> {
    let current = packages.installation(installation_id).ok_or_else(|| {
        error(
            "host_binding.package_installation_not_found",
            "cross-link package installation no longer exists",
        )
    })?;
    if current.host_binding_state == next {
        return Ok(());
    }
    packages
        .transition_host_binding_state(installation_id, expected, next)
        .map(|_| ())
        .map_err(|storage_error| {
            error(
                "host_binding.package_transition_failed",
                storage_error.to_string(),
            )
        })
}

fn error(code: &'static str, message: impl Into<String>) -> HostBindingError {
    HostBindingError::new(code, message)
}
