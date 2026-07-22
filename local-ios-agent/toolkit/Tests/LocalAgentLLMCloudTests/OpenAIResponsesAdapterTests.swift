import Foundation
import LocalAgentLLMContracts
import Testing
@testable import LocalAgentLLMCloud

@Suite("OpenAI Responses semantic adapter", .serialized)
struct OpenAIResponsesAdapterTests {
    @Test
    func statelessStartEncodesStoreFalseFullHistoryToolsAndOpenAIParameters() async throws {
        let history = try CanonicalJSONValue.array([
            .object(entries: [
                .init(name: "content", value: .string("history-sentinel")),
                .init(name: "role", value: .string("assistant")),
                .init(name: "type", value: .string("message")),
            ]),
        ])
        let parameters = GenerationConfiguration()
            .setting(.samplingTemperature, to: .decimal(0.25))
            .setting(.samplingTopP, to: .decimal(0.9))
            .setting(.generationMaxOutputTokens, to: .integer(512))
            .setting(.reasoningEffort, to: .text("high"))
            .setting(.generationStopSequences, to: .textList(["END"]))
        let fixture = try await makeAuthorizedTransportFixture(
            modelID: "gpt-5",
            providerHistory: history,
            parameters: parameters
        )
        defer { fixture.cleanup() }
        let adapter = OpenAIResponsesAdapter()
        let session = try adapter.makeSession(fixture.sessionContext)

        let wire = try session.encodeStart(fixture.authorizedTurn)
        let body = try wireJSONObject(wire)
        let serialized = try wireJSONString(wire)

        #expect(adapter.presetID == .openAI)
        #expect(adapter.adapterID == "openai.responses")
        #expect(adapter.adapterVersion == "1")
        #expect(wire.method == "POST")
        #expect(wire.path == "/responses")
        #expect(wire.dataProvenance == .generation)
        #expect(body["model"] as? String == "gpt-5")
        #expect(body["stream"] as? Bool == true)
        #expect(body["store"] as? Bool == false)
        #expect(body["previous_response_id"] == nil)
        #expect(body["temperature"] as? Double == 0.25)
        #expect(body["top_p"] as? Double == 0.9)
        #expect(body["max_output_tokens"] as? Int == 512)
        #expect((body["reasoning"] as? [String: Any])?["effort"] as? String == "high")
        #expect(body["stop"] as? [String] == ["END"])
        #expect(serialized.contains("history-sentinel"))
        #expect(serialized.contains("contacts.search"))
        #expect(!serialized.lowercased().contains("authorization"))
    }

    @Test
    func resumeWithoutDecodedToolBatchFailsBeforeWireEncoding() async throws {
        let fixture = try await makeAuthorizedTransportFixture(
            modelID: "gpt-5",
            includeToolResult: true
        )
        defer { fixture.cleanup() }
        let session = try OpenAIResponsesAdapter().makeSession(fixture.sessionContext)

        expectAdapterFailure("cloud_adapter.continuation_missing") {
            _ = try session.encodeResume(fixture.authorizedTurn)
        }
    }

    @Test
    func textReasoningUsageAndUnknownEventsNormalizeWithoutRawReasoning() async throws {
        let fixture = try await makeAuthorizedTransportFixture(modelID: "gpt-5")
        defer { fixture.cleanup() }
        let session = try OpenAIResponsesAdapter().makeSession(fixture.sessionContext)

        let text = try await decodeResponsesFixture("responses-text", session: session)
        #expect(text == [
            .textDelta("Hello"),
            .textDelta(" world"),
            .usageUpdated(LLMUsage(inputTokens: 12, outputTokens: 3)),
            .generationCompleted(LLMBackendCompletion(
                outcome: .finalResponse,
                orderedCallIDs: [],
                finishReason: .stop
            )),
        ])

        let reasoningSession = try OpenAIResponsesAdapter().makeSession(fixture.sessionContext)
        let reasoning = try await decodeResponsesFixture("responses-reasoning", session: reasoningSession)
        #expect(reasoning.contains(.reasoningSummaryDelta("Checking constraints")))
        #expect(!String(describing: reasoning).lowercased().contains("raw_reasoning"))

        let unknownSession = try OpenAIResponsesAdapter().makeSession(fixture.sessionContext)
        let unknown = try await decodeResponsesFixture("responses-unknown", session: unknownSession)
        #expect(unknown.contains(.textDelta("Known")))
        #expect(!String(describing: unknown).contains("must-not-surface"))
    }

    @Test
    func twoToolCallsCompleteAsOneOrderedBatchWithMixedTextPreamble() async throws {
        let fixture = try await makeAuthorizedTransportFixture(modelID: "gpt-5")
        defer { fixture.cleanup() }
        let session = try OpenAIResponsesAdapter().makeSession(fixture.sessionContext)

        let events = try await decodeResponsesFixture("responses-two-tools", session: session)
        let completedCalls = events.compactMap { event -> String? in
            guard case let .toolCallCompleted(call) = event else { return nil }
            return call.callID
        }

        #expect(events.first == .textDelta("I will check both. "))
        #expect(completedCalls == ["call_weather", "call_calendar"])
        #expect(events.last == .generationCompleted(LLMBackendCompletion(
            outcome: .toolCallsReady,
            orderedCallIDs: ["call_weather", "call_calendar"],
            finishReason: .toolCalls
        )))
    }

    @Test
    func statelessResumeResendsHistoryAndEncryptedContinuationWithoutResponseID() async throws {
        let first = try await makeAuthorizedTransportFixture(modelID: "gpt-5")
        let next = try await makeAuthorizedTransportFixture(
            modelID: "gpt-5",
            providerHistory: .array([.string("complete-history-sentinel")]),
            toolResults: [responseToolResult(
                callID: "call-1",
                name: "contacts.search",
                output: "two contacts"
            )]
        )
        defer { first.cleanup(); next.cleanup() }
        let session = try OpenAIResponsesAdapter().makeSession(first.sessionContext)
        _ = try await decodeResponsesFixture("responses-encrypted-tool", session: session)

        let wire = try session.encodeResume(next.authorizedTurn)
        let body = try wireJSONObject(wire)
        let serialized = try wireJSONString(wire)

        #expect(body["store"] as? Bool == false)
        #expect(body["previous_response_id"] == nil)
        #expect(serialized.contains("complete-history-sentinel"))
        #expect(serialized.contains("encrypted-reasoning-token"))
        let rawInput = try #require(body["input"] as? [Any])
        let input = rawInput.compactMap { $0 as? [String: Any] }
        let types = input.compactMap { $0["type"] as? String }
        let callIndex = try #require(types.firstIndex(of: "function_call"))
        let outputIndex = try #require(types.firstIndex(of: "function_call_output"))
        #expect(callIndex < outputIndex)
        #expect(input[callIndex]["id"] as? String == "item-1")
        #expect(input[callIndex]["call_id"] as? String == "call-1")
        #expect(input[callIndex]["name"] as? String == "contacts.search")
        #expect(input[callIndex]["arguments"] as? String == "{}")

        expectAdapterFailure("cloud_adapter.continuation_missing") {
            _ = try session.encodeResume(next.authorizedTurn)
        }
    }

    @Test
    func resumeRequiresExactOrderedDecodedToolBatch() async throws {
        let first = try await makeAuthorizedTransportFixture(modelID: "gpt-5")
        defer { first.cleanup() }
        let session = try OpenAIResponsesAdapter().makeSession(first.sessionContext)
        _ = try await decodeResponsesFixture("responses-two-tools", session: session)
        let weather = responseToolResult(
            callID: "call_weather",
            name: "weather.get",
            output: "sunny"
        )
        let calendar = responseToolResult(
            callID: "call_calendar",
            name: "calendar.search",
            output: "free"
        )
        let invalidBatches = [
            [weather],
            [weather, weather],
            [calendar, weather],
            [weather, calendar, responseToolResult(
                callID: "call_extra",
                name: "extra",
                output: "extra"
            )],
            [responseToolResult(
                callID: "call_unrelated",
                name: "unrelated",
                output: "unrelated"
            ), calendar],
        ]
        for (index, results) in invalidBatches.enumerated() {
            let next = try await makeAuthorizedTransportFixture(
                modelID: "gpt-5",
                providerHistory: .array([.string("history-\(index)")]),
                toolResults: results
            )
            defer { next.cleanup() }
            expectAdapterFailure("cloud_adapter.tool_result_batch_mismatch") {
                _ = try session.encodeResume(next.authorizedTurn)
            }
        }

        let valid = try await makeAuthorizedTransportFixture(
            modelID: "gpt-5",
            providerHistory: .array([.string("complete-history")]),
            toolResults: [weather, calendar]
        )
        defer { valid.cleanup() }
        let body = try wireJSONObject(session.encodeResume(valid.authorizedTurn))
        let rawInput = try #require(body["input"] as? [Any])
        let input = rawInput.compactMap { $0 as? [String: Any] }
        let continuation = input.filter {
            ["function_call", "function_call_output"].contains($0["type"] as? String)
        }
        #expect(continuation.compactMap { $0["type"] as? String } == [
            "function_call", "function_call", "function_call_output", "function_call_output",
        ])
        #expect(continuation.compactMap { $0["call_id"] as? String } == [
            "call_weather", "call_calendar", "call_weather", "call_calendar",
        ])
    }

    @Test
    func statefulContinuationRequiresTheExactRetentionApprovalIdentity() async throws {
        let first = try await makeAuthorizedTransportFixture(
            retentionMode: .providerStateApproved,
            modelID: "gpt-5"
        )
        let next = try await makeAuthorizedTransportFixture(
            retentionMode: .providerStateApproved,
            modelID: "gpt-5",
            toolResults: [
                responseToolResult(callID: "call_weather", name: "weather.get", output: "sunny"),
                responseToolResult(callID: "call_calendar", name: "calendar.search", output: "free"),
            ]
        )
        defer { first.cleanup(); next.cleanup() }
        let session = try OpenAIResponsesAdapter().makeSession(first.sessionContext)
        _ = try await decodeResponsesFixture("responses-two-tools", session: session)

        let body = try wireJSONObject(session.encodeResume(next.authorizedTurn))
        #expect(body["store"] as? Bool == true)
        #expect(body["previous_response_id"] as? String == "resp_tools")

        let wrongContext = CloudProviderSessionContext(
            targetID: first.sessionContext.targetID,
            targetRevision: first.sessionContext.targetRevision,
            providerProfileID: first.sessionContext.providerProfileID,
            providerProfileRevision: first.sessionContext.providerProfileRevision,
            modelID: first.sessionContext.modelID,
            retentionMode: .providerStateApproved,
            retentionApprovalRevision: (first.sessionContext.retentionApprovalRevision ?? 0) + 1,
            retentionApprovalDigest: first.sessionContext.retentionApprovalDigest,
            hostProcessEpoch: first.sessionContext.hostProcessEpoch
        )
        let mismatched = try OpenAIResponsesAdapter().makeSession(wrongContext)
        expectAdapterFailure("cloud_adapter.session_mismatch") {
            _ = try mismatched.encodeStart(first.authorizedTurn)
        }
    }

    @Test
    func malformedIncompleteAuthenticationRateLimitAndCancellationAreTerminal() async throws {
        let fixture = try await makeAuthorizedTransportFixture(modelID: "gpt-5")
        defer { fixture.cleanup() }
        for (name, code) in [
            ("responses-malformed-tool", "cloud_adapter.tool_arguments_invalid"),
            ("responses-no-terminal", "cloud_adapter.terminal_missing"),
            ("responses-auth-error", "cloud_transport.unauthorized"),
            ("responses-rate-limit", "cloud_transport.rate_limited"),
        ] {
            let session = try OpenAIResponsesAdapter().makeSession(fixture.sessionContext)
            await expectResponsesDecodeFailure(code, fixture: name, session: session)
        }
        let cancelledSession = try OpenAIResponsesAdapter().makeSession(fixture.sessionContext)
        #expect(try await decodeResponsesFixture(
            "responses-cancelled",
            session: cancelledSession
        ) == [.cancelled])
    }
}

private func responseToolResult(
    callID: String,
    name: String,
    output: String
) -> NormalizedToolResult {
    NormalizedToolResult(
        callID: callID,
        toolName: name,
        result: .string(output),
        isError: false,
        dataClasses: [.toolResult],
        highestSensitivity: .routine
    )
}

func decodeResponsesFixture(
    _ name: String,
    session: any CloudProviderSession
) async throws -> [LLMBackendEvent] {
    let data = try Data(contentsOf: try #require(
        Bundle.module.url(forResource: name, withExtension: "sse")
    ))
    var parser = SSEEventParser()
    let parsed = try parser.append(data) + parser.finish()
    let source = AsyncThrowingStream<SSEEvent, Error> { continuation in
        for event in parsed { continuation.yield(event) }
        continuation.finish()
    }
    var values: [LLMBackendEvent] = []
    for try await event in session.decode(source) { values.append(event) }
    return values
}

func wireJSONObject(_ wire: CloudWireRequest) throws -> [String: Any] {
    let data = try #require(wire.body)
    let object = try JSONSerialization.jsonObject(with: data)
    return try #require(object as? [String: Any])
}

func wireJSONString(_ wire: CloudWireRequest) throws -> String {
    String(decoding: try #require(wire.body), as: UTF8.self)
}

func expectAdapterFailure(_ code: String, operation: () throws -> Void) {
    do {
        try operation()
        Issue.record("expected adapter failure \(code)")
    } catch let failure as LLMFailure {
        #expect(failure.code == code)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

private func expectResponsesDecodeFailure(
    _ code: String,
    fixture: String,
    session: any CloudProviderSession
) async {
    do {
        let values = try await decodeResponsesFixture(fixture, session: session)
        Issue.record("expected \(code), got \(values)")
    } catch let failure as LLMFailure {
        #expect(failure.code == code)
        let serialized = (try? JSONEncoder().encode(failure)).map {
            String(decoding: $0, as: UTF8.self)
        } ?? ""
        #expect(!serialized.contains("SECRET"))
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}
