import Foundation
import Testing
import LocalAgentLLMContracts
@testable import LocalAgentLLMCore

@Suite("Capability matrix")
struct CapabilityMatrixTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func unknownCapabilityNeverSatisfiesRequirement() {
        let snapshot = CapabilityMatrix.resolve(observations: [], now: now)

        #expect(snapshot.support(for: "tool_calling") == .unknown)
        #expect(!snapshot.satisfies(CapabilityRequirement(capabilityID: "tool_calling")))
    }

    @Test
    func lowestNonExpiredVerifiedNumericLimitWins() {
        let observations = [
            CapabilityObservation(
                capabilityID: "context_window_tokens",
                dimension: .modelSupports,
                value: .verifiedUpperBound(32_768),
                authority: .verified,
                observedAt: now.addingTimeInterval(-100),
                expiresAt: nil
            ),
            CapabilityObservation(
                capabilityID: "context_window_tokens",
                dimension: .endpointSupports,
                value: .verifiedUpperBound(8_192),
                authority: .verified,
                observedAt: now.addingTimeInterval(-50),
                expiresAt: nil
            ),
            CapabilityObservation(
                capabilityID: "context_window_tokens",
                dimension: .availabilityValidated,
                value: .verifiedUpperBound(4_096),
                authority: .verified,
                observedAt: now.addingTimeInterval(-10_000),
                expiresAt: now.addingTimeInterval(-1)
            ),
        ]

        let snapshot = CapabilityMatrix.resolve(observations: observations, now: now)

        #expect(snapshot.verifiedUpperBound(for: "context_window_tokens") == 8_192)
        #expect(snapshot.support(for: "context_window_tokens") == .supported)
    }

    @Test
    func authoritativeUnsupportedWinsOverPositiveClaim() {
        let observations = [
            CapabilityObservation(
                capabilityID: "image_input",
                dimension: .modelSupports,
                value: .support(.supported),
                authority: .verified,
                observedAt: now,
                expiresAt: nil
            ),
            CapabilityObservation(
                capabilityID: "image_input",
                dimension: .adapterCanEncode,
                value: .support(.unsupported),
                authority: .authoritative,
                observedAt: now,
                expiresAt: nil
            ),
        ]

        let snapshot = CapabilityMatrix.resolve(observations: observations, now: now)

        #expect(snapshot.support(for: "image_input") == .unsupported)
    }

    @Test
    func localPolicyRequiresMatchingModelAndEngineDimensions() {
        let exact = CapabilitySubject(
            engineID: "llama_cpp",
            modelID: "model-a",
            modelRevision: "1",
            catalogRevision: 3
        )
        let model = observation(
            dimension: .modelSupports,
            subject: exact,
            digest: "model-digest"
        )
        let engine = observation(
            dimension: .engineCanExecute,
            subject: CapabilitySubject(engineID: "llama_cpp"),
            digest: "engine-digest"
        )

        let missingEngine = CapabilityMatrix.resolve(
            observations: [model],
            subject: exact,
            policy: .local,
            now: now
        )
        #expect(missingEngine.support(for: "tool_calling") == .unknown)

        let complete = CapabilityMatrix.resolve(
            observations: [model, engine],
            subject: exact,
            policy: .local,
            now: now
        )
        #expect(complete.support(for: "tool_calling") == .supported)
        #expect(complete.contributingObservationDigests == ["engine-digest", "model-digest"])
    }

    @Test
    func localPolicyRejectsSubjectMismatchAndTracksNearestExpiry() {
        let exact = CapabilitySubject(
            engineID: "llama_cpp",
            modelID: "model-a",
            modelRevision: "2",
            catalogRevision: 3
        )
        let wrongModel = observation(
            dimension: .modelSupports,
            subject: CapabilitySubject(
                engineID: "llama_cpp",
                modelID: "model-a",
                modelRevision: "1",
                catalogRevision: 3
            ),
            digest: "wrong"
        )
        let engine = observation(
            dimension: .engineCanExecute,
            subject: CapabilitySubject(engineID: "llama_cpp"),
            digest: "engine",
            expiresAt: now.addingTimeInterval(60)
        )

        let snapshot = CapabilityMatrix.resolve(
            observations: [wrongModel, engine],
            subject: exact,
            policy: .local,
            now: now
        )
        #expect(snapshot.support(for: "tool_calling") == .unknown)
        #expect(snapshot.nearestExpiry == now.addingTimeInterval(60))
        #expect(snapshot.contributingObservationDigests == ["engine"])
    }

    @Test
    func advisoryClaimsCannotSatisfyLocalPolicy() {
        let exact = CapabilitySubject(engineID: "llama_cpp", modelID: "model-a", modelRevision: "1")
        let advisoryModel = CapabilityObservation(
            capabilityID: "tool_calling",
            dimension: .modelSupports,
            value: .support(.supported),
            authority: .advisory,
            source: .providerNeutral,
            subject: exact,
            observedAt: now,
            expiresAt: now.addingTimeInterval(10),
            observationDigest: "advisory"
        )
        let engine = observation(
            dimension: .engineCanExecute,
            subject: CapabilitySubject(engineID: "llama_cpp"),
            digest: "engine"
        )
        let snapshot = CapabilityMatrix.resolve(
            observations: [advisoryModel, engine],
            subject: exact,
            policy: .local,
            now: now
        )
        #expect(snapshot.support(for: "tool_calling") == .unknown)
        #expect(snapshot.contributingObservationDigests == ["engine"])
        #expect(snapshot.nearestExpiry == nil)
    }

    private func observation(
        dimension: CapabilityDimension,
        subject: CapabilitySubject,
        digest: String,
        expiresAt: Date? = nil
    ) -> CapabilityObservation {
        CapabilityObservation(
            capabilityID: "tool_calling",
            dimension: dimension,
            value: .support(.supported),
            authority: .authoritative,
            source: dimension == .modelSupports ? .signedLocalCatalog : .compiledLocalEngine,
            subject: subject,
            adapterOrEngineVersion: "1",
            observedAt: now,
            expiresAt: expiresAt,
            validationScope: dimension == .modelSupports ? .signedDeclaration : .compiledDescriptor,
            invalidationTriggers: [.engineVersion],
            evidenceDigest: "evidence-\(digest)",
            observationDigest: digest
        )
    }
}
