import LocalAgentBridge
import LocalAgentLLMContracts
import LocalAgentLLMCore
import Testing
@testable import LocalAgentApp

@Suite("Host-bound Agent publication")
struct HostBoundAgentPublishTests {
    @Test("publication returns only after exact Swift binding is active in both stores")
    func publishWaitsForExactHostBindingActivation() async throws {
        let target = LLMTargetRevision(
            targetID: LLMTargetID(rawValue: "target.local"),
            revision: 2,
            kind: .local(installationID: "installation.local"),
            modelID: "local-model",
            defaultParameters: GenerationConfiguration()
        )
        let schema = LLMParameterSchema(definitions: [
            .choice(
                .reasoningEffort,
                support: .supported,
                choices: ["low", "high"]
            ),
        ])
        let store = LLMStore.inMemory()
        try await store.publishTarget(target)
        let rust = RecordingPortableAgentBuilderClient()
        let client = HostBoundAgentBuilderClient(
            portable: rust,
            targets: StaticAgentLLMTargetCatalog(options: [
                AgentLLMTargetOption(target: target, parameterSchema: schema),
            ]),
            bindingSaga: AgentHostBindingSaga(store: store)
        )
        let llm = AgentLLMSelectionDraft(
            operationID: "publish.profile-a.1",
            target: target.reference,
            requirements: AgentLLMRequirementsDTO(
                slotId: "slot.model.primary",
                capabilities: ["tool_calling"],
                contextBudget: "16384",
                streamingRequired: true,
                toolCallingMode: "allowed"
            ),
            parameterOverrides: GenerationConfiguration()
                .setting(.reasoningEffort, to: .text("high"))
        )

        let published = try await client.publish(
            draft: AgentBuilderDraftDTO(
                profileId: "profile-a",
                templateId: "template.assistant.default",
                displayName: "Agent A"
            ),
            llm: llm
        )

        #expect(published.profileRevisionId == 1)
        let confirmedValue = await rust.confirmedBinding
        let confirmed = try #require(confirmedValue)
        let activeValue = try await client.activeBinding(
            profileID: "profile-a",
            profileRevision: 1
        )
        let active = try #require(activeValue)
        #expect(confirmed == active)
        let buildRequestCount = await rust.buildRequests.count
        #expect(buildRequestCount == 1)
    }

    @Test("publication persists the complete ordered fallback group")
    func publishPersistsOrderedFallbackGroup() async throws {
        let primary = LLMTargetRevision(
            targetID: LLMTargetID(rawValue: "target.primary"),
            revision: 1,
            kind: .local(installationID: "installation.primary"),
            modelID: "primary-model",
            defaultParameters: GenerationConfiguration()
        )
        let fallback = LLMTargetRevision(
            targetID: LLMTargetID(rawValue: "target.fallback"),
            revision: 1,
            kind: .cloud(
                providerProfileID: "provider.fallback",
                providerProfileRevision: 1
            ),
            modelID: "fallback-model",
            defaultParameters: GenerationConfiguration()
        )
        let schema = LLMParameterSchema(definitions: [])
        let store = LLMStore.inMemory()
        try await store.publishTarget(primary)
        try await store.publishTarget(fallback)
        let selectionRegistry = AppLLMHostSelectionRegistry()
        let client = HostBoundAgentBuilderClient(
            portable: RecordingPortableAgentBuilderClient(),
            targets: StaticAgentLLMTargetCatalog(options: [
                AgentLLMTargetOption(target: primary, parameterSchema: schema),
                AgentLLMTargetOption(target: fallback, parameterSchema: schema),
            ]),
            bindingSaga: AgentHostBindingSaga(store: store),
            selectionRegistry: selectionRegistry
        )
        let selection = AgentLLMSelectionDraft(
            operationID: "publish.profile-a.group",
            target: primary.reference,
            requirements: AgentLLMRequirementsDTO(
                slotId: "slot.model.primary",
                contextBudget: "16384",
                streamingRequired: true,
                toolCallingMode: "allowed"
            ),
            parameterOverrides: GenerationConfiguration(),
            fallbackCandidates: [
                AgentLLMCandidateDraft(
                    target: fallback.reference,
                    parameterOverrides: GenerationConfiguration()
                ),
            ]
        )

        _ = try await client.publish(
            draft: AgentBuilderDraftDTO(
                profileId: "profile-a",
                templateId: "template.assistant.default",
                displayName: "Agent A"
            ),
            llm: selection
        )

        let active = try await store.activeHostBindings().sorted {
            ($0.configuration.fallbackPriority ?? .max)
                < ($1.configuration.fallbackPriority ?? .max)
        }
        #expect(active.map(\.configuration.selectedTarget) == [
            primary.reference,
            fallback.reference,
        ])
        #expect(active.map(\.configuration.fallbackPriority) == [0, 1])
        #expect(Set(active.compactMap(\.configuration.fallbackGroupID)).count == 1)
        let executable = await selectionRegistry.selectionGroup(
            profileID: "profile-a",
            revision: 1
        )
        #expect(executable?.count == 2)
    }
}

private actor RecordingPortableAgentBuilderClient: PortableAgentBuilderClient {
    private(set) var buildRequests: [BuildAgentV2RequestDTO] = []
    private(set) var confirmedBinding: HostBindingTuple?

    func loadTemplate(_ id: String) async throws -> AgentBuilderUIModel {
        AgentBuilderUIModel(
            profileId: id,
            displayName: "Agent",
            readiness: PermissionReadinessUIModel()
        )
    }

    func validateDraft(_ draft: AgentBuilderDraftDTO) async throws -> ReadinessUIModel {
        PermissionReadinessUIModel()
    }

    func buildPendingProfile(
        _ request: BuildAgentV2RequestDTO
    ) async throws -> PendingAgentProfileDTO {
        buildRequests.append(request)
        return PendingAgentProfileDTO(
            profileId: request.draft.profileId,
            profileRevisionId: 1,
            displayName: request.draft.displayName ?? "Agent",
            llmSlotId: request.requirements.slotId,
            requirementsHash: "requirements-hash"
        )
    }

    func previewContext(
        _ request: BuilderContextPreviewRequestDTO
    ) async throws -> BuilderContextPreviewResponseDTO {
        throw PublishTestError.unimplemented
    }

    func prepareProfilePublish(
        _ request: ProfilePublishPreparationDTO
    ) async throws -> HostBindingOperationDTO {
        HostBindingOperationDTO(
            kind: "profile_publish",
            idempotencyKey: request.idempotencyKey,
            token: "operation-token",
            tokenDigest: "operation-token-digest",
            subjectId: request.agentProfileId,
            agentProfileId: request.agentProfileId,
            agentProfileRevision: request.agentProfileRevision,
            llmSlotId: request.llmSlotId,
            requirementsHash: request.requirementsHash,
            state: "prepared"
        )
    }

    func commitProfilePublish(
        _ request: HostBindingCommitDTO
    ) async throws -> HostBindingCrossLinkDTO {
        HostBindingCrossLinkDTO(
            operationToken: request.token,
            tokenDigest: request.receipt.tokenDigest,
            kind: "profile_publish",
            llmSlotId: request.receipt.llmSlotId,
            requirementsHash: request.receipt.requirementsHash,
            binding: request.binding,
            stagingReceiptDigest: request.receipt.receiptDigest,
            state: "host_unbound"
        )
    }

    func prepareProfileRebind(
        _ request: ProfilePublishPreparationDTO
    ) async throws -> HostBindingOperationDTO {
        throw PublishTestError.unimplemented
    }

    func commitProfileRebind(
        _ request: HostBindingCommitDTO
    ) async throws -> HostBindingCrossLinkDTO {
        throw PublishTestError.unimplemented
    }

    func confirmHostBindingActivation(
        _ request: HostBindingActivationConfirmationDTO
    ) async throws -> HostBindingCrossLinkDTO {
        confirmedBinding = HostBindingTuple(
            bindingID: request.binding.bindingId,
            bindingRevision: request.binding.bindingRevision,
            bindingHash: request.binding.bindingHash
        )
        return HostBindingCrossLinkDTO(
            operationToken: "operation-token",
            tokenDigest: "operation-token-digest",
            kind: "profile_publish",
            llmSlotId: request.llmSlotId,
            requirementsHash: request.requirementsHash,
            binding: request.binding,
            stagingReceiptDigest: request.stagingReceiptDigest,
            state: "active"
        )
    }
}

private enum PublishTestError: Error {
    case unimplemented
}
