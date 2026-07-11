# Post-MVP Remaining Work Execution Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the remaining work in `local-ios-agent/docs/TODO.md` into a sequenced, reviewable path from the current MVP closure to a fuller local agent product.

**Architecture:** Treat the current MVP branch as the base product slice: Builder, Toolkit, Chat, AppShell, Context Inspector, Tool Center, Model Center, and Settings exist. Future work proceeds in narrow vertical slices with explicit stop gates: Builder composition, pending interaction/pickers, additional native adapters, model/provider setup, conversation polish, release hardening, and Rust follow-ups.

**Tech Stack:** SwiftUI, Swift Observation, SwiftPM `LocalAgentToolkit`, Rust core FFI/Agent OS bridge, C++ local inference backend, Xcode project `LocalAgentApp.xcodeproj`, XCTest/Swift Testing, iOS system frameworks as introduced by each slice.

## Global Constraints

- Base branch must include commit `bfe28a60 feat: close chat inline card actions` or an equivalent merge containing the MVP closure.
- Do not start a later task until the previous task has fresh verification evidence and a short self-review.
- Every implementation slice must use TDD for public behavior, then run a full relevant verification pass.
- Xcode verification must use `/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild`; do not use `DEVELOPER_DIR=... xcodebuild`.
- Do not commit `.derivedData/`, `.xcresult`, or other local build artifacts.
- Keep native tool manifests as the single source of truth for Builder cards, Tool Center rows, Rust schema export, and runtime approval metadata.
- Keep conversation/execution boundary intact: conversation prepares `ConversationRunFrameRef`; execution consumes `profile_id + profile_revision_id + conversation_run_frame_ref`.
- Swift owns iOS permissions, picker UI, attachment access, model downloads, provider API key entry, and product navigation.
- Rust owns agent profile revision resolution, run snapshots, execution policy, context assembly, tool routing contracts, and durable conversation facts.
- C++ owns only local inference engine abstraction and local model inference calls.
- When a finding is outside the active task, record it under the correct future section instead of implementing it opportunistically.

---

## Execution Order

```text
0. Base Hygiene And Merge Readiness
1. Builder Card-Backed Profile Composition Foundation
2. Pending Interaction And Picker Closure
3. Native Toolkit Additional Adapters
4. Model Download And Provider Setup
5. Conversation Workspace Polish
6. Release Hardening For The Current Swift Product Scope
7. Rust And Swift Component Follow-Up Contracts
```

This order is intentional:

- Builder composition first, because tools, context, memory, skills, and model setup need a clear place to be selected.
- Pending interaction second, because file/photo picker tools are already visible and need a real continuation path.
- Additional native adapters third, because adding more tools before picker recovery is stable would create more half-operable cards.
- Model Center fourth, because local/cloud readiness is already visible but not yet production-complete.
- Conversation polish fifth, because it should integrate real Builder, Toolkit, and Model behavior rather than guessing.
- Release hardening verifies the current Swift product scope. If a release scope includes advanced memory/skills/context trace, execute Task 7 before Task 6.
- Rust and Swift component follow-ups are pulled forward only when Builder or Context Inspector needs skills, memory, cross-platform tool capabilities, or expanded context trace.

## Coverage Matrix

| Remaining area | Covered by | Notes |
| --- | --- | --- |
| Expand card-backed publish beyond MVP prompt/persona/tool/context-step slice | Task 1, Task 7 | Task 1 completes the supported profile foundation; Task 7 adds memory/skill/full trace contracts. |
| Full context policy, memory policy, selected tools, skills | Task 1, Task 7 | Selected tools and context step ids are Task 1; memory and skills are Task 7. |
| Full source-map trace with memory, skills, attachments, runtime policy | Task 7 | Requires Rust trace expansion plus Swift DTO/UI consumption. |
| Unsupported card and publish-blocking validation copy | Task 1 | Copy must be explicit and honest about what is included in publish. |
| Real file/photo picker presentation and resume/cancel | Task 2 | Must use pending interaction broker and durable state. |
| Share, Vision, OCR, Speech, Maps, Shortcut metadata | Task 3 | Each adapter is a separate commit with fake adapter tests. |
| Harden web fetch beyond host-literal checks | Task 3 | Must precede adding more external-content tools. |
| Local model download and cloud provider setup | Task 4 | Swift-owned app/product concern; C++ remains local inference only. |
| Conversation repair routes, session/fork/edit, trust warnings, selector/drift | Task 5 | No silent revision migration. |
| Onboarding, privacy, export/reset, manual smoke, accessibility | Task 6 | Execute after the product scope it verifies is actually present. |
| Skill packages, memory bridge, cross-platform tool abstraction | Task 7 | Keep Rust contracts minimal; platform implementation remains Swift-owned. |

---

### Task 0: Base Hygiene And Merge Readiness

**Files:**
- Inspect: `local-ios-agent/docs/TODO.md`
- Inspect: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj/project.pbxproj`
- Inspect: `local-ios-agent/toolkit/Package.swift`
- Ignore: `.derivedData/`

**Interfaces:**
- Consumes: current MVP branch with AppShell, Builder, Toolkit, Chat inline cards, Context Inspector, Tool Center, Model Center, and Settings.
- Produces: a clean base for future feature branches; no product behavior changes.

- [ ] **Step 1: Confirm branch contains the MVP closure**

Run:

```bash
git log --oneline --decorate -5
```

Expected:

```text
bfe28a60 feat: close chat inline card actions
```

or a later merge commit that includes it.

- [ ] **Step 2: Confirm no source changes are pending**

Run:

```bash
git status --short
```

Expected:

```text
?? .derivedData/
```

or no output. If `.derivedData/` appears, leave it untracked. If source files appear, inspect them before proceeding.

- [ ] **Step 3: Run the full App verification**

Run:

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath /Users/alexandercou/Projects/Alex-agent/.worktrees/swift-product-mvp/.derivedData/LocalAgentApp
```

Expected:

```text
** TEST SUCCEEDED **
```

- [ ] **Step 4: Run toolkit verification**

Run:

```bash
swift test --package-path local-ios-agent/toolkit
swift build --package-path local-ios-agent/toolkit
```

Expected:

```text
Test run with 101 tests passed
Build complete!
```

The exact test count may increase later, but failures block the next task.

- [ ] **Step 5: Run static checks**

Run:

```bash
git diff --check
plutil -lint local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj/project.pbxproj
```

Expected:

```text
local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj/project.pbxproj: OK
```

- [ ] **Step 6: Commit only if this task made documentation or hygiene changes**

If no files changed, do not commit.

If a documentation-only clarification was made:

```bash
git add local-ios-agent/docs/TODO.md local-ios-agent/docs/superpowers/plans/2026-07-08-post-mvp-remaining-work-execution.md
git commit -m "docs: sequence post-mvp remaining work"
```

---

### Task 1: Builder Card-Backed Profile Composition Foundation

**Files:**
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/AgentBuilder/AgentBuilderDraftModels.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/AgentBuilder/AgentBuilderViewModel.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/AgentBuilder/AgentBuilderCards.swift`
- Modify: `local-ios-agent/toolkit/Sources/LocalAgentBridge/AgentOSDTOs.swift`
- Modify: `local-ios-agent/rust-core/src/user_customization/agent_profile.rs`
- Modify: `local-ios-agent/rust-core/src/run_snapshot/resolver.rs`
- Modify: `local-ios-agent/rust-core/src/ffi_bridge.rs`
- Test: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Runtime/RustRuntimeAppIntegrationTests.swift`
- Test: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Presentation/AgentBuilder/AgentBuilderViewModelTests.swift`
- Test: `local-ios-agent/rust-core/tests/contract/run_snapshot_resolution_agent_os.rs`

**Interfaces:**
- Consumes: `AgentBuilderDraftDTO(profileId:templateId:displayName:systemPrompt:persona:responseStyle:selectedToolIds:contextStepIds:)`.
- Produces: a Rust-resolvable `AgentProfileDTO(profileId:displayName:profileRevisionId:)` whose revision stores selected prompt/persona/style, tool ids, context step ids, and explicit unsupported-card warnings.

- [ ] **Step 1: Write failing Swift publish contract tests**

Add tests to `AgentBuilderViewModelTests.swift`:

```swift
@Test("publish includes full builder card-backed fields")
@MainActor
func publishIncludesFullBuilderFields() async throws {
    let client = RecordingAgentBuilderClient()
    let viewModel = AgentBuilderViewModel(
        profileId: "profile_custom",
        builderClient: client,
        permissionClient: MockPermissionClient(issues: []),
        toolCatalogClient: StaticAgentBuilderToolCatalogClient(cards: [
            AgentBuilderToolCard(
                id: "web.fetch_url_text",
                name: "web.fetch_url_text",
                displayName: "Fetch Web Page",
                description: "Fetch public web page text.",
                riskLevel: "medium",
                approvalPolicy: "per_call",
                availability: "available"
            )
        ])
    )

    await viewModel.load()
    viewModel.updateIdentity(displayName: "Researcher", description: "Checks sources.")
    viewModel.updatePrompt(
        systemPrompt: "Use sourced reasoning.",
        persona: "Careful researcher",
        responseStyle: "Brief"
    )
    viewModel.toggleTool("web.fetch_url_text")
    viewModel.setContextStep("memory_summary", isEnabled: true)
    await viewModel.validateCurrentDraft()
    await viewModel.publishCurrentDraft()

    let request = try #require(client.lastPublishedDraft)
    #expect(request.profileId == "profile_custom")
    #expect(request.displayName == "Researcher")
    #expect(request.systemPrompt == "Use sourced reasoning.")
    #expect(request.persona == "Careful researcher")
    #expect(request.responseStyle == "Brief")
    #expect(request.selectedToolIds == ["web.fetch_url_text"])
    #expect(request.contextStepIds.contains("memory_summary"))
}
```

Expected failure before implementation: missing fields are not persisted into Rust-resolved profile or the test helper lacks recorded draft values.

- [ ] **Step 2: Write failing Rust snapshot resolution tests**

Add a test to `run_snapshot_resolution_agent_os.rs`:

```rust
#[test]
fn published_card_backed_profile_revision_resolves_prompt_tools_and_context_steps() {
    let service = seeded_app_service();
    let profile = service
        .build_agent(BuildAgentRequest {
            template_id: "template_1".to_string(),
            profile_id: Some("profile_custom".to_string()),
            display_name: Some("Researcher".to_string()),
            system_prompt: Some("Use sourced reasoning.".to_string()),
            persona: Some("Careful researcher".to_string()),
            response_style: Some("Brief".to_string()),
            selected_tool_ids: vec!["web.fetch_url_text".to_string()],
            context_step_ids: vec![
                "system_prompt".to_string(),
                "conversation_history".to_string(),
                "tool_results".to_string(),
                "memory_summary".to_string(),
            ],
        })
        .expect("profile builds");

    let snapshot = service
        .resolve_run_snapshot(StartRunRequest::new(
            profile.profile_id.clone(),
            profile.profile_revision_id,
            "Summarize this URL".to_string(),
        ))
        .expect("snapshot resolves");

    assert_eq!(snapshot.agent_profile().display_name(), "Researcher");
    assert!(snapshot.agent_profile().tool_ids().contains(&"web.fetch_url_text".to_string()));
    assert!(snapshot.context_policy().enabled_step_ids().contains(&"memory_summary".to_string()));
}
```

Expected failure before implementation: `BuildAgentRequest` or `AgentProfile` does not expose all fields.

- [ ] **Step 3: Extend DTOs without changing conversation/execution boundary**

Modify `AgentOSDTOs.swift` and Rust request JSON structs so `BuildAgentRequestDTO` includes:

```swift
public var profileId: String?
public var displayName: String?
public var systemPrompt: String?
public var persona: String?
public var responseStyle: String?
public var selectedToolIds: [String]
public var contextStepIds: [String]
```

Encoding keys must be:

```text
profile_id
display_name
system_prompt
persona
response_style
selected_tool_ids
context_step_ids
```

Do not add these fields to `prepareUserTurn`; they belong only to Builder publish and execution snapshot resolution.

- [ ] **Step 4: Persist selected Builder values into Rust profile revision**

Update `agent_profile.rs` so a published revision stores:

```rust
pub struct AgentProfileRevisionContent {
    pub display_name: String,
    pub system_prompt: String,
    pub persona: Option<String>,
    pub response_style: Option<String>,
    pub selected_tool_ids: Vec<String>,
    pub context_step_ids: Vec<String>,
    pub unsupported_card_warnings: Vec<String>,
}
```

Validation rules:

```text
display_name: non-empty after trimming
system_prompt: non-empty after trimming
selected_tool_ids: every id must exist in the current registered tool schema set
context_step_ids: unknown ids are rejected
required context step ids cannot be removed
unsupported_card_warnings: persisted as warnings, not run blockers
```

- [ ] **Step 5: Resolve published revision into run snapshot**

Update `run_snapshot/resolver.rs` so `ResolvedRunSnapshot` uses the exact revision content:

```text
profile_id + profile_revision_id
  -> display name
  -> prompt/persona/style
  -> selected tool ids
  -> context policy step ids
```

Do not fall back to latest revision once an explicit `profile_revision_id` is supplied.

- [ ] **Step 6: Show unsupported-card validation copy in Builder**

Update `AgentBuilderCards.swift` so disabled Memory, Skill, and advanced Model cards show:

```text
Not included in this published revision.
```

when the card remains unsupported. If a card is represented as a warning in Rust, show the warning in publish review.

- [ ] **Step 7: Run focused tests**

Run:

```bash
swift test --package-path local-ios-agent/toolkit --filter AgentBuilder
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml run_snapshot_resolution_agent_os
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath /Users/alexandercou/Projects/Alex-agent/.worktrees/swift-product-mvp/.derivedData/LocalAgentApp \
  -only-testing:LocalAgentAppTests/AgentBuilderViewModelTests
```

Expected:

```text
0 failed
```

- [ ] **Step 8: Full verification and commit**

Run:

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath /Users/alexandercou/Projects/Alex-agent/.worktrees/swift-product-mvp/.derivedData/LocalAgentApp
swift test --package-path local-ios-agent/toolkit
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml
git diff --check
```

Commit:

```bash
git add local-ios-agent/apps/LocalAgentApp local-ios-agent/toolkit local-ios-agent/rust-core
git commit -m "feat: publish card-backed agent revisions"
```

---

### Task 2: Pending Interaction And Picker Closure

**Files:**
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Tools/NativeInteractionBroker.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/App/BuilderFirstHostView.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/ConversationWorkspaceView.swift`
- Modify: `local-ios-agent/toolkit/Sources/LocalNativeToolkit/PendingUserInteractionStore.swift`
- Modify: `local-ios-agent/toolkit/Sources/LocalNativeToolkit/AttachmentTools.swift`
- Test: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Tools/NativeInteractionBrokerTests.swift`
- Test: `local-ios-agent/toolkit/Tests/LocalNativeToolkitTests/AttachmentToolsTests.swift`

**Interfaces:**
- Consumes: `PendingUserInteractionRecord`, `PendingInteractionCardState`, `RunInlineCardAction.continuePendingInteraction`.
- Produces: real presenter-backed pending interaction completion for file/photo picker flows, with durable resume/cancel/error states.

- [ ] **Step 1: Write failing broker resume/cancel tests**

Add tests to `NativeInteractionBrokerTests.swift`:

```swift
@Test("file picker completion submits attachment result through pending interaction")
func filePickerCompletionSubmitsAttachmentResult() async throws {
    let store = InMemoryPendingUserInteractionStore()
    let presenter = RecordingNativeInteractionPresenter(result: .completed)
    let broker = NativeInteractionBroker(store: store, presenter: presenter)
    let record = PendingUserInteractionRecord(
        id: "pending_1",
        runId: "run_1",
        toolCallId: "tool_call_1",
        manifestId: "native.files.pick_document.v1",
        interactionKind: .documentPicker,
        title: "Choose document",
        state: .requested
    )

    let result = try await broker.present(record)

    #expect(result == .completed)
    #expect(await store.record(id: "pending_1")?.state == .completed)
}

@Test("user cancellation persists cancelled state")
func filePickerCancellationPersistsCancelledState() async throws {
    let store = InMemoryPendingUserInteractionStore()
    let presenter = RecordingNativeInteractionPresenter(result: .cancelled)
    let broker = NativeInteractionBroker(store: store, presenter: presenter)
    let record = PendingUserInteractionRecord(
        id: "pending_1",
        runId: "run_1",
        toolCallId: "tool_call_1",
        manifestId: "native.files.pick_document.v1",
        interactionKind: .documentPicker,
        title: "Choose document",
        state: .requested
    )

    let result = try await broker.present(record)

    #expect(result == .cancelled)
    #expect(await store.record(id: "pending_1")?.state == .cancelledByUser)
}
```

Expected failure before implementation: real state transitions or test accessors are incomplete.

- [ ] **Step 2: Add presenter protocols for file and photo pickers**

Add protocols inside the app target, not toolkit:

```swift
protocol DocumentPickerPresenting: Sendable {
    func pickDocument(for record: PendingUserInteractionRecord) async throws -> NativeInteractionResult
}

protocol PhotoPickerPresenting: Sendable {
    func pickImages(for record: PendingUserInteractionRecord) async throws -> NativeInteractionResult
}
```

`NativeInteractionBroker` chooses the presenter by `PendingInteractionKind`.

- [ ] **Step 3: Persist state before, during, and after presentation**

State transitions:

```text
requested -> presentingSystemUI -> completed
requested -> presentingSystemUI -> cancelledByUser
requested -> presentingSystemUI -> failedToPresent
```

If the app restarts and finds `presentingSystemUI`, show a pending card with:

```text
Selection was interrupted. Continue to choose again.
```

- [ ] **Step 4: Ensure cancellation creates a structured tool result**

When the user cancels a picker, submit a conservative result envelope:

```json
{
  "schema_version": 1,
  "tool_call_id": "<tool_call_id>",
  "is_error": true,
  "error_code": "user_cancelled",
  "result_payload": {
    "cancelled": true
  },
  "provenance": {
    "source_kind": "user_mediated_picker",
    "trust_level": "trusted_user_selection"
  },
  "context_policy": {
    "include_in_context": false,
    "retention": "run_only",
    "sensitivity": "private"
  }
}
```

This keeps Rust execution from waiting forever.

- [ ] **Step 5: Run focused picker tests**

Run:

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath /Users/alexandercou/Projects/Alex-agent/.worktrees/swift-product-mvp/.derivedData/LocalAgentApp \
  -only-testing:LocalAgentAppTests/NativeInteractionBrokerTests
swift test --package-path local-ios-agent/toolkit --filter Attachment
```

Expected:

```text
0 failed
```

- [ ] **Step 6: Full verification and commit**

Run the full Xcode, SwiftPM, and `git diff --check` commands from Task 1 Step 8.

Commit:

```bash
git add local-ios-agent/apps/LocalAgentApp local-ios-agent/toolkit
git commit -m "feat: complete pending interaction picker flow"
```

---

### Task 3: Native Toolkit Additional Adapters

**Files:**
- Modify: `local-ios-agent/toolkit/Sources/LocalNativeToolkit/NativeToolManifest.swift`
- Modify: `local-ios-agent/toolkit/Sources/LocalNativeToolkit/WebTools.swift`
- Modify: `local-ios-agent/toolkit/Sources/LocalNativeToolkit/WebFetchPolicy.swift`
- Create: `local-ios-agent/toolkit/Sources/LocalNativeToolkit/ShareCaptureTools.swift`
- Create: `local-ios-agent/toolkit/Sources/LocalNativeToolkit/VisionTools.swift`
- Create: `local-ios-agent/toolkit/Sources/LocalNativeToolkit/SpeechTools.swift`
- Create: `local-ios-agent/toolkit/Sources/LocalNativeToolkit/MapTools.swift`
- Test: `local-ios-agent/toolkit/Tests/LocalNativeToolkitTests/WebFetchPolicyTests.swift`
- Test: `local-ios-agent/toolkit/Tests/LocalNativeToolkitTests/NativeToolSchemaExportTests.swift`

**Interfaces:**
- Consumes: stable `NativeToolManifest`, `NativeToolCatalog`, `ToolResultEnvelopeV1`, and `NativeAttachmentStore`.
- Produces: additional adapters only after each tool has a manifest, a fake adapter test, a permission/readiness state, and a bounded result envelope.

- [ ] **Step 1: Harden web fetch before adding new external-input tools**

Add failing tests:

```swift
@Test("resolved private network address is denied")
func resolvedPrivateNetworkAddressIsDenied() async throws {
    let resolver = StaticHostResolver(addresses: ["93.184.216.34", "127.0.0.1"])
    let policy = WebFetchPolicyV1(hostResolver: resolver)

    let result = await policy.validate(URL(string: "https://example.com/page")!)

    #expect(result == .denied("private_network_denied"))
}

@Test("response stream stops at byte limit")
func responseStreamStopsAtByteLimit() async throws {
    let fetcher = StreamingURLSessionWebFetcher(maxResponseBytes: 8)

    await #expect(throws: WebFetchError.responseTooLarge) {
        _ = try await fetcher.fetch(URL(string: "https://example.com/large")!)
    }
}
```

Implement resolved-address checks behind an injectable resolver. If platform-level resolved-address inspection is unavailable in the current test environment, keep the resolver interface and production fallback as best-effort with an audit warning.

- [ ] **Step 2: Add adapter only when manifest is complete**

For each new adapter, first add a test that `NativeToolSchemaExport.export(_:mode: .product)` exports exactly one manifest-backed schema.

Required manifest fields:

```text
manifest_id
tool name
display name
description
JSON schema
risk level
approval policy
permission scope
trust level
mode
availability
fallback
audit policy
```

If any field is unavailable, do not register the adapter in the product catalog.

- [ ] **Step 3: Add Share capture only as app-owned action adapter**

The Share Extension must create app-owned captured input records:

```text
share input -> attachment/capture record -> app route -> user chooses agent/conversation
```

It must not expose arbitrary Share Extension execution as a model-callable background tool.

Acceptance test:

```swift
@Test("share capture stores input without exposing raw file path")
func shareCaptureStoresOpaqueAttachment() async throws {
    let store = InMemoryNativeAttachmentStore()
    let tool = ShareCaptureTool(store: store)

    let result = try await tool.captureText("Selected page text", sourceURL: URL(string: "https://example.com")!)

    #expect(result.attachmentId.hasPrefix("attachment_"))
    #expect(result.modelVisibleText.contains("attachment_id"))
    #expect(!result.modelVisibleText.contains("/private/var"))
}
```

- [ ] **Step 4: Add Vision, Speech, and Maps as separate commits**

Do not batch these adapters into one commit.

Commit sequence:

```bash
git commit -m "feat: add share capture adapter"
git commit -m "feat: add vision extraction adapters"
git commit -m "feat: add speech transcription adapter"
git commit -m "feat: add map lookup adapters"
```

Each commit must include fake adapter tests and manifest export tests.

- [ ] **Step 5: Full verification after each adapter commit**

Run:

```bash
swift test --package-path local-ios-agent/toolkit
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath /Users/alexandercou/Projects/Alex-agent/.worktrees/swift-product-mvp/.derivedData/LocalAgentApp
git diff --check
```

Expected:

```text
0 failed
```

---

### Task 4: Model Download And Provider Setup

**Files:**
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Models/ModelCenterViewModel.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Models/ModelCenterView.swift`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Models/LocalModelCatalog.swift`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Models/ModelDownloadStore.swift`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Models/CloudProviderCredentialStore.swift`
- Test: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Presentation/Models/ModelCenterViewModelTests.swift`

**Interfaces:**
- Consumes: C++ compiled engine list through Swift local inference client, existing Model Center readiness model, app shell active model selection.
- Produces: persisted active local/cloud model selection, explicit readiness, download/storage state, cloud credential validation state.

- [ ] **Step 1: Write failing local model readiness tests**

Add:

```swift
@Test("downloaded local model becomes selectable only when engine is compatible")
@MainActor
func downloadedLocalModelRequiresCompatibleEngine() async throws {
    let catalog = LocalModelCatalog(models: [
        LocalModelDescriptor(
            id: "qwen-local",
            displayName: "Qwen Local",
            requiredEngineIds: ["llama_cpp"],
            artifact: .remote(url: URL(string: "https://models.example/qwen.gguf")!, expectedBytes: 1024)
        )
    ])
    let downloads = InMemoryModelDownloadStore(downloadedModelIds: ["qwen-local"])
    let engines = StaticLocalInferenceEngineRegistry(engineIds: ["litert"])
    let viewModel = ModelCenterViewModel(catalog: catalog, downloads: downloads, engines: engines)

    await viewModel.load()

    #expect(viewModel.rows.first?.readiness == .blocked("Requires llama_cpp engine."))
}
```

- [ ] **Step 2: Add download state machine**

States:

```text
notDownloaded
queued
downloading(progress: Double)
downloaded(localURL: URL, bytes: Int64)
failed(message: String)
needsUpdate
```

The store must persist:

```text
model_id
engine_id
local_path
bytes
checksum if available
updated_at
```

- [ ] **Step 3: Add cloud credential readiness**

States:

```text
missingAPIKey
validating
ready
invalid(message)
```

Credentials must be stored through Keychain-facing protocol:

```swift
protocol CloudProviderCredentialStore: Sendable {
    func credential(for providerId: String) async throws -> String?
    func saveCredential(_ value: String, for providerId: String) async throws
    func deleteCredential(for providerId: String) async throws
}
```

Tests use an in-memory fake. Production implementation must not log credential values.

- [ ] **Step 4: Connect active model selection to runtime defaults**

When a ready model is selected:

```text
ModelCenterViewModel.select(model_id)
  -> AppShell activeModel
  -> AgentRuntimeService runtime options before send
```

If no ready model exists, Chat must show the existing model readiness card with a route to Model Center.

- [ ] **Step 5: Verify**

Run:

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath /Users/alexandercou/Projects/Alex-agent/.worktrees/swift-product-mvp/.derivedData/LocalAgentApp \
  -only-testing:LocalAgentAppTests/ModelCenterViewModelTests
swift test --package-path local-ios-agent/toolkit
```

Commit:

```bash
git add local-ios-agent/apps/LocalAgentApp
git commit -m "feat: add model download and provider readiness"
```

---

### Task 5: Conversation Workspace Polish

**Files:**
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/ConversationWorkspaceView.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/ChatView.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/RunInlineCards.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/ConversationViewModel.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/ContextInspector/ContextInspectorViewModel.swift`
- Test: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Presentation/Chat/ConversationWorkspaceViewModelTests.swift`
- Test: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Presentation/Chat/RunInlineCardsTests.swift`
- Test: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Presentation/ContextInspector/ContextInspectorViewModelTests.swift`

**Interfaces:**
- Consumes: active agent selection, model readiness, native interaction broker, context inspector trace, external-content trust labels.
- Produces: daily-usable Chat with repair routes, session/fork/edit affordances, source/trust warnings, and revision drift visibility.

- [ ] **Step 1: Replace disabled reasons with real routes where destinations exist**

Tests:

```swift
@Test("permission repair card routes to focused tool center row")
func permissionRepairRoutesToToolCenter() {
    let viewModel = ConversationWorkspaceViewModel.fixture()

    viewModel.handleRunCard(.permissionRepair(scope: "calendar.events.read_full"))

    #expect(viewModel.route == .tools(focusedToolName: "calendar.search_events"))
}

@Test("model readiness card routes to model center")
func modelReadinessRoutesToModelCenter() {
    let viewModel = ConversationWorkspaceViewModel.fixture()

    viewModel.handleRunCard(.modelMissing)

    #expect(viewModel.route == .models)
}
```

- [ ] **Step 2: Finish session/branch/fork/edit affordances**

Scope:

```text
conversation list search
branch leaf indicator
fork from message
edit user turn and resend
rename session
archive/delete session
```

Do not add collaboration, sharing, or team features.

- [ ] **Step 3: Surface external-content trust warnings in assistant responses**

When a response used `untrusted_external_content`, show:

```text
Used external content. Verify important facts.
```

This warning must be derived from source/trust metadata, not from text heuristics.

- [ ] **Step 4: Add agent selector and revision drift visibility**

Minimal selector:

```text
current active agent
current revision
published revisions list
use selected revision
```

Revision drift indicator:

```text
This conversation uses revision 2. Latest is revision 5.
```

Do not silently migrate an old conversation to the latest revision.

- [ ] **Step 5: Verify**

Run:

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath /Users/alexandercou/Projects/Alex-agent/.worktrees/swift-product-mvp/.derivedData/LocalAgentApp \
  -only-testing:LocalAgentAppTests/ConversationWorkspaceViewModelTests \
  -only-testing:LocalAgentAppTests/RunInlineCardsTests \
  -only-testing:LocalAgentAppTests/ContextInspectorViewModelTests
```

Commit:

```bash
git add local-ios-agent/apps/LocalAgentApp
git commit -m "feat: polish conversation workspace flows"
```

---

### Task 6: Release Hardening For The Current Swift Product Scope

**Files:**
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Settings/PrivacySettingsProjection.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Settings/SettingsView.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/App/AppShellView.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/App/LocalAgentApp.swift`
- Test: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Presentation/Settings/PrivacySettingsProjectionTests.swift`

**Interfaces:**
- Consumes: all product surfaces from Tasks 1-5.
- Produces: release readiness evidence, accessibility pass, privacy review, export/reset behavior, and debug-safe defaults.

Execution gate:

```text
If the release target includes only the current Swift product scope:
  execute this task after Task 5.

If the release target includes memory/skills/full context trace:
  execute Task 7 first, then return here.
```

- [ ] **Step 1: Add privacy review checklist to Settings**

Settings must list:

```text
active model/provider
enabled native tools
attachment storage usage
memory retention state
debug trace state
data export action
data reset action
```

If a section is not implemented, it must be shown as unavailable with a reason.

- [ ] **Step 2: Add data export/reset behavior**

Export includes:

```text
conversation summaries and messages
agent profiles and revisions
tool audit summaries
attachment metadata, not raw inaccessible security-scoped source paths
settings snapshot
```

Reset must require explicit confirmation and must not delete files outside the app container.

- [ ] **Step 3: Audit debug-safe defaults**

Release defaults:

```text
advanced debug off
mock engines hidden unless debug/test flag is enabled
raw prompt traces hidden unless user enables advanced debug
credentials never included in debug archives
```

- [ ] **Step 4: Run manual smoke**

Manual smoke checklist:

```text
launch app
open Builder
edit identity/prompt/context/tool card
publish revision
use revision in Chat
send text message
approve/deny a tool request
open Tool Center and Model Center
open Context Inspector
open Settings privacy summary
quit and relaunch app
confirm selected agent/model state restores
```

Record device/simulator, iOS version, commit hash, and blockers in a release note or PR comment.

- [ ] **Step 5: Verify and commit**

Run:

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath /Users/alexandercou/Projects/Alex-agent/.worktrees/swift-product-mvp/.derivedData/LocalAgentApp
swift test --package-path local-ios-agent/toolkit
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml
git diff --check
plutil -lint local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj/project.pbxproj
```

Commit:

```bash
git add local-ios-agent/apps/LocalAgentApp local-ios-agent/docs
git commit -m "feat: harden app release readiness"
```

---

### Task 7: Rust And Swift Component Follow-Up Contracts

**Files:**
- Modify: `local-ios-agent/rust-core/src/user_customization/component_content.rs`
- Modify: `local-ios-agent/rust-core/src/memory/resolver.rs`
- Modify: `local-ios-agent/rust-core/src/context/assembler.rs`
- Modify: `local-ios-agent/rust-core/src/tool/schema.rs`
- Modify: `local-ios-agent/rust-core/src/run_snapshot/resolver.rs`
- Modify: `local-ios-agent/toolkit/Sources/LocalAgentBridge/AgentOSDTOs.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/AgentBuilder/AgentBuilderDraftModels.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/ContextInspector/ContextInspectorViewModel.swift`
- Test: `local-ios-agent/rust-core/tests/contract/conversation_execution_boundary.rs`
- Test: `local-ios-agent/rust-core/tests/contract/run_snapshot_resolution_agent_os.rs`
- Test: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Presentation/AgentBuilder/AgentBuilderViewModelTests.swift`
- Test: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Presentation/ContextInspector/ContextInspectorViewModelTests.swift`

**Interfaces:**
- Consumes: Swift Builder needs for skills, memory, cross-platform tools, and expanded context trace.
- Produces: minimal Rust contracts plus Swift DTO/UI bindings that allow Builder and Context Inspector to bind skills, memory, tool capabilities, and expanded context trace without Rust owning iOS implementation details.

- [ ] **Step 1: Skill package discovery/activation contract**

Add Rust types:

```rust
pub struct SkillPackageManifest {
    pub id: String,
    pub version: String,
    pub title: String,
    pub summary: String,
    pub required_capabilities: Vec<String>,
    pub context_contribution_policy: SkillContextContributionPolicy,
}

pub enum SkillContextContributionPolicy {
    OnActivation,
    OnToolMatch,
    ManualOnly,
}
```

Do not add a runtime script executor in this task. Skills are context/workflow packages first.

- [ ] **Step 2: Memory extraction and memory-to-context bridge**

Add policy types:

```rust
pub struct MemoryExtractionPolicy {
    pub enabled: bool,
    pub candidate_kinds: Vec<MemoryCandidateKind>,
    pub sensitivity_filter: Vec<String>,
    pub review_required: bool,
}

pub struct MemoryInjectionPolicy {
    pub enabled: bool,
    pub max_items: usize,
    pub include_unconfirmed: bool,
}
```

Context assembly may consume selected memory contributions, but extraction remains a separate policy step.

- [ ] **Step 3: Cross-platform tool capability abstraction**

Extend `ToolSchema` metadata with stable capability ids:

```text
capability_id
permission_scope
platform_support
approval_policy
trust_level
```

Swift iOS tools can provide iOS-specific implementations; other platforms can provide different adapters for the same capability.

- [ ] **Step 4: Context assembly trace expansion**

Add trace segments for:

```text
system prompt
conversation frame
selected tools
tool observations
memory contributions
skill instructions
attachments
runtime policy clipping
```

Every segment must include:

```text
segment_id
source_kind
trust_level
included
token_estimate
redaction_reason if excluded
```

- [ ] **Step 5: Add Swift DTOs for expanded component contracts**

Extend `AgentOSDTOs.swift` with:

```swift
public struct SkillPackageManifestDTO: Codable, Equatable, Sendable {
    public var id: String
    public var version: String
    public var title: String
    public var summary: String
    public var requiredCapabilities: [String]
    public var contextContributionPolicy: String
}

public struct MemoryPolicyDTO: Codable, Equatable, Sendable {
    public var extractionEnabled: Bool
    public var injectionEnabled: Bool
    public var maxInjectedItems: Int
    public var reviewRequired: Bool
}

public struct ContextTraceSegmentDTO: Codable, Equatable, Sendable {
    public var segmentId: String
    public var sourceKind: String
    public var trustLevel: String
    public var included: Bool
    public var tokenEstimate: Int
    public var redactionReason: String?
}
```

Encoding keys must be snake case:

```text
required_capabilities
context_contribution_policy
extraction_enabled
injection_enabled
max_injected_items
review_required
segment_id
source_kind
trust_level
token_estimate
redaction_reason
```

- [ ] **Step 6: Bind Memory and Skill cards in Builder only after contracts exist**

Update `AgentBuilderDraftModels.swift` so Memory and Skill cards can become publish-affecting only when they have contract-backed payloads:

```swift
struct MemoryPolicyPayload: Equatable, Sendable {
    var extractionEnabled: Bool
    var injectionEnabled: Bool
    var maxInjectedItems: Int
    var reviewRequired: Bool
}

struct SkillPackageSelectionPayload: Equatable, Sendable {
    var selectedSkillPackageIds: [String]
}
```

Rules:

```text
If Rust does not expose memory/skill contract support:
  card remains disabled with an explicit reason.

If Rust exposes the contracts:
  card edits update AgentBuilderDraftDTO.
  publish validation rejects unknown skill package ids.
  publish validation rejects memory injection when extraction is disabled and no existing memory store is available.
```

- [ ] **Step 7: Show expanded context trace in Context Inspector**

Update `ContextInspectorViewModel` so trace segments include:

```text
source kind
trust level
included/excluded
token estimate
redaction reason
```

Acceptance test:

```swift
@Test("context inspector shows memory skill and attachment trace segments")
func contextInspectorShowsExpandedTraceSegments() {
    let viewModel = ContextInspectorViewModel(trace: .fixture(segments: [
        ContextTraceSegmentDTO(
            segmentId: "memory_1",
            sourceKind: "memory",
            trustLevel: "trusted_user_memory",
            included: true,
            tokenEstimate: 42,
            redactionReason: nil
        ),
        ContextTraceSegmentDTO(
            segmentId: "skill_1",
            sourceKind: "skill",
            trustLevel: "trusted_app_policy",
            included: false,
            tokenEstimate: 0,
            redactionReason: "not activated"
        )
    ]))

    #expect(viewModel.rows.map(\.sourceKind) == ["memory", "skill"])
    #expect(viewModel.rows[1].redactionReason == "not activated")
}
```

- [ ] **Step 8: Verify Rust and Swift component contracts**

Run:

```bash
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml
swift test --package-path local-ios-agent/toolkit
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath /Users/alexandercou/Projects/Alex-agent/.worktrees/swift-product-mvp/.derivedData/LocalAgentApp \
  -only-testing:LocalAgentAppTests/AgentBuilderViewModelTests \
  -only-testing:LocalAgentAppTests/ContextInspectorViewModelTests
```

Commit:

```bash
git add local-ios-agent/rust-core local-ios-agent/toolkit local-ios-agent/apps/LocalAgentApp
git commit -m "feat: add agent component follow-up contracts"
```

---

## Final Integration Gate

After the selected product scope is complete, run:

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath /Users/alexandercou/Projects/Alex-agent/.worktrees/swift-product-mvp/.derivedData/LocalAgentApp
swift test --package-path local-ios-agent/toolkit
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml
git diff --check
plutil -lint local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj/project.pbxproj
```

Then perform two self-reviews:

1. **System boundary review:** confirm Swift owns platform UI and permissions, Rust owns agent contracts and context assembly, C++ owns local inference only.
2. **Product closure review:** confirm every visible UI control either works, routes to a working destination, or shows an explicit disabled reason.

Only fix P0/P1 and release-blocking P2 issues during the final gate. Everything else becomes a clearly scoped future issue.
