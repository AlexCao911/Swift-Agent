import LocalAgentLLMContracts
import Testing
@testable import LocalAgentLLMLocal

@Suite("Local model device compatibility")
struct LocalDeviceCompatibilityTests {
    @Test
    func rejectsUnsupportedOSDeviceClassAndMemoryBeforeDownload() throws {
        let manifest = try productionManifest()

        #expect(policy(os: 16, device: .phone, memoryGiB: 16)
            .compatibility(of: manifest) == .incompatible(code: "download.os_unsupported"))
        #expect(policy(os: 17, device: .tablet, memoryGiB: 16)
            .compatibility(of: copy(manifest, devices: [.phone]))
            == .incompatible(code: "download.device_unsupported"))
        #expect(policy(os: 17, device: .phone, memoryGiB: 3)
            .compatibility(of: manifest)
            == .incompatible(code: "download.memory_unsupported"))
    }

    @Test
    func largeModelsRequireTwelveGiBWhileSmallModelsRemainPhoneEligible() throws {
        let manifest = try productionManifest()
        let eightGiBPhone = policy(os: 17, device: .phone, memoryGiB: 8)

        #expect(eightGiBPhone.compatibility(
            of: copy(manifest, memoryClass: .small)
        ) == .compatible)
        #expect(eightGiBPhone.compatibility(
            of: copy(manifest, memoryClass: .large)
        ) == .incompatible(code: "download.memory_unsupported"))
        #expect(policy(os: 17, device: .tablet, memoryGiB: 16).compatibility(
            of: copy(manifest, memoryClass: .large)
        ) == .compatible)
    }
}

private func policy(
    os: Int,
    device: LocalDeviceClass,
    memoryGiB: UInt64
) -> LocalDeviceCompatibilityPolicy {
    LocalDeviceCompatibilityPolicy(device: LocalDeviceCapabilities(
        osMajor: os,
        deviceClass: device,
        physicalMemoryBytes: memoryGiB * 1_024 * 1_024 * 1_024
    ))
}

private func productionManifest() throws -> LocalModelRevisionManifest {
    let resources = try OfficialModelCatalogResources.loadBundled()
    let catalog = try OfficialLocalModelCatalogVerifier.verify(
        envelope: resources.envelope,
        keyRing: resources.keyRing
    )
    return try #require(catalog.models[
        LocalModelRevisionID(modelID: "minicpm5-1b-q4-k-m", revision: 1)
    ])
}

private func copy(
    _ manifest: LocalModelRevisionManifest,
    devices: Set<LocalDeviceClass>? = nil,
    memoryClass: LocalMemoryClass? = nil
) -> LocalModelRevisionManifest {
    LocalModelRevisionManifest(
        id: manifest.id,
        displayName: manifest.displayName,
        family: manifest.family,
        engineID: manifest.engineID,
        modelFormat: manifest.modelFormat,
        artifacts: manifest.artifacts,
        installedByteSize: manifest.installedByteSize,
        minimumOSMajor: manifest.minimumOSMajor,
        supportedDeviceClasses: devices ?? manifest.supportedDeviceClasses,
        estimatedMemoryClass: memoryClass ?? manifest.estimatedMemoryClass,
        declaredCapabilities: manifest.declaredCapabilities,
        parameterSchema: manifest.parameterSchema,
        parameterDefaults: manifest.parameterDefaults,
        loadTemplate: manifest.loadTemplate,
        chatTemplate: manifest.chatTemplate,
        toolCallCodecID: manifest.toolCallCodecID
    )
}
