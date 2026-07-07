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
}
