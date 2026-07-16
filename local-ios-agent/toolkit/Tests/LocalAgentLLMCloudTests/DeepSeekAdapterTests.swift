import Foundation
import LocalAgentLLMContracts
import Testing
@testable import LocalAgentLLMCloud

@Suite("DeepSeek Chat semantic adapter", .serialized)
struct DeepSeekAdapterTests {
    @Test
    func startEncodesCompleteHistoryToolsAndSupportedThinkingParameters() async throws {
        let fixture = try await makeAuthorizedTransportFixture(
            modelID: "deepseek-reasoner",
            providerHistory: .array([try .object(entries: [
                .init(name: "role", value: .string("assistant")),
                .init(name: "content", value: .string("deepseek-history-sentinel")),
            ])]),
            parameters: GenerationConfiguration()
                .setting(.reasoningEffort, to: .text("high"))
                .setting(.generationMaxOutputTokens, to: .integer(400))
        )
        defer { fixture.cleanup() }
        let adapter = DeepSeekAdapter()
        let session = try adapter.makeSession(fixture.sessionContext)

        let wire = try session.encodeStart(fixture.authorizedTurn)
        let body = try wireJSONObject(wire)
        let serialized = try wireJSONString(wire)

        #expect(adapter.presetID == .deepSeek)
        #expect(adapter.adapterID == "deepseek.chat_completions")
        #expect(wire.path == "/chat/completions")
        #expect(body["stream"] as? Bool == true)
        #expect(body["store"] == nil)
        #expect(body["previous_response_id"] == nil)
        #expect((body["thinking"] as? [String: Any])?["type"] as? String == "enabled")
        #expect(body["max_tokens"] as? Int == 400)
        #expect(serialized.contains("deepseek-history-sentinel"))
        #expect(serialized.contains("contacts.search"))
    }

    @Test
    func thinkingToolResumePreservesCompleteAssistantMessageUnchanged() async throws {
        let start = try await makeAuthorizedTransportFixture(
            modelID: "deepseek-reasoner",
            parameters: GenerationConfiguration().setting(.reasoningEffort, to: .text("high"))
        )
        let resume = try await makeAuthorizedTransportFixture(
            modelID: "deepseek-reasoner",
            parameters: GenerationConfiguration().setting(.reasoningEffort, to: .text("high")),
            toolResults: [
                chatToolResult("ds_call_weather", name: "weather.get"),
                chatToolResult("ds_call_calendar", name: "calendar.search"),
            ]
        )
        defer { start.cleanup(); resume.cleanup() }
        let session = try DeepSeekAdapter().makeSession(start.sessionContext)
        _ = try session.encodeStart(start.authorizedTurn)

        let events = try await decodeChatFixture("deepseek-thinking-tools", session: session)
        #expect(!events.contains { if case .reasoningSummaryDelta = $0 { true } else { false } })
        #expect(events.last == .generationCompleted(LLMBackendCompletion(
            outcome: .toolCallsReady,
            orderedCallIDs: ["ds_call_weather", "ds_call_calendar"],
            finishReason: .toolCalls
        )))

        let body = try wireJSONObject(session.encodeResume(resume.authorizedTurn))
        let messages = try #require(body["messages"] as? [[String: Any]])
        let assistant = try #require(messages.first { $0["role"] as? String == "assistant"
            && $0["reasoning_content"] != nil })
        #expect(assistant["reasoning_content"] as? String == "We need weather.")
        #expect(assistant["content"] as? String == "Checking. ")
        let calls = try #require(assistant["tool_calls"] as? [[String: Any]])
        #expect(calls.compactMap { $0["id"] as? String } == [
            "ds_call_weather", "ds_call_calendar",
        ])
        let toolMessages = messages.filter { $0["role"] as? String == "tool" }
        let lastToolCallID = toolMessages.last?["tool_call_id"] as? String
        #expect(lastToolCallID == "ds_call_calendar")
    }

    @Test
    func toolResultResumeWithoutPrivateAssistantContinuationFailsBeforeNetwork() async throws {
        let fixture = try await makeAuthorizedTransportFixture(
            modelID: "deepseek-reasoner",
            includeToolResult: true
        )
        defer { fixture.cleanup() }
        let session = try DeepSeekAdapter().makeSession(fixture.sessionContext)
        expectAdapterFailure("cloud_adapter.continuation_missing") {
            _ = try session.encodeResume(fixture.authorizedTurn)
        }
    }

    @Test
    func textUsageFinishAndDoneNormalizeWhileMissingDoneIsInterrupted() async throws {
        let fixture = try await makeAuthorizedTransportFixture(modelID: "deepseek-chat")
        defer { fixture.cleanup() }
        let session = try DeepSeekAdapter().makeSession(fixture.sessionContext)
        let events = try await decodeChatFixture("deepseek-text", session: session)
        #expect(events == [
            .textDelta("Hello"),
            .textDelta(" DeepSeek"),
            .usageUpdated(LLMUsage(inputTokens: 4, outputTokens: 2)),
            .generationCompleted(LLMBackendCompletion(
                outcome: .finalResponse,
                orderedCallIDs: [],
                finishReason: .stop
            )),
        ])

        let interrupted = try DeepSeekAdapter().makeSession(fixture.sessionContext)
        await expectChatDecodeFailure(
            "stream.interrupted",
            fixture: "deepseek-no-done",
            session: interrupted
        )
    }

    @Test
    func authRateCancellationAndModelConstraintsFailWithStableSemantics() async throws {
        let fixture = try await makeAuthorizedTransportFixture(modelID: "deepseek-chat")
        defer { fixture.cleanup() }
        await expectChatDecodeFailure(
            "cloud_transport.unauthorized",
            fixture: "deepseek-auth-error",
            session: try DeepSeekAdapter().makeSession(fixture.sessionContext)
        )
        await expectChatDecodeFailure(
            "cloud_transport.rate_limited",
            fixture: "deepseek-rate-error",
            session: try DeepSeekAdapter().makeSession(fixture.sessionContext)
        )
        let cancelled = try DeepSeekAdapter().makeSession(fixture.sessionContext)
        #expect(try await collectChat(cancelled.decode(AsyncThrowingStream<SSEEvent, Error> { continuation in
            continuation.finish(throwing: CancellationError())
        })) == [.cancelled])

        let wrongModel = try await makeAuthorizedTransportFixture(modelID: "glm-4")
        defer { wrongModel.cleanup() }
        let wrongSession = try DeepSeekAdapter().makeSession(wrongModel.sessionContext)
        expectAdapterFailure("cloud_adapter.model_incompatible") {
            _ = try wrongSession.encodeStart(wrongModel.authorizedTurn)
        }
    }

    @Test
    func reasoningControlIsRejectedForADeepSeekModelWithoutThinkingSupport() async throws {
        let fixture = try await makeAuthorizedTransportFixture(
            modelID: "deepseek-chat",
            parameters: GenerationConfiguration().setting(.reasoningEffort, to: .text("high"))
        )
        defer { fixture.cleanup() }
        let session = try DeepSeekAdapter().makeSession(fixture.sessionContext)
        expectAdapterFailure("cloud_adapter.parameter_unsupported") {
            _ = try session.encodeStart(fixture.authorizedTurn)
        }
    }
}

private func chatToolResult(_ callID: String, name: String) -> NormalizedToolResult {
    NormalizedToolResult(
        callID: callID,
        toolName: name,
        result: .string("tool result for \(callID)"),
        isError: false,
        dataClasses: [.toolResult],
        highestSensitivity: .routine
    )
}

func decodeChatFixture(
    _ name: String,
    session: any CloudProviderSession
) async throws -> [LLMBackendEvent] {
    let data = try Data(contentsOf: try #require(
        Bundle.module.url(forResource: name, withExtension: "sse")
    ))
    var parser = SSEEventParser()
    let events = try parser.append(data) + parser.finish()
    return try await collectChat(session.decode(AsyncThrowingStream { continuation in
        for event in events { continuation.yield(event) }
        continuation.finish()
    }))
}

func collectChat(_ stream: LLMBackendEventStream) async throws -> [LLMBackendEvent] {
    var output: [LLMBackendEvent] = []
    for try await event in stream { output.append(event) }
    return output
}

func expectChatDecodeFailure(
    _ code: String,
    fixture: String,
    session: any CloudProviderSession
) async {
    do {
        let events = try await decodeChatFixture(fixture, session: session)
        Issue.record("expected \(code), got \(events)")
    } catch let failure as LLMFailure {
        #expect(failure.code == code)
        #expect(!failure.message.contains("SECRET"))
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}
