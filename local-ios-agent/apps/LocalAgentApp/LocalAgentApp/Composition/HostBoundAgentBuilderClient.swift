import LocalAgentBridge
import LocalAgentLLMContracts
import LocalAgentLLMCore

struct AgentLLMTargetOption: Equatable, Sendable {
    let target: LLMTargetRevision
    let parameterSchema: LLMParameterSchema
}

struct AgentLLMSelectionDraft: Equatable, Sendable {
    let operationID: String
    let target: LLMTargetReference
    let requirements: AgentLLMRequirementsDTO
    let parameterOverrides: GenerationConfiguration
}

protocol AgentLLMTargetCatalog: Sendable {
    func targetOptions() async throws -> [AgentLLMTargetOption]
}

struct StaticAgentLLMTargetCatalog: AgentLLMTargetCatalog {
    let options: [AgentLLMTargetOption]

    func targetOptions() async throws -> [AgentLLMTargetOption] {
        options
    }
}

protocol AgentBuilderPublishing: Sendable {
    func loadTemplate(_ id: String) async throws -> AgentBuilderUIModel
    func validateDraft(_ draft: AgentBuilderDraftDTO) async throws -> ReadinessUIModel
    func previewContext(
        _ request: BuilderContextPreviewRequestDTO
    ) async throws -> BuilderContextPreviewResponseDTO
    func availableTargets() async throws -> [AgentLLMTargetOption]
    func publish(
        draft: AgentBuilderDraftDTO,
        llm: AgentLLMSelectionDraft
    ) async throws -> PublishedAgentSelection
}

struct AgentBuilderPublishError: Error, Equatable, Sendable {
    let code: String
    let message: String
}

struct LegacyAgentBuilderPublishingAdapter: AgentBuilderPublishing {
    let client: any AgentBuilderClient

    func loadTemplate(_ id: String) async throws -> AgentBuilderUIModel {
        try await client.loadTemplate(id)
    }

    func validateDraft(_ draft: AgentBuilderDraftDTO) async throws -> ReadinessUIModel {
        try await client.validateDraft(draft)
    }

    func previewContext(
        _ request: BuilderContextPreviewRequestDTO
    ) async throws -> BuilderContextPreviewResponseDTO {
        try await client.previewContext(request)
    }

    func availableTargets() async throws -> [AgentLLMTargetOption] {
        []
    }

    func publish(
        draft: AgentBuilderDraftDTO,
        llm: AgentLLMSelectionDraft
    ) async throws -> PublishedAgentSelection {
        let profile = try await client.publishProfile(draft)
        return PublishedAgentSelection(
            profileId: profile.profileId,
            profileRevisionId: profile.profileRevisionId,
            displayName: profile.displayName
        )
    }
}

actor HostBoundAgentBuilderClient: AgentBuilderPublishing {
    private let portable: any PortableAgentBuilderClient
    private let targets: any AgentLLMTargetCatalog
    private let bindingSaga: AgentHostBindingSaga
    private var activeConfigurations: [String: (AgentHostConfiguration, LLMTargetRevision)] = [:]

    init(
        portable: any PortableAgentBuilderClient,
        targets: any AgentLLMTargetCatalog,
        bindingSaga: AgentHostBindingSaga
    ) {
        self.portable = portable
        self.targets = targets
        self.bindingSaga = bindingSaga
    }

    func availableTargets() async throws -> [AgentLLMTargetOption] {
        try await targets.targetOptions()
    }

    func loadTemplate(_ id: String) async throws -> AgentBuilderUIModel {
        try await portable.loadTemplate(id)
    }

    func validateDraft(_ draft: AgentBuilderDraftDTO) async throws -> ReadinessUIModel {
        try await portable.validateDraft(draft)
    }

    func previewContext(
        _ request: BuilderContextPreviewRequestDTO
    ) async throws -> BuilderContextPreviewResponseDTO {
        try await portable.previewContext(request)
    }

    func publish(
        draft: AgentBuilderDraftDTO,
        llm: AgentLLMSelectionDraft
    ) async throws -> PublishedAgentSelection {
        let option = try await exactTarget(llm.target)
        let overrides = try LLMParameterSystem.resolve(
            targetDefaults: option.target.defaultParameters,
            hostOverrides: llm.parameterOverrides,
            schema: option.parameterSchema
        )
        let pending = try await portable.buildPendingProfile(BuildAgentV2RequestDTO(
            operationId: llm.operationID,
            draft: draft,
            requirements: llm.requirements
        ))
        let operation = try await portable.prepareProfilePublish(ProfilePublishPreparationDTO(
            idempotencyKey: llm.operationID,
            agentProfileId: pending.profileId,
            agentProfileRevision: pending.profileRevisionId,
            llmSlotId: pending.llmSlotId,
            requirementsHash: pending.requirementsHash
        ))
        let configuration = AgentHostConfiguration(
            bindingID: "binding.\(pending.profileId).\(pending.profileRevisionId)",
            revision: 1,
            agentProfileID: pending.profileId,
            agentProfileRevision: pending.profileRevisionId,
            llmSlotID: pending.llmSlotId,
            requirementsHash: pending.requirementsHash,
            llmTargetID: option.target.targetID,
            llmTargetRevision: option.target.revision,
            parameterOverrides: overrides
        )
        let receipt = try await bindingSaga.stageHostBinding(HostBindingStageRequest(
            operationToken: operation.token,
            tokenDigest: operation.tokenDigest,
            llmSlotID: operation.llmSlotId,
            requirementsHash: operation.requirementsHash,
            configuration: configuration
        ))
        let binding = HostBindingTupleDTO(
            bindingId: receipt.binding.bindingID,
            bindingRevision: receipt.binding.bindingRevision,
            bindingHash: receipt.binding.bindingHash
        )
        let receiptDTO = HostBindingStagingReceiptDTO(
            tokenDigest: receipt.tokenDigest,
            llmSlotId: receipt.llmSlotID,
            requirementsHash: receipt.requirementsHash,
            binding: binding,
            receiptDigest: receipt.receiptDigest
        )
        let crossLink = try await portable.commitProfilePublish(HostBindingCommitDTO(
            token: operation.token,
            binding: binding,
            receipt: receiptDTO
        ))
        try await bindingSaga.activateHostBinding(
            operationToken: operation.token,
            binding: receipt.binding
        )
        let active = try await portable.confirmHostBindingActivation(
            HostBindingActivationConfirmationDTO(
                agentProfileId: pending.profileId,
                agentProfileRevision: pending.profileRevisionId,
                llmSlotId: pending.llmSlotId,
                requirementsHash: pending.requirementsHash,
                binding: binding,
                stagingReceiptDigest: crossLink.stagingReceiptDigest
            )
        )
        guard active.state == "active", active.binding == binding else {
            throw AgentBuilderPublishError(
                code: "agent_builder.binding_not_active",
                message: "host binding did not reach the exact active state"
            )
        }
        activeConfigurations[configurationKey(
            profileID: pending.profileId,
            revision: pending.profileRevisionId
        )] = (configuration, option.target)
        return PublishedAgentSelection(
            profileId: pending.profileId,
            profileRevisionId: pending.profileRevisionId,
            displayName: pending.displayName
        )
    }

    func activeBinding(
        profileID: String,
        profileRevision: UInt64
    ) async throws -> HostBindingTuple? {
        guard let (configuration, target) = activeConfigurations[
            configurationKey(profileID: profileID, revision: profileRevision)
        ] else {
            return nil
        }
        return try await bindingSaga.requireActive(
            configuration: configuration,
            target: target
        )
    }

    private func exactTarget(
        _ reference: LLMTargetReference
    ) async throws -> AgentLLMTargetOption {
        guard let option = try await targets.targetOptions().first(where: {
            $0.target.reference == reference
        }) else {
            throw AgentBuilderPublishError(
                code: "agent_builder.target_missing",
                message: "selected immutable LLM target revision is unavailable"
            )
        }
        return option
    }

    private func configurationKey(profileID: String, revision: UInt64) -> String {
        "\(profileID):\(revision)"
    }
}
