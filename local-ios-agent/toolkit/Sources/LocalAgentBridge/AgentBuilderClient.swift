public protocol PortableAgentBuilderClient: Sendable {
    func loadTemplate(_ id: String) async throws -> AgentBuilderUIModel
    func validateDraft(_ draft: AgentBuilderDraftDTO) async throws -> ReadinessUIModel
    func buildPendingProfile(_ request: BuildAgentV2RequestDTO) async throws -> PendingAgentProfileDTO
    func previewContext(_ request: BuilderContextPreviewRequestDTO) async throws -> BuilderContextPreviewResponseDTO
    func prepareProfilePublish(_ request: ProfilePublishPreparationDTO) async throws -> HostBindingOperationDTO
    func commitProfilePublish(_ request: HostBindingCommitDTO) async throws -> HostBindingCrossLinkDTO
    func prepareProfileRebind(_ request: ProfilePublishPreparationDTO) async throws -> HostBindingOperationDTO
    func commitProfileRebind(_ request: HostBindingCommitDTO) async throws -> HostBindingCrossLinkDTO
    func confirmHostBindingActivation(
        _ request: HostBindingActivationConfirmationDTO
    ) async throws -> HostBindingCrossLinkDTO
}

public struct RustPortableAgentBuilderClient: PortableAgentBuilderClient {
    private let gateway: any RustAgentOSBridgeGateway

    public init(gateway: any RustAgentOSBridgeGateway) {
        self.gateway = gateway
    }

    public func loadTemplate(_ id: String) async throws -> AgentBuilderUIModel {
        AgentBuilderUIModel(
            profileId: id,
            displayName: "Assistant",
            readiness: PermissionReadinessUIModel()
        )
    }

    public func validateDraft(_ draft: AgentBuilderDraftDTO) async throws -> ReadinessUIModel {
        guard Self.supportedTemplateIDs.contains(draft.templateId) else {
            return PermissionReadinessUIModel(issues: [
                PermissionIssueDTO(
                    code: "agent_builder.template_unsupported",
                    message: "This agent template is not available."
                ),
            ])
        }
        return PermissionReadinessUIModel()
    }

    public func buildPendingProfile(
        _ request: BuildAgentV2RequestDTO
    ) async throws -> PendingAgentProfileDTO {
        try await gateway.request(
            .buildAgentV2,
            request,
            as: PendingAgentProfileDTO.self
        )
    }

    public func previewContext(
        _ request: BuilderContextPreviewRequestDTO
    ) async throws -> BuilderContextPreviewResponseDTO {
        try await gateway.request(
            .previewContext,
            request,
            as: BuilderContextPreviewResponseDTO.self
        )
    }

    public func prepareProfilePublish(
        _ request: ProfilePublishPreparationDTO
    ) async throws -> HostBindingOperationDTO {
        try await gateway.request(
            .prepareProfilePublish,
            request,
            as: HostBindingOperationDTO.self
        )
    }

    public func commitProfilePublish(
        _ request: HostBindingCommitDTO
    ) async throws -> HostBindingCrossLinkDTO {
        try await gateway.request(
            .commitProfilePublish,
            request,
            as: HostBindingCrossLinkDTO.self
        )
    }

    public func prepareProfileRebind(
        _ request: ProfilePublishPreparationDTO
    ) async throws -> HostBindingOperationDTO {
        try await gateway.request(
            .prepareProfileRebind,
            request,
            as: HostBindingOperationDTO.self
        )
    }

    public func commitProfileRebind(
        _ request: HostBindingCommitDTO
    ) async throws -> HostBindingCrossLinkDTO {
        try await gateway.request(
            .commitProfileRebind,
            request,
            as: HostBindingCrossLinkDTO.self
        )
    }

    public func confirmHostBindingActivation(
        _ request: HostBindingActivationConfirmationDTO
    ) async throws -> HostBindingCrossLinkDTO {
        try await gateway.request(
            .confirmHostBindingActivation,
            request,
            as: HostBindingCrossLinkDTO.self
        )
    }

    private static let supportedTemplateIDs: Set<String> = [
        "template_1",
        "template.assistant.default",
    ]
}

@available(*, deprecated, message: "Use PortableAgentBuilderClient for host-bound V2 profiles")
public protocol AgentBuilderClient: Sendable {
    func loadTemplate(_ id: String) async throws -> AgentBuilderUIModel
    func validateDraft(_ draft: AgentBuilderDraftDTO) async throws -> ReadinessUIModel
    func publishProfile(_ draft: AgentBuilderDraftDTO) async throws -> AgentProfileDTO
    func previewContext(_ request: BuilderContextPreviewRequestDTO) async throws -> BuilderContextPreviewResponseDTO
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

    public func previewContext(_ request: BuilderContextPreviewRequestDTO) async throws -> BuilderContextPreviewResponseDTO {
        try await execution.previewContext(request)
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

    public func previewContext(_ request: BuilderContextPreviewRequestDTO) async throws -> BuilderContextPreviewResponseDTO {
        throw RuntimeBridgeError(
            kind: "builder_preview_unavailable",
            message: "Mock builder preview uses the local preview fallback."
        )
    }
}
