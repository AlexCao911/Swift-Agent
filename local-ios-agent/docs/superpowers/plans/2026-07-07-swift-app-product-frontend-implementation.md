# Swift App Product Frontend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the Builder-first app and native toolkit routes into a coherent daily-use Swift frontend with Chat, Agents, Tools, Models, Settings, runtime cards, context inspection, and trust/permission visibility.

**Architecture:** This is the third product-side plan. It assumes the Builder UI plan has produced a visible Builder with exact revision handoff, and the Native Toolkit plan has registered production native tools through `NativeToolExecutor`. This plan introduces the full app shell and product UX around those capabilities without moving Rust agent logic or C++ inference responsibilities into Swift views.

**Tech Stack:** Swift 6, SwiftUI, Observation, Swift Testing, existing app target `apps/LocalAgentApp/LocalAgentApp.xcodeproj`, `LocalAgentBridge`, `LocalNativeToolkit`, existing Conversation/Execution domain adapters.

## Global Constraints

- Unless a step explicitly says otherwise, run shell commands from `local-ios-agent/`.
- Execute this plan after `2026-07-07-swift-agent-builder-ui-implementation.md` and after Tasks 1-2 of `2026-07-07-swift-native-toolkit-real-adapters-implementation.md` are complete. This plan depends on both the native catalog route and `NativePermissionReadiness`.
- Keep Rust as the agent kernel, C++ as local inference, and Swift as app orchestration/UI.
- Do not silently switch active agent revisions. Every chat run must display and use the selected `profile_id + profile_revision_id`.
- After AppShell exists, `AppShellViewModel.activeAgent` is the source of truth for the active agent. `AgentViewState.selectedAgentProfileId/selectedAgentProfileRevisionId` is a runtime-send mirror that Conversation Workspace refreshes from the shell before starting a run.
- Do not hide tool approval, pending user interaction, model missing, permission missing, or untrusted external content states.
- Use Apple platform patterns: sidebar or split layout on wide screens, compact tabs/navigation stack on iPhone, sheets for focused edits/reviews, lists for catalogs, badges for state, and system pickers for media/files.
- Cards represent real runtime/product objects. Do not use decorative nested cards.
- Context Inspector is read-only and must label preview/trace source, trust level, and external/untrusted content.
- Model Center can show local/cloud readiness and selection state, but local model download implementation is outside this plan unless an existing service is already available.
- Advanced Debug/Trace is visible only behind a developer or advanced-user affordance.

---

## Cross-Document Execution Alignment

| Product path | Plan file | Relationship |
| --- | --- | --- |
| Agent Builder UI | `2026-07-07-swift-agent-builder-ui-implementation.md` | Supplies Builder screens, draft lifecycle, publish review, and exact revision handoff. |
| Native Toolkit Real Adapters | `2026-07-07-swift-native-toolkit-real-adapters-implementation.md` | Supplies executable native tool route, permission readiness, and first real adapters. |
| App Product Frontend | this file | Wraps Builder, Chat, Tools, Models, Settings, and runtime interaction states into one product. |

The target app loop is:

```text
Build agent
  -> choose tools/model
  -> chat with exact revision
  -> approve/complete native tool interactions
  -> inspect context/source/tool use
  -> duplicate revision into Builder when refining
```

## Active Agent State Boundary

The Builder-first plan stores `profile_id + profile_revision_id` directly in `AgentViewState` because the full shell does not exist yet. This is a temporary bridge.

Once this plan introduces `AppShellViewModel`, the source of truth moves to:

```swift
AppShellViewModel.activeAgent: ActiveAgentRevisionSelection?
```

Conversation Workspace must treat `AgentViewState.selectedAgentProfileId` and `selectedAgentProfileRevisionId` as a runtime mirror only:

```text
AppShell.activeAgent
  -> ConversationWorkspace header projection
  -> sync into AgentViewState immediately before send
  -> AgentRuntimeService starts run with the same profile id + revision id
```

Do not let Chat header state and send state diverge. Every test that verifies visible active agent state should also verify the runtime-send state.

## File Structure

App shell:

- Create `apps/LocalAgentApp/LocalAgentApp/App/AppRoute.swift`
  Defines stable top-level routes and route payloads.
- Create `apps/LocalAgentApp/LocalAgentApp/App/AppShellViewModel.swift`
  Owns active route, selected profile revision, selected model summary, and global readiness banners.
- Create `apps/LocalAgentApp/LocalAgentApp/App/AppShellView.swift`
  Wide sidebar / compact tab root.
- Modify `apps/LocalAgentApp/LocalAgentApp/App/LocalAgentApp.swift`
  Uses `AppShellView` as the root after Builder-first host is stable.
- Modify `apps/LocalAgentApp/LocalAgentApp/Composition/AppContainer.swift`
  Supplies shell dependencies.

Conversation workspace:

- Create `apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/ConversationWorkspaceView.swift`
  Product-level wrapper around existing `ChatView`.
- Create `apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/ConversationWorkspaceViewModel.swift`
  Binds chat state to active agent/model/tool readiness.
- Create `apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/RunInlineCards.swift`
  Tool approval, pending interaction, model missing, permission missing, and run status cards.
- Create `apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/ContextInspectorView.swift`
  Read-only context/source/trust inspector.
- Modify `apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/ChatView.swift`
  Adds header badges and entry points without moving runtime logic into the view.

Tool Center:

- Create `apps/LocalAgentApp/LocalAgentApp/Presentation/Tools/ToolCenterViewModel.swift`
  Projects `NativeToolManifest` metadata and permission readiness.
- Create `apps/LocalAgentApp/LocalAgentApp/Presentation/Tools/ToolCenterView.swift`
  Shows catalog, permission state, repair actions, and audit/trust descriptions.

Model Center:

- Create `apps/LocalAgentApp/LocalAgentApp/Presentation/Models/ModelCenterViewModel.swift`
  Projects provider/model readiness and active selection.
- Create `apps/LocalAgentApp/LocalAgentApp/Presentation/Models/ModelCenterView.swift`
  Shows local/cloud model sections and setup actions.

Settings, privacy, debug:

- Create `apps/LocalAgentApp/LocalAgentApp/Presentation/Settings/PrivacySettingsView.swift`
- Create `apps/LocalAgentApp/LocalAgentApp/Presentation/Debug/DebugTraceView.swift`
- Create `apps/LocalAgentApp/LocalAgentApp/Presentation/Shared/StateBadges.swift`
- Create `apps/LocalAgentApp/LocalAgentApp/Presentation/Shared/ProductEmptyStates.swift`

Tests:

- Create `apps/LocalAgentApp/LocalAgentAppTests/App/AppShellViewModelTests.swift`
- Create `apps/LocalAgentApp/LocalAgentAppTests/Presentation/Chat/ConversationWorkspaceViewModelTests.swift`
- Create `apps/LocalAgentApp/LocalAgentAppTests/Presentation/Chat/RunInlineCardsTests.swift`
- Create `apps/LocalAgentApp/LocalAgentAppTests/Presentation/Chat/ContextInspectorViewModelTests.swift`
- Create `apps/LocalAgentApp/LocalAgentAppTests/Presentation/Tools/ToolCenterViewModelTests.swift`
- Create `apps/LocalAgentApp/LocalAgentAppTests/Presentation/Models/ModelCenterViewModelTests.swift`

---

### Task 1: App Route And Shell State

**Files:**
- Create: `apps/LocalAgentApp/LocalAgentApp/App/AppRoute.swift`
- Create: `apps/LocalAgentApp/LocalAgentApp/App/AppShellViewModel.swift`
- Test: `apps/LocalAgentApp/LocalAgentAppTests/App/AppShellViewModelTests.swift`

**Interfaces:**

```swift
enum AppRoute: Equatable, Sendable {
    case chat(sessionId: String?)
    case agents(profileId: String?)
    case builder(profileId: String?, revisionId: UInt64?)
    case tools(focusedToolName: String?)
    case models
    case settings
    case debug(runId: String?)
}

struct ActiveAgentRevisionSelection: Equatable, Sendable {
    var profileId: String
    var profileRevisionId: UInt64
    var displayName: String
}

enum ModelRouteKind: Equatable, Sendable {
    case localCpp(engineId: String)
    case cloud(providerId: String)
    case unset
}

enum ModelReadiness: Equatable, Sendable {
    case ready
    case missingConfiguration(reason: String)
    case unavailable(reason: String)
}

struct ActiveModelSummary: Equatable, Sendable {
    var providerId: String
    var modelId: String
    var displayName: String
    var route: ModelRouteKind
    var readiness: ModelReadiness
}

struct GlobalReadinessBanner: Equatable, Sendable, Identifiable {
    enum Kind: Equatable, Sendable {
        case missingAgent
        case missingModel
        case permission
        case runtime
    }

    var id: String
    var kind: Kind
    var title: String
    var message: String
    var route: AppRoute?
}

@MainActor
@Observable
final class AppShellViewModel {
    var route: AppRoute
    var activeAgent: ActiveAgentRevisionSelection?
    var activeModel: ActiveModelSummary?
    var readinessBanners: [GlobalReadinessBanner]
}
```

- [ ] **Step 1: Write failing shell tests**

Cover:

- default route is `.chat(sessionId: nil)`
- selecting a published Builder revision updates `activeAgent`
- starting chat without active agent produces an agent-missing readiness banner
- opening Builder from Chat preserves the current session route for return
- `activeAgent` is the only stored product selection; feature view models receive it as input and do not own a second source of truth

- [ ] **Step 2: Run focused tests**

Run:

```bash
xcodebuild test -project apps/LocalAgentApp/LocalAgentApp.xcodeproj -scheme LocalAgentApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:LocalAgentAppTests/AppShellViewModelTests
```

Expected: FAIL because shell types do not exist.

- [ ] **Step 3: Implement route and view model**

Keep state small and serializable. The shell owns product selection; feature view models own local editing state.

- [ ] **Step 4: Add persistence hook**

Persist only:

```text
active profile_id
active profile_revision_id
last route family
active model id
```

Do not persist transient run cards, picker states, or preview traces in shell state.

- [ ] **Step 5: Verify**

Run:

```bash
xcodebuild test -project apps/LocalAgentApp/LocalAgentApp.xcodeproj -scheme LocalAgentApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:LocalAgentAppTests/AppShellViewModelTests
```

Expected: PASS.

---

### Task 2: AppShell Root And Navigation

**Files:**
- Create: `apps/LocalAgentApp/LocalAgentApp/App/AppShellView.swift`
- Modify: `apps/LocalAgentApp/LocalAgentApp/App/LocalAgentApp.swift`
- Modify: `apps/LocalAgentApp/LocalAgentApp/Composition/AppContainer.swift`
- Test: `apps/LocalAgentApp/LocalAgentAppTests/App/AppShellViewModelTests.swift`

**Interfaces:**

```swift
struct AppShellView: View {
    @Bindable var viewModel: AppShellViewModel
    let container: AppContainer
}
```

- [ ] **Step 1: Add navigation state tests**

Extend `AppShellViewModelTests`:

- `.tools(focusedToolName:)` preserves focused tool name
- `.debug(runId:)` is only reachable when advanced/debug mode is enabled
- selecting `.builder` does not mutate active agent until publish handoff returns

- [ ] **Step 2: Run tests**

Run:

```bash
xcodebuild test -project apps/LocalAgentApp/LocalAgentApp.xcodeproj -scheme LocalAgentApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:LocalAgentAppTests/AppShellViewModelTests
```

Expected: FAIL until routes and guards exist.

- [ ] **Step 3: Implement shell layout**

Use:

```text
NavigationSplitView on wide layouts
TabView + NavigationStack on compact layouts
```

Primary destinations:

```text
Chat
Agents
Tools
Models
Settings
```

Debug is reached from Settings when advanced mode is on.

- [ ] **Step 4: Replace root**

Change `LocalAgentApp` root from direct `ChatView`/Builder-first host to `AppShellView` only after the Builder-first host plan has passed.

- [ ] **Step 5: Verify manually**

Run in simulator:

```bash
xcodebuild build -project apps/LocalAgentApp/LocalAgentApp.xcodeproj -scheme LocalAgentApp -destination 'platform=iOS Simulator,name=iPhone 16'
```

Expected: build succeeds and root shows Chat with reachable Agents/Tools/Models/Settings destinations.

---

### Task 3: Conversation Workspace Header And Agent Handoff

**Files:**
- Create: `apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/ConversationWorkspaceView.swift`
- Create: `apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/ConversationWorkspaceViewModel.swift`
- Modify: `apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/ChatView.swift`
- Test: `apps/LocalAgentApp/LocalAgentAppTests/Presentation/Chat/ConversationWorkspaceViewModelTests.swift`

**Interfaces:**

```swift
struct ConversationWorkspaceHeaderState: Equatable, Sendable {
    var agentName: String
    var profileId: String
    var profileRevisionId: UInt64?
    var modelName: String
    var toolStatusSummary: String
    var canStartRun: Bool
}

enum ConversationWorkspaceError: Error, Equatable {
    case missingActiveAgent
}

@MainActor
@Observable
final class ConversationWorkspaceViewModel {
    func runtimeStateForSend(
        currentState: AgentViewState,
        activeAgent: ActiveAgentRevisionSelection?
    ) throws -> AgentViewState
}
```

- [ ] **Step 1: Write failing header tests**

Cover:

- active agent revision displays `v<revision>`
- active agent profile id and revision in the header match the runtime state used for send
- missing revision disables send and shows repair action to Agents
- active model missing shows repair action to Models
- disabled native tools show a compact warning instead of blocking normal text-only chat

- [ ] **Step 2: Run tests**

Run:

```bash
xcodebuild test -project apps/LocalAgentApp/LocalAgentApp.xcodeproj -scheme LocalAgentApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:LocalAgentAppTests/ConversationWorkspaceViewModelTests
```

Expected: FAIL until the workspace view model exists.

- [ ] **Step 3: Implement workspace view model**

The workspace view model may read shell selection and runtime state, but it must not publish agent revisions or execute tools directly.

Before calling `AgentRuntimeService.sendMessage`, it must refresh the runtime-send mirror from shell selection:

```swift
func runtimeStateForSend(
    currentState: AgentViewState,
    activeAgent: ActiveAgentRevisionSelection?
) throws -> AgentViewState {
    guard let activeAgent else {
        throw ConversationWorkspaceError.missingActiveAgent
    }
    var state = currentState
    state.selectedAgentProfileId = activeAgent.profileId
    state.selectedAgentProfileRevisionId = activeAgent.profileRevisionId
    return state
}
```

Add a regression test where shell displays `profile_new / revision 7` while the incoming runtime state still contains `profile_old / revision 1`; the send state must become `profile_new / revision 7`.

- [ ] **Step 4: Add Chat header badges**

Use compact badges:

```text
Agent name + revision
Model name
Tool readiness summary
```

Tapping a badge routes to the corresponding shell destination.

- [ ] **Step 5: Verify**

Run:

```bash
xcodebuild test -project apps/LocalAgentApp/LocalAgentApp.xcodeproj -scheme LocalAgentApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:LocalAgentAppTests/ConversationWorkspaceViewModelTests
```

Expected: PASS.

---

### Task 4: Runtime Inline Cards

**Files:**
- Create: `apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/RunInlineCards.swift`
- Test: `apps/LocalAgentApp/LocalAgentAppTests/Presentation/Chat/RunInlineCardsTests.swift`

**Interfaces:**

```swift
enum RunInlineCardState: Equatable, Sendable, Identifiable {
    case toolApproval(ToolApprovalCardState)
    case pendingInteraction(PendingInteractionCardState)
    case permissionRepair(PermissionRepairCardState)
    case modelMissing(ModelMissingCardState)
    case runStatus(RunStatusCardState)
}
```

- [ ] **Step 1: Write card projection tests**

Given runtime events or run projection state, assert:

- `run.suspended` with approval request projects to `toolApproval`
- `pending_user_interaction` projects to `pendingInteraction`
- denied native permission projects to `permissionRepair`
- missing model projects to `modelMissing`
- completed run removes transient cards

- [ ] **Step 2: Run failing tests**

Run:

```bash
xcodebuild test -project apps/LocalAgentApp/LocalAgentApp.xcodeproj -scheme LocalAgentApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:LocalAgentAppTests/RunInlineCardsTests
```

Expected: FAIL until card states/projection exist.

- [ ] **Step 3: Implement card projection**

Projection is pure and testable. UI buttons call existing domain/coordinator methods:

```text
approve tool -> ExecutionDomain.approveTool
deny tool -> ExecutionDomain.approveTool with deny decision
continue picker -> NativeInteractionBroker.resume
cancel picker -> submit structured cancelled tool result
repair permission -> open Settings or permission repair route
```

- [ ] **Step 4: Implement SwiftUI cards**

Use concise cards with:

```text
title
one-line reason
primary action
secondary cancel/deny action
small audit/source label
```

Do not put cards inside cards.

- [ ] **Step 5: Verify**

Run:

```bash
xcodebuild test -project apps/LocalAgentApp/LocalAgentApp.xcodeproj -scheme LocalAgentApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:LocalAgentAppTests/RunInlineCardsTests
```

Expected: PASS.

---

### Task 5: Context Inspector And Source Disclosure

**Files:**
- Create: `apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/ContextInspectorView.swift`
- Test: `apps/LocalAgentApp/LocalAgentAppTests/Presentation/Chat/ContextInspectorViewModelTests.swift`

**Interfaces:**

```swift
struct ContextInspectorSegment: Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    var sourceKind: String
    var trustLevel: NativeToolTrustLevel
    var tokenEstimate: Int?
    var previewText: String
    var warning: String?
}
```

- [ ] **Step 1: Write inspector projection tests**

Cover:

- web tool result becomes `untrusted_external_content`
- calendar/reminder result becomes `trusted_tool_result`
- user message becomes `user_instruction`
- preview-only context trace displays a visible preview label
- warnings are generated for external content and missing source metadata

- [ ] **Step 2: Run failing tests**

Run:

```bash
xcodebuild test -project apps/LocalAgentApp/LocalAgentApp.xcodeproj -scheme LocalAgentApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:LocalAgentAppTests/ContextInspectorViewModelTests
```

Expected: FAIL until inspector types exist.

- [ ] **Step 3: Implement inspector view model**

Use runtime events and tool result envelopes where available. If Rust trace data is unavailable, show an honest partial trace with:

```text
Conversation messages
Tool results
External source warnings
Preview only label
```

- [ ] **Step 4: Add Chat entry point**

Add a toolbar or message-row action:

```text
Inspect Context
Sources
```

The inspector is read-only.

- [ ] **Step 5: Verify**

Run:

```bash
xcodebuild test -project apps/LocalAgentApp/LocalAgentApp.xcodeproj -scheme LocalAgentApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:LocalAgentAppTests/ContextInspectorViewModelTests
```

Expected: PASS.

---

### Task 6: Tool Center

**Files:**
- Create: `apps/LocalAgentApp/LocalAgentApp/Presentation/Tools/ToolCenterViewModel.swift`
- Create: `apps/LocalAgentApp/LocalAgentApp/Presentation/Tools/ToolCenterView.swift`
- Test: `apps/LocalAgentApp/LocalAgentAppTests/Presentation/Tools/ToolCenterViewModelTests.swift`

**Interfaces:**

**Prerequisite:** Native Toolkit Tasks 1-2 must be complete before this task starts. `ToolCenterRowState.readiness` uses `NativePermissionReadiness` from the permission gateway task.

```swift
struct ToolCenterRowState: Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var title: String
    var mode: NativeToolMode
    var riskLevel: RiskLevelDTO
    var permissionScope: String?
    var approvalPolicy: NativeToolApprovalPolicy
    var readiness: NativePermissionReadiness
}
```

- [ ] **Step 1: Write catalog projection tests**

Assert:

- rows are sorted by title/name
- metadata comes from manifest schema JSON
- missing manifest marks row unavailable rather than inventing UI metadata
- denied permissions show repair state
- user-mediated tools show picker-required state

- [ ] **Step 2: Run failing tests**

Run:

```bash
xcodebuild test -project apps/LocalAgentApp/LocalAgentApp.xcodeproj -scheme LocalAgentApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:LocalAgentAppTests/ToolCenterViewModelTests
```

Expected: FAIL until Tool Center state exists.

- [ ] **Step 3: Implement Tool Center view model**

Consume `NativeToolkitClient.registrationSnapshot()` and `NativePermissionGateway`.

- [ ] **Step 4: Implement Tool Center view**

Use:

```text
searchable list
mode segmented filter
risk/approval badges
permission repair action
manifest detail sheet
```

- [ ] **Step 5: Verify**

Run:

```bash
xcodebuild test -project apps/LocalAgentApp/LocalAgentApp.xcodeproj -scheme LocalAgentApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:LocalAgentAppTests/ToolCenterViewModelTests
```

Expected: PASS.

---

### Task 7: Model Center

**Files:**
- Create: `apps/LocalAgentApp/LocalAgentApp/Presentation/Models/ModelCenterViewModel.swift`
- Create: `apps/LocalAgentApp/LocalAgentApp/Presentation/Models/ModelCenterView.swift`
- Test: `apps/LocalAgentApp/LocalAgentAppTests/Presentation/Models/ModelCenterViewModelTests.swift`

**Interfaces:**

Use the shell-level model types from Task 1. Task 7 may add query/load behavior around them, but it must not redefine `ActiveModelSummary`, `ModelReadiness`, or `ModelRouteKind`.

```swift
struct ModelCenterRowState: Equatable, Sendable, Identifiable {
    var id: String
    var displayName: String
    var route: ModelRouteKind
    var readiness: ModelReadiness
    var isActive: Bool
}

@MainActor
@Observable
final class ModelCenterViewModel {
    var activeModel: ActiveModelSummary?
    var rows: [ModelCenterRowState]
}
```

- [ ] **Step 1: Write model readiness tests**

Cover:

- no selected model creates missing-model banner
- local model without downloaded weights is not ready
- cloud model without API key is not ready
- selecting a ready model updates shell active model summary

- [ ] **Step 2: Run failing tests**

Run:

```bash
xcodebuild test -project apps/LocalAgentApp/LocalAgentApp.xcodeproj -scheme LocalAgentApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:LocalAgentAppTests/ModelCenterViewModelTests
```

Expected: FAIL until model center state exists.

- [ ] **Step 3: Implement view model**

Use existing provider/model DTOs first. If local model download service is absent, represent it as:

```text
missingConfiguration(reason: "weights_missing")
```

Do not implement a downloader in this plan.

- [ ] **Step 4: Implement view**

Sections:

```text
Active Model
Local Engines
Cloud Providers
Runtime Defaults
```

Keep API key entry and model downloads as explicit setup actions.

- [ ] **Step 5: Verify**

Run:

```bash
xcodebuild test -project apps/LocalAgentApp/LocalAgentApp.xcodeproj -scheme LocalAgentApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:LocalAgentAppTests/ModelCenterViewModelTests
```

Expected: PASS.

---

### Task 8: Settings, Privacy, Debug, And Polish

**Files:**
- Create: `apps/LocalAgentApp/LocalAgentApp/Presentation/Settings/PrivacySettingsView.swift`
- Create: `apps/LocalAgentApp/LocalAgentApp/Presentation/Debug/DebugTraceView.swift`
- Create: `apps/LocalAgentApp/LocalAgentApp/Presentation/Shared/StateBadges.swift`
- Create: `apps/LocalAgentApp/LocalAgentApp/Presentation/Shared/ProductEmptyStates.swift`
- Modify: `apps/LocalAgentApp/LocalAgentApp/App/AppShellView.swift`

- [ ] **Step 1: Add privacy/settings state**

Settings must show:

```text
tool permission summary
attachment storage summary
memory/retention summary
model/provider summary
export/reset entry points
advanced debug toggle
```

- [ ] **Step 2: Add debug trace view**

Debug view shows:

```text
run id
profile revision id
runtime events
tool calls/results
context trace links
snapshot/debug archive links when available
```

Keep this out of the default tab/sidebar unless advanced mode is enabled.

- [ ] **Step 3: Add shared badges**

Centralize badge visuals:

```text
revision badge
model readiness badge
tool approval badge
trust level badge
permission badge
```

- [ ] **Step 4: Accessibility pass**

Check:

```text
all icon-only buttons have labels/tooltips
Dynamic Type does not overlap compact cards
VoiceOver reads card title before actions
color is not the only signal for risk/trust/readiness
```

- [ ] **Step 5: Verify build**

Run:

```bash
xcodebuild build -project apps/LocalAgentApp/LocalAgentApp.xcodeproj -scheme LocalAgentApp -destination 'platform=iOS Simulator,name=iPhone 16'
```

Expected: PASS.

---

### Task 9: Final Product Smoke And Documentation Handoff

**Files:**
- Modify: `docs/TODO.md`

- [ ] **Step 1: Run app tests**

Run:

```bash
xcodebuild test -project apps/LocalAgentApp/LocalAgentApp.xcodeproj -scheme LocalAgentApp -destination 'platform=iOS Simulator,name=iPhone 16'
```

Expected: PASS if Xcode and simulator are available.

- [ ] **Step 2: Run toolkit tests**

Run:

```bash
swift test --package-path toolkit
```

Expected: PASS.

- [ ] **Step 3: Manual MVP smoke**

Verify:

```text
Open app
Open Builder
Publish profile revision
Return to Chat
Header shows active agent revision
Send message with exact revision
Tool approval card appears for per-call tool
native.list_tools runs through NativeToolExecutor
web.fetch_url_text result shows external/untrusted source disclosure
Tool Center shows manifest-derived rows
Model Center shows active model or setup blocker
Settings shows privacy/tool/model summaries
```

- [ ] **Step 4: Update TODO**

Keep remaining work grouped by:

```text
Agent Builder card-backed publish
Native Toolkit additional adapters
Model download/provider setup
Conversation Workspace polish
Release hardening
```

- [ ] **Step 5: Commit**

```bash
git add apps/LocalAgentApp docs/TODO.md
git commit -m "feat: add product frontend shell"
```

## Self-Review Checklist

- AppShell owns routing and active product selection; Builder owns drafts; Chat owns conversation display.
- Runs use exact `profile_revision_id`; no frontend route resolves latest at run time.
- Tool approval and pending interaction states are visible in Conversation Workspace.
- Context Inspector labels trust level and untrusted external content.
- Tool Center reads manifest metadata instead of duplicating labels/risk/policy.
- Model Center shows readiness honestly and does not fake local model download support.
- Settings exposes privacy/storage/permission summaries without burying them in debug UI.
- Debug/Trace is available but not the default experience.
- The plan remains third in sequence; it does not ask workers to implement toolkit adapters before the toolkit plan.
