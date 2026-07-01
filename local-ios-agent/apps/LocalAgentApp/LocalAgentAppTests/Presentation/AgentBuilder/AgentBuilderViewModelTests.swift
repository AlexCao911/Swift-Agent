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
}
