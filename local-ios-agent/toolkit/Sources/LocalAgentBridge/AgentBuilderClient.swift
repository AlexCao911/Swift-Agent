public protocol AgentBuilderClient: Sendable {
    func loadTemplate(_ id: String) async throws -> AgentBuilderUIModel
    func validateDraft(_ draft: AgentBuilderDraftDTO) async throws -> ReadinessUIModel
    func publishProfile(_ draft: AgentBuilderDraftDTO) async throws -> AgentProfileDTO
}

public actor MockAgentBuilderClient: AgentBuilderClient {
    private let model: AgentBuilderUIModel

    public init(model: AgentBuilderUIModel) {
        self.model = model
    }

    public static func withReadinessIssues(_ issues: [PermissionIssueDTO]) -> Self {
        Self(model: AgentBuilderUIModel(
            profileId: "profile_1",
            displayName: "Assistant",
            readiness: PermissionReadinessUIModel(issues: issues)
        ))
    }

    public func loadTemplate(_ id: String) async throws -> AgentBuilderUIModel {
        AgentBuilderUIModel(
            profileId: id,
            displayName: model.displayName,
            readiness: model.readiness
        )
    }

    public func validateDraft(_ draft: AgentBuilderDraftDTO) async throws -> ReadinessUIModel {
        model.readiness
    }

    public func publishProfile(_ draft: AgentBuilderDraftDTO) async throws -> AgentProfileDTO {
        AgentProfileDTO(profileId: draft.profileId, displayName: model.displayName)
    }
}
