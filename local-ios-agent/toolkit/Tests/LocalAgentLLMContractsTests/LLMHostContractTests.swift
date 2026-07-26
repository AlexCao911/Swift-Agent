import Foundation
import Testing
@testable import LocalAgentLLMContracts

@Suite("LLM host bridge contracts")
struct LLMHostContractTests {
    @Test
    func commandFixtureContainsOnlySemanticPayloadAndRecomputesBothDigests() throws {
        let envelope: HostCommandEnvelope = try hostWireFixture(
            "host-command-envelope-v1.json",
            as: HostCommandEnvelope.self
        )

        #expect(try envelope.payload.computedDigest().hex == envelope.payloadDigest)
        #expect(try envelope.recomputedDigest().hex == envelope.commandEnvelopeDigest)
        let bytes = try JSONEncoder().encode(envelope)
        let encoded = String(decoding: bytes, as: UTF8.self)
        for forbidden in ["api_key", "base_url", "provider_profile", "model_path", "response_id"] {
            #expect(!encoded.contains(forbidden))
        }

        let changed = envelope.replacing(commandSequence: 2)
        #expect(try changed.recomputedDigest().hex != envelope.commandEnvelopeDigest)
    }

    @Test
    func eventAndReceiptFixturesBindIdentitySequenceEpochAndPayload() throws {
        let event: LLMEventEnvelope = try hostWireFixture(
            "llm-event-envelope-v1.json",
            as: LLMEventEnvelope.self
        )
        let receipt: LLMEventReceipt = try hostWireFixture(
            "llm-event-receipt-v1.json",
            as: LLMEventReceipt.self
        )

        #expect(try event.recomputedDigest().hex == event.eventEnvelopeDigest)
        #expect(try receipt.recomputedDigest().hex == receipt.receiptDigest)
        #expect(receipt.eventEnvelopeDigest == event.eventEnvelopeDigest)
        #expect(try event.replacing(eventSequence: 2).recomputedDigest().hex != event.eventEnvelopeDigest)
    }

    @Test
    func eventResultMatrixIsExhaustive() {
        #expect(LLMEventSubmissionResult.accepted.sequenceEffect == .consumeNew)
        #expect(LLMEventSubmissionResult.duplicate.sequenceEffect == .alreadyConsumed)
        #expect(LLMEventSubmissionResult.backpressure.sequenceEffect == .doNotConsume)
        #expect(LLMEventSubmissionResult.payloadTooLarge.sequenceEffect == .consumeNew)
        #expect(LLMEventSubmissionResult.sequenceConflict.sequenceEffect == .alreadyConsumed)
        #expect(LLMEventSubmissionResult.turnTerminal.sequenceEffect == .consumeNew)
        #expect(LLMEventSubmissionResult.generationTerminal.sequenceEffect == .consumeNew)
        #expect(LLMEventSubmissionResult.staleSession.retrySameEnvelope == false)
        #expect(LLMEventSubmissionResult.backpressure.retrySameEnvelope)
    }

    @Test
    func productionHostAttestationBuilderMatchesCloudAndLocalFixtures() throws {
        let cloud: HostAttestationV1Document = try hostDocumentFixture(
            "egress-attestation-cloud-v1.json",
            as: HostAttestationV1Document.self
        )
        let local: HostAttestationV1Document = try hostDocumentFixture(
            "egress-attestation-local-v1.json",
            as: HostAttestationV1Document.self
        )

        #expect(try cloud.computedDigest().hex == "9de220bd518ebd4ee705a14b26737fc5b7cea4f1a1b378a112e013c12d404822")
        #expect(try local.computedDigest().hex == "58ef0e04243b5a3b4f324869b60de728ba04928eec536f8d72eff217132c4034")
        #expect(throws: HostAttestationV1Error.self) {
            try local.replacing(expiresAt: "2027-01-15T08:06:00Z").computedDigest()
        }
    }

    @Test
    func completionTerminalEnforcesOutcomeAndOrderedCallBatch() throws {
        #expect(throws: LLMBackendCompletionValidationError.self) {
            try LLMBackendCompletion.validated(
                outcome: .finalResponse,
                orderedCallIDs: ["call-1"],
                finishReason: .stop
            )
        }
        #expect(throws: LLMBackendCompletionValidationError.self) {
            try LLMBackendCompletion.validated(
                outcome: .toolCallsReady,
                orderedCallIDs: [],
                finishReason: .toolCalls
            )
        }
        #expect(throws: LLMBackendCompletionValidationError.self) {
            try LLMBackendCompletion.validated(
                outcome: .toolCallsReady,
                orderedCallIDs: ["call-1", "call-1"],
                finishReason: .toolCalls
            )
        }
        #expect(try LLMBackendCompletion.validated(
            outcome: .toolCallsReady,
            orderedCallIDs: ["call-1", "call-2"],
            finishReason: .toolCalls
        ).orderedCallIDs == ["call-1", "call-2"])
    }
}

private func hostWireFixture<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
    try hostFixture(name, key: "wire", as: type)
}

private func hostDocumentFixture<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
    try hostFixture(name, key: "document", as: type)
}

private func hostFixture<T: Decodable>(_ name: String, key: String, as type: T.Type) throws -> T {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("contracts/canonical-digest-v1/fixtures")
    let object = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(name)))
            as? [String: Any]
    )
    return try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: try #require(object[key])))
}
