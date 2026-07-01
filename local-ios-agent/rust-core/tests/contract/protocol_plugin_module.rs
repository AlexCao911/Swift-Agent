use local_ios_agent_runtime::protocol::{
    CargoFeature, HostCapabilityManifest, InferenceBackendDefinition, LegacyRuntimeAdapterPlugin,
    ModuleId, PluginModule, PluginRegistryBuilder, RegistryError, RegistryResult, StaticPluginList,
    StaticPluginModule, StaticPluginRegistration,
};

#[cfg(feature = "builtin-openai-compatible")]
use local_ios_agent_runtime::protocol::BuiltinProviderPlugin;

struct TestNativeInferencePlugin;

impl PluginModule for TestNativeInferencePlugin {
    fn module_id(&self) -> ModuleId {
        ModuleId::new("test.inference.native")
    }

    fn required_host_capabilities(&self) -> &'static [&'static str] {
        &["native_inference"]
    }

    fn register(&self, builder: &mut PluginRegistryBuilder) -> RegistryResult<()> {
        builder.require_host_capability("native_inference")?;
        builder.register_inference_backend(InferenceBackendDefinition::new("inference.test_native"))
    }
}

#[test]
fn plugin_module_registers_inference_backend_and_freezes_runtime_registry() {
    let host = HostCapabilityManifest::all_supported();
    let mut builder = PluginRegistryBuilder::new(host);
    TestNativeInferencePlugin.register(&mut builder).unwrap();

    let registry = builder.freeze().unwrap();

    assert!(registry
        .inference_backends()
        .contains("inference.test_native"));
    assert!(registry.providers().is_frozen());
    assert!(registry.models().is_frozen());
    assert!(registry.inference_backends().is_frozen());
    assert!(registry.prompt_compilers().is_frozen());
    assert!(registry.tools().is_frozen());
    assert!(registry.memory().is_frozen());
    assert!(registry.context_policies().is_frozen());
    assert!(registry.voice().is_frozen());
}

#[test]
fn host_capability_manifest_blocks_unsupported_plugin() {
    let host = HostCapabilityManifest::new(["keychain", "network"]);
    let mut builder = PluginRegistryBuilder::new(host);

    let error = TestNativeInferencePlugin
        .register(&mut builder)
        .unwrap_err();

    assert!(matches!(error, RegistryError::MissingHostCapability(_)));
}

#[test]
fn cargo_feature_metadata_uses_canonical_feature_names() {
    assert_eq!(
        CargoFeature::BuiltinOpenAICompatible.as_str(),
        "builtin-openai-compatible"
    );
    assert_eq!(
        CargoFeature::LinkLlamaCppLocalInference.as_str(),
        "link-llama-cpp-local-inference"
    );
}

#[cfg(feature = "builtin-openai-compatible")]
#[test]
fn static_plugin_list_records_feature_and_registers_in_order() {
    let host = HostCapabilityManifest::all_supported();
    let list = StaticPluginList::new(vec![
        StaticPluginRegistration::new(
            StaticPluginModule::new("builtin.provider.openai_compatible")
                .with_cargo_feature(CargoFeature::BuiltinOpenAICompatible)
                .requires_host_capability("network"),
            Box::new(BuiltinProviderPlugin::openai_compatible()),
        ),
        StaticPluginRegistration::new(
            StaticPluginModule::new("legacy.runtime_adapter"),
            Box::new(LegacyRuntimeAdapterPlugin::runtime_adapter()),
        ),
    ]);

    let registry = list.build_registry(host).unwrap();

    assert_eq!(
        list.modules()[0].module_id.as_str(),
        "builtin.provider.openai_compatible"
    );
    assert_eq!(
        list.modules()[0].cargo_feature,
        Some(CargoFeature::BuiltinOpenAICompatible)
    );
    assert!(registry.providers().contains("provider.openai_compatible"));
    assert!(registry
        .inference_backends()
        .contains("inference.legacy_runtime_adapter"));
}

#[test]
fn static_plugin_list_rejects_mismatched_module_metadata() {
    let host = HostCapabilityManifest::all_supported();
    let list = StaticPluginList::new(vec![StaticPluginRegistration::new(
        StaticPluginModule::new("wrong.module.id").requires_host_capability("native_inference"),
        Box::new(TestNativeInferencePlugin),
    )]);

    let error = list.build_registry(host).unwrap_err();

    assert!(matches!(
        error,
        RegistryError::StaticPluginMetadataMismatch { .. }
    ));
}

#[test]
fn static_plugin_list_rejects_duplicate_module_id_before_registration() {
    let host = HostCapabilityManifest::all_supported();
    let list = StaticPluginList::new(vec![
        StaticPluginRegistration::new(
            StaticPluginModule::new("test.inference.native")
                .requires_host_capability("native_inference"),
            Box::new(TestNativeInferencePlugin),
        ),
        StaticPluginRegistration::new(
            StaticPluginModule::new("test.inference.native")
                .requires_host_capability("native_inference"),
            Box::new(TestNativeInferencePlugin),
        ),
    ]);

    let error = list.build_registry(host).unwrap_err();

    assert!(matches!(error, RegistryError::DuplicatePluginModuleId(_)));
}

#[test]
fn static_plugin_list_rejects_missing_required_capability_metadata() {
    let host = HostCapabilityManifest::all_supported();
    let list = StaticPluginList::new(vec![StaticPluginRegistration::new(
        StaticPluginModule::new("test.inference.native"),
        Box::new(TestNativeInferencePlugin),
    )]);

    let error = list.build_registry(host).unwrap_err();

    assert!(matches!(
        error,
        RegistryError::StaticPluginCapabilityMismatch { .. }
    ));
}

#[test]
fn static_plugin_list_rejects_extra_capability_metadata() {
    let host = HostCapabilityManifest::all_supported();
    let list = StaticPluginList::new(vec![StaticPluginRegistration::new(
        StaticPluginModule::new("legacy.runtime_adapter").requires_host_capability("network"),
        Box::new(LegacyRuntimeAdapterPlugin::runtime_adapter()),
    )]);

    let error = list.build_registry(host).unwrap_err();

    assert!(matches!(
        error,
        RegistryError::StaticPluginCapabilityMismatch { .. }
    ));
}

#[test]
fn static_plugin_feature_metadata_names_declared_cargo_features() {
    let manifest =
        std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/Cargo.toml")).unwrap();
    let list = StaticPluginList::compiled();

    for module in list.modules() {
        if let Some(feature) = module.cargo_feature {
            assert!(
                manifest.contains(&format!("{} =", feature.as_str())),
                "missing Cargo feature {}",
                feature.as_str()
            );
        }
    }
}

#[cfg(not(feature = "builtin-openai-compatible"))]
#[test]
fn compiled_list_omits_openai_provider_when_feature_is_disabled() {
    let list = StaticPluginList::compiled();

    assert!(!list
        .modules()
        .iter()
        .any(|module| module.module_id.as_str() == "builtin.provider.openai_compatible"));
}

#[cfg(not(feature = "link-llama-cpp-local-inference"))]
#[test]
fn compiled_list_omits_llama_cpp_when_link_feature_is_disabled() {
    let list = StaticPluginList::compiled();

    assert!(!list
        .modules()
        .iter()
        .any(|module| module.module_id.as_str() == "builtin.inference.llama_cpp"));
}

#[cfg(feature = "builtin-openai-compatible")]
#[test]
fn compiled_list_includes_openai_provider_when_feature_is_enabled() {
    let list = StaticPluginList::compiled();
    let registry = list
        .build_registry(HostCapabilityManifest::all_supported())
        .unwrap();

    assert!(list
        .modules()
        .iter()
        .any(|module| module.module_id.as_str() == "builtin.provider.openai_compatible"));
    assert!(registry.providers().contains("provider.openai_compatible"));
}

#[cfg(feature = "link-llama-cpp-local-inference")]
#[test]
fn compiled_list_includes_llama_cpp_when_link_feature_is_enabled() {
    let list = StaticPluginList::compiled();
    let registry = list
        .build_registry(HostCapabilityManifest::all_supported())
        .unwrap();

    let module = list
        .modules()
        .iter()
        .find(|module| module.module_id.as_str() == "builtin.inference.llama_cpp")
        .unwrap();

    assert_eq!(
        module.cargo_feature,
        Some(CargoFeature::LinkLlamaCppLocalInference)
    );
    assert!(registry
        .inference_backends()
        .contains("inference.llama_cpp"));
}
