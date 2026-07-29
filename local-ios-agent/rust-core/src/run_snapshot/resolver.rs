use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use serde::Serialize;

use crate::llm_contracts::{AgentLLMRequirements, LLMInputModality, LLMSlotV2, LLMToolCallingMode};
use crate::run_snapshot::{
    ResolvedComponentBinding, ResolvedMemoryBinding, ResolvedRunSnapshot, ResolvedToolBinding,
    ResolvedVoiceBinding, RunSnapshotError, RunSnapshotId, RunSnapshotResolveInput,
    RunSnapshotResult, StartRunRequest,
};
use crate::storage::{
    InMemoryTransactionRunner, StorageError, StorageResult, TransactionName, TransactionOperation,
    TransactionRunner, UnifiedRuntimeStateRepository, UnitOfWork,
};
use crate::user_customization::{
    AgentProfile, AgentProfileDraft, AgentProfileId, AgentProfileReference, AgentProfileVersion,
    AgentSlotKind, AgentTemplate, ComponentBinding, ComponentCatalogService, ComponentContent,
    ComponentKind, InMemoryAgentProfileRepository, UserComponentVersionId,
};

#[derive(Clone)]
pub struct RunSnapshotResolver {
    sources: RunSnapshotSourceCatalog,
}

#[derive(Clone, Debug, Default)]
pub struct RunSnapshotRepository {
    inner: Arc<Mutex<RunSnapshotRepositoryRecords>>,
}

#[derive(Clone)]
pub struct RunSnapshotSourceCatalog {
    profile_repository: InMemoryAgentProfileRepository,
    runtime_state: Option<Arc<dyn UnifiedRuntimeStateRepository>>,
    component_catalog: ComponentCatalogService,
    component_entity_versions: Arc<Mutex<BTreeMap<UserComponentVersionId, u64>>>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct HostSlotPreparationSources {
    pub(crate) profile_version: AgentProfileVersion,
    pub(crate) requirements: AgentLLMRequirements,
    pub(crate) component_versions: Vec<ResolvedComponentBinding>,
    pub(crate) tool_bindings: Vec<ResolvedToolBinding>,
    pub(crate) memory_binding: Option<ResolvedMemoryBinding>,
    pub(crate) voice_binding: Option<ResolvedVoiceBinding>,
    pub(crate) tool_schema_sources: Vec<ToolSchemaSourceDocument>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub(crate) struct ToolSchemaSourceDocument {
    slot_id: String,
    component_version: String,
    entity_version: String,
    content: ComponentContent,
}

#[derive(Debug, Default)]
struct RunSnapshotRepositoryRecords {
    snapshots: BTreeMap<RunSnapshotId, ResolvedRunSnapshot>,
}

#[derive(Clone, Debug)]
struct ComponentSnapshotSource {
    version_id: String,
    entity_version: u64,
    kind: ComponentKind,
    content: ComponentContent,
}

struct AgentProfileStageOperation {
    repository: InMemoryAgentProfileRepository,
    profile: Option<AgentProfile>,
}

impl RunSnapshotResolver {
    pub fn new(sources: RunSnapshotSourceCatalog) -> Self {
        Self { sources }
    }

    pub fn resolve(
        &self,
        input: RunSnapshotResolveInput,
    ) -> RunSnapshotResult<ResolvedRunSnapshot> {
        let _ = input.into_request();
        Err(RunSnapshotError::new(
            "execution.host_slot_v2_requires_preparation",
            "host-backed LLM slots must enter through authoritative preparation",
        ))
    }

    pub(crate) fn resolve_host_slot_preparation(
        &self,
        request: &StartRunRequest,
    ) -> RunSnapshotResult<HostSlotPreparationSources> {
        let profile = self
            .sources
            .profile(request.agent_profile_id(), request.profile_revision_id())?;
        let slot = profile.llm_slot().ok_or_else(|| {
            RunSnapshotError::new(
                "preparation.host_slot_v2_required",
                "authoritative LLM preparation requires an LLMSlotV2 profile revision",
            )
        })?;
        let component_versions = self.resolve_components(profile.bindings())?;
        let tool_bindings = self.resolve_tool_bindings(&component_versions);
        let memory_binding = self.resolve_memory_binding(&component_versions);
        let voice_binding = self.resolve_voice_binding(&component_versions);
        let tool_schema_sources = profile
            .bindings()
            .iter()
            .filter(|binding| binding.slot_kind() == AgentSlotKind::Toolset)
            .map(|binding| {
                let source = self
                    .sources
                    .component_source(binding.component_version_id())?;
                Ok(ToolSchemaSourceDocument {
                    slot_id: binding.slot_id().as_str().to_string(),
                    component_version: source.version_id,
                    entity_version: source.entity_version.to_string(),
                    content: source.content,
                })
            })
            .collect::<RunSnapshotResult<Vec<_>>>()?;
        Ok(HostSlotPreparationSources {
            profile_version: profile.version(),
            requirements: slot.requirements().clone(),
            component_versions,
            tool_bindings,
            memory_binding,
            voice_binding,
            tool_schema_sources,
        })
    }

    fn resolve_components(
        &self,
        bindings: &[ComponentBinding],
    ) -> RunSnapshotResult<Vec<ResolvedComponentBinding>> {
        bindings
            .iter()
            .map(|binding| {
                let source = self
                    .sources
                    .component_source(binding.component_version_id())?;
                let Some(expected_kind) = expected_component_kind_for_slot(binding.slot_kind())
                else {
                    return Err(RunSnapshotError::new(
                        "snapshot.slot_not_component",
                        "run snapshot component binding references a non-component slot",
                    ));
                };
                if source.kind != expected_kind {
                    return Err(RunSnapshotError::new(
                        "snapshot.component_kind_mismatch",
                        "run snapshot component kind no longer matches the profile slot kind",
                    ));
                }
                Ok(ResolvedComponentBinding::new(
                    binding.slot_id().clone(),
                    binding.slot_kind(),
                    source.version_id,
                    source.entity_version,
                ))
            })
            .collect()
    }

    fn resolve_tool_bindings(
        &self,
        components: &[ResolvedComponentBinding],
    ) -> Vec<ResolvedToolBinding> {
        components
            .iter()
            .filter(|binding| binding.slot_kind() == AgentSlotKind::Toolset)
            .cloned()
            .map(|binding| ResolvedToolBinding::new(binding.slot_id().clone(), binding))
            .collect()
    }

    fn resolve_memory_binding(
        &self,
        components: &[ResolvedComponentBinding],
    ) -> Option<ResolvedMemoryBinding> {
        components
            .iter()
            .find(|binding| binding.slot_kind() == AgentSlotKind::Memory)
            .cloned()
            .map(|binding| ResolvedMemoryBinding::new(binding.slot_id().clone(), binding))
    }

    fn resolve_voice_binding(
        &self,
        components: &[ResolvedComponentBinding],
    ) -> Option<ResolvedVoiceBinding> {
        components
            .iter()
            .find(|binding| binding.slot_kind() == AgentSlotKind::Voice)
            .cloned()
            .map(|binding| ResolvedVoiceBinding::new(binding.slot_id().clone(), binding))
    }
}

impl RunSnapshotSourceCatalog {
    pub fn new(
        profile_repository: InMemoryAgentProfileRepository,
        component_catalog: ComponentCatalogService,
    ) -> Self {
        Self {
            profile_repository,
            runtime_state: None,
            component_catalog,
            component_entity_versions: Arc::new(Mutex::new(BTreeMap::new())),
        }
    }

    pub fn new_unified(
        runtime_state: Arc<dyn UnifiedRuntimeStateRepository>,
        profile_repository: InMemoryAgentProfileRepository,
        component_catalog: ComponentCatalogService,
    ) -> Self {
        let mut catalog = Self::new(profile_repository, component_catalog);
        catalog.runtime_state = Some(runtime_state);
        catalog
    }

    pub fn fixture_profile_with_persona_and_model() -> Self {
        Self::fixture_with_options(1, 1)
    }

    pub fn fixture_with_profile_version(profile_version: u64) -> Self {
        Self::fixture_with_options(profile_version, 1)
    }

    pub fn fixture_with_component_entity_version(entity_version: u64) -> Self {
        Self::fixture_with_options(1, entity_version)
    }

    pub fn fixture_with_host_slot_v2() -> Self {
        Self::fixture_with_options(1, 1)
    }

    fn fixture_with_options(profile_version: u64, component_entity_version: u64) -> Self {
        let template = AgentTemplate::assistant_default();
        let component_catalog = ComponentCatalogService::default();
        let persona_component_id =
            component_catalog.create_draft(ComponentContent::persona("Researcher"));
        let persona_version = component_catalog
            .publish(persona_component_id)
            .expect("fixture persona should publish");
        let profile_repository = InMemoryAgentProfileRepository::default();
        let llm_slot = LLMSlotV2::new(
            AgentLLMRequirements::new(
                template
                    .slot_id_for_kind(AgentSlotKind::Model)
                    .expect("fixture template has model slot")
                    .as_str(),
                4_096,
                true,
                LLMToolCallingMode::Allowed,
            )
            .requiring_input_modality(LLMInputModality::Text),
        );
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
            persona_version,
        ))
        .with_llm_slot(llm_slot)
        .into_published()
        .with_version(AgentProfileVersion::new(profile_version));
        stage_profile(&profile_repository, profile);

        let sources = Self::new(profile_repository, component_catalog);
        sources
            .component_entity_versions
            .lock()
            .expect("component entity versions mutex poisoned")
            .insert(persona_version, component_entity_version);
        sources
    }

    fn profile(
        &self,
        profile_id: &AgentProfileId,
        profile_revision_id: AgentProfileVersion,
    ) -> RunSnapshotResult<AgentProfile> {
        if let Some(runtime_state) = &self.runtime_state {
            if let Some(profile) = runtime_state
                .agent_profile_exact(profile_id, profile_revision_id)
                .map_err(|error| {
                    RunSnapshotError::new(error.code().to_string(), error.to_string())
                })?
            {
                return Ok(profile);
            }
        }
        self.profile_repository
            .profile(&AgentProfileReference::pinned(
                profile_id.clone(),
                profile_revision_id,
            ))
            .ok_or_else(|| {
                RunSnapshotError::new(
                    "snapshot.profile_revision_missing",
                    "agent profile revision could not be found for run snapshot resolution",
                )
            })
    }

    fn component_source(
        &self,
        version_id: UserComponentVersionId,
    ) -> RunSnapshotResult<ComponentSnapshotSource> {
        let version = self.component_catalog.version(version_id).ok_or_else(|| {
            RunSnapshotError::new(
                "snapshot.component_version_missing",
                "component version could not be found for run snapshot resolution",
            )
        })?;
        let kind = version.content().kind();
        let entity_version = self
            .component_entity_versions
            .lock()
            .expect("component entity versions mutex poisoned")
            .get(&version_id)
            .copied()
            .unwrap_or_else(|| version_id.as_u64());
        Ok(ComponentSnapshotSource {
            version_id: component_snapshot_version_id(kind, version_id),
            entity_version,
            kind,
            content: version.content().clone(),
        })
    }
}

impl RunSnapshotRepository {
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
}

impl TransactionOperation for AgentProfileStageOperation {
    fn execute(&mut self, tx: &mut UnitOfWork) -> StorageResult<()> {
        let profile = self.profile.take().ok_or_else(|| {
            StorageError::new(
                "snapshot.fixture_profile_stage_reused",
                "profile stage operation was reused",
            )
        })?;
        self.repository.stage(tx, profile)
    }
}

fn stage_profile(repository: &InMemoryAgentProfileRepository, profile: AgentProfile) {
    let mut operation = AgentProfileStageOperation {
        repository: repository.clone(),
        profile: Some(profile),
    };
    InMemoryTransactionRunner::default()
        .run(
            TransactionName::new("run_snapshot.fixture.profile"),
            &mut operation,
        )
        .expect("fixture profile should stage");
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

fn expected_component_kind_for_slot(slot_kind: AgentSlotKind) -> Option<ComponentKind> {
    match slot_kind {
        AgentSlotKind::Brain => Some(ComponentKind::BrainPreset),
        AgentSlotKind::Persona => Some(ComponentKind::Persona),
        AgentSlotKind::Instruction => Some(ComponentKind::Instruction),
        AgentSlotKind::Model => None,
        AgentSlotKind::Toolset => Some(ComponentKind::ToolRecipe),
        AgentSlotKind::Memory => Some(ComponentKind::MemoryProfile),
        AgentSlotKind::Voice => Some(ComponentKind::VoiceProfile),
    }
}
