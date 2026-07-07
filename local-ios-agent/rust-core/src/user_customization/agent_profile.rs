use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Arc, Mutex, MutexGuard};

use serde::Serialize;

use crate::{
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
pub struct AgentProfileDraft {
    id: AgentProfileId,
    template_id: AgentTemplateId,
    name: String,
    bindings: Vec<ComponentBinding>,
    model_binding: Option<AgentProfileModelBinding>,
    local_bindings: AgentProfileLocalBindings,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgentProfile {
    id: AgentProfileId,
    version: AgentProfileVersion,
    template_id: AgentTemplateId,
    name: String,
    bindings: Vec<ComponentBinding>,
    model_binding: Option<AgentProfileModelBinding>,
    local_bindings: AgentProfileLocalBindings,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct AgentProfileDebugSummary {
    pub profile_id: String,
    pub profile_version: u64,
    pub template_id: String,
    pub name: String,
    pub component_bindings: Vec<ComponentBindingDebugSummary>,
    pub model_binding: Option<ModelBindingDebugSummary>,
    pub local_bindings: Vec<LocalBindingDebugSummary>,
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

impl AgentProfileDraft {
    pub fn new(id: AgentProfileId, template_id: AgentTemplateId, name: impl Into<String>) -> Self {
        Self {
            id,
            template_id,
            name: name.into(),
            bindings: Vec::new(),
            model_binding: None,
            local_bindings: AgentProfileLocalBindings::default(),
        }
    }

    pub fn bind(mut self, binding: ComponentBinding) -> Self {
        self.bindings.push(binding);
        self
    }

    pub fn with_model_binding(mut self, binding: AgentProfileModelBinding) -> Self {
        self.model_binding = Some(binding);
        self
    }

    pub fn with_local_bindings(mut self, local_bindings: AgentProfileLocalBindings) -> Self {
        self.local_bindings = local_bindings;
        self
    }

    pub(crate) fn into_published(self) -> AgentProfile {
        AgentProfile {
            id: self.id,
            version: AgentProfileVersion::initial(),
            template_id: self.template_id,
            name: self.name,
            bindings: self.bindings,
            model_binding: self.model_binding,
            local_bindings: self.local_bindings,
        }
    }

    pub fn template_id(&self) -> &AgentTemplateId {
        &self.template_id
    }

    pub fn bindings(&self) -> &[ComponentBinding] {
        &self.bindings
    }

    pub fn model_binding(&self) -> Option<&AgentProfileModelBinding> {
        self.model_binding.as_ref()
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
        self.records()
            .profiles
            .values()
            .cloned()
            .collect()
    }

    pub fn latest_profiles(&self) -> Vec<AgentProfile> {
        let inner = self.records();
        let mut latest_by_id: BTreeMap<AgentProfileId, AgentProfile> = BTreeMap::new();
        for profile in inner.profiles.values() {
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

    if let Some(model_binding) = draft.model_binding() {
        validate_model_binding(model_binding, template, model_catalog)?;
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

fn validate_required_slots(
    draft: &AgentProfileDraft,
    template: &AgentTemplate,
) -> StorageResult<()> {
    for slot in template.slots().iter().filter(|slot| slot.is_required()) {
        let satisfied = match slot.kind() {
            AgentSlotKind::Model => draft
                .model_binding()
                .map(|binding| binding.slot_id() == slot.id())
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
    pub(crate) fn installed_package_profile(
        id: AgentProfileId,
        template: &AgentTemplate,
        name: impl Into<String>,
        model_binding: Option<AgentProfileModelBinding>,
        local_bindings: AgentProfileLocalBindings,
    ) -> Self {
        Self {
            id,
            version: AgentProfileVersion::initial(),
            template_id: template.id().clone(),
            name: name.into(),
            bindings: Vec::new(),
            model_binding,
            local_bindings,
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
        self.model_binding.as_ref()
    }

    pub fn local_bindings(&self) -> &AgentProfileLocalBindings {
        &self.local_bindings
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
        let Some(model_binding) = self.model_binding() else {
            report.push_issue(AgentReadinessIssue::new(
                "model.missing",
                "profile is missing model binding",
            ));
            return report;
        };

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
            model_binding: self
                .model_binding
                .as_ref()
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
        }
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
