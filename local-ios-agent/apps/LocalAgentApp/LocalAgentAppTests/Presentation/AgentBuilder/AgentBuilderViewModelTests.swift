import Foundation
import LocalAgentBridge
import Testing
@testable import LocalAgentApp

@Suite("Agent builder view model")
@MainActor
struct AgentBuilderViewModelTests {
    @Test("readiness issues appear without Rust domain objects")
    func readinessIssuesAppearWithoutRustDomainObjects() async {
        let viewModel = AgentBuilderViewModel.fixtureWithMissingModelAndPermission()

        await viewModel.refreshReadiness()

        #expect(viewModel.readiness.issues.map(\.code) == [
            "model.primary.missing",
            "permission.calendar.missing",
        ])
    }

    @Test("editing after validation returns draft to dirty")
    func editingAfterValidationReturnsDraftToDirty() async {
        let viewModel = AgentBuilderViewModel.fixtureReadyToPublish()

        await viewModel.validateCurrentDraft()
        #expect(viewModel.lifecycle == .readyToPublish)

        viewModel.markEdited()
        #expect(viewModel.lifecycle == .dirty)
    }

    @Test("publish pins returned profile revision")
    func publishPinsReturnedProfileRevision() async {
        let viewModel = AgentBuilderViewModel.fixtureReadyToPublish(publishedRevision: 3)

        await viewModel.validateCurrentDraft()
        await viewModel.publishCurrentDraft()

        #expect(viewModel.publishedProfileRevisionId == 3)
        #expect(viewModel.lifecycle == .published(profileRevisionId: 3))
    }

    @Test("stale publish failure does not overwrite later edits")
    func stalePublishFailureDoesNotOverwriteLaterEdits() async {
        let viewModel = AgentBuilderViewModel(
            profileId: "profile_1",
            builderClient: DelayedFailingAgentBuilderClient(),
            permissionClient: MockPermissionClient(issues: []),
            toolCatalogClient: StaticAgentBuilderToolCatalogClient(cards: [])
        )

        await viewModel.validateCurrentDraft()
        let publishTask = Task { await viewModel.publishCurrentDraft() }
        while viewModel.lifecycle != .publishing {
            await Task.yield()
        }

        viewModel.markEdited()
        await publishTask.value

        #expect(viewModel.lifecycle == .dirty)
    }

    @Test("load creates draft and loads manifest-backed tool cards")
    func loadCreatesDraftAndToolCards() async throws {
        let viewModel = AgentBuilderViewModel(
            profileId: "profile_1",
            builderClient: MockAgentBuilderClient.readyToPublish(),
            permissionClient: MockPermissionClient(issues: []),
            toolCatalogClient: StaticAgentBuilderToolCatalogClient(cards: [
                AgentBuilderToolCard.unavailable(
                    id: "web.fetch_url_text",
                    name: "web.fetch_url_text",
                    reason: "test"
                ),
            ])
        )

        await viewModel.load()

        #expect(viewModel.draft?.sourceProfileId == "profile_1")
        #expect(viewModel.toolCards.map(\.name) == ["web.fetch_url_text"])
        #expect(viewModel.lifecycle == .editing)
    }

    @Test("toggle tool marks draft dirty")
    func toggleToolMarksDraftDirty() async throws {
        let viewModel = AgentBuilderViewModel.fixtureReadyToPublish()

        await viewModel.load()
        viewModel.toggleTool("web.fetch_url_text")

        #expect(viewModel.draft?.selectedToolIds == ["web.fetch_url_text"])
        #expect(viewModel.lifecycle == .dirty)
    }

    @Test("preview context produces preview-only result")
    func previewContextProducesPreviewOnlyResult() async throws {
        let viewModel = AgentBuilderViewModel.fixtureReadyToPublish()

        await viewModel.load()
        viewModel.previewContext(sampleUserMessage: "Hello")

        #expect(viewModel.preview?.isPreviewOnly == true)
        #expect(viewModel.preview?.warnings.contains("Preview only: final model input is assembled by Rust execution.") == true)
    }

    @Test("publish stores exact profile selection")
    func publishStoresExactProfileSelection() async throws {
        let viewModel = AgentBuilderViewModel.fixtureReadyToPublish(publishedRevision: 9)

        await viewModel.load()
        await viewModel.validateCurrentDraft()
        await viewModel.publishCurrentDraft()

        #expect(viewModel.publishedAgentSelection == PublishedAgentSelection(
            profileId: "profile_1",
            profileRevisionId: 9,
            displayName: "Assistant"
        ))
    }

    @Test("editing after publish clears stale chat handoff selection")
    func editingAfterPublishClearsStaleSelection() async throws {
        let viewModel = AgentBuilderViewModel.fixtureReadyToPublish(publishedRevision: 9)

        await viewModel.load()
        await viewModel.validateCurrentDraft()
        await viewModel.publishCurrentDraft()
        viewModel.toggleTool("web.fetch_url_text")

        #expect(viewModel.lifecycle == .dirty)
        #expect(viewModel.publishedAgentSelection == nil)
    }
}

private actor DelayedFailingAgentBuilderClient: AgentBuilderClient {
    func loadTemplate(_ id: String) async throws -> AgentBuilderUIModel {
        AgentBuilderUIModel(
            profileId: id,
            displayName: "Assistant",
            readiness: PermissionReadinessUIModel()
        )
    }

    func validateDraft(_ draft: AgentBuilderDraftDTO) async throws -> ReadinessUIModel {
        ReadinessUIModel(issues: [])
    }

    func publishProfile(_ draft: AgentBuilderDraftDTO) async throws -> AgentProfileDTO {
        try await Task.sleep(nanoseconds: 50_000_000)
        throw AgentBuilderTestError.publishFailed
    }
}

private enum AgentBuilderTestError: Error, LocalizedError {
    case publishFailed

    var errorDescription: String? {
        "Publish failed"
    }
}
