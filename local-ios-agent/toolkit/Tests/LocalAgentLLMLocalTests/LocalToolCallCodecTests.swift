import LocalAgentLLMContracts
import Testing
@testable import LocalAgentLLMLocal

@Suite("Local tool-call codec")
struct LocalToolCallCodecTests {
    @Test
    func parsesOrderedBatchAndKeepsOnlyThePreambleVisible() throws {
        let decoded = try LocalToolCallCodec.decode(
            codecID: "json_tool_calls_v1",
            rawText: "I will check. <tool_calls>{\"calls\":[{\"id\":\"call-b\",\"name\":\"search\",\"arguments\":{\"q\":\"swift\"}},{\"id\":\"call-a\",\"name\":\"open\",\"arguments\":{\"id\":1}}]}</tool_calls>"
        )

        #expect(decoded.visiblePreamble == "I will check. ")
        #expect(decoded.calls.map(\.callID) == ["call-b", "call-a"])
        #expect(decoded.calls.map(\.name) == ["search", "open"])
        #expect(decoded.calls[0].argumentsJSON == "{\"q\":\"swift\"}")
        #expect(decoded.completion == LLMBackendCompletion(
            outcome: .toolCallsReady,
            orderedCallIDs: ["call-b", "call-a"],
            finishReason: .toolCalls
        ))
    }

    @Test
    func malformedOrTrailingToolOutputFailsRatherThanGuessing() {
        expectCodecFailure {
            try LocalToolCallCodec.decode(
                codecID: "json_tool_calls_v1",
                rawText: "<tool_calls>{\"calls\":[{\"id\":\"x\"}]}</tool_calls>"
            )
        }
        expectCodecFailure {
            try LocalToolCallCodec.decode(
                codecID: "json_tool_calls_v1",
                rawText: "<tool_calls>{\"calls\":[]}</tool_calls>unframed tail"
            )
        }
        expectCodecFailure {
            try LocalToolCallCodec.decode(codecID: "unknown", rawText: "hello")
        }
    }

    @Test
    func continuationRestoresAssistantToolBatchBeforeToolResults() throws {
        let input = AgentLLMInput(
            inputID: "turn-2",
            messages: [
                LLMInputMessage(role: .system, content: [.text("policy")]),
                LLMInputMessage(role: .user, content: [.text("find Ada")]),
                LLMInputMessage(role: .tool, content: [.text("Ada")]),
            ]
        )
        let continued = try localContinuationInput(
            input,
            pendingToolCalls: [
                NormalizedToolCall(
                    callID: "call-1",
                    name: "contacts.search",
                    argumentsJSON: #"{"query":"Ada"}"#
                ),
            ]
        )

        #expect(continued.messages.map(\.role) == [
            .system, .user, .assistant, .tool,
        ])
        guard case let .text(text)? = continued.messages[2].content.first else {
            Issue.record("assistant tool-call batch is missing")
            return
        }
        #expect(
            text
                == #"<tool_calls>{"calls":[{"arguments":{"query":"Ada"},"id":"call-1","name":"contacts.search"}]}</tool_calls>"#
        )
    }

    @Test
    func nativeLlamaToolResultBecomesOneOrderedBatchWithoutLeakingMarkup() async throws {
        let channel = CppEventChannel(maxEventCount: 8, maxUTF8Bytes: 4_096)
        #expect(channel.send(.textDelta(
            "<tool_call><function=search><parameter=q>swift</parameter></function></tool_call>"
        )) == .accepted)
        #expect(channel.send(.nativeToolResult(
            visibleText: "I will search. ",
            calls: [
                NormalizedToolCall(
                    callID: "local-call-1",
                    name: "search",
                    argumentsJSON: #"{"q":"swift"}"#
                ),
            ]
        )) == .accepted)
        #expect(channel.send(.completed(rawFinishReason: "stop")) == .accepted)
        channel.finish()

        let sequence = LLMBackendEventSequence(
            native: channel.sequence,
            toolCallCodecID: "llama_cpp_native_tools_v1",
            terminal: { _ in }
        )
        var events: [LLMBackendEvent] = []
        for try await event in sequence { events.append(event) }

        #expect(events == [
            .textDelta("I will search. "),
            .toolCallStarted(callID: "local-call-1", name: "search"),
            .toolCallCompleted(NormalizedToolCall(
                callID: "local-call-1",
                name: "search",
                argumentsJSON: #"{"q":"swift"}"#
            )),
            .generationCompleted(LLMBackendCompletion(
                outcome: .toolCallsReady,
                orderedCallIDs: ["local-call-1"],
                finishReason: .toolCalls
            )),
        ])
    }
}

private func expectCodecFailure(operation: () throws -> Void) {
    do {
        try operation()
        Issue.record("expected tool codec failure")
    } catch let failure as LLMFailure {
        #expect(failure.code.hasPrefix("local_engine.tool_codec"))
    } catch {
        Issue.record("unexpected codec error: \(error)")
    }
}
