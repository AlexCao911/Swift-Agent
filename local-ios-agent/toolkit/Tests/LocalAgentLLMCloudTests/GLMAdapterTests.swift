import Foundation
import LocalAgentLLMContracts
import Testing
@testable import LocalAgentLLMCloud

@Suite("GLM Chat semantic adapter", .serialized)
struct GLMAdapterTests {
    @Test
    func thinkingAndClearThinkingAreDerivedFromCanonicalReasoningMode() async throws {
        let enabled = try await makeAuthorizedTransportFixture(
            modelID: "glm-4.5",
            parameters: GenerationConfiguration().setting(.reasoningEffort, to: .text("high"))
        )
        let disabled = try await makeAuthorizedTransportFixture(
            modelID: "glm-4.5",
            parameters: GenerationConfiguration().setting(.reasoningEffort, to: .text("none"))
        )
        defer { enabled.cleanup(); disabled.cleanup() }
        let adapter = GLMAdapter()

        let enabledBody = try wireJSONObject(
            try adapter.makeSession(enabled.sessionContext).encodeStart(enabled.authorizedTurn)
        )
        let disabledBody = try wireJSONObject(
            try adapter.makeSession(disabled.sessionContext).encodeStart(disabled.authorizedTurn)
        )

        #expect(adapter.presetID == .glm)
        #expect(adapter.adapterID == "glm.chat_completions")
        #expect((enabledBody["thinking"] as? [String: Any])?["type"] as? String == "enabled")
        #expect(enabledBody["clear_thinking"] as? Bool == false)
        #expect((disabledBody["thinking"] as? [String: Any])?["type"] as? String == "disabled")
        #expect(disabledBody["clear_thinking"] as? Bool == true)
    }

    @Test
    func interleavedReasoningIsPrivateButPreservedExactlyForToolResume() async throws {
        let start = try await makeAuthorizedTransportFixture(
            modelID: "glm-4.5",
            parameters: GenerationConfiguration().setting(.reasoningEffort, to: .text("high"))
        )
        let resume = try await makeAuthorizedTransportFixture(
            modelID: "glm-4.5",
            parameters: GenerationConfiguration().setting(.reasoningEffort, to: .text("high")),
            toolResults: [
                NormalizedToolResult(
                    callID: "glm_call_1",
                    toolName: "search.one",
                    result: .string("one"),
                    isError: false,
                    dataClasses: [.toolResult],
                    highestSensitivity: .routine
                ),
                NormalizedToolResult(
                    callID: "glm_call_2",
                    toolName: "search.two",
                    result: .string("two"),
                    isError: false,
                    dataClasses: [.toolResult],
                    highestSensitivity: .routine
                ),
            ]
        )
        defer { start.cleanup(); resume.cleanup() }
        let session = try GLMAdapter().makeSession(start.sessionContext)
        _ = try session.encodeStart(start.authorizedTurn)

        let events = try await decodeChatFixture("glm-thinking-tools", session: session)
        #expect(!events.contains { if case .reasoningSummaryDelta = $0 { true } else { false } })
        #expect(events.last == .generationCompleted(LLMBackendCompletion(
            outcome: .toolCallsReady,
            orderedCallIDs: ["glm_call_1", "glm_call_2"],
            finishReason: .toolCalls
        )))

        let body = try wireJSONObject(session.encodeResume(resume.authorizedTurn))
        let messages = try #require(body["messages"] as? [[String: Any]])
        let assistant = try #require(messages.first { $0["reasoning_content"] != nil })
        #expect(assistant["reasoning_content"] as? String == "Plan A. Plan B.")
        #expect(assistant["content"] as? String == "Working. ")
        let calls = try #require(assistant["tool_calls"] as? [[String: Any]])
        #expect(calls.compactMap { $0["id"] as? String } == ["glm_call_1", "glm_call_2"])
    }

    @Test
    func textStreamNeverPublishesRawReasoningAndRequiresDone() async throws {
        let fixture = try await makeAuthorizedTransportFixture(modelID: "glm-4.5")
        defer { fixture.cleanup() }
        let session = try GLMAdapter().makeSession(fixture.sessionContext)
        let events = try await decodeChatFixture("glm-text", session: session)
        #expect(events.contains(.textDelta("GLM answer")))
        #expect(!events.contains { if case .reasoningSummaryDelta = $0 { true } else { false } })

        await expectChatDecodeFailure(
            "stream.interrupted",
            fixture: "glm-no-terminal",
            session: try GLMAdapter().makeSession(fixture.sessionContext)
        )
    }

    @Test
    func nonGLMModelAndProviderPrivateParameterNamesAreRejected() async throws {
        let wrong = try await makeAuthorizedTransportFixture(modelID: "deepseek-chat")
        let raw = try await makeAuthorizedTransportFixture(
            modelID: "glm-4.5",
            parameters: GenerationConfiguration(parameters: [
                "clear_thinking": .boolean(false),
            ])
        )
        defer { wrong.cleanup(); raw.cleanup() }
        expectAdapterFailure("cloud_adapter.model_incompatible") {
            _ = try GLMAdapter().makeSession(wrong.sessionContext).encodeStart(wrong.authorizedTurn)
        }
        expectAdapterFailure("cloud_adapter.parameter_unsupported") {
            _ = try GLMAdapter().makeSession(raw.sessionContext).encodeStart(raw.authorizedTurn)
        }
    }
}
