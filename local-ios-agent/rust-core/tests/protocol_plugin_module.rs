use local_ios_agent_runtime::protocol::{
    BuiltinInferencePlugin, CargoFeature, HostCapabilityManifest, LegacyRuntimeAdapterPlugin,
    PluginRegistryBuilder, RegistryError, StaticPluginList, StaticPluginModule,
    StaticPluginRegistration,
};

#[cfg(feature = "builtin-openai-compatible")]
use local_ios_agent_runtime::protocol::BuiltinProviderPlugin;

#[test]
fn plugin_module_registers_inference_backend_and_freezes_runtime_registry() {
    let host = HostCapabilityManifest::all_supported();
    let mut builder = PluginRegistryBuilder::new(host);
    BuiltinInferencePlugin::llama_cpp()
        .register(&mut builder)
        .unwrap();

    let registry = builder.freeze().unwrap();

    assert!(registry
        .inference_backends()
        .contains("inference.llama_cpp"));
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

    let error = BuiltinInferencePlugin::llama_cpp()
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
        Box::new(BuiltinInferencePlugin::llama_cpp()),
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
            StaticPluginModule::new("builtin.inference.llama_cpp")
                .requires_host_capability("native_inference"),
            Box::new(BuiltinInferencePlugin::llama_cpp()),
        ),
        StaticPluginRegistration::new(
            StaticPluginModule::new("builtin.inference.llama_cpp")
                .requires_host_capability("native_inference"),
            Box::new(BuiltinInferencePlugin::llama_cpp()),
        ),
    ]);

    let error = list.build_registry(host).unwrap_err();

    assert!(matches!(error, RegistryError::DuplicatePluginModuleId(_)));
}

#[test]
fn static_plugin_list_rejects_missing_required_capability_metadata() {
    let host = HostCapabilityManifest::all_supported();
    let list = StaticPluginList::new(vec![StaticPluginRegistration::new(
        StaticPluginModule::new("builtin.inference.llama_cpp"),
        Box::new(BuiltinInferencePlugin::llama_cpp()),
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
