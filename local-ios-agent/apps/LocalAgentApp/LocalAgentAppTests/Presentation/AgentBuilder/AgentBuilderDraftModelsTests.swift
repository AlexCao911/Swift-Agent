import Foundation
import Testing
@testable import LocalAgentApp

@Suite("Agent builder draft models")
struct AgentBuilderDraftModelsTests {
    @Test("default draft has the MVP card families in stable order")
    func defaultDraftHasMVPCardFamilies() {
        let draft = AgentBuilderDraft.makeDefault(profileId: "profile_1")

        #expect(draft.sourceProfileId == "profile_1")
        #expect(draft.cards.map(\.kind) == [
            .identity,
            .prompt,
            .toolBelt,
            .contextPipeline,
            .memory,
            .skill,
            .model,
        ])
        #expect(draft.cards.first?.payload.identity?.displayName == "Assistant")
        #expect(draft.cards.first(where: { $0.kind == .identity })?.isPublishAffecting == false)
        #expect(draft.cards.first(where: { $0.kind == .prompt })?.isPublishAffecting == false)
        #expect(draft.cards.first(where: { $0.kind == .toolBelt })?.isPublishAffecting == false)
        #expect(draft.cards.first(where: { $0.kind == .contextPipeline })?.isPublishAffecting == false)
        #expect(draft.cards.first(where: { $0.kind == .memory })?.isPublishAffecting == false)
        #expect(draft.cards.first(where: { $0.kind == .skill })?.isPublishAffecting == false)
    }

    @Test("toggling a tool updates only tool belt payload")
    func togglingToolUpdatesToolBelt() {
        var draft = AgentBuilderDraft.makeDefault(profileId: "profile_1")

        draft.toggleTool("web.fetch_url_text")
        #expect(draft.selectedToolIds == ["web.fetch_url_text"])

        draft.toggleTool("web.fetch_url_text")
        #expect(draft.selectedToolIds == [])
    }

    @Test("context preview identifies unsupported disabled segments")
    func previewMarksDisabledSegments() {
        let draft = AgentBuilderDraft.makeDefault(profileId: "profile_1")
        let preview = BuilderContextPreviewResult.previewOnly(
            draft: draft,
            sampleUserMessage: "Summarize this page"
        )

        #expect(preview.isPreviewOnly)
        #expect(preview.segments.contains { $0.title == "Memory Summary" && !$0.isEnabled })
        #expect(preview.warnings.contains("Preview only: final model input is assembled by Rust execution."))
    }
}
