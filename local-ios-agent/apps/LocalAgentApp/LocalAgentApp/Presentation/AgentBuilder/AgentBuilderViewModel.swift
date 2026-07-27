import LocalAgentBridge
import LocalAgentLLMContracts
import LocalAgentLLMCore
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
    private let builderClient: any AgentBuilderPublishing
    private let requiresHostTarget: Bool
    private let permissionClient: any PermissionClient
    private let toolCatalogClient: any AgentBuilderToolCatalogClient
    private var draftVersion: UInt64 = 0

    var draft: AgentBuilderDraft?
    var selectedCardId: String?
    var toolCards: [AgentBuilderToolCard] = []
    var llmTargets: [AgentLLMTargetOption] = []
    var llmSelection: AgentLLMSelectionDraft?
    var readiness: PermissionReadinessUIModel
    var preview: BuilderContextPreviewResult?
    var lifecycle: AgentDraftLifecycleState = .empty
    var publishedAgentSelection: PublishedAgentSelection?
    var publishedProfileRevisionId: UInt64? {
        publishedAgentSelection?.profileRevisionId
    }

    init(
        profileId: String,
        templateId: String = "template_1",
        builderClient: any AgentBuilderClient,
        permissionClient: any PermissionClient,
        toolCatalogClient: any AgentBuilderToolCatalogClient = StaticAgentBuilderToolCatalogClient(cards: []),
        readiness: PermissionReadinessUIModel = PermissionReadinessUIModel()
    ) {
        self.profileId = profileId
        self.templateId = templateId
        self.builderClient = LegacyAgentBuilderPublishingAdapter(client: builderClient)
        self.requiresHostTarget = false
        self.permissionClient = permissionClient
        self.toolCatalogClient = toolCatalogClient
        self.readiness = readiness
    }

    init(
        profileId: String,
        templateId: String = "template_1",
        publisher: any AgentBuilderPublishing,
        permissionClient: any PermissionClient,
        toolCatalogClient: any AgentBuilderToolCatalogClient = StaticAgentBuilderToolCatalogClient(cards: []),
        readiness: PermissionReadinessUIModel = PermissionReadinessUIModel()
    ) {
        self.profileId = profileId
        self.templateId = templateId
        self.builderClient = publisher
        self.requiresHostTarget = true
        self.permissionClient = permissionClient
        self.toolCatalogClient = toolCatalogClient
        self.readiness = readiness
    }

    func load() async {
        do {
            _ = try await builderClient.loadTemplate(templateId)
            let targets = try await builderClient.availableTargets()
            let cards = try await toolCatalogClient.loadToolCards()
            draft = AgentBuilderDraft.makeDefault(profileId: profileId)
            selectedCardId = draft?.cards.first?.id
            toolCards = cards
            llmTargets = targets
            if let target = targets.first {
                llmSelection = selection(for: target.target.reference)
            } else if !requiresHostTarget {
                llmSelection = legacyFallbackSelection()
            }
            lifecycle = .editing
        } catch {
            readiness = PermissionReadinessUIModel(issues: [
                PermissionIssueDTO(code: "builder.load_failed", message: error.localizedDescription),
            ])
            lifecycle = .invalid
        }
    }

    func selectCard(_ cardId: String) {
        selectedCardId = cardId
    }

    func toggleTool(_ toolId: String) {
        guard var draft else {
            return
        }
        draft.toggleTool(toolId)
        self.draft = draft
        markEdited()
    }

    func updateIdentity(displayName: String, description: String) {
        guard var draft else {
            return
        }
        draft.updateIdentity(
            displayName: displayName,
            description: description
        )
        self.draft = draft
        markEdited()
    }

    func updatePrompt(systemPrompt: String, persona: String, responseStyle: String) {
        guard var draft else {
            return
        }
        draft.updatePrompt(
            systemPrompt: systemPrompt,
            persona: persona,
            responseStyle: responseStyle
        )
        self.draft = draft
        markEdited()
    }

    func setContextStep(_ stepId: String, isEnabled: Bool) {
        guard var draft else {
            return
        }
        guard draft.setContextStep(stepId, isEnabled: isEnabled) else {
            return
        }
        self.draft = draft
        markEdited()
    }

    func selectTarget(_ reference: LLMTargetReference) {
        guard llmTargets.contains(where: { $0.target.reference == reference }) else {
            return
        }
        llmSelection = selection(for: reference)
        markEdited()
    }

    func setParameter(_ id: LLMParameterID, _ value: LLMParameterValue) {
        guard let selection = llmSelection else { return }
        llmSelection = AgentLLMSelectionDraft(
            operationID: selection.operationID,
            target: selection.target,
            requirements: selection.requirements,
            parameterOverrides: selection.parameterOverrides.setting(id, to: value)
        )
        markEdited()
    }

    func previewContext(sampleUserMessage: String) async {
        guard let draft else {
            return
        }

        let fallback = BuilderContextPreviewResult.previewOnly(
            draft: draft,
            sampleUserMessage: sampleUserMessage
        )

        do {
            let response = try await builderClient.previewContext(BuilderContextPreviewRequestDTO(
                draft: draft.publishDTO(templateId: templateId),
                sampleUserMessage: sampleUserMessage
            ))
            preview = BuilderContextPreviewResult(dto: response)
        } catch {
            preview = fallback
        }
    }

    func refreshReadiness() async {
        do {
            let draft = draftDTO()
            async let draftReadiness = builderClient.validateDraft(draft)
            async let permissionReadiness = permissionClient.readiness([])
            let draftResult = try await draftReadiness
            let permissionResult = try await permissionReadiness
            var issues = draftResult.issues + permissionResult.issues
            if requiresHostTarget, llmSelection == nil {
                issues.append(PermissionIssueDTO(
                    code: "llm_target.required",
                    message: "Select an LLM target before publishing."
                ))
            }
            readiness = PermissionReadinessUIModel(issues: issues)
        } catch {
            readiness = PermissionReadinessUIModel(issues: [
                PermissionIssueDTO(code: "readiness.refresh_failed", message: error.localizedDescription),
            ])
        }
    }

    func markEdited() {
        draftVersion += 1
        if let selection = llmSelection {
            llmSelection = AgentLLMSelectionDraft(
                operationID: "\(requiresHostTarget ? "agent-builder" : "legacy").\(profileId).\(draftVersion)",
                target: selection.target,
                requirements: selection.requirements,
                parameterOverrides: selection.parameterOverrides
            )
        }
        publishedAgentSelection = nil
        switch lifecycle {
        case .validating, .invalid, .readyToPublish, .editing, .published, .publishFailed, .empty, .publishing:
            lifecycle = .dirty
        case .dirty:
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
            guard let llmSelection else {
                lifecycle = .publishFailed("Select an LLM target before publishing.")
                return
            }
            let profile = try await builderClient.publish(
                draft: draftDTO(),
                llm: llmSelection
            )
            guard version == draftVersion else {
                lifecycle = .dirty
                return
            }
            publishedAgentSelection = PublishedAgentSelection(
                profileId: profile.profileId,
                profileRevisionId: profile.profileRevisionId,
                displayName: profile.displayName
            )
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
            ]),
            toolCatalogClient: StaticAgentBuilderToolCatalogClient(cards: [])
        )
    }

    static func fixtureReadyToPublish(publishedRevision: UInt64 = 1) -> AgentBuilderViewModel {
        AgentBuilderViewModel(
            profileId: "profile_1",
            builderClient: MockAgentBuilderClient.readyToPublish(publishedRevision: publishedRevision),
            permissionClient: MockPermissionClient(issues: []),
            toolCatalogClient: StaticAgentBuilderToolCatalogClient(cards: [
                AgentBuilderToolCard.unavailable(
                    id: "web.fetch_url_text",
                    name: "web.fetch_url_text",
                    reason: "Preview tool metadata"
                ),
            ])
        )
    }

    private func draftDTO() -> AgentBuilderDraftDTO {
        draft?.publishDTO(templateId: templateId)
            ?? AgentBuilderDraftDTO(profileId: profileId, templateId: templateId)
    }

    private func selection(for reference: LLMTargetReference) -> AgentLLMSelectionDraft {
        AgentLLMSelectionDraft(
            operationID: "agent-builder.\(profileId).\(draftVersion)",
            target: reference,
            requirements: AgentLLMRequirementsDTO(
                slotId: "slot.model.primary",
                capabilities: draft?.selectedToolIds.isEmpty == false ? ["tool_calling"] : [],
                inputModalities: ["text"],
                contextBudget: "4096",
                streamingRequired: true,
                toolCallingMode: draft?.selectedToolIds.isEmpty == false ? "allowed" : "disabled"
            ),
            parameterOverrides: GenerationConfiguration()
        )
    }

    private func legacyFallbackSelection() -> AgentLLMSelectionDraft {
        AgentLLMSelectionDraft(
            operationID: "legacy.\(profileId).\(draftVersion)",
            target: LLMTargetReference(
                targetID: LLMTargetID(rawValue: "legacy"),
                revision: 1
            ),
            requirements: AgentLLMRequirementsDTO(
                slotId: "slot.model.primary",
                contextBudget: "4096",
                streamingRequired: true,
                toolCallingMode: "disabled"
            ),
            parameterOverrides: GenerationConfiguration()
        )
    }
}
