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
