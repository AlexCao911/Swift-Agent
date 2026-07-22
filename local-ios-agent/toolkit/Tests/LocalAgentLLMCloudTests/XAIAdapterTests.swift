import Foundation
import LocalAgentLLMContracts
import Testing
@testable import LocalAgentLLMCloud

@Suite("xAI Responses semantic adapter", .serialized)
struct XAIAdapterTests {
    @Test
    func grokRequestOverridesStorageAndMapsReasoningEffortSeparately() async throws {
        let fixture = try await makeAuthorizedTransportFixture(
            modelID: "grok-4",
            parameters: GenerationConfiguration()
                .setting(.reasoningEffort, to: .text("high"))
                .setting(.generationMaxOutputTokens, to: .integer(256))
        )
        defer { fixture.cleanup() }
        let adapter = XAIAdapter()
        let session = try adapter.makeSession(fixture.sessionContext)

        let body = try wireJSONObject(session.encodeStart(fixture.authorizedTurn))

        #expect(adapter.presetID == .xAI)
        #expect(adapter.adapterID == "xai.responses")
        #expect(adapter.adapterVersion == "1")
        #expect(body["model"] as? String == "grok-4")
        #expect(body["store"] as? Bool == false)
        #expect(body["previous_response_id"] == nil)
        #expect((body["reasoning"] as? [String: Any])?["effort"] as? String == "high")
        #expect(body["max_output_tokens"] as? Int == 256)
    }

    @Test
    func xAIRejectsReasoningIncompatibleStopPresenceAndFrequencyControls() async throws {
        for incompatible in [
            (LLMParameterID.generationStopSequences, LLMParameterValue.textList(["stop"])),
            (LLMParameterID(rawValue: "sampling.presence_penalty"), .decimal(0.5)),
            (LLMParameterID(rawValue: "sampling.frequency_penalty"), .decimal(0.5)),
        ] {
            let fixture = try await makeAuthorizedTransportFixture(
                modelID: "grok-4",
                parameters: GenerationConfiguration()
                    .setting(.reasoningEffort, to: .text("high"))
                    .setting(incompatible.0, to: incompatible.1)
            )
            defer { fixture.cleanup() }
            let session = try XAIAdapter().makeSession(fixture.sessionContext)
            expectAdapterFailure("cloud_adapter.parameter_incompatible") {
                _ = try session.encodeStart(fixture.authorizedTurn)
            }
        }
    }

    @Test
    func nonGrokModelIsRejectedBeforeWireEncoding() async throws {
        let fixture = try await makeAuthorizedTransportFixture(modelID: "gpt-5")
        defer { fixture.cleanup() }
        let session = try XAIAdapter().makeSession(fixture.sessionContext)
        expectAdapterFailure("cloud_adapter.model_incompatible") {
            _ = try session.encodeStart(fixture.authorizedTurn)
        }
    }

    @Test
    func grokResumeResendsCompleteStatelessHistoryAndToolResults() async throws {
        let first = try await makeAuthorizedTransportFixture(modelID: "grok-4")
        let fixture = try await makeAuthorizedTransportFixture(
            modelID: "grok-4",
            providerHistory: .array([.string("xai-history-sentinel")]),
            toolResults: [
                xaiToolResult(callID: "xcall_1", name: "search.one"),
                xaiToolResult(callID: "xcall_2", name: "search.two"),
            ]
        )
        defer { first.cleanup(); fixture.cleanup() }
        let session = try XAIAdapter().makeSession(first.sessionContext)
        _ = try await decodeResponsesFixture("xai-two-tools", session: session)

        let wire = try session.encodeResume(fixture.authorizedTurn)
        let body = try wireJSONObject(wire)
        let serialized = try wireJSONString(wire)

        #expect(body["store"] as? Bool == false)
        #expect(body["previous_response_id"] == nil)
        #expect(serialized.contains("xai-history-sentinel"))
        #expect(serialized.contains("function_call_output"))
        #expect(serialized.contains("xcall_1"))
        #expect(serialized.contains("xcall_2"))
    }

    @Test
    func resumeRejectsReorderedToolResults() async throws {
        let first = try await makeAuthorizedTransportFixture(modelID: "grok-4")
        let reordered = try await makeAuthorizedTransportFixture(
            modelID: "grok-4",
            toolResults: [
                xaiToolResult(callID: "xcall_2", name: "search.two"),
                xaiToolResult(callID: "xcall_1", name: "search.one"),
            ]
        )
        defer { first.cleanup(); reordered.cleanup() }
        let session = try XAIAdapter().makeSession(first.sessionContext)
        _ = try await decodeResponsesFixture("xai-two-tools", session: session)

        expectAdapterFailure("cloud_adapter.tool_result_batch_mismatch") {
            _ = try session.encodeResume(reordered.authorizedTurn)
        }
    }

    @Test
    func grokReasoningAndToolStreamsUseSharedWireButExactXAIIdentity() async throws {
        let fixture = try await makeAuthorizedTransportFixture(modelID: "grok-4")
        defer { fixture.cleanup() }
        let reasoningSession = try XAIAdapter().makeSession(fixture.sessionContext)
        let reasoning = try await decodeResponsesFixture("xai-reasoning", session: reasoningSession)
        #expect(reasoning.contains(.reasoningSummaryDelta("Grok summary")))
        #expect(reasoning.contains(.usageUpdated(LLMUsage(inputTokens: 8, outputTokens: 4))))

        let toolSession = try XAIAdapter().makeSession(fixture.sessionContext)
        let tools = try await decodeResponsesFixture("xai-two-tools", session: toolSession)
        #expect(tools.last == .generationCompleted(LLMBackendCompletion(
            outcome: .toolCallsReady,
            orderedCallIDs: ["xcall_1", "xcall_2"],
            finishReason: .toolCalls
        )))
    }

    @Test
    func sharedRateLimitFailureIsRedactedUnderXAIAdapter() async throws {
        let fixture = try await makeAuthorizedTransportFixture(modelID: "grok-4")
        defer { fixture.cleanup() }
        let session = try XAIAdapter().makeSession(fixture.sessionContext)
        do {
            _ = try await decodeResponsesFixture("responses-rate-limit", session: session)
            Issue.record("expected rate limit failure")
        } catch let failure as LLMFailure {
            #expect(failure.code == "cloud_transport.rate_limited")
            #expect(failure.retryable)
            #expect(!failure.message.contains("SECRET"))
        }
    }
}

private func xaiToolResult(callID: String, name: String) -> NormalizedToolResult {
    NormalizedToolResult(
        callID: callID,
        toolName: name,
        result: .string("result"),
        isError: false,
        dataClasses: [.toolResult],
        highestSensitivity: .routine
    )
}
