import LocalAgentBridge
import Observation

enum AgentDraftLifecycleState: Equatable, Sendable {
    case empty
    case editing
    case dirty
    case validating
    case invalid
    case readyToPublish
    case publishing
    case published(profileRevisionId: UInt64)
    case publishFailed(String)
}

@MainActor
@Observable
final class AgentBuilderViewModel {
    private let profileId: String
    private let templateId: String
    private let builderClient: any AgentBuilderClient
    private let permissionClient: any PermissionClient
    private var draftVersion: UInt64 = 0

    var readiness: PermissionReadinessUIModel
    var lifecycle: AgentDraftLifecycleState = .empty
    var publishedProfileRevisionId: UInt64?

    init(
        profileId: String,
        templateId: String = "template_1",
        builderClient: any AgentBuilderClient,
        permissionClient: any PermissionClient,
        readiness: PermissionReadinessUIModel = PermissionReadinessUIModel()
    ) {
        self.profileId = profileId
        self.templateId = templateId
        self.builderClient = builderClient
        self.permissionClient = permissionClient
        self.readiness = readiness
    }

    func refreshReadiness() async {
        do {
            let draft = AgentBuilderDraftDTO(profileId: profileId, templateId: templateId)
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

    func markEdited() {
        draftVersion += 1
        switch lifecycle {
        case .validating, .invalid, .readyToPublish, .editing, .published, .publishFailed, .empty:
            lifecycle = .dirty
        case .dirty, .publishing:
            break
        }
    }

    func validateCurrentDraft() async {
        let version = draftVersion
        lifecycle = .validating
        await refreshReadiness()
        guard version == draftVersion else {
            lifecycle = .dirty
            return
        }
        lifecycle = readiness.issues.isEmpty ? .readyToPublish : .invalid
    }

    func publishCurrentDraft() async {
        guard lifecycle == .readyToPublish else {
            return
        }
        let version = draftVersion
        lifecycle = .publishing
        do {
            let profile = try await builderClient.publishProfile(
                AgentBuilderDraftDTO(profileId: profileId, templateId: templateId)
            )
            guard version == draftVersion else {
                lifecycle = .dirty
                return
            }
            publishedProfileRevisionId = profile.profileRevisionId
            lifecycle = .published(profileRevisionId: profile.profileRevisionId)
        } catch {
            guard version == draftVersion else {
                lifecycle = .dirty
                return
            }
            lifecycle = .publishFailed(error.localizedDescription)
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

    static func fixtureReadyToPublish(publishedRevision: UInt64 = 1) -> AgentBuilderViewModel {
        AgentBuilderViewModel(
            profileId: "profile_1",
            builderClient: MockAgentBuilderClient.readyToPublish(publishedRevision: publishedRevision),
            permissionClient: MockPermissionClient(issues: [])
        )
    }
}
