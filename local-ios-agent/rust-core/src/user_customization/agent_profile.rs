use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Arc, Mutex, MutexGuard};

use serde::Serialize;

use crate::{
    llm_contracts::{LLMBindingSchema, LLMInputModality, LLMSlotV2, LLMToolCallingMode},
    model::{ModelBindingCatalog, ModelSelection},
    protocol::{BindingId, ComponentBinding as ProtocolComponentBinding, InstanceId, SlotKey},
    storage::{
        PendingStoreWrite, StorageError, StorageResult, TransactionName, TransactionOperation,
        TransactionRunner, UnitOfWork,
    },
    user_customization::{
        AgentReadinessIssue, AgentReadinessReport, AgentSlotId, AgentSlotKind, AgentTemplate,
        AgentTemplateId, ComponentCatalogService, ComponentKind, UserComponentVersionId,
    },
};

#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct AgentProfileId(String);

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct AgentProfileVersion(u64);

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ComponentSettings {
    values: BTreeMap<String, String>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct AgentProfileLocalBindings {
    credential_refs: BTreeMap<String, String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ComponentBinding {
    slot_id: AgentSlotId,
    slot_kind: AgentSlotKind,
    component_version_id: UserComponentVersionId,
    settings: ComponentSettings,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgentProfileModelBinding {
    slot_id: AgentSlotId,
    selection: ModelSelection,
    settings: ComponentSettings,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum AgentProfileLLMBinding {
    LegacyV1(AgentProfileModelBinding),
    HostSlotV2(LLMSlotV2),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentProfileHostBindingState {
    NotRequired,
    PendingHostBinding,
    HostUnbound,
    Active,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgentProfileDraft {
    id: AgentProfileId,
    template_id: AgentTemplateId,
    name: String,
    bindings: Vec<ComponentBinding>,
    llm_binding: Option<AgentProfileLLMBinding>,
    local_bindings: AgentProfileLocalBindings,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgentProfile {
    id: AgentProfileId,
    version: AgentProfileVersion,
    template_id: AgentTemplateId,
    name: String,
    bindings: Vec<ComponentBinding>,
    llm_binding: Option<AgentProfileLLMBinding>,
    local_bindings: AgentProfileLocalBindings,
    host_binding_state: AgentProfileHostBindingState,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct AgentProfileDebugSummary {
    pub profile_id: String,
    pub profile_version: u64,
    pub template_id: String,
    pub name: String,
    pub component_bindings: Vec<ComponentBindingDebugSummary>,
    pub llm_binding_schema: Option<String>,
    pub llm_slot: Option<LLMSlotDebugSummary>,
    pub model_binding: Option<ModelBindingDebugSummary>,
    pub local_bindings: Vec<LocalBindingDebugSummary>,
    pub host_binding_state: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct ComponentBindingDebugSummary {
    pub slot_id: String,
    pub slot_kind: String,
    pub component_version_id: u64,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct ModelBindingDebugSummary {
    pub slot_id: String,
    pub binding_id: String,
    pub provider_account_id: String,
    pub provider_id: String,
    pub model_id: String,
    pub catalog_version: u64,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct LLMSlotDebugSummary {
    pub slot_id: String,
    pub capabilities: Vec<String>,
    pub input_modalities: Vec<String>,
    pub context_budget: String,
    pub streaming_required: bool,
    pub tool_calling_mode: String,
    pub model_family_hint: Option<String>,
    pub model_id_hint: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct LocalBindingDebugSummary {
    pub binding_key: String,
    pub credential_ref: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgentProfileReference {
    profile_id: AgentProfileId,
    profile_version: Option<AgentProfileVersion>,
}

#[derive(Clone, Debug, Default)]
pub struct InMemoryAgentProfileRepository {
    inner: Arc<Mutex<AgentProfileRecords>>,
}

pub struct AgentProfilePublisher {
    runner: Box<dyn TransactionRunner>,
    repository: InMemoryAgentProfileRepository,
}

#[derive(Default, Debug)]
struct AgentProfileRecords {
    profiles: BTreeMap<(AgentProfileId, AgentProfileVersion), AgentProfile>,
}

struct PendingAgentProfileWrite {
    repository: InMemoryAgentProfileRepository,
    profile: AgentProfile,
}

struct AgentProfilePublishOperation<'a> {
    draft: Option<AgentProfileDraft>,
    profile_version: AgentProfileVersion,
    template: &'a AgentTemplate,
    catalog: &'a ComponentCatalogService,
    model_catalog: &'a ModelBindingCatalog,
    repository: InMemoryAgentProfileRepository,
    result: Option<AgentProfileReference>,
}

impl AgentProfileId {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl AgentProfileVersion {
    pub fn initial() -> Self {
        Self(1)
    }

    pub fn new(value: u64) -> Self {
        Self(value)
    }

    pub fn as_u64(&self) -> u64 {
        self.0
    }
}

impl ComponentSettings {
    pub fn with_value(mut self, key: impl Into<String>, value: impl Into<String>) -> Self {
        self.values.insert(key.into(), value.into());
        self
    }

    pub fn value(&self, key: &str) -> Option<&str> {
        self.values.get(key).map(String::as_str)
    }

    pub fn values(&self) -> &BTreeMap<String, String> {
        &self.values
    }
}

impl AgentProfileLocalBindings {
    pub fn with_credential_ref(
        mut self,
        binding_key: impl Into<String>,
        credential_ref: impl Into<String>,
    ) -> Self {
        self.credential_refs
            .insert(binding_key.into(), credential_ref.into());
        self
    }

    pub fn credential_ref(&self, binding_key: &str) -> Option<&str> {
        self.credential_refs.get(binding_key).map(String::as_str)
    }

    pub fn credential_refs(&self) -> &BTreeMap<String, String> {
        &self.credential_refs
    }

    pub fn is_empty(&self) -> bool {
        self.credential_refs.is_empty()
    }
}

impl ComponentBinding {
    pub fn new(
        slot_id: AgentSlotId,
        slot_kind: AgentSlotKind,
        component_version_id: UserComponentVersionId,
        settings: ComponentSettings,
    ) -> Self {
        Self {
            slot_id,
            slot_kind,
            component_version_id,
            settings,
        }
    }

    pub fn persona(slot_id: AgentSlotId, component_version_id: UserComponentVersionId) -> Self {
        Self {
            slot_id,
            slot_kind: AgentSlotKind::Persona,
            component_version_id,
            settings: ComponentSettings::default(),
        }
    }

    pub fn slot_id(&self) -> &AgentSlotId {
        &self.slot_id
    }

    pub fn slot_kind(&self) -> AgentSlotKind {
        self.slot_kind
    }

    pub fn component_version_id(&self) -> UserComponentVersionId {
        self.component_version_id
    }

    pub fn settings(&self) -> &ComponentSettings {
        &self.settings
    }

    pub fn to_protocol_binding(&self) -> ProtocolComponentBinding {
        let component_version_key = self.component_version_id.stable_key();
        ProtocolComponentBinding::new(
            BindingId::new(format!(
                "binding.{}.{}",
                self.slot_id.as_str(),
                component_version_key
            )),
            SlotKey::new(self.slot_id.as_str()),
            InstanceId::new(component_version_key),
        )
    }
}

impl AgentProfileModelBinding {
    pub fn new(slot_id: AgentSlotId, selection: ModelSelection) -> Self {
        Self {
            slot_id,
            selection,
            settings: ComponentSettings::default(),
        }
    }

    pub fn with_settings(mut self, settings: ComponentSettings) -> Self {
        self.settings = settings;
        self
    }

    pub fn slot_id(&self) -> &AgentSlotId {
        &self.slot_id
    }

    pub fn slot_kind(&self) -> AgentSlotKind {
        AgentSlotKind::Model
    }

    pub fn selection(&self) -> &ModelSelection {
        &self.selection
    }

    pub fn settings(&self) -> &ComponentSettings {
        &self.settings
    }
}

impl AgentProfileLLMBinding {
    pub fn schema(&self) -> LLMBindingSchema {
        match self {
            Self::LegacyV1(_) => LLMBindingSchema::LegacyV1,
            Self::HostSlotV2(_) => LLMBindingSchema::HostSlotV2,
        }
    }

    fn slot_id(&self) -> &str {
        match self {
            Self::LegacyV1(binding) => binding.slot_id().as_str(),
            Self::HostSlotV2(slot) => slot.requirements().slot_id(),
        }
    }
}

impl AgentProfileDraft {
    pub fn new(id: AgentProfileId, template_id: AgentTemplateId, name: impl Into<String>) -> Self {
        Self {
            id,
            template_id,
            name: name.into(),
            bindings: Vec::new(),
            llm_binding: None,
            local_bindings: AgentProfileLocalBindings::default(),
        }
    }

    pub fn bind(mut self, binding: ComponentBinding) -> Self {
        self.bindings.push(binding);
        self
    }

    pub fn with_model_binding(mut self, binding: AgentProfileModelBinding) -> Self {
        self.llm_binding = Some(AgentProfileLLMBinding::LegacyV1(binding));
        self
    }

    pub fn with_llm_slot(mut self, slot: LLMSlotV2) -> Self {
        self.llm_binding = Some(AgentProfileLLMBinding::HostSlotV2(slot));
        self
    }

    pub fn with_local_bindings(mut self, local_bindings: AgentProfileLocalBindings) -> Self {
        self.local_bindings = local_bindings;
        self
    }

    pub(crate) fn into_published(self) -> AgentProfile {
        let host_binding_state = match self.llm_binding.as_ref() {
            Some(AgentProfileLLMBinding::HostSlotV2(_)) => {
                AgentProfileHostBindingState::PendingHostBinding
            }
            _ => AgentProfileHostBindingState::NotRequired,
        };
        AgentProfile {
            id: self.id,
            version: AgentProfileVersion::initial(),
            template_id: self.template_id,
            name: self.name,
            bindings: self.bindings,
            llm_binding: self.llm_binding,
            local_bindings: self.local_bindings,
            host_binding_state,
        }
    }

    pub fn template_id(&self) -> &AgentTemplateId {
        &self.template_id
    }

    pub fn bindings(&self) -> &[ComponentBinding] {
        &self.bindings
    }

    pub fn model_binding(&self) -> Option<&AgentProfileModelBinding> {
        match self.llm_binding.as_ref() {
            Some(AgentProfileLLMBinding::LegacyV1(binding)) => Some(binding),
            _ => None,
        }
    }

    pub fn llm_binding(&self) -> Option<&AgentProfileLLMBinding> {
        self.llm_binding.as_ref()
    }

    pub fn llm_slot(&self) -> Option<&LLMSlotV2> {
        match self.llm_binding.as_ref() {
            Some(AgentProfileLLMBinding::HostSlotV2(slot)) => Some(slot),
            _ => None,
        }
    }
}

impl InMemoryAgentProfileRepository {
    fn records(&self) -> MutexGuard<'_, AgentProfileRecords> {
        self.inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    pub fn stage(&self, tx: &mut UnitOfWork, profile: AgentProfile) -> StorageResult<()> {
        tx.push_store_write(Box::new(PendingAgentProfileWrite {
            repository: self.clone(),
            profile,
        }));
        Ok(())
    }

    pub fn profile(&self, reference: &AgentProfileReference) -> Option<AgentProfile> {
        let inner = self.records();
        let profile_version = reference.profile_version().or_else(|| {
            inner
                .profiles
                .keys()
                .filter(|(profile_id, _)| profile_id == reference.profile_id())
                .map(|(_, version)| *version)
                .max()
        })?;

        inner
            .profiles
            .get(&(reference.profile_id().clone(), profile_version))
            .cloned()
    }

    pub fn profiles(&self) -> Vec<AgentProfile> {
        self.records().profiles.values().cloned().collect()
    }

    pub fn latest_profiles(&self) -> Vec<AgentProfile> {
        let inner = self.records();
        let mut latest_by_id: BTreeMap<AgentProfileId, AgentProfile> = BTreeMap::new();
        for profile in inner.profiles.values().filter(|profile| {
            profile.host_binding_state() != AgentProfileHostBindingState::PendingHostBinding
        }) {
            let replace = latest_by_id
                .get(profile.id())
                .map(|current| profile.version() > current.version())
                .unwrap_or(true);
            if replace {
                latest_by_id.insert(profile.id().clone(), profile.clone());
            }
        }
        latest_by_id.into_values().collect()
    }

    pub fn latest_version(&self, profile_id: &AgentProfileId) -> Option<AgentProfileVersion> {
        self.records()
            .profiles
            .keys()
            .filter(|(id, _)| id == profile_id)
            .map(|(_, version)| *version)
            .max()
    }

    pub fn transition_host_binding_state(
        &self,
        profile_id: &AgentProfileId,
        version: AgentProfileVersion,
        expected: AgentProfileHostBindingState,
        next: AgentProfileHostBindingState,
    ) -> StorageResult<AgentProfile> {
        let mut inner = self.records();
        let profile = inner
            .profiles
            .get_mut(&(profile_id.clone(), version))
            .ok_or_else(|| {
                StorageError::new(
                    "agent_profile.not_found",
                    "agent profile revision was not found",
                )
            })?;
        if profile.host_binding_state != expected {
            return Err(StorageError::new(
                "agent_profile.host_binding_state_stale",
                "agent profile host-binding state changed before transition",
            ));
        }
        profile.host_binding_state = next;
        Ok(profile.clone())
    }

    fn validate_profile(&self, profile: &AgentProfile) -> StorageResult<()> {
        let inner = self.records();
        if inner
            .profiles
            .contains_key(&(profile.id().clone(), profile.version()))
        {
            return Err(StorageError::new(
                "agent_profile.duplicate",
                "agent profile version already exists",
            ));
        }
        Ok(())
    }

    fn commit_profile(&self, profile: AgentProfile) {
        let mut inner = self.records();
        inner
            .profiles
            .insert((profile.id().clone(), profile.version()), profile);
    }
}

impl PendingStoreWrite for PendingAgentProfileWrite {
    fn validate(&self) -> StorageResult<()> {
        self.repository.validate_profile(&self.profile)
    }

    fn commit(self: Box<Self>) {
        self.repository.commit_profile(self.profile);
    }
}

impl AgentProfilePublisher {
    pub fn new(
        runner: Box<dyn TransactionRunner>,
        repository: InMemoryAgentProfileRepository,
    ) -> Self {
        Self { runner, repository }
    }

    pub fn publish(
        &self,
        draft: AgentProfileDraft,
        template: &AgentTemplate,
        catalog: &ComponentCatalogService,
        model_catalog: &ModelBindingCatalog,
    ) -> StorageResult<AgentProfileReference> {
        self.publish_with_version(
            draft,
            AgentProfileVersion::initial(),
            template,
            catalog,
            model_catalog,
        )
    }

    pub fn publish_with_version(
        &self,
        draft: AgentProfileDraft,
        profile_version: AgentProfileVersion,
        template: &AgentTemplate,
        catalog: &ComponentCatalogService,
        model_catalog: &ModelBindingCatalog,
    ) -> StorageResult<AgentProfileReference> {
        let mut operation = AgentProfilePublishOperation {
            draft: Some(draft),
            profile_version,
            template,
            catalog,
            model_catalog,
            repository: self.repository.clone(),
            result: None,
        };

        self.runner.run(
            TransactionName::new("agent_profile.publish"),
            &mut operation,
        )?;

        operation.result.ok_or_else(|| {
            StorageError::new(
                "agent_profile.publish_failed",
                "agent profile publish operation did not produce a reference",
            )
        })
    }
}

impl TransactionOperation for AgentProfilePublishOperation<'_> {
    fn execute(&mut self, tx: &mut UnitOfWork) -> StorageResult<()> {
        let draft = self.draft.take().ok_or_else(|| {
            StorageError::new(
                "agent_profile.publish_reused",
                "agent profile publish operation was reused",
            )
        })?;

        validate_profile_draft(&draft, self.template, self.catalog, self.model_catalog)?;
        let profile = draft.into_published().with_version(self.profile_version);
        let reference = profile.reference();
        self.repository.stage(tx, profile)?;
        self.result = Some(reference.clone());
        Ok(())
    }
}

fn validate_profile_draft(
    draft: &AgentProfileDraft,
    template: &AgentTemplate,
    catalog: &ComponentCatalogService,
    model_catalog: &ModelBindingCatalog,
) -> StorageResult<()> {
    if draft.template_id() != template.id() {
        return Err(StorageError::new(
            "agent_profile.template_mismatch",
            "agent profile draft does not match template",
        ));
    }

    let mut bound_component_slots = BTreeSet::new();
    for binding in draft.bindings() {
        if !bound_component_slots.insert(binding.slot_id().clone()) {
            return Err(StorageError::new(
                "agent_profile.duplicate_slot_binding",
                "agent profile binds the same component slot more than once",
            ));
        }

        let Some(slot) = template.slot_for_id(binding.slot_id()) else {
            return Err(StorageError::new(
                "agent_profile.slot_unsupported",
                "agent profile binding references a slot outside the template",
            ));
        };
        if slot.kind() != binding.slot_kind() {
            return Err(StorageError::new(
                "agent_profile.slot_kind_mismatch",
                "agent profile binding slot kind does not match template slot",
            ));
        }
        validate_component_version(binding, catalog)?;
    }

    if let Some(llm_binding) = draft.llm_binding() {
        match llm_binding {
            AgentProfileLLMBinding::LegacyV1(model_binding) => {
                validate_model_binding(model_binding, template, model_catalog)?;
            }
            AgentProfileLLMBinding::HostSlotV2(slot) => validate_llm_slot(slot, template)?,
        }
    }

    validate_required_slots(draft, template)?;

    Ok(())
}

fn validate_model_binding(
    binding: &AgentProfileModelBinding,
    template: &AgentTemplate,
    model_catalog: &ModelBindingCatalog,
) -> StorageResult<()> {
    let Some(slot) = template.slot_for_id(binding.slot_id()) else {
        return Err(StorageError::new(
            "agent_profile.model_slot_unsupported",
            "agent profile model binding references a slot outside the template",
        ));
    };

    if slot.kind() != AgentSlotKind::Model {
        return Err(StorageError::new(
            "agent_profile.model_slot_kind_mismatch",
            "agent profile model binding must target a model slot",
        ));
    }

    if !binding.selection().is_pinnable() {
        return Err(StorageError::new(
            "agent_profile.model_binding_invalid",
            "agent profile model binding must include a binding id, provider account, provider, model id, and catalog version",
        ));
    }

    if !model_catalog.contains_exact_selection(binding.selection()) {
        return Err(StorageError::new(
            "agent_profile.model_binding_missing",
            "agent profile model binding must reference a known model selection and catalog version",
        ));
    }

    Ok(())
}

fn validate_llm_slot(slot: &LLMSlotV2, template: &AgentTemplate) -> StorageResult<()> {
    let slot_id = slot.requirements().slot_id();
    let Some(template_slot) = template
        .slots()
        .iter()
        .find(|candidate| candidate.id().as_str() == slot_id)
    else {
        return Err(StorageError::new(
            "agent_profile.model_slot_unsupported",
            "agent profile LLM slot references a slot outside the template",
        ));
    };

    if template_slot.kind() != AgentSlotKind::Model {
        return Err(StorageError::new(
            "agent_profile.model_slot_kind_mismatch",
            "agent profile LLM slot must target a model slot",
        ));
    }

    Ok(())
}

fn validate_required_slots(
    draft: &AgentProfileDraft,
    template: &AgentTemplate,
) -> StorageResult<()> {
    for slot in template.slots().iter().filter(|slot| slot.is_required()) {
        let satisfied = match slot.kind() {
            AgentSlotKind::Model => draft
                .llm_binding()
                .map(|binding| binding.slot_id() == slot.id().as_str())
                .unwrap_or(false),
            _ => draft
                .bindings()
                .iter()
                .any(|binding| binding.slot_id() == slot.id()),
        };

        if !satisfied {
            return Err(StorageError::new(
                "agent_profile.required_slot_missing",
                format!(
                    "agent profile is missing required slot {}",
                    slot.id().as_str()
                ),
            ));
        }
    }

    Ok(())
}

fn validate_component_version(
    binding: &ComponentBinding,
    catalog: &ComponentCatalogService,
) -> StorageResult<()> {
    if !binding.component_version_id().is_published() {
        return Err(StorageError::new(
            "agent_profile.component_version_unpublished",
            "agent profile binding must reference a published component version",
        ));
    }

    let version = catalog
        .version(binding.component_version_id())
        .ok_or_else(|| {
            StorageError::new(
                "agent_profile.component_version_missing",
                "agent profile binding references an unknown component version",
            )
        })?;

    let Some(expected_kind) = expected_component_kind_for_slot(binding.slot_kind()) else {
        return Err(StorageError::new(
            "agent_profile.slot_not_component",
            "agent profile binding references a non-component slot",
        ));
    };
    if version.content().kind() != expected_kind {
        return Err(StorageError::new(
            "agent_profile.component_kind_mismatch",
            "agent profile binding component kind does not match slot kind",
        ));
    }

    Ok(())
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

impl AgentProfile {
    pub(crate) fn installed_package_host_slot_profile(
        id: AgentProfileId,
        template: &AgentTemplate,
        name: impl Into<String>,
        llm_slot: LLMSlotV2,
    ) -> Self {
        Self {
            id,
            version: AgentProfileVersion::initial(),
            template_id: template.id().clone(),
            name: name.into(),
            bindings: Vec::new(),
            llm_binding: Some(AgentProfileLLMBinding::HostSlotV2(llm_slot)),
            local_bindings: AgentProfileLocalBindings::default(),
            host_binding_state: AgentProfileHostBindingState::PendingHostBinding,
        }
    }

    pub(crate) fn with_version(mut self, version: AgentProfileVersion) -> Self {
        self.version = version;
        self
    }

    pub fn id(&self) -> &AgentProfileId {
        &self.id
    }

    pub fn version(&self) -> AgentProfileVersion {
        self.version
    }

    pub fn template_id(&self) -> &AgentTemplateId {
        &self.template_id
    }

    pub fn name(&self) -> &str {
        &self.name
    }

    pub fn bindings(&self) -> &[ComponentBinding] {
        &self.bindings
    }

    pub fn model_binding(&self) -> Option<&AgentProfileModelBinding> {
        match self.llm_binding.as_ref() {
            Some(AgentProfileLLMBinding::LegacyV1(binding)) => Some(binding),
            _ => None,
        }
    }

    pub fn llm_binding(&self) -> Option<&AgentProfileLLMBinding> {
        self.llm_binding.as_ref()
    }

    pub fn llm_binding_schema(&self) -> Option<LLMBindingSchema> {
        self.llm_binding
            .as_ref()
            .map(AgentProfileLLMBinding::schema)
    }

    pub fn llm_slot(&self) -> Option<&LLMSlotV2> {
        match self.llm_binding.as_ref() {
            Some(AgentProfileLLMBinding::HostSlotV2(slot)) => Some(slot),
            _ => None,
        }
    }

    pub fn local_bindings(&self) -> &AgentProfileLocalBindings {
        &self.local_bindings
    }

    pub fn host_binding_state(&self) -> AgentProfileHostBindingState {
        self.host_binding_state
    }

    pub fn binding_for_slot(&self, slot_id: &AgentSlotId) -> Option<&ComponentBinding> {
        self.bindings
            .iter()
            .find(|binding| binding.slot_id() == slot_id)
    }

    pub fn bindings_for_kind(&self, slot_kind: AgentSlotKind) -> Vec<&ComponentBinding> {
        self.bindings
            .iter()
            .filter(|binding| binding.slot_kind() == slot_kind)
            .collect()
    }

    pub fn reference(&self) -> AgentProfileReference {
        AgentProfileReference::pinned(self.id.clone(), self.version)
    }

    pub fn readiness(&self) -> AgentReadinessReport {
        let mut report = AgentReadinessReport::ready();
        let Some(llm_binding) = self.llm_binding() else {
            report.push_issue(AgentReadinessIssue::new(
                "model.missing",
                "profile is missing model binding",
            ));
            return report;
        };

        match llm_binding {
            AgentProfileLLMBinding::LegacyV1(model_binding) => {
                if self
                    .local_bindings()
                    .credential_ref(model_binding.selection().provider_account_id())
                    .is_none()
                {
                    report.push_issue(AgentReadinessIssue::new(
                        "local_binding.model_account.missing",
                        "profile model binding is missing a local credential binding",
                    ));
                }
            }
            AgentProfileLLMBinding::HostSlotV2(_)
                if self.host_binding_state != AgentProfileHostBindingState::Active =>
            {
                report.push_issue(AgentReadinessIssue::new(
                    "host_binding.missing",
                    "profile LLM slot requires a Swift host binding",
                ));
            }
            AgentProfileLLMBinding::HostSlotV2(_) => {}
        }

        report
    }

    pub fn debug_summary(&self) -> AgentProfileDebugSummary {
        AgentProfileDebugSummary {
            profile_id: self.id.as_str().to_string(),
            profile_version: self.version.as_u64(),
            template_id: self.template_id.as_str().to_string(),
            name: self.name.clone(),
            component_bindings: self
                .bindings
                .iter()
                .map(|binding| ComponentBindingDebugSummary {
                    slot_id: binding.slot_id().as_str().to_string(),
                    slot_kind: agent_slot_kind_debug_name(binding.slot_kind()).to_string(),
                    component_version_id: binding.component_version_id().as_u64(),
                })
                .collect(),
            llm_binding_schema: self
                .llm_binding_schema()
                .map(llm_binding_schema_name)
                .map(str::to_string),
            llm_slot: self.llm_slot().map(|slot| LLMSlotDebugSummary {
                slot_id: slot.requirements().slot_id().to_string(),
                capabilities: slot
                    .requirements()
                    .capability_requirements()
                    .iter()
                    .map(|requirement| requirement.as_str().to_string())
                    .collect(),
                input_modalities: slot
                    .requirements()
                    .input_modalities()
                    .iter()
                    .map(|modality| llm_input_modality_name(*modality).to_string())
                    .collect(),
                context_budget: slot.requirements().context_budget().to_string(),
                streaming_required: slot.requirements().streaming_required(),
                tool_calling_mode: llm_tool_calling_mode_name(
                    slot.requirements().tool_calling_mode(),
                )
                .to_string(),
                model_family_hint: slot.model_family_hint().map(str::to_string),
                model_id_hint: slot.model_id_hint().map(str::to_string),
            }),
            model_binding: self
                .model_binding()
                .map(|binding| ModelBindingDebugSummary {
                    slot_id: binding.slot_id().as_str().to_string(),
                    binding_id: binding.selection().binding_id().as_str().to_string(),
                    provider_account_id: binding.selection().provider_account_id().to_string(),
                    provider_id: binding.selection().provider_id().to_string(),
                    model_id: binding.selection().model_id().to_string(),
                    catalog_version: binding.selection().catalog_version().as_u64(),
                }),
            local_bindings: self
                .local_bindings
                .credential_refs()
                .keys()
                .map(|binding_key| LocalBindingDebugSummary {
                    binding_key: binding_key.clone(),
                    credential_ref: "[redacted]".to_string(),
                })
                .collect(),
            host_binding_state: match self.host_binding_state {
                AgentProfileHostBindingState::NotRequired => "not_required",
                AgentProfileHostBindingState::PendingHostBinding => "pending_host_binding",
                AgentProfileHostBindingState::HostUnbound => "host_unbound",
                AgentProfileHostBindingState::Active => "active",
            }
            .to_string(),
        }
    }
}

fn llm_binding_schema_name(schema: LLMBindingSchema) -> &'static str {
    match schema {
        LLMBindingSchema::LegacyV1 => "legacy_v1",
        LLMBindingSchema::HostSlotV2 => "host_slot_v2",
    }
}

fn llm_input_modality_name(modality: LLMInputModality) -> &'static str {
    match modality {
        LLMInputModality::Text => "text",
        LLMInputModality::Image => "image",
        LLMInputModality::Audio => "audio",
        LLMInputModality::Video => "video",
    }
}

fn llm_tool_calling_mode_name(mode: LLMToolCallingMode) -> &'static str {
    match mode {
        LLMToolCallingMode::Disabled => "disabled",
        LLMToolCallingMode::Allowed => "allowed",
        LLMToolCallingMode::Required => "required",
    }
}

fn agent_slot_kind_debug_name(kind: AgentSlotKind) -> &'static str {
    match kind {
        AgentSlotKind::Brain => "brain",
        AgentSlotKind::Persona => "persona",
        AgentSlotKind::Instruction => "instruction",
        AgentSlotKind::Model => "model",
        AgentSlotKind::Toolset => "toolset",
        AgentSlotKind::Memory => "memory",
        AgentSlotKind::Voice => "voice",
    }
}

impl AgentProfileReference {
    pub fn latest(profile_id: AgentProfileId) -> Self {
        Self::new(profile_id)
    }

    pub fn pinned(profile_id: AgentProfileId, profile_version: AgentProfileVersion) -> Self {
        Self {
            profile_id,
            profile_version: Some(profile_version),
        }
    }

    pub(crate) fn new(profile_id: AgentProfileId) -> Self {
        Self {
            profile_id,
            profile_version: None,
        }
    }

    pub fn with_version(mut self, profile_version: AgentProfileVersion) -> Self {
        self.profile_version = Some(profile_version);
        self
    }

    pub fn profile_id(&self) -> &AgentProfileId {
        &self.profile_id
    }

    pub fn profile_version(&self) -> Option<AgentProfileVersion> {
        self.profile_version
    }
}
