import Foundation
import LocalAgentLLMContracts
import Testing
@testable import LocalAgentLLMCloud

@Suite("Gemini Interactions semantic adapter", .serialized)
struct GeminiInteractionsAdapterTests {
    @Test
    func statelessRequestResendsHistoryAndRespecifiesInteractionControls() async throws {
        let fixture = try await makeAuthorizedTransportFixture(
            modelID: "gemini-3.5-flash",
            providerHistory: try geminiHistory(),
            parameters: GenerationConfiguration(parameters: [
                LLMParameterID.samplingTemperature.rawValue: .decimal(0.4),
                LLMParameterID.samplingTopP.rawValue: .decimal(0.8),
                LLMParameterID.generationMaxOutputTokens.rawValue: .integer(512),
                LLMParameterID.generationSeed.rawValue: .integer(7),
                LLMParameterID.generationStopSequences.rawValue: .textList(["STOP"]),
                LLMParameterID.reasoningEffort.rawValue: .text("high"),
                "thinking.display": .text("summarized"),
            ]),
            systemText: "system sentinel"
        )
        defer { fixture.cleanup() }
        let adapter = GeminiInteractionsAdapter()
        let wire = try adapter.makeSession(fixture.sessionContext).encodeStart(fixture.authorizedTurn)
        let body = try wireJSONObject(wire)
        let config = try #require(body["generation_config"] as? [String: Any])

        #expect(adapter.presetID == .gemini)
        #expect(adapter.adapterID == "gemini.interactions")
        #expect(wire.path == "/interactions")
        #expect(wire.queryItems.isEmpty)
        #expect(wire.headers["x-goog-api-key"] == nil)
        #expect(body["store"] as? Bool == false)
        #expect(body["previous_interaction_id"] == nil)
        #expect(body["system_instruction"] as? String == "system sentinel")
        #expect(config["temperature"] as? Double == 0.4)
        #expect(config["top_p"] as? Double == 0.8)
        #expect(config["max_output_tokens"] as? Int == 512)
        #expect(config["seed"] as? Int == 7)
        #expect(config["thinking_level"] as? String == "high")
        #expect(config["thinking_summaries"] as? String == "auto")
        #expect(try wireJSONString(wire).contains("history sentinel"))
        #expect(try wireJSONString(wire).contains("contacts.search"))
    }

    @Test
    func statelessFunctionTurnPreservesPrivateSignatureAndExactOrderedBatch() async throws {
        let start = try await geminiFixture()
        let resume = try await geminiToolFixture()
        let reversed = try await geminiToolFixture(reversed: true)
        defer { start.cleanup(); resume.cleanup(); reversed.cleanup() }
        let session = try GeminiInteractionsAdapter().makeSession(start.sessionContext)
        _ = try session.encodeStart(start.authorizedTurn)
        let events = try await decodeGeminiFixture("gemini-two-functions", session: session)

        #expect(events.contains(.reasoningSummaryDelta("Checking both sources. ")))
        #expect(events.contains(.textDelta("I will check. ")))
        #expect(events.contains(.usageUpdated(LLMUsage(inputTokens: 20, outputTokens: 8))))
        #expect(events.last == .generationCompleted(LLMBackendCompletion(
            outcome: .toolCallsReady,
            orderedCallIDs: ["fn_weather", "fn_calendar"],
            finishReason: .toolCalls
        )))

        let wire = try session.encodeResume(resume.authorizedTurn)
        let body = try wireJSONObject(wire)
        #expect(body["store"] as? Bool == false)
        #expect(body["previous_interaction_id"] == nil)
        #expect(try wireJSONString(wire).contains("gemini-private-signature"))
        #expect(try wireJSONString(wire).contains("history sentinel"))
        #expect(!wire.debugDescription.contains("gemini-private-signature"))
        expectAdapterFailure("cloud_adapter.tool_result_batch_mismatch") {
            _ = try session.encodeResume(reversed.authorizedTurn)
        }
        expectAdapterFailure("cloud_adapter.tool_result_batch_mismatch") {
            _ = try session.encodeResume(start.authorizedTurn)
        }
    }

    @Test
    func approvedProviderStateUsesOnlyExactPrivateInteractionID() async throws {
        let start = try await geminiFixture(retentionMode: .providerStateApproved)
        let resume = try await geminiToolFixture(retentionMode: .providerStateApproved)
        defer { start.cleanup(); resume.cleanup() }
        let session = try GeminiInteractionsAdapter().makeSession(start.sessionContext)
        let first = try wireJSONObject(session.encodeStart(start.authorizedTurn))
        #expect(first["store"] as? Bool == true)
        #expect(first["previous_interaction_id"] == nil)
        _ = try await decodeGeminiFixture("gemini-two-functions", session: session)

        let wire = try session.encodeResume(resume.authorizedTurn)
        let body = try wireJSONObject(wire)
        #expect(body["store"] as? Bool == true)
        #expect(body["previous_interaction_id"] as? String == "interaction-private-1")
        #expect(!(try wireJSONString(wire)).contains("gemini-private-signature"))
        #expect(!(try wireJSONString(wire)).contains("history sentinel"))
    }

    @Test
    func completedTextUnknownEventsAndModalityUsageNormalize() async throws {
        let fixture = try await geminiFixture()
        defer { fixture.cleanup() }
        let events = try await decodeGeminiFixture(
            "gemini-completed",
            session: try GeminiInteractionsAdapter().makeSession(fixture.sessionContext)
        )
        #expect(events == [
            .textDelta("Gemini answer"),
            .usageUpdated(LLMUsage(inputTokens: 9, outputTokens: 3)),
            .generationCompleted(LLMBackendCompletion(
                outcome: .finalResponse,
                orderedCallIDs: [],
                finishReason: .stop
            )),
        ])
    }

    @Test
    func terminalStatusesAndStreamingErrorsMapWithoutSecretEcho() async throws {
        let fixture = try await geminiFixture()
        defer { fixture.cleanup() }
        await expectGeminiFailure("cloud_adapter.generation_failed", fixture: "gemini-failed", context: fixture.sessionContext)
        await expectGeminiFailure("cloud_adapter.generation_incomplete", fixture: "gemini-incomplete", context: fixture.sessionContext)
        await expectGeminiFailure("cloud_adapter.token_budget_exceeded", fixture: "gemini-budget-exceeded", context: fixture.sessionContext)
        await expectGeminiFailure("cloud_transport.unauthorized", fixture: "gemini-auth-error", context: fixture.sessionContext)
        await expectGeminiFailure("cloud_transport.rate_limited", fixture: "gemini-rate-error", context: fixture.sessionContext)
        let cancelled = try await decodeGeminiFixture(
            "gemini-cancelled",
            session: try GeminiInteractionsAdapter().makeSession(fixture.sessionContext)
        )
        #expect(cancelled == [.cancelled])

        let stateful = try await geminiFixture(retentionMode: .providerStateApproved)
        defer { stateful.cleanup() }
        let statefulSession = try GeminiInteractionsAdapter().makeSession(stateful.sessionContext)
        #expect(try await decodeGeminiFixture(
            "gemini-cancelled",
            session: statefulSession
        ) == [.cancelled])
        let next = try wireJSONObject(statefulSession.encodeStart(stateful.authorizedTurn))
        #expect(next["previous_interaction_id"] == nil)
    }

    @Test
    func malformedIndexesMissingSignatureEOFAndConsumerCancellationFailClosed() async throws {
        let fixture = try await geminiFixture()
        let resume = try await geminiToolFixture()
        defer { fixture.cleanup(); resume.cleanup() }
        await expectGeminiFailure("cloud_adapter.step_index_invalid", fixture: "gemini-bad-index", context: fixture.sessionContext)
        await expectGeminiFailure("stream.interrupted", fixture: "gemini-no-terminal", context: fixture.sessionContext)

        let missing = try GeminiInteractionsAdapter().makeSession(fixture.sessionContext)
        _ = try missing.encodeStart(fixture.authorizedTurn)
        _ = try await decodeGeminiFixture("gemini-missing-signature", session: missing)
        expectAdapterFailure("cloud_adapter.continuation_signature_missing") {
            _ = try missing.encodeResume(resume.authorizedTurn)
        }

        let cancelled = try GeminiInteractionsAdapter().makeSession(fixture.sessionContext)
        let events = try await collectGemini(cancelled.decode(AsyncThrowingStream<SSEEvent, Error> { continuation in
            continuation.finish(throwing: CancellationError())
        }))
        #expect(events == [.cancelled])

        let wrong = try await makeAuthorizedTransportFixture(modelID: "claude-sonnet-4-5")
        defer { wrong.cleanup() }
        expectAdapterFailure("cloud_adapter.model_incompatible") {
            _ = try GeminiInteractionsAdapter().makeSession(wrong.sessionContext)
                .encodeStart(wrong.authorizedTurn)
        }
    }
}

private func geminiFixture(
    retentionMode: ProviderRetentionMode = .statelessRequired
) async throws -> AuthorizedTransportFixture {
    try await makeAuthorizedTransportFixture(
        retentionMode: retentionMode,
        modelID: "gemini-3.5-flash",
        providerHistory: try geminiHistory(),
        parameters: GenerationConfiguration(parameters: [
            LLMParameterID.reasoningEffort.rawValue: .text("high"),
            "thinking.display": .text("summarized"),
        ]),
        systemText: "system sentinel"
    )
}

private func geminiToolFixture(
    retentionMode: ProviderRetentionMode = .statelessRequired,
    reversed: Bool = false
) async throws -> AuthorizedTransportFixture {
    let results = [
        messagesToolResult("fn_weather", "weather.get"),
        messagesToolResult("fn_calendar", "calendar.search"),
    ]
    return try await makeAuthorizedTransportFixture(
        retentionMode: retentionMode,
        modelID: "gemini-3.5-flash",
        providerHistory: try geminiHistory(),
        parameters: GenerationConfiguration(parameters: [
            LLMParameterID.reasoningEffort.rawValue: .text("high"),
            "thinking.display": .text("summarized"),
        ]),
        systemText: "system sentinel",
        toolResults: reversed ? Array(results.reversed()) : results
    )
}

private func geminiHistory() throws -> CanonicalJSONValue {
    .array([
        try .object(entries: [
            .init(name: "content", value: .array([
                try .object(entries: [
                    .init(name: "text", value: .string("history sentinel")),
                    .init(name: "type", value: .string("text")),
                ]),
            ])),
            .init(name: "type", value: .string("user_input")),
        ]),
    ])
}

private func decodeGeminiFixture(
    _ name: String,
    session: any CloudProviderSession
) async throws -> [LLMBackendEvent] {
    let data = try Data(contentsOf: try #require(Bundle.module.url(
        forResource: name,
        withExtension: "sse"
    )))
    var parser = SSEEventParser()
    let parsed = try parser.append(data) + parser.finish()
    return try await collectGemini(session.decode(AsyncThrowingStream { continuation in
        for event in parsed { continuation.yield(event) }
        continuation.finish()
    }))
}

private func collectGemini(_ stream: LLMBackendEventStream) async throws -> [LLMBackendEvent] {
    var values: [LLMBackendEvent] = []
    for try await event in stream { values.append(event) }
    return values
}

private func expectGeminiFailure(
    _ code: String,
    fixture: String,
    context: CloudProviderSessionContext
) async {
    do {
        let values = try await decodeGeminiFixture(
            fixture,
            session: try GeminiInteractionsAdapter().makeSession(context)
        )
        Issue.record("expected \(code), got \(values)")
    } catch let failure as LLMFailure {
        #expect(failure.code == code)
        #expect(!failure.message.contains("SECRET"))
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}
