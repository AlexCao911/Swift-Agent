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
            permissionClient: MockPermissionClient(issues: [])
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
