import Foundation
import Testing
@testable import LocalAgentLLMContracts

@Suite("Host envelope v2")
struct HostEnvelopeV2Tests {
    @Test
    func commandPayloadsValidateByKind() throws {
        let fixture = try hostV2Fixture()
        let generation = HostCommandPayload.generationV2(fixture.modelRequest)
        try generation.validate(for: .startGeneration, envelopeRunID: "run-v2")
        #expect(
            try generation.modelRequest(
                for: .startGeneration,
                envelopeRunID: "run-v2"
            ).purpose == .generation
        )
        let generationDigest = try generation.computedDigest().hex
        #expect(generationDigest == fixture.expectedGenerationPayloadDigest)

        let batch = fixture.toolBatch
        let execute = HostCommandPayload.toolBatchV2(batch)
        try execute.validate(for: .executeToolBatch, envelopeRunID: "run-v2")
        assertContractError("llm.contract.command_payload_mismatch") {
            try execute.validate(for: .cancelToolBatch, envelopeRunID: "run-v2")
        }

        let cancel = HostCommandPayload.cancelToolBatchV2("batch-1")
        try cancel.validate(for: .cancelToolBatch, envelopeRunID: "run-v2")
    }

    @Test
    func generationPreservesOrderedToolResultsOnlyForModelCommands() throws {
        let fixture = try hostV2Fixture()
        let results = [
            HostToolResult(
                callID: "call-1",
                toolName: "shell",
                result: try .object(entries: [
                    .init(name: "stdout", value: .string("first")),
                ]),
                isError: false,
                dataClasses: [],
                highestSensitivity: "public"
            ),
            HostToolResult(
                callID: "call-2",
                toolName: "read_file",
                result: try .object(entries: [
                    .init(name: "content", value: .string("second")),
                ]),
                isError: false,
                dataClasses: [],
                highestSensitivity: "public"
            ),
        ]
        let request = HostModelRequest(
            runID: fixture.modelRequest.runID,
            conversationStreamID: fixture.modelRequest.conversationStreamID,
            systemPrompt: fixture.modelRequest.systemPrompt,
            orderedMessages: fixture.modelRequest.orderedMessages,
            attachmentReferences: fixture.modelRequest.attachmentReferences,
            orderedToolDefinitions: fixture.modelRequest.orderedToolDefinitions,
            orderedToolResults: results,
            purpose: fixture.modelRequest.purpose
        )
        let payload = HostCommandPayload.generationV2(request)

        #expect(
            try payload.modelRequest(
                for: .resumeGeneration,
                envelopeRunID: "run-v2"
            ) == request
        )
        assertContractError("llm.contract.command_payload_mismatch") {
            try payload.validate(for: .closeSession, envelopeRunID: "run-v2")
        }
    }

    @Test
    func toolCompletionRequiresExactEventIdentity() throws {
        let fixture = try hostV2Fixture()
        let payload = LLMEventPayload(
            toolBatchCompletion: fixture.toolBatchCompletion
        )
        try payload.validate(
            for: .toolBatchCompleted,
            envelopeRunID: "run-v2",
            expectedBatchID: "batch-1"
        )
        assertContractError("llm.contract.event_payload_mismatch") {
            try LLMEventPayload().validate(
                for: .toolBatchCompleted,
                envelopeRunID: "run-v2",
                expectedBatchID: "batch-1"
            )
        }
        assertContractError("llm.contract.event_payload_mismatch") {
            try LLMEventPayload(
                text: "unexpected",
                toolBatchCompletion: payload.toolBatchCompletion
            ).validate(
                for: .toolBatchCompleted,
                envelopeRunID: "run-v2",
                expectedBatchID: "batch-1"
            )
        }
        assertContractError("llm.contract.event_payload_mismatch") {
            try payload.validate(
                for: .textDelta,
                envelopeRunID: "run-v2",
                expectedBatchID: "batch-1"
            )
        }
        assertContractError("llm.contract.event_payload_mismatch") {
            try payload.validate(
                for: .toolBatchCompleted,
                envelopeRunID: "other-run",
                expectedBatchID: "batch-1"
            )
        }
    }

}

private struct HostV2Fixture: Decodable {
    let expectedGenerationPayloadDigest: String
    let modelRequest: HostModelRequest
    let toolBatch: HostToolBatch
    let toolBatchCompletion: HostToolBatchCompletion

    private enum CodingKeys: String, CodingKey {
        case expectedGenerationPayloadDigest = "expected_generation_payload_digest"
        case modelRequest = "model_request"
        case toolBatch = "tool_batch"
        case toolBatchCompletion = "tool_batch_completion"
    }
}

private func hostV2Fixture() throws -> HostV2Fixture {
    let url = try #require(
        Bundle.module.url(
            forResource: "valid-contract",
            withExtension: "json"
        )
    )
    return try JSONDecoder().decode(
        HostV2Fixture.self,
        from: Data(contentsOf: url)
    )
}

private func assertContractError<T>(
    _ expectedCode: String,
    operation: () throws -> T
) {
    do {
        _ = try operation()
        Issue.record("expected HostContractValidationError")
    } catch let error as HostContractValidationError {
        #expect(error.code == expectedCode)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}
