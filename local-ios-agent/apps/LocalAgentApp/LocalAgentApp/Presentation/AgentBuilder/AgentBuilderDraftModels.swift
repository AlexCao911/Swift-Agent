import Foundation
import LocalAgentBridge

struct AgentBuilderDraft: Equatable, Sendable, Identifiable {
    var id: String
    var sourceProfileId: String
    var baseRevisionId: UInt64?
    var updatedAt: Date
    var localVersion: UInt64
    var cards: [AgentBuilderCardDraft]

    static func makeDefault(profileId: String, now: Date = Date()) -> AgentBuilderDraft {
        AgentBuilderDraft(
            id: "draft.\(profileId)",
            sourceProfileId: profileId,
            baseRevisionId: nil,
            updatedAt: now,
            localVersion: 0,
            cards: [
                AgentBuilderCardDraft.identity(
                    displayName: "Assistant",
                    description: "A general local assistant."
                ),
                AgentBuilderCardDraft.prompt(
                    systemPrompt: AgentPromptDefaults.systemPrompt,
                    persona: "Helpful, concise, and careful.",
                    responseStyle: "Balanced"
                ),
                AgentBuilderCardDraft.toolBelt(selectedToolIds: []),
                AgentBuilderCardDraft.contextPipeline(),
                AgentBuilderCardDraft.disabled(
                    kind: .memory,
                    reason: "Memory policy editing is coming after the Builder MVP.",
                    futureCapabilityId: "memory.policy"
                ),
                AgentBuilderCardDraft.disabled(
                    kind: .skill,
                    reason: "Skill package editing is coming after the Builder MVP.",
                    futureCapabilityId: "skill.package"
                ),
                AgentBuilderCardDraft.disabled(
                    kind: .model,
                    reason: "Model Center will own model download and provider setup.",
                    futureCapabilityId: "model.center"
                ),
            ]
        )
    }

    var displayName: String {
        cards.compactMap(\.payload.identity?.displayName).first ?? "Assistant"
    }

    var selectedToolIds: [String] {
        cards.compactMap(\.payload.toolBelt?.selectedToolIds).first ?? []
    }

    func publishDTO(templateId: String) -> AgentBuilderDraftDTO {
        let prompt = cards.compactMap(\.payload.prompt).first
        let enabledContextStepIds = cards
            .compactMap(\.payload.contextPipeline?.steps)
            .flatMap { $0 }
            .filter(\.isEnabled)
            .sorted { $0.order < $1.order }
            .map(\.id)

        return AgentBuilderDraftDTO(
            profileId: sourceProfileId,
            templateId: templateId,
            displayName: displayName,
            systemPrompt: prompt?.systemPrompt,
            persona: prompt?.persona,
            responseStyle: prompt?.responseStyle,
            selectedToolIds: selectedToolIds,
            contextStepIds: enabledContextStepIds
        )
    }

    mutating func touch() {
        localVersion += 1
        updatedAt = Date()
    }

    mutating func updatePrompt(systemPrompt: String, persona: String, responseStyle: String) {
        guard let index = cards.firstIndex(where: { $0.kind == .prompt }) else {
            return
        }
        cards[index].payload = .prompt(PromptPayload(
            systemPrompt: systemPrompt,
            persona: persona,
            responseStyle: responseStyle
        ))
        touch()
    }

    mutating func toggleTool(_ toolId: String) {
        guard let index = cards.firstIndex(where: { $0.kind == .toolBelt }),
              var payload = cards[index].payload.toolBelt
        else {
            return
        }

        if payload.selectedToolIds.contains(toolId) {
            payload.selectedToolIds.removeAll { $0 == toolId }
        } else {
            payload.selectedToolIds.append(toolId)
            payload.selectedToolIds.sort()
        }

        cards[index].payload = .toolBelt(payload)
        touch()
    }
}

struct PublishedAgentSelection: Equatable, Sendable, Identifiable {
    var profileId: String
    var profileRevisionId: UInt64
    var displayName: String

    var id: String {
        "\(profileId):\(profileRevisionId)"
    }
}

struct AgentBuilderCardDraft: Equatable, Sendable, Identifiable {
    var id: String
    var kind: AgentBuilderCardKind
    var position: Int
    var isEnabled: Bool
    var payload: AgentBuilderCardPayload
    var validationState: AgentBuilderCardValidationState
    var isPublishAffecting: Bool

    static func identity(displayName: String, description: String) -> AgentBuilderCardDraft {
        AgentBuilderCardDraft(
            id: "card.identity",
            kind: .identity,
            position: 0,
            isEnabled: true,
            payload: .identity(AgentIdentityPayload(
                displayName: displayName,
                description: description,
                iconName: "sparkles",
                accentColorName: "blue"
            )),
            validationState: .valid,
            isPublishAffecting: false
        )
    }

    static func prompt(systemPrompt: String, persona: String, responseStyle: String) -> AgentBuilderCardDraft {
        AgentBuilderCardDraft(
            id: "card.prompt",
            kind: .prompt,
            position: 1,
            isEnabled: true,
            payload: .prompt(PromptPayload(
                systemPrompt: systemPrompt,
                persona: persona,
                responseStyle: responseStyle
            )),
            validationState: .valid,
            isPublishAffecting: false
        )
    }

    static func toolBelt(selectedToolIds: [String]) -> AgentBuilderCardDraft {
        AgentBuilderCardDraft(
            id: "card.tool_belt",
            kind: .toolBelt,
            position: 2,
            isEnabled: true,
            payload: .toolBelt(ToolBeltPayload(selectedToolIds: selectedToolIds.sorted())),
            validationState: .valid,
            isPublishAffecting: false
        )
    }

    static func contextPipeline() -> AgentBuilderCardDraft {
        AgentBuilderCardDraft(
            id: "card.context_pipeline",
            kind: .contextPipeline,
            position: 3,
            isEnabled: true,
            payload: .contextPipeline(ContextPipelinePayload(steps: ContextStepDraft.defaultSteps)),
            validationState: .valid,
            isPublishAffecting: false
        )
    }

    static func disabled(kind: AgentBuilderCardKind, reason: String, futureCapabilityId: String) -> AgentBuilderCardDraft {
        AgentBuilderCardDraft(
            id: "card.\(kind.rawValue)",
            kind: kind,
            position: kind.defaultPosition,
            isEnabled: false,
            payload: .disabled(DisabledCardPayload(
                reason: reason,
                futureCapabilityId: futureCapabilityId
            )),
            validationState: .warning(reason),
            isPublishAffecting: false
        )
    }
}

enum AgentBuilderCardKind: String, CaseIterable, Equatable, Sendable {
    case identity
    case prompt
    case toolBelt = "tool_belt"
    case contextPipeline = "context_pipeline"
    case memory
    case skill
    case model

    var title: String {
        switch self {
        case .identity: "Identity"
        case .prompt: "Prompt"
        case .toolBelt: "Tool Belt"
        case .contextPipeline: "Context Pipeline"
        case .memory: "Memory"
        case .skill: "Skills"
        case .model: "Model"
        }
    }

    var systemImageName: String {
        switch self {
        case .identity: "person.crop.circle"
        case .prompt: "text.quote"
        case .toolBelt: "wrench.and.screwdriver"
        case .contextPipeline: "square.stack.3d.up"
        case .memory: "brain.head.profile"
        case .skill: "shippingbox"
        case .model: "cpu"
        }
    }

    var defaultPosition: Int {
        switch self {
        case .identity: 0
        case .prompt: 1
        case .toolBelt: 2
        case .contextPipeline: 3
        case .memory: 4
        case .skill: 5
        case .model: 6
        }
    }
}

enum AgentBuilderCardPayload: Equatable, Sendable {
    case identity(AgentIdentityPayload)
    case prompt(PromptPayload)
    case toolBelt(ToolBeltPayload)
    case contextPipeline(ContextPipelinePayload)
    case disabled(DisabledCardPayload)

    var identity: AgentIdentityPayload? {
        if case .identity(let value) = self {
            return value
        }
        return nil
    }

    var prompt: PromptPayload? {
        if case .prompt(let value) = self {
            return value
        }
        return nil
    }

    var toolBelt: ToolBeltPayload? {
        if case .toolBelt(let value) = self {
            return value
        }
        return nil
    }

    var contextPipeline: ContextPipelinePayload? {
        if case .contextPipeline(let value) = self {
            return value
        }
        return nil
    }

    var disabled: DisabledCardPayload? {
        if case .disabled(let value) = self {
            return value
        }
        return nil
    }
}

struct AgentIdentityPayload: Equatable, Sendable {
    var displayName: String
    var description: String
    var iconName: String?
    var accentColorName: String?
}

struct PromptPayload: Equatable, Sendable {
    var systemPrompt: String
    var persona: String
    var responseStyle: String
}

struct ToolBeltPayload: Equatable, Sendable {
    var selectedToolIds: [String]
}

struct ContextPipelinePayload: Equatable, Sendable {
    var steps: [ContextStepDraft]
}

struct ContextStepDraft: Equatable, Sendable, Identifiable {
    var id: String
    var kind: ContextStepKind
    var isEnabled: Bool
    var order: Int
    var budgetPolicy: String
    var visibilityInPreview: Bool

    static let defaultSteps: [ContextStepDraft] = [
        ContextStepDraft(id: "system_prompt", kind: .systemPrompt, isEnabled: true, order: 0, budgetPolicy: "required", visibilityInPreview: true),
        ContextStepDraft(id: "conversation_history", kind: .conversationHistory, isEnabled: true, order: 1, budgetPolicy: "budgeted", visibilityInPreview: true),
        ContextStepDraft(id: "tool_results", kind: .toolResults, isEnabled: true, order: 2, budgetPolicy: "budgeted", visibilityInPreview: true),
        ContextStepDraft(id: "memory_summary", kind: .memorySummary, isEnabled: false, order: 3, budgetPolicy: "disabled", visibilityInPreview: true),
        ContextStepDraft(id: "skill_instruction", kind: .skillInstruction, isEnabled: false, order: 4, budgetPolicy: "disabled", visibilityInPreview: true),
    ]
}

enum ContextStepKind: String, Equatable, Sendable {
    case systemPrompt = "system_prompt"
    case conversationHistory = "conversation_history"
    case selectedAttachments = "selected_attachments"
    case toolResults = "tool_results"
    case memorySummary = "memory_summary"
    case skillInstruction = "skill_instruction"

    var title: String {
        switch self {
        case .systemPrompt: "System Prompt"
        case .conversationHistory: "Conversation History"
        case .selectedAttachments: "Selected Attachments"
        case .toolResults: "Tool Results"
        case .memorySummary: "Memory Summary"
        case .skillInstruction: "Skill Instructions"
        }
    }
}

struct DisabledCardPayload: Equatable, Sendable {
    var reason: String
    var futureCapabilityId: String
}

enum AgentBuilderCardValidationState: Equatable, Sendable {
    case valid
    case warning(String)
    case invalid(String)
}

struct BuilderContextPreviewResult: Equatable, Sendable {
    var isPreviewOnly: Bool
    var segments: [BuilderContextPreviewSegment]
    var tokenEstimate: Int
    var warnings: [String]
    var missingInputs: [String]

    static func previewOnly(
        draft: AgentBuilderDraft,
        sampleUserMessage: String
    ) -> BuilderContextPreviewResult {
        let segments = draft.cards
            .compactMap(\.payload.contextPipeline?.steps)
            .flatMap { $0 }
            .filter(\.visibilityInPreview)
            .sorted { $0.order < $1.order }
            .map { step in
                BuilderContextPreviewSegment(
                    id: step.id,
                    title: step.kind.title,
                    sourceLabel: step.kind.rawValue,
                    trustLevel: step.isEnabled ? "trusted_app_policy" : "disabled",
                    isEnabled: step.isEnabled,
                    previewText: previewText(
                        for: step,
                        draft: draft,
                        sampleUserMessage: sampleUserMessage
                    )
                )
            }

        return BuilderContextPreviewResult(
            isPreviewOnly: true,
            segments: segments,
            tokenEstimate: max(64, sampleUserMessage.count / 4 + segments.count * 32),
            warnings: ["Preview only: final model input is assembled by Rust execution."],
            missingInputs: segments.filter { !$0.isEnabled }.map(\.title)
        )
    }

    private static func previewText(
        for step: ContextStepDraft,
        draft: AgentBuilderDraft,
        sampleUserMessage: String
    ) -> String {
        switch step.kind {
        case .systemPrompt:
            return draft.cards.compactMap(\.payload.prompt?.systemPrompt).first ?? ""
        case .conversationHistory:
            return "Current conversation branch plus sample user message: \(sampleUserMessage)"
        case .selectedAttachments:
            return "Selected attachments will appear here when attachment tools are enabled."
        case .toolResults:
            return "Tool observations from this run are appended by execution."
        case .memorySummary:
            return "Disabled in Builder MVP."
        case .skillInstruction:
            return "Disabled in Builder MVP."
        }
    }
}

struct BuilderContextPreviewSegment: Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    var sourceLabel: String
    var trustLevel: String
    var isEnabled: Bool
    var previewText: String
}
