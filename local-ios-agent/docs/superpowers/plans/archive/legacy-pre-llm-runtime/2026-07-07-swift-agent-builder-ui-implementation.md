# Swift Agent Builder UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Builder-first Swift product slice: users can open Agent Builder, edit a card-shaped draft, preview the draft, publish a Rust-resolvable profile revision, and use that exact revision in Chat.

**Architecture:** This plan implements the first product path from the three aligned specs. It adds a minimal Builder host and handoff instead of a complete AppShell; it uses existing `AgentBuilderClient.publishProfile` for template-backed real publish; it renders tool metadata from `NativeToolManifest` through a small Tool Catalog projection. Native real adapters and the full workspace shell are intentionally separate follow-up plans.

**Tech Stack:** Swift 6, SwiftUI, Observation, Swift Testing, `LocalAgentBridge`, `LocalNativeToolkit`, existing Xcode project `apps/LocalAgentApp/LocalAgentApp.xcodeproj`.

## Global Constraints

- Unless a step explicitly says otherwise, run shell commands from `local-ios-agent/`.
- Builder-first: do not implement the final AppShell before Builder host/handoff works.
- Phase 1 publish must use the existing template-backed Rust-resolvable publish path, not a mock runnable profile.
- Card-backed publish is a later phase; the first UI must visibly distinguish cards that affect publish from disabled or preview-only cards.
- The UI should follow Apple platform principles: clear hierarchy, familiar controls, explicit user actions, progressive disclosure, no custom node-editor interaction in the MVP.
- Cards are not nested inside other cards.
- `AgentBuilderDraft` and card payloads must be typed Swift value models; do not use `[String: Any]` in app UI state.
- `NativeToolManifest` remains the single source for tool card labels, risk, approval policy, fallback, and trust metadata.
- Context Preview V0 must show a visible `Preview only` label and must not claim parity with Rust final context assembly.
- Chat handoff must store and use exact `profile_id + profile_revision_id`; never pass a revision without its matching profile id, and never resolve "latest" for a run.
- Native Toolkit real adapters, Tool Center, Model Center, approval cards, pending interaction cards, and complete AppShell are out of scope for this plan.

---

## Cross-Document Execution Alignment

This plan is the first executable plan after the three specs were aligned:

| Product path | Spec source | This plan's responsibility |
| --- | --- | --- |
| Agent Builder | `2026-07-07-swift-agent-builder-ui-design.md` | Implements Phase 1 plus enough Phase 2/3 UI to make the Builder product loop visible. |
| Native Toolkit | `2026-07-07-swift-native-toolkit-real-adapters-design.md` | Consumes manifest/schema metadata only; does not implement real Apple framework adapters. |
| Full App Frontend | `2026-07-07-swift-app-product-frontend-design.md` | Adds minimal Builder host/handoff; does not replace the root with the final AppShell. |

Follow-up plans should be:

1. `2026-07-07-swift-native-toolkit-real-adapters-implementation.md`
   - Register and execute native catalog.
   - Then EventKit/reminders real background adapters.
2. `2026-07-07-swift-app-product-frontend-implementation.md`
   - Full AppShell.
   - Runtime cards.
   - Tool Center, Model Center, Settings, privacy, debug, onboarding.

## File Structure

Swift app files:

- Create `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/AgentBuilder/AgentBuilderDraftModels.swift`
  Defines typed Builder draft/card/context-preview value models.
- Create `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/AgentBuilder/AgentBuilderToolCatalog.swift`
  Projects `NativeToolSchemaMetadataV1` into Builder tool card view state.
- Modify `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/AgentBuilder/AgentBuilderViewModel.swift`
  Owns draft, selected card, tool catalog, preview, and template-backed publish lifecycle.
- Create `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/AgentBuilder/AgentBuilderView.swift`
  Main Builder screen with overview cards, validation, preview entry, and publish action.
- Create `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/AgentBuilder/AgentBuilderCards.swift`
  Small card components for identity, prompt, tool belt, context pipeline, disabled cards, and badges.
- Create `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/AgentBuilder/AgentBuilderToolPickerView.swift`
  Searchable tool picker sheet backed by manifest-derived cards.
- Create `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/AgentBuilder/AgentBuilderContextPreviewView.swift`
  Preview-only context segment sheet.
- Create `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/AgentBuilder/AgentBuilderPublishReviewView.swift`
  Publish review sheet.
- Create `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/App/BuilderFirstHostView.swift`
  Minimal host that presents Builder from the current Chat-first app and writes selected revision into Chat state.
- Modify `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/ChatView.swift`
  Adds optional Builder action and active revision badge.
- Modify `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Composition/AppContainer.swift`
  Supplies Builder dependencies and tool catalog client.
- Modify `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/App/LocalAgentApp.swift`
  Uses `BuilderFirstHostView` as the root instead of directly constructing `ChatView`.
- Modify `local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj/project.pbxproj`
  Adds new Swift source files to the app target and new tests to the test target.

Tests:

- Create `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Presentation/AgentBuilder/AgentBuilderDraftModelsTests.swift`
- Create `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Presentation/AgentBuilder/AgentBuilderToolCatalogTests.swift`
- Modify `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Presentation/AgentBuilder/AgentBuilderViewModelTests.swift`
- Create `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/App/BuilderFirstHostViewModelTests.swift`

---

### Task 1: Typed Agent Builder Draft Model

**Files:**
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/AgentBuilder/AgentBuilderDraftModels.swift`
- Test: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Presentation/AgentBuilder/AgentBuilderDraftModelsTests.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces:
  - `AgentBuilderDraft`
  - `AgentBuilderCardDraft`
  - `AgentBuilderCardKind`
  - `AgentBuilderCardPayload`
  - `ContextStepDraft`
  - `BuilderContextPreviewResult`
- Consumes: no new runtime services.

- [ ] **Step 1: Write failing draft model tests**

Create `AgentBuilderDraftModelsTests.swift`:

```swift
import Foundation
import Testing
@testable import LocalAgentApp

@Suite("Agent builder draft models")
struct AgentBuilderDraftModelsTests {
    @Test("default draft has the MVP card families in stable order")
    func defaultDraftHasMVPCardFamilies() {
        let draft = AgentBuilderDraft.makeDefault(profileId: "profile_1")

        #expect(draft.sourceProfileId == "profile_1")
        #expect(draft.cards.map(\.kind) == [
            .identity,
            .prompt,
            .toolBelt,
            .contextPipeline,
            .memory,
            .skill,
            .model,
        ])
        #expect(draft.cards.first?.payload.identity?.displayName == "Assistant")
        #expect(draft.cards.first(where: { $0.kind == .identity })?.isPublishAffecting == false)
        #expect(draft.cards.first(where: { $0.kind == .prompt })?.isPublishAffecting == false)
        #expect(draft.cards.first(where: { $0.kind == .toolBelt })?.isPublishAffecting == false)
        #expect(draft.cards.first(where: { $0.kind == .contextPipeline })?.isPublishAffecting == false)
        #expect(draft.cards.first(where: { $0.kind == .memory })?.isPublishAffecting == false)
        #expect(draft.cards.first(where: { $0.kind == .skill })?.isPublishAffecting == false)
    }

    @Test("toggling a tool updates only tool belt payload")
    func togglingToolUpdatesToolBelt() {
        var draft = AgentBuilderDraft.makeDefault(profileId: "profile_1")

        draft.toggleTool("web.fetch_url_text")
        #expect(draft.selectedToolIds == ["web.fetch_url_text"])

        draft.toggleTool("web.fetch_url_text")
        #expect(draft.selectedToolIds == [])
    }

    @Test("context preview identifies unsupported disabled segments")
    func previewMarksDisabledSegments() {
        let draft = AgentBuilderDraft.makeDefault(profileId: "profile_1")
        let preview = BuilderContextPreviewResult.previewOnly(
            draft: draft,
            sampleUserMessage: "Summarize this page"
        )

        #expect(preview.isPreviewOnly)
        #expect(preview.segments.contains(where: { $0.title == "Memory Summary" && !$0.isEnabled }))
        #expect(preview.warnings.contains("Preview only: final model input is assembled by Rust execution."))
    }
}
```

- [ ] **Step 2: Run focused test and verify it fails**

Run:

```bash
xcodebuild test -project apps/LocalAgentApp/LocalAgentApp.xcodeproj -scheme LocalAgentApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:LocalAgentAppTests/AgentBuilderDraftModelsTests
```

Expected: FAIL because `AgentBuilderDraftModelsTests.swift` and the draft model types do not exist.

If this environment only has Command Line Tools and not full Xcode, record the `xcode-select` failure in the task notes and continue with source-level implementation. Do not claim Xcode tests pass unless this command runs.

- [ ] **Step 3: Add draft model types**

Create `AgentBuilderDraftModels.swift`:

```swift
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
                AgentBuilderCardDraft.identity(displayName: "Assistant", description: "A general local assistant."),
                AgentBuilderCardDraft.prompt(systemPrompt: AgentPromptDefaults.systemPrompt, persona: "Helpful, concise, and careful.", responseStyle: "Balanced"),
                AgentBuilderCardDraft.toolBelt(selectedToolIds: []),
                AgentBuilderCardDraft.contextPipeline(),
                AgentBuilderCardDraft.disabled(kind: .memory, reason: "Memory policy editing is coming after the Builder MVP.", futureCapabilityId: "memory.policy"),
                AgentBuilderCardDraft.disabled(kind: .skill, reason: "Skill package editing is coming after the Builder MVP.", futureCapabilityId: "skill.package"),
                AgentBuilderCardDraft.disabled(kind: .model, reason: "Model Center will own model download and provider setup.", futureCapabilityId: "model.center"),
            ]
        )
    }

    var displayName: String {
        cards.compactMap(\.payload.identity?.displayName).first ?? "Assistant"
    }

    var selectedToolIds: [String] {
        cards.compactMap(\.payload.toolBelt?.selectedToolIds).first ?? []
    }

    mutating func touch() {
        localVersion += 1
        updatedAt = Date()
    }

    mutating func updatePrompt(systemPrompt: String, persona: String, responseStyle: String) {
        guard let index = cards.firstIndex(where: { $0.kind == .prompt }) else { return }
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
        else { return }

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
            payload: .identity(AgentIdentityPayload(displayName: displayName, description: description, iconName: "sparkles", accentColorName: "blue")),
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
            payload: .prompt(PromptPayload(systemPrompt: systemPrompt, persona: persona, responseStyle: responseStyle)),
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
            payload: .disabled(DisabledCardPayload(reason: reason, futureCapabilityId: futureCapabilityId)),
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
        if case .identity(let value) = self { return value }
        return nil
    }

    var prompt: PromptPayload? {
        if case .prompt(let value) = self { return value }
        return nil
    }

    var toolBelt: ToolBeltPayload? {
        if case .toolBelt(let value) = self { return value }
        return nil
    }

    var contextPipeline: ContextPipelinePayload? {
        if case .contextPipeline(let value) = self { return value }
        return nil
    }

    var disabled: DisabledCardPayload? {
        if case .disabled(let value) = self { return value }
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

    static func previewOnly(draft: AgentBuilderDraft, sampleUserMessage: String) -> BuilderContextPreviewResult {
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
                    previewText: previewText(for: step, draft: draft, sampleUserMessage: sampleUserMessage)
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
```

- [ ] **Step 4: Add files to the Xcode project**

Modify `LocalAgentApp.xcodeproj/project.pbxproj` so:

- `AgentBuilderDraftModels.swift` is in the app target sources.
- `AgentBuilderDraftModelsTests.swift` is in the test target sources.

Use the existing `AgentBuilderViewModel.swift` and `AgentBuilderViewModelTests.swift` entries as the placement pattern.

- [ ] **Step 5: Run focused test**

Run:

```bash
xcodebuild test -project apps/LocalAgentApp/LocalAgentApp.xcodeproj -scheme LocalAgentApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:LocalAgentAppTests/AgentBuilderDraftModelsTests
```

Expected: PASS in an environment with Xcode installed.

- [ ] **Step 6: Commit**

```bash
git add apps/LocalAgentApp/LocalAgentApp/Presentation/AgentBuilder/AgentBuilderDraftModels.swift \
  apps/LocalAgentApp/LocalAgentAppTests/Presentation/AgentBuilder/AgentBuilderDraftModelsTests.swift \
  apps/LocalAgentApp/LocalAgentApp.xcodeproj/project.pbxproj
git commit -m "feat: add agent builder draft model"
```

---

### Task 2: Manifest-Backed Tool Catalog Projection

**Files:**
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/AgentBuilder/AgentBuilderToolCatalog.swift`
- Test: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Presentation/AgentBuilder/AgentBuilderToolCatalogTests.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes:
  - `LocalNativeToolkit.NativeToolCatalog`
  - `LocalNativeToolkit.NativeToolSchemaExport`
  - `LocalNativeToolkit.NativeToolSchemaMetadataV1`
- Produces:
  - `AgentBuilderToolCard`
  - `AgentBuilderToolCatalogClient`
  - `NativeManifestToolCatalogClient`
  - `StaticAgentBuilderToolCatalogClient`

- [ ] **Step 1: Write failing tool catalog tests**

Create `AgentBuilderToolCatalogTests.swift`:

```swift
import LocalAgentBridge
import LocalNativeToolkit
import Testing
@testable import LocalAgentApp

@Suite("Agent builder tool catalog")
struct AgentBuilderToolCatalogTests {
    @Test("tool catalog decodes manifest metadata for Builder cards")
    func catalogDecodesManifestMetadata() async throws {
        let catalog = try NativeToolCatalog(tools: [
            BuilderToolStub(
                name: "web.fetch_url_text",
                manifest: NativeToolManifest(
                    manifestId: "native.web.fetch_url_text.v1",
                    capabilityId: "web.fetch_url_text",
                    title: "Fetch Web Page",
                    description: "Fetch bounded text from a public HTTPS page.",
                    mode: .background,
                    permissionScope: NativePermissionScope("web.fetch.approved"),
                    requiredPrivacyKeys: [],
                    requiresForegroundUI: false,
                    minimumOS: "iOS 17.0",
                    regionPolicy: "available",
                    fallback: NativeToolFallback(kind: .unavailable, message: "Cannot fetch this URL."),
                    riskLevel: .readOnly,
                    approvalPolicy: .perCall,
                    trustLevel: .untrustedExternalContent,
                    retention: .runOnly,
                    audit: NativeToolAudit(label: "Web Fetch", resultSummaryPolicy: .excerptOnly)
                )
            ),
        ])

        let client = NativeManifestToolCatalogClient(catalogProvider: { catalog })
        let cards = try await client.loadToolCards()

        #expect(cards.map(\.id) == ["web.fetch_url_text"])
        #expect(cards.first?.title == "Fetch Web Page")
        #expect(cards.first?.approvalPolicy == "per_call")
        #expect(cards.first?.trustLevel == "untrusted_external_content")
        #expect(cards.first?.isAvailable == true)
    }

    @Test("tools without stable manifest metadata are unavailable")
    func missingMetadataIsUnavailable() async throws {
        let client = StaticAgentBuilderToolCatalogClient(cards: [
            AgentBuilderToolCard.unavailable(
                id: "legacy.tool",
                name: "legacy.tool",
                reason: "Missing stable NativeToolManifest metadata."
            ),
        ])

        let cards = try await client.loadToolCards()

        #expect(cards.first?.isAvailable == false)
        #expect(cards.first?.statusText == "Missing stable NativeToolManifest metadata.")
    }
}

private struct BuilderToolStub: NativeTool {
    let schema: NativeToolSchema

    init(name: String, manifest: NativeToolManifest) {
        self.schema = NativeToolSchema(
            name: name,
            description: manifest.description,
            inputSchema: .object(),
            riskLevel: manifest.riskLevel,
            permissionScope: manifest.permissionScope,
            availability: .available,
            manifest: manifest
        )
    }

    func execute(argumentsJson: String) async -> ToolResultDTO {
        NativeToolResultBuilder.error(
            manifestId: schema.manifest?.manifestId ?? "stub",
            toolName: schema.name,
            toolCallId: "stub",
            code: "stub",
            displayText: "stub",
            auditSummary: "stub"
        )
    }
}
```

- [ ] **Step 2: Run focused test and verify it fails**

Run:

```bash
xcodebuild test -project apps/LocalAgentApp/LocalAgentApp.xcodeproj -scheme LocalAgentApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:LocalAgentAppTests/AgentBuilderToolCatalogTests
```

Expected: FAIL because the catalog client and card types do not exist.

- [ ] **Step 3: Add tool catalog projection**

Create `AgentBuilderToolCatalog.swift`:

```swift
import Foundation
import LocalAgentBridge
import LocalNativeToolkit

struct AgentBuilderToolCard: Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var title: String
    var description: String
    var riskLevel: String
    var approvalPolicy: String
    var trustLevel: String
    var permissionScope: String?
    var fallbackText: String
    var statusText: String
    var isAvailable: Bool

    static func unavailable(id: String, name: String, reason: String) -> AgentBuilderToolCard {
        AgentBuilderToolCard(
            id: id,
            name: name,
            title: name,
            description: reason,
            riskLevel: "unavailable",
            approvalPolicy: "always_deny_until_configured",
            trustLevel: "trusted_tool_result",
            permissionScope: nil,
            fallbackText: reason,
            statusText: reason,
            isAvailable: false
        )
    }
}

protocol AgentBuilderToolCatalogClient: Sendable {
    func loadToolCards() async throws -> [AgentBuilderToolCard]
}

struct NativeManifestToolCatalogClient: AgentBuilderToolCatalogClient {
    private let catalogProvider: @Sendable () throws -> NativeToolCatalog

    init(catalogProvider: @escaping @Sendable () throws -> NativeToolCatalog) {
        self.catalogProvider = catalogProvider
    }

    func loadToolCards() async throws -> [AgentBuilderToolCard] {
        let catalog = try catalogProvider()
        return NativeToolSchemaExport.exportSchemas(from: catalog)
            .map(Self.card(from:))
            .sorted { $0.name < $1.name }
    }

    private static func card(from schema: ToolSchemaDTO) -> AgentBuilderToolCard {
        guard let metadataJson = schema.metadataJson,
              let data = metadataJson.data(using: .utf8),
              let metadata = try? JSONDecoder().decode(NativeToolSchemaMetadataV1.self, from: data)
        else {
            return AgentBuilderToolCard.unavailable(
                id: schema.name,
                name: schema.name,
                reason: "Missing stable NativeToolManifest metadata."
            )
        }

        let isAvailable = metadata.availability.state == "available"
        return AgentBuilderToolCard(
            id: schema.name,
            name: schema.name,
            title: metadata.audit.label,
            description: schema.description,
            riskLevel: schema.riskLevel.rawValue,
            approvalPolicy: metadata.approvalPolicy.rawValue,
            trustLevel: metadata.contextTrustLevel.rawValue,
            permissionScope: metadata.permissionScope,
            fallbackText: metadata.fallback.message,
            statusText: isAvailable ? "Available" : metadata.availability.state,
            isAvailable: isAvailable
        )
    }
}

struct StaticAgentBuilderToolCatalogClient: AgentBuilderToolCatalogClient {
    var cards: [AgentBuilderToolCard]

    func loadToolCards() async throws -> [AgentBuilderToolCard] {
        cards.sorted { $0.name < $1.name }
    }
}
```

- [ ] **Step 4: Add files to the Xcode project**

Modify `LocalAgentApp.xcodeproj/project.pbxproj` so:

- `AgentBuilderToolCatalog.swift` is in the app target sources.
- `AgentBuilderToolCatalogTests.swift` is in the test target sources.

- [ ] **Step 5: Run focused test**

Run:

```bash
xcodebuild test -project apps/LocalAgentApp/LocalAgentApp.xcodeproj -scheme LocalAgentApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:LocalAgentAppTests/AgentBuilderToolCatalogTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add apps/LocalAgentApp/LocalAgentApp/Presentation/AgentBuilder/AgentBuilderToolCatalog.swift \
  apps/LocalAgentApp/LocalAgentAppTests/Presentation/AgentBuilder/AgentBuilderToolCatalogTests.swift \
  apps/LocalAgentApp/LocalAgentApp.xcodeproj/project.pbxproj
git commit -m "feat: project native tool manifests into builder cards"
```

---

### Task 3: AgentBuilderViewModel Draft, Tool, Preview, And Publish State

**Files:**
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/AgentBuilder/AgentBuilderViewModel.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Presentation/AgentBuilder/AgentBuilderViewModelTests.swift`

**Interfaces:**
- Consumes:
  - `AgentBuilderDraft`
  - `AgentBuilderToolCatalogClient`
  - `BuilderContextPreviewResult`
  - existing `AgentBuilderClient`
  - existing `PermissionClient`
- Produces:
  - `draft`
  - `selectedCardId`
  - `toolCards`
  - `preview`
  - `load()`
  - `toggleTool(_:)`
  - `previewContext(sampleUserMessage:)`

- [ ] **Step 1: Extend tests first**

Append to `AgentBuilderViewModelTests.swift`:

```swift
@Test("load creates draft and loads manifest-backed tool cards")
func loadCreatesDraftAndToolCards() async throws {
    let viewModel = AgentBuilderViewModel(
        profileId: "profile_1",
        builderClient: MockAgentBuilderClient.readyToPublish(),
        permissionClient: MockPermissionClient(issues: []),
        toolCatalogClient: StaticAgentBuilderToolCatalogClient(cards: [
            AgentBuilderToolCard.unavailable(id: "web.fetch_url_text", name: "web.fetch_url_text", reason: "test"),
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

@Test("preview context produces preview-only result")
func previewContextProducesPreviewOnlyResult() async throws {
    let viewModel = AgentBuilderViewModel.fixtureReadyToPublish()

    await viewModel.load()
    viewModel.previewContext(sampleUserMessage: "Hello")

    #expect(viewModel.preview?.isPreviewOnly == true)
    #expect(viewModel.preview?.warnings.contains("Preview only: final model input is assembled by Rust execution.") == true)
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
```

- [ ] **Step 2: Run focused tests and verify failure**

Run:

```bash
xcodebuild test -project apps/LocalAgentApp/LocalAgentApp.xcodeproj -scheme LocalAgentApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:LocalAgentAppTests/AgentBuilderViewModelTests
```

Expected: FAIL because the initializer and methods do not exist yet.

- [ ] **Step 3: Extend `AgentBuilderViewModel`**

Modify `AgentBuilderViewModel.swift`:

```swift
@MainActor
@Observable
final class AgentBuilderViewModel {
    private let profileId: String
    private let templateId: String
    private let builderClient: any AgentBuilderClient
    private let permissionClient: any PermissionClient
    private let toolCatalogClient: any AgentBuilderToolCatalogClient
    private var draftVersion: UInt64 = 0

    var draft: AgentBuilderDraft?
    var selectedCardId: String?
    var toolCards: [AgentBuilderToolCard] = []
    var readiness: PermissionReadinessUIModel
    var preview: BuilderContextPreviewResult?
    var lifecycle: AgentDraftLifecycleState = .empty
    var publishedAgentSelection: PublishedAgentSelection?

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
        self.builderClient = builderClient
        self.permissionClient = permissionClient
        self.toolCatalogClient = toolCatalogClient
        self.readiness = readiness
    }

    func load() async {
        do {
            let model = try await builderClient.loadTemplate(templateId)
            let cards = try await toolCatalogClient.loadToolCards()
            draft = AgentBuilderDraft.makeDefault(profileId: model.profileId)
            selectedCardId = draft?.cards.first?.id
            toolCards = cards
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
        guard var draft else { return }
        draft.toggleTool(toolId)
        self.draft = draft
        markEdited()
    }

    func previewContext(sampleUserMessage: String) {
        guard let draft else { return }
        preview = BuilderContextPreviewResult.previewOnly(
            draft: draft,
            sampleUserMessage: sampleUserMessage
        )
    }

    func refreshReadiness() async {
        do {
            let draftDTO = AgentBuilderDraftDTO(profileId: profileId, templateId: templateId)
            async let draftReadiness = builderClient.validateDraft(draftDTO)
            async let permissionReadiness = permissionClient.readiness([])
            let draftResult = try await draftReadiness
            let permissionResult = try await permissionReadiness
            readiness = PermissionReadinessUIModel(issues: draftResult.issues + permissionResult.issues)
        } catch {
            readiness = PermissionReadinessUIModel(issues: [
                PermissionIssueDTO(code: "readiness.refresh_failed", message: error.localizedDescription),
            ])
        }
    }

    func markEdited() {
        draftVersion += 1
        publishedAgentSelection = nil
        switch lifecycle {
        case .validating, .invalid, .readyToPublish, .editing, .published, .publishFailed, .empty:
            lifecycle = .dirty
        case .dirty, .publishing:
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
            let profile = try await builderClient.publishProfile(
                AgentBuilderDraftDTO(profileId: profileId, templateId: templateId)
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
}
```

Then update the fixture helpers in the same file to pass a static tool catalog:

```swift
static func fixtureReadyToPublish(publishedRevision: UInt64 = 1) -> AgentBuilderViewModel {
    AgentBuilderViewModel(
        profileId: "profile_1",
        builderClient: MockAgentBuilderClient.readyToPublish(publishedRevision: publishedRevision),
        permissionClient: MockPermissionClient(issues: []),
        toolCatalogClient: StaticAgentBuilderToolCatalogClient(cards: [
            AgentBuilderToolCard.unavailable(id: "web.fetch_url_text", name: "web.fetch_url_text", reason: "Preview tool metadata"),
        ])
    )
}
```

- [ ] **Step 4: Run focused tests**

Run:

```bash
xcodebuild test -project apps/LocalAgentApp/LocalAgentApp.xcodeproj -scheme LocalAgentApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:LocalAgentAppTests/AgentBuilderViewModelTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/LocalAgentApp/LocalAgentApp/Presentation/AgentBuilder/AgentBuilderViewModel.swift \
  apps/LocalAgentApp/LocalAgentAppTests/Presentation/AgentBuilder/AgentBuilderViewModelTests.swift
git commit -m "feat: extend agent builder view model for card drafts"
```

---

### Task 4: Builder SwiftUI Screens

**Files:**
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/AgentBuilder/AgentBuilderView.swift`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/AgentBuilder/AgentBuilderCards.swift`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/AgentBuilder/AgentBuilderToolPickerView.swift`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/AgentBuilder/AgentBuilderContextPreviewView.swift`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/AgentBuilder/AgentBuilderPublishReviewView.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes:
  - `AgentBuilderViewModel`
  - `AgentBuilderDraft`
  - `AgentBuilderToolCard`
  - `BuilderContextPreviewResult`
- Produces:
  - `AgentBuilderView`
  - small value-input card views
  - tool picker sheet
  - context preview sheet
  - publish review sheet

- [ ] **Step 1: Add the view files with Apple-native layout**

Create `AgentBuilderView.swift`:

```swift
import SwiftUI

struct AgentBuilderView: View {
    @Bindable var viewModel: AgentBuilderViewModel
    var onUseInChat: (PublishedAgentSelection) -> Void

    @State private var isToolPickerPresented = false
    @State private var isPreviewPresented = false
    @State private var isPublishReviewPresented = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    if let draft = viewModel.draft {
                        ForEach(draft.cards.sorted { $0.position < $1.position }) { card in
                            AgentBuilderCardView(
                                card: card,
                                selectedToolCount: draft.selectedToolIds.count,
                                onSelect: { viewModel.selectCard(card.id) },
                                onConfigureTools: { isToolPickerPresented = true },
                                onPreviewContext: {
                                    viewModel.previewContext(sampleUserMessage: "What should this agent know before answering?")
                                    isPreviewPresented = true
                                }
                            )
                        }
                    } else {
                        ContentUnavailableView(
                            "No Agent Draft",
                            systemImage: "square.stack.3d.up",
                            description: Text("Load a template to start composing an agent.")
                        )
                    }
                }
                .padding()
            }
            .navigationTitle("Agent Builder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Review") {
                        isPublishReviewPresented = true
                    }
                    .disabled(viewModel.draft == nil || viewModel.lifecycle == .publishing)
                }
            }
            .safeAreaInset(edge: .bottom) {
                AgentBuilderBottomBar(
                    lifecycle: viewModel.lifecycle,
                    publishedSelection: viewModel.publishedAgentSelection,
                    onValidate: { Task { await viewModel.validateCurrentDraft() } },
                    onPublish: { Task { await viewModel.publishCurrentDraft() } },
                    onUseInChat: onUseInChat
                )
                .background(.thinMaterial)
            }
        }
        .task {
            if viewModel.draft == nil {
                await viewModel.load()
            }
        }
        .sheet(isPresented: $isToolPickerPresented) {
            AgentBuilderToolPickerView(
                tools: viewModel.toolCards,
                selectedToolIds: viewModel.draft?.selectedToolIds ?? [],
                onToggle: { toolId in viewModel.toggleTool(toolId) }
            )
        }
        .sheet(isPresented: $isPreviewPresented) {
            AgentBuilderContextPreviewView(preview: viewModel.preview)
        }
        .sheet(isPresented: $isPublishReviewPresented) {
            AgentBuilderPublishReviewView(
                lifecycle: viewModel.lifecycle,
                readiness: viewModel.readiness,
                draft: viewModel.draft,
                publishedSelection: viewModel.publishedAgentSelection,
                onValidate: { Task { await viewModel.validateCurrentDraft() } },
                onPublish: { Task { await viewModel.publishCurrentDraft() } }
            )
        }
    }
}
```

Create the support views with these constraints:

- `AgentBuilderCards.swift` owns only visual card rows and badges.
- `AgentBuilderToolPickerView.swift` uses `List`, `Searchable`, and checkmarks; no custom grid needed.
- `AgentBuilderContextPreviewView.swift` shows `Preview only`, token estimate, warnings, then segment rows.
- `AgentBuilderPublishReviewView.swift` shows readiness issues, explicit Publish action, and separates `Included in this publish` from `Preview only / not included in this template-backed publish`.

- [ ] **Step 2: Add the core card code**

Create `AgentBuilderCards.swift`:

```swift
import SwiftUI

struct AgentBuilderCardView: View {
    var card: AgentBuilderCardDraft
    var selectedToolCount: Int
    var onSelect: () -> Void
    var onConfigureTools: () -> Void
    var onPreviewContext: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: card.kind.systemImageName)
                        .frame(width: 28, height: 28)
                        .foregroundStyle(card.isEnabled ? .blue : .secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(card.kind.title)
                            .font(.headline)
                        Text(summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer()

                    if card.isPublishAffecting {
                        Label("Included", systemImage: "checkmark.seal")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else if card.isEnabled {
                        Label("Preview only", systemImage: "eye")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Label("Later", systemImage: "lock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if card.kind == .toolBelt {
                    Button {
                        onConfigureTools()
                    } label: {
                        Label("Choose Tools", systemImage: "wrench.and.screwdriver")
                    }
                    .buttonStyle(.bordered)
                }

                if card.kind == .contextPipeline {
                    Button {
                        onPreviewContext()
                    } label: {
                        Label("Preview Context", systemImage: "eye")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.quaternary)
            }
        }
        .buttonStyle(.plain)
        .disabled(!card.isEnabled && card.payload.disabled != nil)
    }

    private var summary: String {
        switch card.payload {
        case .identity(let payload):
            return payload.description
        case .prompt(let payload):
            return payload.persona
        case .toolBelt:
            return selectedToolCount == 0 ? "No tools selected" : "\(selectedToolCount) tools selected"
        case .contextPipeline(let payload):
            return "\(payload.steps.filter(\.isEnabled).count) enabled context steps"
        case .disabled(let payload):
            return payload.reason
        }
    }
}

struct AgentBuilderBottomBar: View {
    var lifecycle: AgentDraftLifecycleState
    var publishedSelection: PublishedAgentSelection?
    var onValidate: () -> Void
    var onPublish: () -> Void
    var onUseInChat: (PublishedAgentSelection) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Button("Validate", action: onValidate)
                .disabled(lifecycle == .validating || lifecycle == .publishing)

            Button("Publish", action: onPublish)
                .buttonStyle(.borderedProminent)
                .disabled(lifecycle != .readyToPublish)

            if let publishedSelection {
                Button("Use in Chat") {
                    onUseInChat(publishedSelection)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var statusText: String {
        switch lifecycle {
        case .empty: "No draft loaded"
        case .editing: "Editing"
        case .dirty: "Draft changed"
        case .validating: "Validating..."
        case .invalid: "Needs attention"
        case .readyToPublish: "Ready to publish"
        case .publishing: "Publishing..."
        case .published(let revision): "Published revision \(revision)"
        case .publishFailed(let message): message
        }
    }
}
```

- [ ] **Step 3: Add sheets**

Create the sheet files with value inputs only:

```swift
import SwiftUI

struct AgentBuilderToolPickerView: View {
    var tools: [AgentBuilderToolCard]
    var selectedToolIds: [String]
    var onToggle: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List(filteredTools) { tool in
                Button {
                    if tool.isAvailable { onToggle(tool.id) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tool.title)
                                .font(.headline)
                            Text(tool.description)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Text("\(tool.riskLevel) · \(tool.approvalPolicy)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selectedToolIds.contains(tool.id) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.blue)
                        }
                    }
                }
                .disabled(!tool.isAvailable)
            }
            .searchable(text: $query, prompt: "Search tools")
            .navigationTitle("Choose Tools")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var filteredTools: [AgentBuilderToolCard] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return tools
        }
        return tools.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.name.localizedCaseInsensitiveContains(query)
        }
    }
}
```

The context preview and publish review views should use the same `NavigationStack + List + toolbar Done` sheet pattern. Keep these views under 150 lines each.

The publish review must make template-backed limitations visible:

```swift
struct AgentBuilderPublishReviewView: View {
    var lifecycle: AgentDraftLifecycleState
    var readiness: PermissionReadinessUIModel
    var draft: AgentBuilderDraft?
    var publishedSelection: PublishedAgentSelection?
    var onValidate: () -> Void
    var onPublish: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Included in this publish") {
                    Text("Template profile")
                    Text("Exact profile revision id after publish")
                }

                Section("Preview only / not included in this template-backed publish") {
                    ForEach(draft?.cards.filter { !$0.isPublishAffecting && $0.isEnabled } ?? []) { card in
                        Label(card.kind.title, systemImage: "eye")
                    }
                }

                Section("Readiness") {
                    ForEach(readiness.issues, id: \.code) { issue in
                        Text(issue.message)
                    }
                }
            }
            .navigationTitle("Publish Review")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Publish", action: onPublish)
                        .disabled(lifecycle != .readyToPublish)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Validate", action: onValidate)
                }
            }
        }
    }
}
```

- [ ] **Step 4: Add files to Xcode project**

Add all Builder view files to the app target in `project.pbxproj`.

- [ ] **Step 5: Build**

Run:

```bash
xcodebuild build -project apps/LocalAgentApp/LocalAgentApp.xcodeproj -scheme LocalAgentApp -destination 'platform=iOS Simulator,name=iPhone 16'
```

Expected: PASS in an environment with Xcode installed.

- [ ] **Step 6: Commit**

```bash
git add apps/LocalAgentApp/LocalAgentApp/Presentation/AgentBuilder/AgentBuilderView.swift \
  apps/LocalAgentApp/LocalAgentApp/Presentation/AgentBuilder/AgentBuilderCards.swift \
  apps/LocalAgentApp/LocalAgentApp/Presentation/AgentBuilder/AgentBuilderToolPickerView.swift \
  apps/LocalAgentApp/LocalAgentApp/Presentation/AgentBuilder/AgentBuilderContextPreviewView.swift \
  apps/LocalAgentApp/LocalAgentApp/Presentation/AgentBuilder/AgentBuilderPublishReviewView.swift \
  apps/LocalAgentApp/LocalAgentApp.xcodeproj/project.pbxproj
git commit -m "feat: add builder card UI"
```

---

### Task 5: Builder-First Host And Chat Handoff

**Files:**
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/App/BuilderFirstHostView.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/App/LocalAgentApp.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/ChatView.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Composition/AppContainer.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/State/AgentViewState.swift`
- Test: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/App/BuilderFirstHostViewModelTests.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes:
  - `AppContainer.makeAgentViewModel()`
  - `AppContainer.makeAgentBuilderViewModel(...)`
  - `AgentViewModel.state.selectedAgentProfileId`
  - `AgentViewModel.state.selectedAgentProfileRevisionId`
- Produces:
  - `PublishedAgentSelection(profileId, profileRevisionId, displayName)` handoff DTO
  - `BuilderFirstHostView`
  - Chat toolbar Builder entry
  - active profile/revision badge

- [ ] **Step 1: Write handoff state test**

Create `BuilderFirstHostViewModelTests.swift` for the state helper used by the host:

```swift
import Testing
@testable import LocalAgentApp

@Suite("Builder first host selection")
@MainActor
struct BuilderFirstHostViewModelTests {
    @Test("using published selection updates chat profile and revision")
    func usingPublishedSelectionUpdatesChatProfileAndRevision() {
        let viewModel = AgentViewModel(
            service: FailingAgentRuntimeService(),
            initialState: AgentViewState(
                selectedAgentProfileId: "profile_old",
                selectedAgentProfileRevisionId: 1
            )
        )
        let selection = PublishedAgentSelection(
            profileId: "profile_new",
            profileRevisionId: 7,
            displayName: "Research Agent"
        )

        BuilderFirstHostSelection.apply(selection, to: viewModel)

        #expect(viewModel.state.selectedAgentProfileId == "profile_new")
        #expect(viewModel.state.selectedAgentProfileRevisionId == 7)
    }
}

private struct FailingAgentRuntimeService: AgentRuntimeServicing {
    func prepare() async throws -> AgentViewState { AgentViewState() }
    func sendMessage(_ text: String, state: AgentViewState, onEvent: @escaping @Sendable (RuntimeEventDTO) async -> Void) async throws -> AgentViewState { state }
    func cancel(state: AgentViewState) async throws -> AgentViewState { state }
    func selectProvider(_ providerId: String, state: AgentViewState) async throws -> AgentViewState { state }
    func newChat(state: AgentViewState) async throws -> AgentViewState { state }
    func loadConversations(state: AgentViewState) async throws -> AgentViewState { state }
    func selectConversation(sessionId: String, state: AgentViewState) async throws -> AgentViewState { state }
    func renameConversation(_ sessionId: String, title: String, state: AgentViewState) async throws -> AgentViewState { state }
    func archiveConversation(_ sessionId: String, state: AgentViewState) async throws -> AgentViewState { state }
    func deleteConversation(_ sessionId: String, state: AgentViewState) async throws -> AgentViewState { state }
    func editAndResend(messageId: String, text: String, state: AgentViewState, onEvent: @escaping @Sendable (RuntimeEventDTO) async -> Void) async throws -> AgentViewState { state }
    func registerToolSchemas() async throws {}
}
```

If the real `AgentRuntimeServicing` signature differs, adapt the fake to the actual protocol before writing implementation.

- [ ] **Step 2: Run focused test and verify failure**

Run:

```bash
xcodebuild test -project apps/LocalAgentApp/LocalAgentApp.xcodeproj -scheme LocalAgentApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:LocalAgentAppTests/BuilderFirstHostViewModelTests
```

Expected: FAIL because `BuilderFirstHostSelection` and stored `selectedAgentProfileId` do not exist.

- [ ] **Step 3: Store exact profile selection in `AgentViewState`**

Modify `AgentViewState.swift` so profile id and revision id are both stored state:

```swift
struct AgentViewState: Equatable, Sendable {
    var phase: AppRuntimePhase
    var messages: [AgentMessageViewState]
    var draft: UserDraftViewState
    var currentSessionId: String?
    var errorMessage: String?
    var provider: ProviderSelectionViewState
    var conversations: ConversationListViewState
    var lastTerminalReason: RunTerminalReason?
    var lastAppliedRuntimeSequence: UInt64
    var lastAppliedExecutionSequenceByRunId: [String: UInt64]
    var promptLibrary: PromptLibraryViewState
    var modelSettings: ModelSettingsViewState
    var selectedAgentProfileId: String
    var selectedAgentProfileRevisionId: UInt64?

    init(
        phase: AppRuntimePhase = .booting,
        messages: [AgentMessageViewState] = [],
        draft: UserDraftViewState = UserDraftViewState(),
        currentSessionId: String? = nil,
        errorMessage: String? = nil,
        provider: ProviderSelectionViewState = ProviderSelectionViewState(),
        conversations: ConversationListViewState = ConversationListViewState(),
        lastTerminalReason: RunTerminalReason? = nil,
        lastAppliedRuntimeSequence: UInt64 = 0,
        lastAppliedExecutionSequenceByRunId: [String: UInt64] = [:],
        promptLibrary: PromptLibraryViewState = PromptLibraryViewState(),
        modelSettings: ModelSettingsViewState = ModelSettingsViewState(),
        selectedAgentProfileId: String = "profile_1",
        selectedAgentProfileRevisionId: UInt64? = 1
    ) {
        self.phase = phase
        self.messages = messages
        self.draft = draft
        self.currentSessionId = currentSessionId
        self.errorMessage = errorMessage
        self.provider = provider
        self.conversations = conversations
        self.lastTerminalReason = lastTerminalReason
        self.lastAppliedRuntimeSequence = lastAppliedRuntimeSequence
        self.lastAppliedExecutionSequenceByRunId = lastAppliedExecutionSequenceByRunId
        self.promptLibrary = promptLibrary
        self.modelSettings = modelSettings
        self.selectedAgentProfileId = selectedAgentProfileId
        self.selectedAgentProfileRevisionId = selectedAgentProfileRevisionId
    }
}
```

Remove the computed `var selectedAgentProfileId: String { "profile_1" }`. A computed default would reintroduce the bug this task is closing.

- [ ] **Step 4: Add host view and selection helper**

Create `BuilderFirstHostView.swift`:

```swift
import SwiftUI

enum BuilderFirstHostSelection {
    @MainActor
    static func apply(_ selection: PublishedAgentSelection, to viewModel: AgentViewModel) {
        viewModel.state.selectedAgentProfileId = selection.profileId
        viewModel.state.selectedAgentProfileRevisionId = selection.profileRevisionId
    }
}

struct BuilderFirstHostView: View {
    private let container: AppContainer

    @State private var chatViewModel: AgentViewModel
    @State private var builderViewModel: AgentBuilderViewModel
    @State private var isBuilderPresented = false

    @MainActor
    init(container: AppContainer) {
        self.container = container
        _chatViewModel = State(initialValue: container.makeAgentViewModel())
        _builderViewModel = State(initialValue: container.makeAgentBuilderViewModel())
    }

    var body: some View {
        ChatView(
            viewModel: chatViewModel,
            onOpenBuilder: {
                isBuilderPresented = true
            }
        )
        .sheet(isPresented: $isBuilderPresented) {
            AgentBuilderView(
                viewModel: builderViewModel,
                onUseInChat: { selection in
                    BuilderFirstHostSelection.apply(selection, to: chatViewModel)
                    isBuilderPresented = false
                }
            )
        }
    }
}
```

- [ ] **Step 5: Update ChatView initializer and toolbar**

Modify `ChatView.swift`:

```swift
struct ChatView: View {
    @Bindable var viewModel: AgentViewModel
    var onOpenBuilder: (() -> Void)?

    init(viewModel: AgentViewModel, onOpenBuilder: (() -> Void)? = nil) {
        self.viewModel = viewModel
        self.onOpenBuilder = onOpenBuilder
    }
```

Add a Builder action to the principal menu:

```swift
if let onOpenBuilder {
    Button(action: onOpenBuilder) {
        Label("Agent Builder", systemImage: "square.stack.3d.up")
    }
}
```

Add a compact active revision badge near the title:

```swift
if let revision = viewModel.state.selectedAgentProfileRevisionId {
    Text("\(viewModel.state.selectedAgentProfileId) r\(revision)")
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.quaternary, in: Capsule())
        .accessibilityLabel("Active agent \(viewModel.state.selectedAgentProfileId), revision \(revision)")
}
```

- [ ] **Step 6: Update app root**

Modify `LocalAgentApp.swift`:

```swift
var body: some Scene {
    WindowGroup {
        BuilderFirstHostView(container: container)
    }
}
```

- [ ] **Step 7: Add files to Xcode project**

Add `BuilderFirstHostView.swift` and `BuilderFirstHostViewModelTests.swift` to the app and test targets.

- [ ] **Step 8: Run focused test and build**

Run:

```bash
xcodebuild test -project apps/LocalAgentApp/LocalAgentApp.xcodeproj -scheme LocalAgentApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:LocalAgentAppTests/BuilderFirstHostViewModelTests
xcodebuild build -project apps/LocalAgentApp/LocalAgentApp.xcodeproj -scheme LocalAgentApp -destination 'platform=iOS Simulator,name=iPhone 16'
```

Expected: PASS in an environment with Xcode installed.

- [ ] **Step 9: Commit**

```bash
git add apps/LocalAgentApp/LocalAgentApp/App/BuilderFirstHostView.swift \
  apps/LocalAgentApp/LocalAgentApp/App/LocalAgentApp.swift \
  apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/ChatView.swift \
  apps/LocalAgentApp/LocalAgentApp/State/AgentViewState.swift \
  apps/LocalAgentApp/LocalAgentAppTests/App/BuilderFirstHostViewModelTests.swift \
  apps/LocalAgentApp/LocalAgentApp.xcodeproj/project.pbxproj
git commit -m "feat: add builder first chat handoff"
```

---

### Task 6: Container Wiring And Preview Tool Cards

**Files:**
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Composition/AppContainer.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Composition/AppBootstrapper.swift`
- Test: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Integration/RustRuntimeAppIntegrationTests.swift`

**Interfaces:**
- Consumes:
  - `NativeManifestToolCatalogClient`
  - `NativeToolCatalog`
  - existing `RustAgentBuilderClient`
- Produces:
  - `AppContainer.agentBuilderToolCatalogClient`
  - Builder VM created with real manifest-derived cards when possible.

- [ ] **Step 1: Add integration test expectation**

Extend `RustRuntimeAppIntegrationTests.swift`:

```swift
@Test("container builder view model loads tool cards")
func containerBuilderViewModelLoadsToolCards() async throws {
    let container = try AppBootstrapper.makeContainer(environment: [
        "LOCAL_AGENT_ENABLE_CONVERSATION_EXECUTION_COORDINATOR": "1",
    ])
    let viewModel = await container.makeAgentBuilderViewModel()

    await viewModel.load()

    #expect(viewModel.draft != nil)
    #expect(viewModel.toolCards.isEmpty == false)
}
```

- [ ] **Step 2: Run focused integration test and verify failure**

Run:

```bash
xcodebuild test -project apps/LocalAgentApp/LocalAgentApp.xcodeproj -scheme LocalAgentApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:LocalAgentAppTests/RustRuntimeAppIntegrationTests/containerBuilderViewModelLoadsToolCards
```

Expected: FAIL because `AppContainer` does not yet inject a tool catalog client.

- [ ] **Step 3: Extend AppContainer**

Modify `AppContainer.swift`:

```swift
import LocalAgentBridge
import LocalNativeToolkit

struct AppContainer {
    let runtimeService: AgentRuntimeService
    let agentBuilderClient: any AgentBuilderClient
    let permissionClient: any PermissionClient
    let agentBuilderToolCatalogClient: any AgentBuilderToolCatalogClient

    @MainActor
    func makeAgentViewModel() -> AgentViewModel {
        AgentViewModel(service: runtimeService)
    }

    @MainActor
    func makeAgentBuilderViewModel(
        profileId: String = "profile_1",
        templateId: String = "template_1"
    ) -> AgentBuilderViewModel {
        AgentBuilderViewModel(
            profileId: profileId,
            templateId: templateId,
            builderClient: agentBuilderClient,
            permissionClient: permissionClient,
            toolCatalogClient: agentBuilderToolCatalogClient
        )
    }
}
```

- [ ] **Step 4: Wire a small preview catalog**

Modify `AppBootstrapper.makeContainer(...)` to construct a catalog client. Use native meta/web tools first; do not block on EventKit adapters:

```swift
let permissionStore = PermissionStore()
let nativeCatalog = try NativeToolCatalog(tools: [
    NativePermissionStatusTool(permissionStore: permissionStore),
    WebFetchURLTextTool(),
])
let builderToolCatalogClient = NativeManifestToolCatalogClient(catalogProvider: {
    nativeCatalog
})
```

Pass `builderToolCatalogClient` into `AppContainer`.

For the bootstrap failure fallback, pass:

```swift
agentBuilderToolCatalogClient: StaticAgentBuilderToolCatalogClient(cards: [])
```

- [ ] **Step 5: Run focused integration test**

Run:

```bash
xcodebuild test -project apps/LocalAgentApp/LocalAgentApp.xcodeproj -scheme LocalAgentApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:LocalAgentAppTests/RustRuntimeAppIntegrationTests/containerBuilderViewModelLoadsToolCards
```

Expected: PASS in an environment with Xcode installed.

- [ ] **Step 6: Commit**

```bash
git add apps/LocalAgentApp/LocalAgentApp/Composition/AppContainer.swift \
  apps/LocalAgentApp/LocalAgentApp/Composition/AppBootstrapper.swift \
  apps/LocalAgentApp/LocalAgentAppTests/Integration/RustRuntimeAppIntegrationTests.swift
git commit -m "feat: wire builder tool catalog"
```

---

### Task 7: Final Verification And Documentation Alignment

**Files:**
- Modify if needed: `local-ios-agent/docs/superpowers/specs/2026-07-07-swift-agent-builder-ui-design.md`
- Modify if needed: `local-ios-agent/docs/superpowers/specs/2026-07-07-swift-native-toolkit-real-adapters-design.md`
- Modify if needed: `local-ios-agent/docs/superpowers/specs/2026-07-07-swift-app-product-frontend-design.md`

**Interfaces:**
- Consumes: all previous tasks.
- Produces: verified Builder-first slice and notes for next implementation plan.

- [ ] **Step 1: Run available app verification**

Run:

```bash
xcodebuild test -project apps/LocalAgentApp/LocalAgentApp.xcodeproj -scheme LocalAgentApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:LocalAgentAppTests/AgentBuilderViewModelTests
xcodebuild test -project apps/LocalAgentApp/LocalAgentApp.xcodeproj -scheme LocalAgentApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:LocalAgentAppTests/AgentBuilderDraftModelsTests
xcodebuild test -project apps/LocalAgentApp/LocalAgentApp.xcodeproj -scheme LocalAgentApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:LocalAgentAppTests/AgentBuilderToolCatalogTests
xcodebuild build -project apps/LocalAgentApp/LocalAgentApp.xcodeproj -scheme LocalAgentApp -destination 'platform=iOS Simulator,name=iPhone 16'
```

Expected: PASS in an environment with Xcode installed. If Xcode is unavailable, report the exact `xcode-select` or simulator error and do not claim app tests passed.

- [ ] **Step 2: Run toolkit verification**

Run:

```bash
swift test --package-path toolkit
```

Expected: PASS. This confirms the LocalNativeToolkit and LocalAgentBridge package still builds after app imports and catalog usage are introduced.

- [ ] **Step 3: Confirm Builder-first scope**

Run:

```bash
rg -n "Phase 1: Builder-First Host And Handoff|Phase 1: Register And Execute Native Catalog|Phase 4: Card-Backed Publish" docs/superpowers/specs
```

Expected: finds the aligned headings in the three specs.

- [ ] **Step 4: Write next-plan note**

Append a short note to this plan's implementation PR or final response:

```text
Next implementation plan: Swift Native Toolkit Real Adapters.
Start with Register And Execute Native Catalog, then EventKit calendar search and reminders.create_reminder.
Do not start full AppShell before Builder handoff and first native catalog route are verified.
```

- [ ] **Step 5: Final commit**

```bash
git status --short
git add apps/LocalAgentApp docs/superpowers
git commit -m "feat: complete builder first product slice"
```

## Self-Review Checklist

- Spec coverage:
  - Builder-first host/handoff: Task 5.
  - Template-backed real publish: Task 3 and Task 5.
  - Typed card draft models: Task 1.
  - Tool Belt manifest metadata: Task 2 and Task 6.
  - Context Preview V0: Task 1 and Task 4.
  - Apple-native UI shape: Task 4.
- Out-of-scope items:
  - Real EventKit/reminders adapters are not in this plan.
  - Full AppShell is not in this plan.
  - Tool approval/pending interaction runtime cards are not in this plan.
  - Model Center is not in this plan.
- Verification:
  - Xcode app build/tests are required during execution, but this environment may need full Xcode selected.
  - Swift package tests should continue to pass through `swift test --package-path toolkit`.
