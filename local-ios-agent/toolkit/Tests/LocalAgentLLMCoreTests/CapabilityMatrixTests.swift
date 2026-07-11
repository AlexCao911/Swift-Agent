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
}
