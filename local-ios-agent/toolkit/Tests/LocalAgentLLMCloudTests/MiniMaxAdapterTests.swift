import Foundation
import LocalAgentLLMContracts
import Testing
@testable import LocalAgentLLMCloud

@Suite("MiniMax Messages semantic adapter", .serialized)
struct MiniMaxAdapterTests {
    @Test
    func ownEndpointIdentityAndSupportedParametersMapWithoutStorageState() async throws {
        let fixture = try await makeAuthorizedTransportFixture(
            modelID: "MiniMax-M2.1",
            parameters: GenerationConfiguration()
                .setting(.samplingTemperature, to: .decimal(0.4))
                .setting(.samplingTopP, to: .decimal(0.8))
                .setting(.generationMaxOutputTokens, to: .integer(512))
        )
        defer { fixture.cleanup() }
        let adapter = MiniMaxAdapter()
        let wire = try adapter.makeSession(fixture.sessionContext).encodeStart(fixture.authorizedTurn)
        let body = try wireJSONObject(wire)
        #expect(adapter.presetID == .miniMax)
        #expect(adapter.adapterID == "minimax.messages")
        #expect(wire.path == "/messages")
        #expect(body["temperature"] as? Double == 0.4)
        #expect(body["top_p"] as? Double == 0.8)
        #expect(body["max_tokens"] as? Int == 512)
        #expect(body["store"] == nil)
    }

    @Test
    func documentedIgnoredTopKAndStopSequencesAreRejected() async throws {
        for parameter in [
            (LLMParameterID.samplingTopK, LLMParameterValue.integer(20)),
            (LLMParameterID.generationStopSequences, .textList(["stop"])),
        ] {
            let fixture = try await makeAuthorizedTransportFixture(
                modelID: "MiniMax-M2.1",
                parameters: GenerationConfiguration().setting(parameter.0, to: parameter.1)
            )
            defer { fixture.cleanup() }
            expectAdapterFailure("cloud_adapter.parameter_unsupported") {
                _ = try MiniMaxAdapter().makeSession(fixture.sessionContext)
                    .encodeStart(fixture.authorizedTurn)
            }
        }
    }

    @Test
    func rawThinkingStaysPrivateAndTextUsageCompletes() async throws {
        let fixture = try await makeAuthorizedTransportFixture(modelID: "MiniMax-M2.1")
        defer { fixture.cleanup() }
        let events = try await decodeMessagesFixture(
            "minimax-text",
            session: try MiniMaxAdapter().makeSession(fixture.sessionContext)
        )
        #expect(events.contains(.textDelta("MiniMax answer")))
        #expect(!events.contains { if case .reasoningSummaryDelta = $0 { true } else { false } })
        #expect(events.contains(.usageUpdated(LLMUsage(inputTokens: 5, outputTokens: 3))))
    }

    @Test
    func toolUseContinuationUsesMiniMaxBlockStateAndExactResultID() async throws {
        let start = try await makeAuthorizedTransportFixture(modelID: "MiniMax-M2.1")
        let resume = try await makeAuthorizedTransportFixture(
            modelID: "MiniMax-M2.1",
            toolResults: [messagesToolResult("minimax_call", "weather.get")]
        )
        defer { start.cleanup(); resume.cleanup() }
        let session = try MiniMaxAdapter().makeSession(start.sessionContext)
        _ = try session.encodeStart(start.authorizedTurn)
        let events = try await decodeMessagesFixture("minimax-tool", session: session)
        #expect(events.last == .generationCompleted(LLMBackendCompletion(
            outcome: .toolCallsReady,
            orderedCallIDs: ["minimax_call"],
            finishReason: .toolCalls
        )))
        let serialized = try wireJSONString(session.encodeResume(resume.authorizedTurn))
        #expect(serialized.contains("minimax_call"))
        #expect(serialized.contains("tool_result"))
    }
}
