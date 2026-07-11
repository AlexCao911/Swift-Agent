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
        let model = try #require(catalog.models.values.first)
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
