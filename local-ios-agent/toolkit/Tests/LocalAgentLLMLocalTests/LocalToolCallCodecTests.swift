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
