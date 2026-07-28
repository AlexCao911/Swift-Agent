import Foundation
import LocalAgentLLMContracts
import Testing
@testable import LocalAgentLLMLocal

@Suite("Local capability observations")
struct LocalCapabilityObservationTests {
    @Test
    func signedCatalogCreatesExactAuthoritativeObservationsAndRegisteredDigests() throws {
        let resources = try OfficialModelCatalogResources.loadBundled()
        let catalog = try OfficialLocalModelCatalogVerifier.verify(
            envelope: resources.envelope,
            keyRing: resources.keyRing
        )
        let model = try #require(catalog.models[
            LocalModelRevisionID(modelID: "gemma-3-1b-it-q4", revision: 1)
        ])
        let observations = try LocalCapabilityObservationFactory.observations(
            for: model.id,
            in: catalog,
            engineVersion: "engine-1",
            appBuild: "build-1",
            observedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let streaming = try #require(observations.first { $0.capabilityID == "streaming" })

        #expect(streaming.dimension == .modelSupports)
        #expect(streaming.source == .signedLocalCatalog)
        #expect(streaming.authority == .authoritative)
        #expect(streaming.subject.engineID == "llama_cpp")
        #expect(streaming.subject.modelID == model.id.modelID)
        #expect(streaming.subject.modelRevision == String(model.id.revision))
        #expect(streaming.subject.catalogRevision == catalog.catalogRevision)
        #expect(streaming.expiresAt == nil)
        #expect(streaming.invalidationTriggers == [
            .catalogRevision, .engineVersion, .appBuild, .osCapabilities,
        ])
        let expectedEvidence = try fixtureDigest("capability-evidence-local-catalog-v1.json")
        let expectedObservation = try fixtureDigest("capability-observation-local-catalog-v1.json")
        #expect(streaming.evidenceDigest == expectedEvidence)
        #expect(streaming.observationDigest == expectedObservation)
        #expect(streaming.evidenceDigest != model.artifacts[0].artifactSHA256)
    }

    @Test
    func imageInputUsesTheCompiledMtmdCapability() throws {
        let resources = try OfficialModelCatalogResources.loadBundled()
        let catalog = try OfficialLocalModelCatalogVerifier.verify(
            envelope: resources.envelope,
            keyRing: resources.keyRing
        )
        let manifest = try #require(catalog.models[
            LocalModelRevisionID(modelID: "lfm2.5-vl-1.6b-q4-0", revision: 1)
        ])
        let descriptor = CppEngineDescriptor(
            engineID: "llama_cpp",
            abiVersion: "2",
            engineVersion: "mtmd-test",
            displayName: "llama.cpp",
            testOnly: false,
            capabilities: CppEngineCapabilities(
                supportedModelFormats: ["gguf"],
                supportsVision: true,
                supportsNativeToolCalling: true,
                supportsStreaming: true,
                supportsCancellation: true,
                supportsTokenUsage: false,
                maxContextTokens: nil,
                backendParameters: []
            )
        )
        let observations = try LocalCapabilityObservationFactory.engineObservations(
            descriptor: descriptor,
            manifest: manifest,
            subject: CapabilitySubject(engineID: "llama_cpp"),
            appBuild: "tests",
            observedAt: Date(timeIntervalSince1970: 0)
        )

        #expect(observations.first {
            $0.capabilityID == "image_input"
        }?.value == .support(.supported))
        #expect(observations.first {
            $0.capabilityID == "tool_calling"
        }?.value == .support(.supported))
    }
}

private func fixtureDigest(_ name: String) throws -> String {
    let data = try Data(contentsOf: contractsFixtures.appending(path: name))
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    return try #require(object["expected_sha256"] as? String)
}

private let contractsFixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appending(path: "contracts/canonical-digest-v1/fixtures")
