import Foundation
import LocalAgentLLMContracts
import LocalAgentLLMCore
import Testing
@testable import LocalAgentLLMCloud

@Suite("Cloud model discovery and capability authority")
struct CloudModelDiscoveryTests {
    @Test
    func providerListAndManualIDsCannotOverclaimSemanticCapabilities() throws {
        let catalog = try verifiedDiscoveryCatalog()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let route = cloudRouteSubject(modelID: "placeholder", modelRevision: nil, catalogRevision: nil)
        let models = try CloudModelDiscoveryService(clock: { now }).merge(
            liveModelIDs: ["live-only"],
            manualModelID: "manual-only",
            presetID: .openAI,
            adapterID: "openai.responses",
            adapterVersion: "1",
            catalog: catalog,
            routeSubject: route
        )
        let live = try #require(models.first { $0.modelID == "live-only" })
        #expect(live.observations.allSatisfy { $0.dimension == .availabilityValidated })
        #expect(live.observations.first?.expiresAt == now.addingTimeInterval(24 * 60 * 60))
        let liveSnapshot = CapabilityMatrix.resolve(
            observations: live.observations,
            subject: cloudRouteSubject(modelID: "live-only", modelRevision: nil, catalogRevision: nil),
            policy: .cloud,
            now: now
        )
        #expect(liveSnapshot.support(for: "tool_calling") == .unknown)
        #expect(liveSnapshot.support(for: "context_length") == .unknown)

        let manual = try #require(models.first { $0.modelID == "manual-only" })
        #expect(manual.observations.isEmpty)
        #expect(manual.catalogEntry == nil)
    }

    @Test
    func signedCatalogSuppliesAllThreeDimensionsForExactRetentionBoundSubject() throws {
        let catalog = try verifiedDiscoveryCatalog()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let route = cloudRouteSubject(modelID: "placeholder", modelRevision: nil, catalogRevision: nil)
        let models = try CloudModelDiscoveryService(clock: { now }).merge(
            liveModelIDs: ["fixture-model"],
            presetID: .openAI,
            adapterID: "openai.responses",
            adapterVersion: "1",
            catalog: catalog,
            routeSubject: route
        )
        let model = try #require(models.first { $0.modelID == "fixture-model" })
        let exact = cloudRouteSubject(
            modelID: "fixture-model",
            modelRevision: "2026-01",
            catalogRevision: 1
        )
        let snapshot = CapabilityMatrix.resolve(
            observations: model.observations,
            subject: exact,
            policy: .cloud,
            now: now
        )
        #expect(snapshot.support(for: "tool_calling") == .supported)
        #expect(snapshot.verifiedUpperBound(for: "context_length") == 128_000)

        let changedRetention = CapabilitySubject(
            adapterID: exact.adapterID,
            providerProfileID: exact.providerProfileID,
            providerProfileRevision: exact.providerProfileRevision,
            credentialGeneration: exact.credentialGeneration,
            modelID: exact.modelID,
            modelRevision: exact.modelRevision,
            catalogRevision: exact.catalogRevision,
            retentionMode: ProviderRetentionMode.providerStateApproved.rawValue,
            retentionApprovalRevision: 9,
            retentionApprovalDigest: String(repeating: "a", count: 64)
        )
        let invalidated = CapabilityMatrix.resolve(
            observations: model.observations,
            subject: changedRetention,
            policy: .cloud,
            now: now
        )
        #expect(invalidated.support(for: "tool_calling") == .unknown)
    }

    @Test
    func attachmentsRemainUnknownEvenWhenSignedCatalogClaimsSupport() throws {
        let fixture = try signedCloudCatalog(
            revision: 1,
            capabilities: [
                .init(capabilityID: "image_input", value: .support(.supported)),
                .init(capabilityID: "audio_input", value: .support(.unsupported)),
                .init(capabilityID: "video_input", value: .support(.supported)),
                .init(capabilityID: "document_input", value: .support(.supported)),
            ]
        )
        let catalog = try CloudCapabilityCatalogVerifier.verify(
            envelope: fixture.envelope,
            keyRing: fixture.keyRing
        )
        let entry = try #require(catalog.entry(presetID: .openAI, modelID: "fixture-model"))
        let exact = cloudRouteSubject(
            modelID: "fixture-model",
            modelRevision: "2026-01",
            catalogRevision: 1
        )
        let observations = try CloudCapabilityObservationFactory.catalogObservations(
            entry: entry,
            catalog: catalog,
            exactSubject: exact,
            adapterVersion: "1",
            observedAt: Date()
        )
        let snapshot = CapabilityMatrix.resolve(
            observations: observations,
            subject: exact,
            policy: .cloud,
            now: Date()
        )
        for capability in ["image_input", "audio_input", "video_input", "document_input"] {
            #expect(snapshot.support(for: capability) == .unknown)
        }
    }

    @Test
    func routineProbeCanProveOnlyTextAndStreamingForUnknownModel() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let exact = cloudRouteSubject(modelID: "manual-model", modelRevision: nil, catalogRevision: nil)
        let observations = try CloudCapabilityObservationFactory.routineProbeObservations(
            subject: exact,
            adapterVersion: "1",
            observedAt: now,
            expiresAt: now.addingTimeInterval(86_400)
        )
        let snapshot = CapabilityMatrix.resolve(
            observations: observations,
            subject: exact,
            policy: .cloud,
            now: now
        )
        #expect(snapshot.support(for: "text_generation") == .supported)
        #expect(snapshot.support(for: "streaming") == .supported)
        #expect(snapshot.support(for: "tool_calling") == .unknown)
    }

    @Test
    func cloudPolicyUsesLowestTrustedBoundAndAuthoritativeNegativeWins() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let subject = cloudRouteSubject(
            modelID: "fixture-model",
            modelRevision: "2026-01",
            catalogRevision: 1
        )
        let positives = [
            cloudObservation(
                dimension: .adapterCanEncode,
                value: .verifiedUpperBound(200_000),
                source: .shippedCloudAdapter,
                subject: subject,
                now: now
            ),
            cloudObservation(
                dimension: .endpointSupports,
                value: .verifiedUpperBound(100_000),
                source: .signedCloudCatalog,
                subject: subject,
                now: now
            ),
            cloudObservation(
                dimension: .modelSupports,
                value: .verifiedUpperBound(150_000),
                source: .signedCloudCatalog,
                subject: subject,
                now: now
            ),
        ]
        let supported = CapabilityMatrix.resolve(
            observations: positives,
            subject: subject,
            policy: .cloud,
            now: now
        )
        #expect(supported.support(for: "context_length") == .supported)
        #expect(supported.verifiedUpperBound(for: "context_length") == 100_000)

        let denied = CapabilityMatrix.resolve(
            observations: positives + [cloudObservation(
                dimension: .endpointSupports,
                value: .support(.unsupported),
                source: .signedCloudCatalog,
                subject: subject,
                now: now
            )],
            subject: subject,
            policy: .cloud,
            now: now
        )
        #expect(denied.support(for: "context_length") == .unsupported)
        #expect(denied.verifiedUpperBound(for: "context_length") == nil)
    }
}

private func verifiedDiscoveryCatalog() throws -> VerifiedCloudCapabilityCatalog {
    let fixture = try signedCloudCatalog(revision: 1)
    return try CloudCapabilityCatalogVerifier.verify(
        envelope: fixture.envelope,
        keyRing: fixture.keyRing
    )
}

func cloudRouteSubject(
    modelID: String,
    modelRevision: String?,
    catalogRevision: UInt64?
) -> CapabilitySubject {
    CloudCapabilityObservationFactory.exactSubject(
        adapterID: "openai.responses",
        profileID: "profile-main",
        profileRevision: 1,
        credentialGeneration: 1,
        modelID: modelID,
        modelRevision: modelRevision,
        catalogRevision: catalogRevision,
        retentionMode: .statelessRequired,
        retentionApprovalRevision: nil,
        retentionApprovalDigest: nil
    )
}

private func cloudObservation(
    dimension: CapabilityDimension,
    value: CapabilityValue,
    source: CapabilitySource,
    subject: CapabilitySubject,
    now: Date
) -> CapabilityObservation {
    CapabilityObservation(
        capabilityID: "context_length",
        dimension: dimension,
        value: value,
        authority: .authoritative,
        source: source,
        subject: subject,
        adapterOrEngineVersion: "1",
        observedAt: now,
        expiresAt: nil,
        validationScope: .signedDeclaration,
        evidenceDigest: String(repeating: "a", count: 64),
        observationDigest: "\(dimension.rawValue)-\(value)"
    )
}
