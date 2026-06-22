import Testing
@testable import LocalAgentApp

@Suite("Reasoning tag parser")
struct ReasoningTagParserTests {
    @Test("complete reasoning block is separated from answer text")
    func completeReasoningBlock() {
        var parser = ReasoningTagParser()

        parser.append("<think>I should inspect this.</think>The answer.")
        let parts = parser.finish()

        #expect(parts == [
            .reasoning(ReasoningPartViewState(id: "reasoning_0", text: "I should inspect this.", isCollapsed: true, isStreaming: false)),
            .text(TextPartViewState(id: "text_1", text: "The answer.")),
        ])
    }

    @Test("split tags across chunks do not leak raw tags")
    func splitTagsAcrossChunks() {
        var parser = ReasoningTagParser()

        parser.append("<thi")
        #expect(parser.snapshot(isFinal: false) == [])

        parser.append("nk>hidden")
        #expect(parser.snapshot(isFinal: false) == [
            .reasoning(ReasoningPartViewState(id: "reasoning_0", text: "hidden", isCollapsed: false, isStreaming: true)),
        ])

        parser.append("</thi")
        #expect(parser.snapshot(isFinal: false) == [
            .reasoning(ReasoningPartViewState(id: "reasoning_0", text: "hidden", isCollapsed: false, isStreaming: true)),
        ])

        parser.append("nk>visible")
        let parts = parser.finish()

        #expect(parts == [
            .reasoning(ReasoningPartViewState(id: "reasoning_0", text: "hidden", isCollapsed: true, isStreaming: false)),
            .text(TextPartViewState(id: "text_1", text: "visible")),
        ])
    }

    @Test("unclosed reasoning remains streaming and hides raw tag")
    func unclosedReasoningBlock() {
        var parser = ReasoningTagParser()

        parser.append("<think>still thinking")
        let parts = parser.snapshot(isFinal: false)

        #expect(parts == [
            .reasoning(ReasoningPartViewState(id: "reasoning_0", text: "still thinking", isCollapsed: false, isStreaming: true)),
        ])
    }

    @Test("normal text without reasoning stays as text")
    func normalTextOnly() {
        var parser = ReasoningTagParser()

        parser.append("plain answer")
        let parts = parser.finish()

        #expect(parts == [
            .text(TextPartViewState(id: "text_0", text: "plain answer")),
        ])
    }
}

@Suite("Agent message view state")
struct AgentMessageViewStateTests {
    @Test("compatibility text append preserves streamed reasoning source")
    func compatibilityTextAppendPreservesStreamedReasoningSource() {
        var message = AgentMessageViewState(id: "assistant_1", role: .assistant, text: "", isStreaming: true)

        message.text += "<think>hidden"
        message.text += "</think>visible"

        #expect(message.isStreaming)
        #expect(message.parts == [
            .reasoning(ReasoningPartViewState(id: "reasoning_0", text: "hidden", isCollapsed: true, isStreaming: false)),
            .text(TextPartViewState(id: "text_1", text: "visible")),
        ])
    }

    @Test("finalizing streaming message normalizes reasoning part state")
    func finalizingStreamingMessageNormalizesReasoningPartState() {
        var message = AgentMessageViewState(
            id: "assistant_1",
            role: .assistant,
            text: "<think>still thinking",
            isStreaming: true
        )

        message.isStreaming = false

        #expect(message.parts == [
            .reasoning(ReasoningPartViewState(id: "reasoning_0", text: "still thinking", isCollapsed: true, isStreaming: false)),
        ])
    }
}
