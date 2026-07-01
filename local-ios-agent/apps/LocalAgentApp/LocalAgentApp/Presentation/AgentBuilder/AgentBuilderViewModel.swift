import LocalAgentBridge
import Observation

@MainActor
@Observable
final class AgentBuilderViewModel {
    private let profileId: String
    private let builderClient: any AgentBuilderClient
    private let permissionClient: any PermissionClient

    var readiness: PermissionReadinessUIModel

    init(
        profileId: String,
        builderClient: any AgentBuilderClient,
        permissionClient: any PermissionClient,
        readiness: PermissionReadinessUIModel = PermissionReadinessUIModel()
    ) {
        self.profileId = profileId
        self.builderClient = builderClient
        self.permissionClient = permissionClient
        self.readiness = readiness
    }

    func refreshReadiness() async {
        do {
            let draft = AgentBuilderDraftDTO(profileId: profileId)
            async let draftReadiness = builderClient.validateDraft(draft)
            async let permissionReadiness = permissionClient.readiness([])
            let draftResult = try await draftReadiness
            let permissionResult = try await permissionReadiness
            readiness = PermissionReadinessUIModel(issues: draftResult.issues + permissionResult.issues)
        } catch {
            readiness = PermissionReadinessUIModel(issues: [
                PermissionIssueDTO(code: "readiness.refresh_failed", message: error.localizedDescription),
            ])
        }
    }

    static func fixtureWithMissingModelAndPermission() -> AgentBuilderViewModel {
        AgentBuilderViewModel(
            profileId: "profile_1",
            builderClient: MockAgentBuilderClient.withReadinessIssues([
                PermissionIssueDTO(code: "model.primary.missing", message: "Select a model"),
            ]),
            permissionClient: MockPermissionClient(issues: [
                PermissionIssueDTO(code: "permission.calendar.missing", message: "Calendar access is off"),
            ])
        )
    }
}
