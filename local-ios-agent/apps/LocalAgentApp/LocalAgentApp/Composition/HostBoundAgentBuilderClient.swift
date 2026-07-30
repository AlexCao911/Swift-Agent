import LocalAgentBridge
import LocalAgentLLMContracts
import LocalAgentLLMCore

struct AgentLLMTargetOption: Equatable, Sendable {
    let target: LLMTargetRevision
    let parameterSchema: LLMParameterSchema
}

struct AgentLLMCandidateDraft: Equatable, Sendable {
    let target: LLMTargetReference
    let parameterOverrides: GenerationConfiguration
}

struct AgentLLMSelectionDraft: Equatable, Sendable {
    let operationID: String
    let target: LLMTargetReference
    let requirements: AgentLLMRequirementsDTO
    let parameterOverrides: GenerationConfiguration
    let fallbackCandidates: [AgentLLMCandidateDraft]

    init(
        operationID: String,
        target: LLMTargetReference,
        requirements: AgentLLMRequirementsDTO,
        parameterOverrides: GenerationConfiguration,
        fallbackCandidates: [AgentLLMCandidateDraft] = []
    ) {
        self.operationID = operationID
        self.target = target
        self.requirements = requirements
        self.parameterOverrides = parameterOverrides
        self.fallbackCandidates = fallbackCandidates
    }

    var orderedCandidates: [AgentLLMCandidateDraft] {
        [
            AgentLLMCandidateDraft(
                target: target,
                parameterOverrides: parameterOverrides
            ),
        ] + fallbackCandidates
    }
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
    private let selectionRegistry: AppLLMHostSelectionRegistry?
    private var activeConfigurations: [
        String: [(AgentHostConfiguration, LLMTargetRevision)]
    ] = [:]

    init(
        portable: any PortableAgentBuilderClient,
        targets: any AgentLLMTargetCatalog,
        bindingSaga: AgentHostBindingSaga,
        selectionRegistry: AppLLMHostSelectionRegistry? = nil
    ) {
        self.portable = portable
        self.targets = targets
        self.bindingSaga = bindingSaga
        self.selectionRegistry = selectionRegistry
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
        let candidates = llm.orderedCandidates
        guard Set(candidates.map {
            "\($0.target.targetID.rawValue)#\($0.target.revision)"
        }).count == candidates.count else {
            throw AgentBuilderPublishError(
                code: "agent_builder.fallback_target_duplicate",
                message: "each fallback target revision must appear only once"
            )
        }
        var resolvedCandidates: [
            (option: AgentLLMTargetOption, overrides: GenerationConfiguration)
        ] = []
        for candidate in candidates {
            let option = try await exactTarget(candidate.target)
            let overrides = try LLMParameterSystem.resolve(
                targetDefaults: option.target.defaultParameters,
                hostOverrides: candidate.parameterOverrides,
                schema: option.parameterSchema
            )
            resolvedCandidates.append((option, overrides))
        }
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
        let groupID = "providers.\(pending.profileId).\(pending.profileRevisionId)"
        var staged: [(
            operationToken: String,
            configuration: AgentHostConfiguration,
            target: LLMTargetRevision,
            receipt: HostBindingStagingReceipt
        )] = []
        for (index, candidate) in resolvedCandidates.enumerated() {
            let priority = UInt64(index)
            let operationToken = index == 0
                ? operation.token
                : "\(operation.token).fallback.\(priority)"
            let tokenDigest = index == 0
                ? operation.tokenDigest
                : try fallbackTokenDigest(
                    primaryTokenDigest: operation.tokenDigest,
                    priority: priority
                )
            let configuration = AgentHostConfiguration(
                bindingID: index == 0
                    ? "binding.\(pending.profileId).\(pending.profileRevisionId)"
                    : "binding.\(pending.profileId).\(pending.profileRevisionId).fallback.\(priority)",
                revision: 1,
                agentProfileID: pending.profileId,
                agentProfileRevision: pending.profileRevisionId,
                llmSlotID: pending.llmSlotId,
                requirementsHash: pending.requirementsHash,
                llmTargetID: candidate.option.target.targetID,
                llmTargetRevision: candidate.option.target.revision,
                fallbackGroupID: groupID,
                fallbackPriority: priority,
                parameterOverrides: candidate.overrides
            )
            let receipt = try await bindingSaga.stageHostBinding(
                HostBindingStageRequest(
                    operationToken: operationToken,
                    tokenDigest: tokenDigest,
                    llmSlotID: operation.llmSlotId,
                    requirementsHash: operation.requirementsHash,
                    configuration: configuration
                )
            )
            staged.append((
                operationToken,
                configuration,
                candidate.option.target,
                receipt
            ))
        }
        guard let primary = staged.first else {
            throw AgentBuilderPublishError(
                code: "agent_builder.target_missing",
                message: "select at least one immutable LLM target revision"
            )
        }
        let primaryBinding = HostBindingTupleDTO(
            bindingId: primary.receipt.binding.bindingID,
            bindingRevision: primary.receipt.binding.bindingRevision,
            bindingHash: primary.receipt.binding.bindingHash
        )
        let receiptDTO = HostBindingStagingReceiptDTO(
            tokenDigest: primary.receipt.tokenDigest,
            llmSlotId: primary.receipt.llmSlotID,
            requirementsHash: primary.receipt.requirementsHash,
            binding: primaryBinding,
            receiptDigest: primary.receipt.receiptDigest
        )
        let crossLink = try await portable.commitProfilePublish(HostBindingCommitDTO(
            token: operation.token,
            binding: primaryBinding,
            receipt: receiptDTO
        ))
        for candidate in staged {
            try await bindingSaga.activateHostBinding(
                operationToken: candidate.operationToken,
                binding: candidate.receipt.binding
            )
        }
        let active = try await portable.confirmHostBindingActivation(
            HostBindingActivationConfirmationDTO(
                agentProfileId: pending.profileId,
                agentProfileRevision: pending.profileRevisionId,
                llmSlotId: pending.llmSlotId,
                requirementsHash: pending.requirementsHash,
                binding: primaryBinding,
                stagingReceiptDigest: crossLink.stagingReceiptDigest
            )
        )
        guard active.state == "active", active.binding == primaryBinding else {
            throw AgentBuilderPublishError(
                code: "agent_builder.binding_not_active",
                message: "host binding did not reach the exact active state"
            )
        }
        let activeBindings = staged.map {
            ActiveAgentHostBinding(
                configuration: $0.configuration,
                binding: $0.receipt.binding
            )
        }
        if let selectionRegistry {
            let issues = await selectionRegistry.installGroup(
                bindings: activeBindings,
                targets: staged.map(\.target),
                available: resolvedCandidates.map(\.option)
            )
            guard issues.isEmpty else {
                throw AgentBuilderPublishError(
                    code: "agent_builder.fallback_group_not_executable",
                    message: "published fallback group is not executable: \(issues.joined(separator: ", "))"
                )
            }
        }
        activeConfigurations[configurationKey(
            profileID: pending.profileId,
            revision: pending.profileRevisionId
        )] = staged.map { ($0.configuration, $0.target) }
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
        ]?.first else {
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

    private func fallbackTokenDigest(
        primaryTokenDigest: String,
        priority: UInt64
    ) throws -> String {
        try CanonicalDigestV1.digest(
            domain: "saga-token:v1",
            document: .object(entries: [
                .init(
                    name: "primary_token_digest",
                    value: .string(primaryTokenDigest)
                ),
                .init(
                    name: "fallback_priority",
                    value: .string(String(priority))
                ),
            ])
        ).hex
    }
}
