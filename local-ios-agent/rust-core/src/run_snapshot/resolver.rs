use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};

use crate::llm_contracts::{
    AgentLLMRequirements, LLMBindingSchema, LLMInputModality, LLMSlotV2, LLMToolCallingMode,
};
use crate::model::{
    InMemoryModelBindingCatalog, ModelBindingId, ModelCatalogVersion, ModelSelection,
};
use crate::run_snapshot::{
    CredentialAvailability, LocalBindingState, ResolvedComponentBinding, ResolvedMemoryBinding,
    ResolvedModelBinding, ResolvedRunSnapshot, ResolvedToolBinding, ResolvedVoiceBinding,
    RunSnapshotError, RunSnapshotId, RunSnapshotReadinessIssue, RunSnapshotReadinessReport,
    RunSnapshotResolveInput, RunSnapshotResult, StartRunRequest, TrustedHostRunState,
};
use crate::security::{
    CapabilityRequirement, CredentialPurpose, CredentialRef, CredentialRefResolver,
    InMemoryCredentialResolver, PermissionState, SecurityPermissionService,
    StaticSecurityPermissionService,
};
use crate::storage::{
    InMemoryTransactionRunner, PendingStoreWrite, StorageError, StorageResult, TransactionName,
    TransactionOperation, TransactionRunner, UnitOfWork,
};
use crate::user_customization::{
    AgentProfile, AgentProfileDraft, AgentProfileId, AgentProfileLocalBindings,
    AgentProfileModelBinding, AgentProfileReference, AgentProfileVersion, AgentSlotKind,
    AgentTemplate, ComponentBinding, ComponentCatalogService, ComponentContent, ComponentKind,
    InMemoryAgentProfileRepository, UserComponentVersionId,
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
    component_catalog: ComponentCatalogService,
    model_catalog: InMemoryModelBindingCatalog,
    security: Arc<dyn SecurityPermissionService>,
    credential_resolver: Arc<dyn CredentialRefResolver>,
    component_entity_versions: Arc<Mutex<BTreeMap<UserComponentVersionId, u64>>>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ProfileExecutionRoute {
    schema_version: u32,
    profile_id: String,
    profile_revision: u64,
    llm_binding_schema: LLMBindingSchema,
}

impl ProfileExecutionRoute {
    pub fn schema_version(&self) -> u32 {
        self.schema_version
    }

    pub fn profile_id(&self) -> &str {
        &self.profile_id
    }

    pub fn profile_revision(&self) -> u64 {
        self.profile_revision
    }

    pub fn llm_binding_schema(&self) -> LLMBindingSchema {
        self.llm_binding_schema
    }
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

#[derive(Debug)]
struct RunSnapshotRepositoryRecords {
    snapshots: BTreeMap<RunSnapshotId, ResolvedRunSnapshot>,
    next_snapshot_id: u64,
}

#[derive(Clone, Debug)]
struct ComponentSnapshotSource {
    version_id: String,
    entity_version: u64,
    kind: ComponentKind,
    content: ComponentContent,
}

struct PendingRunSnapshotWrite {
    repository: RunSnapshotRepository,
    snapshot: ResolvedRunSnapshot,
    committed_snapshot: Arc<Mutex<Option<ResolvedRunSnapshot>>>,
}

struct AgentProfileStageOperation {
    repository: InMemoryAgentProfileRepository,
    profile: Option<AgentProfile>,
}

struct ModelSelectionStageOperation {
    catalog: InMemoryModelBindingCatalog,
    selection: ModelSelection,
}

impl Default for RunSnapshotRepositoryRecords {
    fn default() -> Self {
        Self {
            snapshots: BTreeMap::new(),
            next_snapshot_id: 1,
        }
    }
}

impl RunSnapshotResolver {
    pub fn new(sources: RunSnapshotSourceCatalog) -> Self {
        Self { sources }
    }

    pub fn resolve(
        &self,
        input: RunSnapshotResolveInput,
    ) -> RunSnapshotResult<ResolvedRunSnapshot> {
        let (request, trusted_host_state) = input.into_parts();
        let profile = self
            .sources
            .profile(request.agent_profile_id(), request.profile_revision_id())?;
        if profile.llm_slot().is_some() {
            return Err(RunSnapshotError::new(
                "execution.host_slot_v2_requires_preparation",
                "host-backed LLM slots must enter through authoritative preparation",
            ));
        }
        let component_versions = self.resolve_components(profile.bindings())?;
        let model_binding = self.resolve_model_binding(&profile)?;
        let tool_bindings = self.resolve_tool_bindings(&component_versions);
        let memory_binding = self.resolve_memory_binding(&component_versions);
        let voice_binding = self.resolve_voice_binding(&component_versions);
        let readiness_report = readiness_from_trusted_host_state(&trusted_host_state);

        Ok(ResolvedRunSnapshot::new(
            RunSnapshotId::unpersisted(),
            request,
            profile.version(),
            component_versions,
            model_binding,
            tool_bindings,
            memory_binding,
            voice_binding,
            trusted_host_state,
            readiness_report,
            0,
        ))
    }

    pub fn profile_execution_route(
        &self,
        profile_id: &AgentProfileId,
        profile_revision: AgentProfileVersion,
    ) -> RunSnapshotResult<ProfileExecutionRoute> {
        let profile = self.sources.profile(profile_id, profile_revision)?;
        let llm_binding_schema = profile.llm_binding_schema().ok_or_else(|| {
            RunSnapshotError::new(
                "execution.llm_binding_missing",
                "agent profile revision does not declare an LLM binding schema",
            )
        })?;
        Ok(ProfileExecutionRoute {
            schema_version: 1,
            profile_id: profile.id().as_str().to_string(),
            profile_revision: profile.version().as_u64(),
            llm_binding_schema,
        })
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
            .sources
            .model_selection(profile_model.selection().binding_id())?;
        if &current_selection != profile_model.selection() {
            return Err(RunSnapshotError::new(
                "snapshot.model_selection_conflict",
                "model catalog selection no longer matches the agent profile model pin",
            ));
        }
        Ok(ResolvedModelBinding::from_selection(&current_selection))
    }

    fn resolve_tool_bindings(
        &self,
        component_versions: &[ResolvedComponentBinding],
    ) -> Vec<ResolvedToolBinding> {
        component_versions
            .iter()
            .filter(|binding| binding.slot_kind() == AgentSlotKind::Toolset)
            .cloned()
            .map(|binding| ResolvedToolBinding::new(binding.slot_id().clone(), binding))
            .collect()
    }

    fn resolve_memory_binding(
        &self,
        component_versions: &[ResolvedComponentBinding],
    ) -> Option<ResolvedMemoryBinding> {
        component_versions
            .iter()
            .find(|binding| binding.slot_kind() == AgentSlotKind::Memory)
            .cloned()
            .map(|binding| ResolvedMemoryBinding::new(binding.slot_id().clone(), binding))
    }

    fn resolve_voice_binding(
        &self,
        component_versions: &[ResolvedComponentBinding],
    ) -> Option<ResolvedVoiceBinding> {
        component_versions
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
        model_catalog: InMemoryModelBindingCatalog,
        security: Arc<dyn SecurityPermissionService>,
        credential_resolver: Arc<dyn CredentialRefResolver>,
    ) -> Self {
        Self {
            profile_repository,
            component_catalog,
            model_catalog,
            security,
            credential_resolver,
            component_entity_versions: Arc::new(Mutex::new(BTreeMap::new())),
        }
    }

    pub fn fixture_profile_with_persona_and_model() -> Self {
        Self::fixture_with_options(FixtureOptions::default())
    }

    pub fn fixture_with_profile_version(profile_version: u64) -> Self {
        Self::fixture_with_options(FixtureOptions {
            profile_version,
            ..FixtureOptions::default()
        })
    }

    pub fn fixture_with_component_entity_version(entity_version: u64) -> Self {
        Self::fixture_with_options(FixtureOptions {
            component_entity_version: entity_version,
            ..FixtureOptions::default()
        })
    }

    pub fn fixture_with_model_catalog_version(catalog_version: u64) -> Self {
        Self::fixture_with_options(FixtureOptions {
            model_catalog_version: catalog_version,
            ..FixtureOptions::default()
        })
    }

    pub fn fixture_with_model_id_at_same_catalog_version(model_id: impl Into<String>) -> Self {
        Self::fixture_with_options(FixtureOptions {
            model_id: model_id.into(),
            ..FixtureOptions::default()
        })
    }

    pub fn fixture_with_permission_state(permission_state: PermissionState) -> Self {
        Self::fixture_with_options(FixtureOptions {
            permission_state,
            ..FixtureOptions::default()
        })
    }

    pub fn fixture_without_credentials() -> Self {
        Self::fixture_with_options(FixtureOptions {
            include_credentials: false,
            ..FixtureOptions::default()
        })
    }

    pub fn fixture_with_host_slot_v2() -> Self {
        Self::fixture_with_options(FixtureOptions {
            host_slot_v2: true,
            include_credentials: false,
            ..FixtureOptions::default()
        })
    }

    fn fixture_with_options(options: FixtureOptions) -> Self {
        let template = AgentTemplate::assistant_default();
        let component_catalog = ComponentCatalogService::default();
        let persona_component_id =
            component_catalog.create_draft(ComponentContent::persona("Researcher"));
        let persona_version = component_catalog
            .publish(persona_component_id)
            .expect("fixture persona should publish");
        let model_catalog = InMemoryModelBindingCatalog::default();
        let model_selection = fixture_model_selection(
            ModelCatalogVersion::new(options.model_catalog_version),
            options.model_id,
        );
        stage_model_selection(&model_catalog, model_selection.clone());

        let profile_repository = InMemoryAgentProfileRepository::default();
        let draft = AgentProfileDraft::new(
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
        ));
        let draft = if options.host_slot_v2 {
            draft.with_llm_slot(LLMSlotV2::new(
                AgentLLMRequirements::new(
                    template
                        .slot_id_for_kind(AgentSlotKind::Model)
                        .expect("fixture template has model slot")
                        .as_str(),
                    4096,
                    true,
                    LLMToolCallingMode::Allowed,
                )
                .requiring_input_modality(LLMInputModality::Text),
            ))
        } else {
            draft
                .with_model_binding(AgentProfileModelBinding::new(
                    template
                        .slot_id_for_kind(AgentSlotKind::Model)
                        .expect("fixture template has model slot")
                        .clone(),
                    model_selection,
                ))
                .with_local_bindings(
                    AgentProfileLocalBindings::default()
                        .with_credential_ref("account.openai.default", "credential.openai.default"),
                )
        };
        let profile = draft
            .into_published()
            .with_version(AgentProfileVersion::new(options.profile_version));
        stage_profile(&profile_repository, profile);

        let security = Arc::new(
            StaticSecurityPermissionService::default()
                .with_permission("run.start", options.permission_state),
        );
        let credential_resolver: Arc<dyn CredentialRefResolver> = if options.include_credentials {
            Arc::new(InMemoryCredentialResolver::default().with_secret_for(
                "credential.openai.default",
                "secret",
                [CredentialPurpose::RemoteProvider],
            ))
        } else {
            Arc::new(InMemoryCredentialResolver::default())
        };

        let sources = Self::new(
            profile_repository,
            component_catalog,
            model_catalog,
            security,
            credential_resolver,
        );
        sources
            .component_entity_versions
            .lock()
            .expect("component entity versions mutex poisoned")
            .insert(persona_version, options.component_entity_version);
        sources
    }

    pub(in crate::run_snapshot) fn capture_trusted_host_state(
        &self,
        request: &StartRunRequest,
    ) -> RunSnapshotResult<TrustedHostRunState> {
        let profile = self.profile(request.agent_profile_id(), request.profile_revision_id())?;
        let permission_state = self
            .security
            .permission_state(&[CapabilityRequirement::new("run.start")]);
        let local_bindings = LocalBindingState::from_profile(profile.local_bindings());
        let mut credential_availability = CredentialAvailability::default();
        let required_model_credential_key = profile
            .model_binding()
            .map(|binding| binding.selection().provider_account_id().to_string());

        if let Some(binding_key) = required_model_credential_key.as_deref() {
            let credential_ref = profile
                .local_bindings()
                .credential_ref(binding_key)
                .ok_or_else(|| {
                    RunSnapshotError::new(
                        "snapshot.credential_binding_missing",
                        "agent profile model binding is missing a local credential binding",
                    )
                })?;
            resolve_credential_ref(
                self.credential_resolver.as_ref(),
                binding_key,
                credential_ref,
            )?;
            credential_availability =
                credential_availability.with_available_ref(binding_key, credential_ref);
        }

        for (binding_key, credential_ref) in profile.local_bindings().credential_refs() {
            if required_model_credential_key.as_deref() == Some(binding_key.as_str()) {
                continue;
            }
            resolve_credential_ref(
                self.credential_resolver.as_ref(),
                binding_key,
                credential_ref,
            )?;
            credential_availability =
                credential_availability.with_available_ref(binding_key, credential_ref);
        }

        Ok(TrustedHostRunState::new(
            permission_state,
            local_bindings,
            credential_availability,
        ))
    }

    fn profile(
        &self,
        profile_id: &AgentProfileId,
        profile_revision_id: AgentProfileVersion,
    ) -> RunSnapshotResult<AgentProfile> {
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

    fn model_selection(&self, binding_id: &ModelBindingId) -> RunSnapshotResult<ModelSelection> {
        self.model_catalog.selection(binding_id).ok_or_else(|| {
            RunSnapshotError::new(
                "snapshot.model_binding_missing",
                "model binding could not be found for run snapshot resolution",
            )
        })
    }
}

impl RunSnapshotRepository {
    pub(in crate::run_snapshot) fn stage_snapshot(
        &self,
        tx: &mut UnitOfWork,
        snapshot: ResolvedRunSnapshot,
        committed_snapshot: Arc<Mutex<Option<ResolvedRunSnapshot>>>,
    ) -> StorageResult<()> {
        tx.push_store_write(Box::new(PendingRunSnapshotWrite {
            repository: self.clone(),
            snapshot,
            committed_snapshot,
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

    fn commit_snapshot(&self, snapshot: ResolvedRunSnapshot) -> ResolvedRunSnapshot {
        let mut inner = self
            .inner
            .lock()
            .expect("run snapshot repository mutex poisoned");
        let snapshot_id = RunSnapshotId::new(inner.next_snapshot_id);
        inner.next_snapshot_id += 1;
        let snapshot = snapshot.with_snapshot_id(snapshot_id);
        inner.snapshots.insert(snapshot_id, snapshot.clone());
        snapshot
    }
}

impl PendingStoreWrite for PendingRunSnapshotWrite {
    fn validate(&self) -> StorageResult<()> {
        Ok(())
    }

    fn commit(self: Box<Self>) {
        let snapshot = self.repository.commit_snapshot(self.snapshot);
        *self
            .committed_snapshot
            .lock()
            .expect("committed snapshot mutex poisoned") = Some(snapshot);
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

impl TransactionOperation for ModelSelectionStageOperation {
    fn execute(&mut self, tx: &mut UnitOfWork) -> StorageResult<()> {
        self.catalog.stage(tx, self.selection.clone())
    }
}

#[derive(Clone, Debug)]
struct FixtureOptions {
    profile_version: u64,
    component_entity_version: u64,
    model_catalog_version: u64,
    model_id: String,
    permission_state: PermissionState,
    include_credentials: bool,
    host_slot_v2: bool,
}

impl Default for FixtureOptions {
    fn default() -> Self {
        Self {
            profile_version: 1,
            component_entity_version: 1,
            model_catalog_version: 7,
            model_id: "gpt-4.1-mini".to_string(),
            permission_state: PermissionState::Granted,
            include_credentials: true,
            host_slot_v2: false,
        }
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

fn stage_model_selection(catalog: &InMemoryModelBindingCatalog, selection: ModelSelection) {
    let mut operation = ModelSelectionStageOperation {
        catalog: catalog.clone(),
        selection,
    };
    InMemoryTransactionRunner::default()
        .run(
            TransactionName::new("run_snapshot.fixture.model_binding"),
            &mut operation,
        )
        .expect("fixture model selection should stage");
}

fn fixture_model_selection(
    catalog_version: ModelCatalogVersion,
    model_id: impl Into<String>,
) -> ModelSelection {
    ModelSelection::new(
        ModelBindingId::new("model_binding.primary"),
        "account.openai.default",
        "provider.openai",
        model_id,
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

fn resolve_credential_ref(
    resolver: &dyn CredentialRefResolver,
    binding_key: &str,
    credential_ref: &str,
) -> RunSnapshotResult<()> {
    resolver
        .resolve(
            &CredentialRef::new(credential_ref),
            CredentialPurpose::RemoteProvider,
        )
        .map(|_| ())
        .map_err(|error| {
            RunSnapshotError::new(
                "snapshot.credential_unavailable",
                format!(
                    "credential {} for binding {} is unavailable for run snapshot resolution: {}",
                    credential_ref, binding_key, error
                ),
            )
        })
}

fn readiness_from_trusted_host_state(
    trusted_host_state: &TrustedHostRunState,
) -> RunSnapshotReadinessReport {
    let mut report = RunSnapshotReadinessReport::ready();
    if trusted_host_state.permission_state() != &PermissionState::Granted {
        report = report.with_issue(RunSnapshotReadinessIssue::new(
            "snapshot.permission_not_granted",
            "required run permissions are not granted",
        ));
    }
    report
}
