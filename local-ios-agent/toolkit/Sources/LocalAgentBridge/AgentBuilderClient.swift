public protocol AgentBuilderClient: Sendable {
    func loadTemplate(_ id: String) async throws -> AgentBuilderUIModel
    func validateDraft(_ draft: AgentBuilderDraftDTO) async throws -> ReadinessUIModel
    func publishProfile(_ draft: AgentBuilderDraftDTO) async throws -> AgentProfileDTO
}

public struct RustAgentBuilderClient: AgentBuilderClient {
    private let execution: any ExecutionBridgeClient

    public init(execution: any ExecutionBridgeClient) {
        self.execution = execution
    }

    public func loadTemplate(_ id: String) async throws -> AgentBuilderUIModel {
        AgentBuilderUIModel(
            profileId: id,
            displayName: "Assistant",
            readiness: PermissionReadinessUIModel()
        )
    }

    public func validateDraft(_ draft: AgentBuilderDraftDTO) async throws -> ReadinessUIModel {
        guard Self.supportedTemplateIds.contains(draft.templateId) else {
            return PermissionReadinessUIModel(issues: [
                PermissionIssueDTO(
                    code: "agent_builder.template_unsupported",
                    message: "This agent template is not available."
                ),
            ])
        }

        return PermissionReadinessUIModel()
    }

    public func publishProfile(_ draft: AgentBuilderDraftDTO) async throws -> AgentProfileDTO {
        try await execution.buildAgent(BuildAgentRequestDTO(
            profileId: draft.profileId,
            templateId: draft.templateId,
            displayName: draft.displayName,
            systemPrompt: draft.systemPrompt,
            persona: draft.persona,
            responseStyle: draft.responseStyle,
            selectedToolIds: draft.selectedToolIds,
            contextStepIds: draft.contextStepIds
        ))
    }

    private static let supportedTemplateIds: Set<String> = [
        "template_1",
        "template.assistant.default",
    ]
}

public actor MockAgentBuilderClient: AgentBuilderClient {
    private let model: AgentBuilderUIModel
    private let publishedRevision: UInt64

    public init(model: AgentBuilderUIModel, publishedRevision: UInt64 = 1) {
        self.model = model
        self.publishedRevision = publishedRevision
    }

    public static func withReadinessIssues(_ issues: [PermissionIssueDTO]) -> Self {
        Self(model: AgentBuilderUIModel(
            profileId: "profile_1",
            displayName: "Assistant",
            readiness: PermissionReadinessUIModel(issues: issues)
        ))
    }

    public static func readyToPublish(publishedRevision: UInt64 = 1) -> Self {
        Self(
            model: AgentBuilderUIModel(
                profileId: "profile_1",
                displayName: "Assistant",
                readiness: PermissionReadinessUIModel()
            ),
            publishedRevision: publishedRevision
        )
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
        AgentProfileDTO(
            profileId: draft.profileId,
            profileRevisionId: publishedRevision,
            displayName: model.displayName
        )
    }
}
