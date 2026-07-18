import Foundation
import LocalAgentLLMContracts
import Testing
@testable import LocalAgentLLMCloud

@Suite("Anthropic Messages semantic adapter", .serialized)
struct AnthropicMessagesAdapterTests {
    @Test
    func requestMapsSystemToolsThinkingBudgetAndDisplayPolicy() async throws {
        let fixture = try await makeAuthorizedTransportFixture(
            modelID: "claude-sonnet-4-5",
            parameters: GenerationConfiguration(parameters: [
                LLMParameterID.generationMaxOutputTokens.rawValue: .integer(800),
                LLMParameterID.reasoningTokenBudget.rawValue: .integer(256),
                "thinking.display": .text("summarized"),
            ])
        )
        defer { fixture.cleanup() }
        let adapter = AnthropicMessagesAdapter()
        let session = try adapter.makeSession(fixture.sessionContext)

        let wire = try session.encodeStart(fixture.authorizedTurn)
        let body = try wireJSONObject(wire)
        #expect(adapter.presetID == .anthropic)
        #expect(adapter.adapterID == "anthropic.messages")
        #expect(wire.path == "/messages")
        #expect(wire.headers["anthropic-version"] == "2023-06-01")
        #expect(body["max_tokens"] as? Int == 800)
        #expect((body["thinking"] as? [String: Any])?["budget_tokens"] as? Int == 256)
        #expect(body["thinking_display"] == nil)
        #expect(try wireJSONString(wire).contains("contacts.search"))
    }

    @Test
    func summarizedThinkingIsPublicButSignatureRoundTripsPrivatelyForToolResume() async throws {
        let start = try await claudeFixture(display: "summarized")
        let resume = try await claudeToolResultFixture(display: "summarized")
        let reversed = try await claudeToolResultFixture(display: "summarized", reversed: true)
        defer { start.cleanup(); resume.cleanup(); reversed.cleanup() }
        let session = try AnthropicMessagesAdapter().makeSession(start.sessionContext)
        _ = try session.encodeStart(start.authorizedTurn)

        let events = try await decodeMessagesFixture("anthropic-thinking-tools", session: session)
        #expect(events.contains(.reasoningSummaryDelta("Consider weather. ")))
        #expect(events.last == .generationCompleted(LLMBackendCompletion(
            outcome: .toolCallsReady,
            orderedCallIDs: ["claude_call_weather", "claude_call_calendar"],
            finishReason: .toolCalls
        )))

        let serialized = try wireJSONString(session.encodeResume(resume.authorizedTurn))
        #expect(serialized.contains("Consider weather. "))
        #expect(serialized.contains("sig-private-123"))
        #expect(serialized.contains("claude_call_weather"))
        #expect(serialized.contains("tool_result"))
        expectAdapterFailure("cloud_adapter.tool_result_batch_mismatch") {
            _ = try session.encodeResume(reversed.authorizedTurn)
        }
    }

    @Test
    func omittedThinkingNeverBecomesPublicButStillRoundTripsSignature() async throws {
        let start = try await claudeFixture(display: "omitted")
        let resume = try await claudeToolResultFixture(display: "omitted")
        defer { start.cleanup(); resume.cleanup() }
        let session = try AnthropicMessagesAdapter().makeSession(start.sessionContext)
        _ = try session.encodeStart(start.authorizedTurn)
        let events = try await decodeMessagesFixture("anthropic-thinking-tools", session: session)
        #expect(!events.contains { if case .reasoningSummaryDelta = $0 { true } else { false } })
        let serialized = try wireJSONString(session.encodeResume(resume.authorizedTurn))
        #expect(serialized.contains("sig-private-123"))
        #expect(serialized.contains("Consider weather. "))
    }

    @Test
    func textPingUnknownUsageAndTerminalRulesNormalizeConservatively() async throws {
        let fixture = try await makeAuthorizedTransportFixture(modelID: "claude-sonnet-4-5")
        defer { fixture.cleanup() }
        let events = try await decodeMessagesFixture(
            "anthropic-text",
            session: try AnthropicMessagesAdapter().makeSession(fixture.sessionContext)
        )
        #expect(events == [
            .textDelta("Claude answer"),
            .usageUpdated(LLMUsage(inputTokens: 4, outputTokens: 2)),
            .generationCompleted(LLMBackendCompletion(
                outcome: .finalResponse,
                orderedCallIDs: [],
                finishReason: .stop
            )),
        ])
        await expectMessagesFailure(
            "stream.interrupted",
            fixture: "anthropic-no-stop",
            session: try AnthropicMessagesAdapter().makeSession(fixture.sessionContext)
        )
        await expectMessagesFailure(
            "cloud_adapter.block_index_invalid",
            fixture: "anthropic-bad-index",
            session: try AnthropicMessagesAdapter().makeSession(fixture.sessionContext)
        )
        await expectMessagesFailure(
            "cloud_adapter.tool_arguments_invalid",
            fixture: "anthropic-incomplete-tool",
            session: try AnthropicMessagesAdapter().makeSession(fixture.sessionContext)
        )
    }

    @Test
    func authRateCancellationAndWrongModelUseRedactedStableFailures() async throws {
        let fixture = try await makeAuthorizedTransportFixture(modelID: "claude-sonnet-4-5")
        defer { fixture.cleanup() }
        await expectMessagesFailure(
            "cloud_transport.unauthorized",
            fixture: "anthropic-auth-error",
            session: try AnthropicMessagesAdapter().makeSession(fixture.sessionContext)
        )
        await expectMessagesFailure(
            "cloud_transport.rate_limited",
            fixture: "anthropic-rate-error",
            session: try AnthropicMessagesAdapter().makeSession(fixture.sessionContext)
        )
        let cancelled = try AnthropicMessagesAdapter().makeSession(fixture.sessionContext)
        #expect(try await collectMessages(cancelled.decode(AsyncThrowingStream<SSEEvent, Error> {
            $0.finish(throwing: CancellationError())
        })) == [.cancelled])
        let wrong = try await makeAuthorizedTransportFixture(modelID: "MiniMax-M2")
        defer { wrong.cleanup() }
        expectAdapterFailure("cloud_adapter.model_incompatible") {
            _ = try AnthropicMessagesAdapter().makeSession(wrong.sessionContext)
                .encodeStart(wrong.authorizedTurn)
        }
    }
}

private func claudeFixture(display: String) async throws -> AuthorizedTransportFixture {
    return try await makeAuthorizedTransportFixture(
        modelID: "claude-sonnet-4-5",
        parameters: GenerationConfiguration(parameters: [
            LLMParameterID.reasoningTokenBudget.rawValue: .integer(256),
            "thinking.display": .text(display),
        ])
    )
}

private func claudeToolResultFixture(
    display: String,
    reversed: Bool = false
) async throws -> AuthorizedTransportFixture {
    let results = [
        messagesToolResult("claude_call_weather", "weather.get"),
        messagesToolResult("claude_call_calendar", "calendar.search"),
    ]
    return try await makeAuthorizedTransportFixture(
        modelID: "claude-sonnet-4-5",
        parameters: GenerationConfiguration(parameters: [
            LLMParameterID.reasoningTokenBudget.rawValue: .integer(256),
            "thinking.display": .text(display),
        ]),
        toolResults: reversed ? Array(results.reversed()) : results
    )
}

func messagesToolResult(_ callID: String, _ name: String) -> NormalizedToolResult {
    NormalizedToolResult(
        callID: callID,
        toolName: name,
        result: .string("result-\(callID)"),
        isError: false,
        dataClasses: [.toolResult],
        highestSensitivity: .routine
    )
}

func decodeMessagesFixture(
    _ name: String,
    session: any CloudProviderSession
) async throws -> [LLMBackendEvent] {
    let data = try Data(contentsOf: try #require(
        Bundle.module.url(forResource: name, withExtension: "sse")
    ))
    var parser = SSEEventParser()
    let events = try parser.append(data) + parser.finish()
    return try await collectMessages(session.decode(AsyncThrowingStream { continuation in
        for event in events { continuation.yield(event) }
        continuation.finish()
    }))
}

func collectMessages(_ stream: LLMBackendEventStream) async throws -> [LLMBackendEvent] {
    var output: [LLMBackendEvent] = []
    for try await event in stream { output.append(event) }
    return output
}

func expectMessagesFailure(
    _ code: String,
    fixture: String,
    session: any CloudProviderSession
) async {
    do {
        let events = try await decodeMessagesFixture(fixture, session: session)
        Issue.record("expected \(code), got \(events)")
    } catch let failure as LLMFailure {
        #expect(failure.code == code)
        #expect(!failure.message.contains("SECRET"))
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}
