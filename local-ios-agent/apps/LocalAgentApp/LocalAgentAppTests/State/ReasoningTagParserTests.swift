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
        parser.append("nk>hidden")
        parser.append("</thi")
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
