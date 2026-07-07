import Foundation
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

    @Test("editing after validation returns draft to dirty")
    func editingAfterValidationReturnsDraftToDirty() async {
        let viewModel = AgentBuilderViewModel.fixtureReadyToPublish()

        await viewModel.validateCurrentDraft()
        #expect(viewModel.lifecycle == .readyToPublish)

        viewModel.markEdited()
        #expect(viewModel.lifecycle == .dirty)
    }

    @Test("publish pins returned profile revision")
    func publishPinsReturnedProfileRevision() async {
        let viewModel = AgentBuilderViewModel.fixtureReadyToPublish(publishedRevision: 3)

        await viewModel.validateCurrentDraft()
        await viewModel.publishCurrentDraft()

        #expect(viewModel.publishedProfileRevisionId == 3)
        #expect(viewModel.lifecycle == .published(profileRevisionId: 3))
    }

    @Test("stale publish failure does not overwrite later edits")
    func stalePublishFailureDoesNotOverwriteLaterEdits() async {
        let viewModel = AgentBuilderViewModel(
            profileId: "profile_1",
            builderClient: DelayedFailingAgentBuilderClient(),
            permissionClient: MockPermissionClient(issues: []),
            toolCatalogClient: StaticAgentBuilderToolCatalogClient(cards: [])
        )

        await viewModel.validateCurrentDraft()
        let publishTask = Task { await viewModel.publishCurrentDraft() }
        while viewModel.lifecycle != .publishing {
            await Task.yield()
        }

        viewModel.markEdited()
        await publishTask.value

        #expect(viewModel.lifecycle == .dirty)
    }

    @Test("editing during publish immediately returns draft to dirty")
    func editingDuringPublishImmediatelyReturnsDraftToDirty() async {
        let viewModel = AgentBuilderViewModel(
            profileId: "profile_1",
            builderClient: DelayedFailingAgentBuilderClient(),
            permissionClient: MockPermissionClient(issues: []),
            toolCatalogClient: StaticAgentBuilderToolCatalogClient(cards: [])
        )

        await viewModel.validateCurrentDraft()
        let publishTask = Task { await viewModel.publishCurrentDraft() }
        while viewModel.lifecycle != .publishing {
            await Task.yield()
        }

        viewModel.markEdited()

        #expect(viewModel.lifecycle == .dirty)
        await publishTask.value
        #expect(viewModel.lifecycle == .dirty)
    }

    @Test("load creates draft and loads manifest-backed tool cards")
    func loadCreatesDraftAndToolCards() async throws {
        let viewModel = AgentBuilderViewModel(
            profileId: "profile_1",
            builderClient: MockAgentBuilderClient.readyToPublish(),
            permissionClient: MockPermissionClient(issues: []),
            toolCatalogClient: StaticAgentBuilderToolCatalogClient(cards: [
                AgentBuilderToolCard.unavailable(
                    id: "web.fetch_url_text",
                    name: "web.fetch_url_text",
                    reason: "test"
                ),
            ])
        )

        await viewModel.load()

        #expect(viewModel.draft?.sourceProfileId == "profile_1")
        #expect(viewModel.toolCards.map(\.name) == ["web.fetch_url_text"])
        #expect(viewModel.lifecycle == .editing)
    }

    @Test("toggle tool marks draft dirty")
    func toggleToolMarksDraftDirty() async throws {
        let viewModel = AgentBuilderViewModel.fixtureReadyToPublish()

        await viewModel.load()
        viewModel.toggleTool("web.fetch_url_text")

        #expect(viewModel.draft?.selectedToolIds == ["web.fetch_url_text"])
        #expect(viewModel.lifecycle == .dirty)
    }

    @Test("editing prompt updates draft and published profile fields")
    func editingPromptUpdatesDraftAndPublishedProfileFields() async throws {
        let builderClient = RecordingAgentBuilderClient()
        let viewModel = AgentBuilderViewModel(
            profileId: "profile_1",
            builderClient: builderClient,
            permissionClient: MockPermissionClient(issues: []),
            toolCatalogClient: StaticAgentBuilderToolCatalogClient(cards: [])
        )

        await viewModel.load()
        viewModel.updatePrompt(
            systemPrompt: "Use precise citations.",
            persona: "Research partner",
            responseStyle: "Dense"
        )
        await viewModel.validateCurrentDraft()
        await viewModel.publishCurrentDraft()

        let prompt = viewModel.draft?.cards.compactMap(\.payload.prompt).first
        #expect(prompt?.systemPrompt == "Use precise citations.")
        #expect(prompt?.persona == "Research partner")
        #expect(prompt?.responseStyle == "Dense")

        let publishedDraft = await builderClient.publishedDrafts.last
        #expect(publishedDraft?.systemPrompt == "Use precise citations.")
        #expect(publishedDraft?.persona == "Research partner")
        #expect(publishedDraft?.responseStyle == "Dense")
    }

    @Test("editing identity updates draft and published profile name")
    func editingIdentityUpdatesDraftAndPublishedProfileName() async throws {
        let builderClient = RecordingAgentBuilderClient()
        let viewModel = AgentBuilderViewModel(
            profileId: "profile_1",
            builderClient: builderClient,
            permissionClient: MockPermissionClient(issues: []),
            toolCatalogClient: StaticAgentBuilderToolCatalogClient(cards: [])
        )

        await viewModel.load()
        viewModel.updateIdentity(
            displayName: "Research Agent",
            description: "Tracks sources before answering."
        )
        await viewModel.validateCurrentDraft()
        await viewModel.publishCurrentDraft()

        let identity = viewModel.draft?.cards.compactMap(\.payload.identity).first
        #expect(identity?.displayName == "Research Agent")
        #expect(identity?.description == "Tracks sources before answering.")

        let publishedDraft = await builderClient.publishedDrafts.last
        #expect(publishedDraft?.displayName == "Research Agent")
        #expect(viewModel.publishedAgentSelection?.displayName == "Research Agent")
    }

    @Test("toggling context step updates draft and published context ids")
    func togglingContextStepUpdatesDraftAndPublishedContextIds() async throws {
        let builderClient = RecordingAgentBuilderClient()
        let viewModel = AgentBuilderViewModel(
            profileId: "profile_1",
            builderClient: builderClient,
            permissionClient: MockPermissionClient(issues: []),
            toolCatalogClient: StaticAgentBuilderToolCatalogClient(cards: [])
        )

        await viewModel.load()
        viewModel.setContextStep("tool_results", isEnabled: false)
        await viewModel.validateCurrentDraft()
        await viewModel.publishCurrentDraft()

        let steps = viewModel.draft?.cards
            .compactMap(\.payload.contextPipeline?.steps)
            .flatMap { $0 }
        #expect(steps?.first(where: { $0.id == "tool_results" })?.isEnabled == false)

        let publishedDraft = await builderClient.publishedDrafts.last
        #expect(publishedDraft?.contextStepIds == [
            "system_prompt",
            "conversation_history",
        ])
    }

    @Test("required context step remains in published context")
    func requiredContextStepRemainsInPublishedContext() async throws {
        let builderClient = RecordingAgentBuilderClient()
        let viewModel = AgentBuilderViewModel(
            profileId: "profile_1",
            builderClient: builderClient,
            permissionClient: MockPermissionClient(issues: []),
            toolCatalogClient: StaticAgentBuilderToolCatalogClient(cards: [])
        )

        await viewModel.load()
        viewModel.setContextStep("system_prompt", isEnabled: false)
        await viewModel.validateCurrentDraft()
        await viewModel.publishCurrentDraft()

        let steps = viewModel.draft?.cards
            .compactMap(\.payload.contextPipeline?.steps)
            .flatMap { $0 }
        #expect(steps?.first(where: { $0.id == "system_prompt" })?.isEnabled == true)

        let publishedDraft = await builderClient.publishedDrafts.last
        #expect(publishedDraft?.contextStepIds.contains("system_prompt") == true)
    }

    @Test("preview context produces preview-only result")
    func previewContextProducesPreviewOnlyResult() async throws {
        let viewModel = AgentBuilderViewModel.fixtureReadyToPublish()

        await viewModel.load()
        await viewModel.previewContext(sampleUserMessage: "Hello")

        #expect(viewModel.preview?.isPreviewOnly == true)
        #expect(viewModel.preview?.warnings.contains("Preview only: final model input is assembled by Rust execution.") == true)
    }

    @Test("preview context uses Rust-backed builder preview when available")
    func previewContextUsesRustBackedBuilderPreview() async throws {
        let builderClient = RecordingAgentBuilderClient()
        let viewModel = AgentBuilderViewModel(
            profileId: "profile_1",
            builderClient: builderClient,
            permissionClient: MockPermissionClient(issues: []),
            toolCatalogClient: StaticAgentBuilderToolCatalogClient(cards: [])
        )

        await viewModel.load()
        await viewModel.previewContext(sampleUserMessage: "Hello")

        #expect(await builderClient.previewRequests.map(\.sampleUserMessage) == ["Hello"])
        #expect(viewModel.preview?.isPreviewOnly == false)
        #expect(viewModel.preview?.segments.map(\.id) == ["system_prompt"])
        #expect(viewModel.preview?.warnings == ["Rust preview"])
    }

    @Test("publish stores exact profile selection")
    func publishStoresExactProfileSelection() async throws {
        let viewModel = AgentBuilderViewModel.fixtureReadyToPublish(publishedRevision: 9)

        await viewModel.load()
        await viewModel.validateCurrentDraft()
        await viewModel.publishCurrentDraft()

        #expect(viewModel.publishedAgentSelection == PublishedAgentSelection(
            profileId: "profile_1",
            profileRevisionId: 9,
            displayName: "Assistant"
        ))
    }

    @Test("publish sends card-backed draft fields")
    func publishSendsCardBackedDraftFields() async throws {
        let builderClient = RecordingAgentBuilderClient()
        let viewModel = AgentBuilderViewModel(
            profileId: "profile_1",
            builderClient: builderClient,
            permissionClient: MockPermissionClient(issues: []),
            toolCatalogClient: StaticAgentBuilderToolCatalogClient(cards: [])
        )

        await viewModel.load()
        viewModel.toggleTool("web.fetch_url_text")
        await viewModel.validateCurrentDraft()
        await viewModel.publishCurrentDraft()

        let publishedDraft = await builderClient.publishedDrafts.last
        #expect(publishedDraft?.displayName == "Assistant")
        #expect(publishedDraft?.systemPrompt == AgentPromptDefaults.systemPrompt)
        #expect(publishedDraft?.persona == "Helpful, concise, and careful.")
        #expect(publishedDraft?.responseStyle == "Balanced")
        #expect(publishedDraft?.selectedToolIds == ["web.fetch_url_text"])
        #expect(publishedDraft?.contextStepIds == [
            "system_prompt",
            "conversation_history",
            "tool_results",
        ])
    }

    @Test("editing after publish clears stale chat handoff selection")
    func editingAfterPublishClearsStaleSelection() async throws {
        let viewModel = AgentBuilderViewModel.fixtureReadyToPublish(publishedRevision: 9)

        await viewModel.load()
        await viewModel.validateCurrentDraft()
        await viewModel.publishCurrentDraft()
        viewModel.toggleTool("web.fetch_url_text")

        #expect(viewModel.lifecycle == .dirty)
        #expect(viewModel.publishedAgentSelection == nil)
    }
}

private actor RecordingAgentBuilderClient: AgentBuilderClient {
    private(set) var publishedDrafts: [AgentBuilderDraftDTO] = []
    private(set) var previewRequests: [BuilderContextPreviewRequestDTO] = []

    func loadTemplate(_ id: String) async throws -> AgentBuilderUIModel {
        AgentBuilderUIModel(
            profileId: id,
            displayName: "Assistant",
            readiness: PermissionReadinessUIModel()
        )
    }

    func validateDraft(_ draft: AgentBuilderDraftDTO) async throws -> ReadinessUIModel {
        ReadinessUIModel(issues: [])
    }

    func publishProfile(_ draft: AgentBuilderDraftDTO) async throws -> AgentProfileDTO {
        publishedDrafts.append(draft)
        return AgentProfileDTO(
            profileId: draft.profileId,
            profileRevisionId: 11,
            displayName: draft.displayName ?? "Assistant"
        )
    }

    func previewContext(_ request: BuilderContextPreviewRequestDTO) async throws -> BuilderContextPreviewResponseDTO {
        previewRequests.append(request)
        return BuilderContextPreviewResponseDTO(
            isPreviewOnly: false,
            segments: [
                BuilderContextPreviewSegmentDTO(
                    id: "system_prompt",
                    title: "System Prompt",
                    sourceLabel: "prompt",
                    trustLevel: "trusted_app_policy",
                    isEnabled: true,
                    previewText: "system"
                ),
            ],
            tokenEstimate: 4,
            warnings: ["Rust preview"]
        )
    }
}

private actor DelayedFailingAgentBuilderClient: AgentBuilderClient {
    func loadTemplate(_ id: String) async throws -> AgentBuilderUIModel {
        AgentBuilderUIModel(
            profileId: id,
            displayName: "Assistant",
            readiness: PermissionReadinessUIModel()
        )
    }

    func validateDraft(_ draft: AgentBuilderDraftDTO) async throws -> ReadinessUIModel {
        ReadinessUIModel(issues: [])
    }

    func publishProfile(_ draft: AgentBuilderDraftDTO) async throws -> AgentProfileDTO {
        try await Task.sleep(nanoseconds: 50_000_000)
        throw AgentBuilderTestError.publishFailed
    }

    func previewContext(_ request: BuilderContextPreviewRequestDTO) async throws -> BuilderContextPreviewResponseDTO {
        throw AgentBuilderTestError.publishFailed
    }
}

private enum AgentBuilderTestError: Error, LocalizedError {
    case publishFailed

    var errorDescription: String? {
        "Publish failed"
    }
}
