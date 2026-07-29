import Testing
@testable import LocalAgentApp

@Suite("OpenMinis chat presentation facade")
@MainActor
struct OpenMinisChatFacadeTests {
    @Test("send submits the current draft exactly once")
    func sendSubmitsCurrentDraftExactlyOnce() async {
        let recorder = SubmissionRecorder()
        let viewModel = AIChatViewModel(
            conversationStreamID: "conversation-1",
            submit: { submission in
                await recorder.append(submission)
            }
        )
        viewModel.draft = "Inspect the repository"

        await viewModel.send()

        let submissions = await recorder.submissions
        #expect(submissions.count == 1)
        #expect(submissions.first?.conversationStreamID == "conversation-1")
        #expect(submissions.first?.text == "Inspect the repository")
        #expect(submissions.first?.attachments.isEmpty == true)
    }

    @Test("markdown keeps structural blocks and math nodes")
    func markdownKeepsStructuralBlocksAndMathNodes() {
        let content = MarkdownContent(
            """
            # Result

            - first
            - second

            Inline $x^2$.

            $$
            \\sum_{i=1}^{n} i
            $$
            """
        )

        #expect(content.blocks.contains { block in
            guard case .heading(level: 1, _) = block else { return false }
            return true
        })
        #expect(content.blocks.contains { block in
            guard case .bulletedList = block else { return false }
            return true
        })
        #expect(content.blocks.contains { block in
            guard case .mathBlock(content: let latex) = block else { return false }
            return latex.contains("\\sum")
        })
        #expect(content.blocks.contains { block in
            guard case .paragraph(content: let nodes) = block else { return false }
            return nodes.contains(.inlineMath("x^2"))
        })
    }
}

private actor SubmissionRecorder {
    private(set) var submissions: [AIChatViewModel.Submission] = []

    func append(_ submission: AIChatViewModel.Submission) {
        submissions.append(submission)
    }
}
