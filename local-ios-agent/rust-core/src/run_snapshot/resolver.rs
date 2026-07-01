use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use crate::model::{ModelBindingId, ModelCatalogVersion, ModelSelection};
use crate::run_snapshot::{
    ResolvedComponentBinding, ResolvedModelBinding, ResolvedRunSnapshot, RunSnapshotError,
    RunSnapshotId, RunSnapshotResolveInput, RunSnapshotResult, StartRunRequest,
    TrustedHostRunState,
};
use crate::security::PermissionState;
use crate::storage::{PendingStoreWrite, StorageError, StorageResult, UnitOfWork};
use crate::user_customization::{
    AgentProfile, AgentProfileDraft, AgentProfileId, AgentProfileLocalBindings,
    AgentProfileModelBinding, AgentProfileVersion, AgentSlotKind, AgentTemplate, ComponentBinding,
    ComponentKind, UserComponentVersionId,
};

#[derive(Clone, Debug)]
pub struct RunSnapshotResolver {
    repository: RunSnapshotRepository,
}

#[derive(Clone, Debug, Default)]
pub struct RunSnapshotRepository {
    inner: Arc<Mutex<RunSnapshotRepositoryRecords>>,
}

#[derive(Debug)]
struct RunSnapshotRepositoryRecords {
    profiles: BTreeMap<AgentProfileId, ProfileSnapshotSource>,
    components: BTreeMap<UserComponentVersionId, ComponentSnapshotSource>,
    models: BTreeMap<ModelBindingId, ModelSelection>,
    snapshots: BTreeMap<RunSnapshotId, ResolvedRunSnapshot>,
    next_snapshot_id: u64,
}

#[derive(Clone, Debug)]
struct ProfileSnapshotSource {
    profile: AgentProfile,
    profile_version: AgentProfileVersion,
}

#[derive(Clone, Debug)]
struct ComponentSnapshotSource {
    version_id: String,
    entity_version: u64,
}

struct PendingRunSnapshotWrite {
    repository: RunSnapshotRepository,
    snapshot: ResolvedRunSnapshot,
}

impl Default for RunSnapshotRepositoryRecords {
    fn default() -> Self {
        Self {
            profiles: BTreeMap::new(),
            components: BTreeMap::new(),
            models: BTreeMap::new(),
            snapshots: BTreeMap::new(),
            next_snapshot_id: 1,
        }
    }
}

impl RunSnapshotResolver {
    pub fn new(repository: RunSnapshotRepository) -> Self {
        Self { repository }
    }

    pub fn fixture_profile_with_persona_and_model() -> Self {
        Self::new(RunSnapshotRepository::fixture_profile_with_persona_and_model())
    }

    pub fn repository(&self) -> RunSnapshotRepository {
        self.repository.clone()
    }

    pub fn resolve(
        &self,
        input: RunSnapshotResolveInput,
    ) -> RunSnapshotResult<ResolvedRunSnapshot> {
        let (request, trusted_host_state) = input.into_parts();
        let profile = self.repository.profile_source(request.agent_profile_id())?;
        let component_versions = self.resolve_components(profile.profile.bindings())?;
        let model_binding = self.resolve_model_binding(&profile.profile)?;
        let snapshot_id = self.repository.next_snapshot_id();

        Ok(ResolvedRunSnapshot::new(
            snapshot_id,
            request,
            profile.profile_version,
            component_versions,
            model_binding,
            trusted_host_state,
            0,
        ))
    }

    fn resolve_components(
        &self,
        bindings: &[ComponentBinding],
    ) -> RunSnapshotResult<Vec<ResolvedComponentBinding>> {
        bindings
            .iter()
            .map(|binding| {
                let source = self
                    .repository
                    .component_source(binding.component_version_id())?;
                Ok(ResolvedComponentBinding::new(
                    binding.slot_id().clone(),
                    binding.slot_kind(),
                    source.version_id,
                    source.entity_version,
                ))
            })
            .collect()
    }

    fn resolve_model_binding(
        &self,
        profile: &AgentProfile,
    ) -> RunSnapshotResult<ResolvedModelBinding> {
        let profile_model = profile.model_binding().ok_or_else(|| {
            RunSnapshotError::new(
                "snapshot.model_binding_missing",
                "agent profile does not contain a model binding",
            )
        })?;
        let current_selection = self
            .repository
            .model_selection(profile_model.selection().binding_id())?;
        Ok(ResolvedModelBinding::from_selection(&current_selection))
    }
}

impl RunSnapshotRepository {
    pub fn fixture_profile_with_persona_and_model() -> Self {
        let repository = Self::default();
        repository.seed_fixture_profile();
        repository
    }

    fn seed_fixture_profile(&self) {
        let template = AgentTemplate::assistant_default();
        let persona_version_id = UserComponentVersionId::new(1);
        let model_selection = fixture_model_selection(ModelCatalogVersion::new(7));
        let profile = AgentProfileDraft::new(
            AgentProfileId::new("profile_1"),
            template.id().clone(),
            "Fixture Agent",
        )
        .bind(ComponentBinding::persona(
            template
                .slot_id_for_kind(AgentSlotKind::Persona)
                .expect("fixture template has persona slot")
                .clone(),
            persona_version_id,
        ))
        .with_model_binding(AgentProfileModelBinding::new(
            template
                .slot_id_for_kind(AgentSlotKind::Model)
                .expect("fixture template has model slot")
                .clone(),
            model_selection.clone(),
        ))
        .with_local_bindings(
            AgentProfileLocalBindings::default()
                .with_credential_ref("account.openai.default", "credential.openai.default"),
        )
        .into_published();

        let mut inner = self
            .inner
            .lock()
            .expect("run snapshot repository mutex poisoned");
        inner.profiles.insert(
            profile.id().clone(),
            ProfileSnapshotSource {
                profile,
                profile_version: AgentProfileVersion::initial(),
            },
        );
        inner.components.insert(
            persona_version_id,
            ComponentSnapshotSource {
                version_id: component_snapshot_version_id(
                    ComponentKind::Persona,
                    persona_version_id,
                ),
                entity_version: 1,
            },
        );
        inner
            .models
            .insert(model_selection.binding_id().clone(), model_selection);
    }

    pub(in crate::run_snapshot) fn capture_trusted_host_state(
        &self,
        request: &StartRunRequest,
    ) -> RunSnapshotResult<TrustedHostRunState> {
        let profile = self.profile_source(request.agent_profile_id())?;
        Ok(TrustedHostRunState::capture(
            PermissionState::Granted,
            profile.profile.local_bindings(),
        ))
    }

    fn profile_source(
        &self,
        profile_id: &AgentProfileId,
    ) -> RunSnapshotResult<ProfileSnapshotSource> {
        self.inner
            .lock()
            .expect("run snapshot repository mutex poisoned")
            .profiles
            .get(profile_id)
            .cloned()
            .ok_or_else(|| {
                RunSnapshotError::new(
                    "snapshot.profile_missing",
                    "agent profile could not be found for run snapshot resolution",
                )
            })
    }

    fn component_source(
        &self,
        version_id: UserComponentVersionId,
    ) -> RunSnapshotResult<ComponentSnapshotSource> {
        self.inner
            .lock()
            .expect("run snapshot repository mutex poisoned")
            .components
            .get(&version_id)
            .cloned()
            .ok_or_else(|| {
                RunSnapshotError::new(
                    "snapshot.component_version_missing",
                    "component version could not be found for run snapshot resolution",
                )
            })
    }

    fn model_selection(&self, binding_id: &ModelBindingId) -> RunSnapshotResult<ModelSelection> {
        self.inner
            .lock()
            .expect("run snapshot repository mutex poisoned")
            .models
            .get(binding_id)
            .cloned()
            .ok_or_else(|| {
                RunSnapshotError::new(
                    "snapshot.model_binding_missing",
                    "model binding could not be found for run snapshot resolution",
                )
            })
    }

    fn next_snapshot_id(&self) -> RunSnapshotId {
        let inner = self
            .inner
            .lock()
            .expect("run snapshot repository mutex poisoned");
        RunSnapshotId::new(inner.next_snapshot_id)
    }

    pub(in crate::run_snapshot) fn stage_snapshot(
        &self,
        tx: &mut UnitOfWork,
        snapshot: ResolvedRunSnapshot,
    ) -> StorageResult<()> {
        tx.push_store_write(Box::new(PendingRunSnapshotWrite {
            repository: self.clone(),
            snapshot,
        }));
        Ok(())
    }

    pub fn contains(&self, snapshot_id: RunSnapshotId) -> bool {
        self.inner
            .lock()
            .expect("run snapshot repository mutex poisoned")
            .snapshots
            .contains_key(&snapshot_id)
    }

    pub fn stored_snapshot_profile_version(&self, snapshot_id: RunSnapshotId) -> u64 {
        self.inner
            .lock()
            .expect("run snapshot repository mutex poisoned")
            .snapshots
            .get(&snapshot_id)
            .map(|snapshot| snapshot.profile_version().as_u64())
            .unwrap_or(0)
    }

    pub fn mutate_profile_version_for_test(&self, profile_id: &str) {
        let mut inner = self
            .inner
            .lock()
            .expect("run snapshot repository mutex poisoned");
        if let Some(profile) = inner.profiles.get_mut(&AgentProfileId::new(profile_id)) {
            profile.profile_version =
                AgentProfileVersion::new(profile.profile_version.as_u64() + 1);
        }
    }

    pub fn mutate_component_entity_version_for_test(&self, version_id: &str) {
        let mut inner = self
            .inner
            .lock()
            .expect("run snapshot repository mutex poisoned");
        if let Some(component) = inner
            .components
            .values_mut()
            .find(|component| component.version_id == version_id)
        {
            component.entity_version += 1;
        }
    }

    pub fn mutate_model_catalog_version_for_test(&self, binding_id: &str) {
        let mut inner = self
            .inner
            .lock()
            .expect("run snapshot repository mutex poisoned");
        let binding_id = ModelBindingId::new(binding_id);
        if let Some(selection) = inner.models.get_mut(&binding_id) {
            let next_version = ModelCatalogVersion::new(selection.catalog_version().as_u64() + 1);
            *selection = ModelSelection::new(
                selection.binding_id().clone(),
                selection.provider_account_id(),
                selection.provider_id(),
                selection.model_id(),
                next_version,
            );
        }
    }

    fn validate_snapshot_absent(&self, snapshot_id: RunSnapshotId) -> StorageResult<()> {
        if self.contains(snapshot_id) {
            return Err(StorageError::new(
                "snapshot.duplicate",
                "run snapshot id already exists",
            ));
        }
        Ok(())
    }

    fn commit_snapshot(&self, snapshot: ResolvedRunSnapshot) {
        let mut inner = self
            .inner
            .lock()
            .expect("run snapshot repository mutex poisoned");
        let snapshot_id = snapshot.snapshot_id();
        inner.next_snapshot_id = inner.next_snapshot_id.max(snapshot_id.as_u64() + 1);
        inner.snapshots.insert(snapshot_id, snapshot);
    }
}

impl PendingStoreWrite for PendingRunSnapshotWrite {
    fn validate(&self) -> StorageResult<()> {
        self.repository
            .validate_snapshot_absent(self.snapshot.snapshot_id())
    }

    fn commit(self: Box<Self>) {
        self.repository.commit_snapshot(self.snapshot);
    }
}

fn fixture_model_selection(catalog_version: ModelCatalogVersion) -> ModelSelection {
    ModelSelection::new(
        ModelBindingId::new("model_binding.primary"),
        "account.openai.default",
        "provider.openai",
        "gpt-4.1-mini",
        catalog_version,
    )
}

fn component_snapshot_version_id(
    kind: ComponentKind,
    version_id: UserComponentVersionId,
) -> String {
    format!(
        "{}_v{}",
        component_kind_snapshot_name(kind),
        version_id.as_u64()
    )
}

fn component_kind_snapshot_name(kind: ComponentKind) -> &'static str {
    match kind {
        ComponentKind::BrainPreset => "brain",
        ComponentKind::Persona => "persona",
        ComponentKind::Instruction => "instruction",
        ComponentKind::ToolRecipe => "tool",
        ComponentKind::MemoryProfile => "memory",
        ComponentKind::VoiceProfile => "voice",
        ComponentKind::Prompt => "prompt",
        ComponentKind::Skill => "skill",
    }
}
