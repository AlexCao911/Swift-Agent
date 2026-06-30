use local_ios_agent_runtime::protocol::{
    BuiltinInferencePlugin, BuiltinProviderPlugin, HostCapabilityManifest, PluginRegistryBuilder,
    RegistryError, StaticPluginList, StaticPluginModule, StaticPluginRegistration,
};

#[test]
fn plugin_module_registers_provider_and_freezes_runtime_registry() {
    let host = HostCapabilityManifest::all_supported();
    let mut builder = PluginRegistryBuilder::new(host);
    BuiltinProviderPlugin::openai_compatible()
        .register(&mut builder)
        .unwrap();

    let registry = builder.freeze().unwrap();

    assert!(registry.providers().contains("provider.openai_compatible"));
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
fn static_plugin_list_records_feature_and_registers_in_order() {
    let host = HostCapabilityManifest::all_supported();
    let list = StaticPluginList::new(vec![
        StaticPluginRegistration::new(
            StaticPluginModule::new("builtin.provider.openai_compatible")
                .with_cargo_feature("builtin-openai-compatible")
                .requires_host_capability("network"),
            Box::new(BuiltinProviderPlugin::openai_compatible()),
        ),
        StaticPluginRegistration::new(
            StaticPluginModule::new("legacy.runtime_adapter"),
            Box::new(
                local_ios_agent_runtime::protocol::LegacyRuntimeAdapterPlugin::runtime_adapter(),
            ),
        ),
    ]);

    let registry = list.build_registry(host).unwrap();

    assert_eq!(
        list.modules()[0].module_id.as_str(),
        "builtin.provider.openai_compatible"
    );
    assert_eq!(
        list.modules()[0].cargo_feature.as_deref(),
        Some("builtin-openai-compatible")
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
        StaticPluginModule::new("wrong.module.id").requires_host_capability("network"),
        Box::new(BuiltinProviderPlugin::openai_compatible()),
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
            StaticPluginModule::new("builtin.provider.openai_compatible")
                .requires_host_capability("network"),
            Box::new(BuiltinProviderPlugin::openai_compatible()),
        ),
        StaticPluginRegistration::new(
            StaticPluginModule::new("builtin.provider.openai_compatible")
                .requires_host_capability("network"),
            Box::new(BuiltinProviderPlugin::openai_compatible()),
        ),
    ]);

    let error = list.build_registry(host).unwrap_err();

    assert!(matches!(error, RegistryError::DuplicatePluginModuleId(_)));
}

#[test]
fn static_plugin_list_rejects_missing_required_capability_metadata() {
    let host = HostCapabilityManifest::all_supported();
    let list = StaticPluginList::new(vec![StaticPluginRegistration::new(
        StaticPluginModule::new("builtin.provider.openai_compatible"),
        Box::new(BuiltinProviderPlugin::openai_compatible()),
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
        if let Some(feature) = module.cargo_feature.as_deref() {
            assert!(
                manifest.contains(&format!("{feature} =")),
                "missing Cargo feature {feature}"
            );
        }
    }
}

#[test]
fn compiled_list_includes_openai_provider_when_feature_is_enabled() {
    if !cfg!(feature = "builtin-openai-compatible") {
        return;
    }

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
