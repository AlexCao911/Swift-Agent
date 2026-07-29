# LocalAgent OpenMinis Capability Migration and Rust ReAct Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:subagent-driven-development` (recommended) or
> `superpowers:executing-plans` to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the existing `LocalAgentApp` as the only App, with selected
OpenMinis UI/product/iSH/tool/provider capabilities migrated into it and a
small Rust-owned direct ReAct loop driving both cloud and local models.

**Architecture:** Swift owns the LocalAgent product shell, migrated OpenMinis
facilities, credentials, one complete model request, and one complete tool
batch. Rust owns Prompt/Context, the canonical transcript, projection, and a
plain ReAct loop. The existing C++ local inference runtime and the existing
sequenced/digested/backpressured Rust/Swift host transport remain in place.

**Tech Stack:** Swift 6, SwiftUI/UIKit, iOS 17+, Objective-C/C for iSH and
native offloads, Rust 2021, SQLite, Swift Package Manager, Xcode, C++/llama.cpp,
`LocalAgentLLMCloud`, CloudKit/App Groups for eligible product data only.

**Supersedes:** `2026-07-28-openminis-rust-react-core-implementation.md`

## Global Constraints

- `local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj` is the only
  shipping App project; keep bundle ID `com.localagent.app`, Swift 6, iOS 17,
  and iPhone/iPad device families.
- Start implementation from LocalAgent baseline
  `cbb89cb86ece80e2eac2b223c674cfd0680c69f3`. Do not base product work on the
  branch that imported the complete OpenMinis repository.
- The existing worktree
  `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react`
  is read-only donor/reference input during implementation. Do not stage,
  discard, or modify its paused Rust/Swift work.
- Migrate source selectively into LocalAgent-owned paths. The final product
  tree contains no `OpenMinis/` checkout, `Minis.xcodeproj`, `MinisApp`,
  Minis bundle identifiers, or upstream commit metadata.
- Preserve GPLv3 copyright/license text and required third-party notices.
- Keep the existing Agent Builder, local-model download/management/selection,
  App Intents, debug traces, Rust bridge/security boundaries, and C++ local
  inference.
- Rust is the complete Agent Core. Swift never runs an agent loop or appends a
  second base prompt, Skill body, Memory fragment, MCP fragment, or tool schema.
- Use a direct Rust ReAct loop with `MAX_MODEL_TURNS: usize = 200`; do not add
  a business phase enum, configurable limit, or generic approval state machine.
- Swift executes one complete model request or one ordered tool batch. Tool
  execution may have at most ten calls in flight.
- Rust is the only canonical transcript writer. Swift `ChatStore` is only a
  rebuildable one-way projection/read model.
- Reuse `HostCommandEnvelope`, `LLMEventEnvelope`, receipts, sequence,
  canonical digest, epoch, backpressure, and necessary transport lifecycle.
  Do not create a second wire protocol or global projection cursor.
- `LocalAgentLLMCloud` is the only executable model/provider HTTP stack.
  Provider/OAuth/API Key/Base URL UI remains Swift-owned; credentials never
  enter Rust or iSH.
- Skills preload at most 20 descriptors. Descriptor locations use
  `/var/localagent/skills/<skill-id>/SKILL.md`; full files are read only
  through ordinary file tools.
- Raw iSH networking remains enabled by default and is disclosed as an
  independent high-privilege network path. Do not claim cloud egress policy
  covers guest sockets.
- Only the main App's Rust runtime writes canonical storage. Extensions do not
  open the Rust store, write transcript `ChatStore`, or import canonical events.
- Generated native libraries, frameworks, extracted release sources,
  `RootfsPatch.bundle`, fakefs data, and `alpine-rootfs.zip` stay ignored.
  Their source, scripts, exact URL/version/SHA-256 lock, license, and Xcode
  references stay committed.
- Every task that retains donor source updates
  `local-ios-agent/docs/openminis-migration-manifest.md`.
- `LocalAgentApp.xcodeproj` uses explicit PBX references. Every task that
  creates App, test, extension, or resource files must list
  `project.pbxproj`, add the exact Sources/Test Sources/Resources membership,
  and verify required framework/package linkage before accepting an
  `xcodebuild` result. Zero discovered tests is failure.
- Use focused suites in component tasks. Final product verification contains
  only one complete ReAct path, one relaunch/projection-replay path, and one
  diagnostics/benchmark comparison.

## Execution Workspace

Before Task 1, use `superpowers:using-git-worktrees` and create the clean
implementation worktree:

```bash
cd /Users/alexandercou/Projects/Alex-agent
git worktree add \
  /Users/alexandercou/Projects/Alex-agent/.worktrees/localagent-openminis-migration \
  -b codex/localagent-openminis-migration \
  cbb89cb86ece80e2eac2b223c674cfd0680c69f3
git -C /Users/alexandercou/Projects/Alex-agent/.worktrees/localagent-openminis-migration \
  checkout codex/openminis-rust-react -- \
  local-ios-agent/docs/superpowers/specs/2026-07-29-localagent-openminis-capability-migration-rust-react-core-design.md \
  local-ios-agent/docs/superpowers/plans/2026-07-29-localagent-openminis-capability-migration-rust-react-core-implementation.md
```

Run every task below from:

```text
/Users/alexandercou/Projects/Alex-agent/.worktrees/localagent-openminis-migration
```

Read donor files only from:

```text
/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis
```

Before running Xcode tests, validate the two simulator inputs already used by
the repository's phase-5 test script:

```bash
: "${LOCAL_AGENT_PHASE5_IPHONE_UDID:?Set an available iPhone simulator UDID}"
: "${LOCAL_AGENT_PHASE5_IPAD_UDID:?Set an available iPad simulator UDID}"
xcrun simctl list devices available | rg -F "$LOCAL_AGENT_PHASE5_IPHONE_UDID"
xcrun simctl list devices available | rg -F "$LOCAL_AGENT_PHASE5_IPAD_UDID"
```

The variables are test-environment inputs, not project configuration.

## File and Ownership Map

| Responsibility | LocalAgent-owned destination |
| --- | --- |
| App identity/navigation/composition | `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/App/`, `Composition/` |
| Migrated chat/message/Markdown UI | `LocalAgentApp/ThirdParty/OpenMinis/ChatUI/`, `UI/` |
| Swift projection read model | `LocalAgentApp/ThirdParty/OpenMinis/ChatUI/ChatStore.swift` |
| Rust/Swift UI coordinator | `LocalAgentApp/Runtime/RustAgentCoordinator.swift` |
| Projection application/feed ownership | `LocalAgentApp/Runtime/ChatStoreProjectionApplier.swift`, `ProjectionFeedController.swift` |
| Migrated iSH/terminal/filesystem | `LocalAgentApp/ThirdParty/OpenMinis/ISH/` |
| Migrated tools/browser/MCP/offloads | `LocalAgentApp/ThirdParty/OpenMinis/Tools/` |
| Migrated Skills product store/UI | `LocalAgentApp/ThirdParty/OpenMinis/Skills/` |
| Prompt Markdown documents | `LocalAgentApp/ThirdParty/OpenMinis/Skills/PromptDocumentStore.swift` |
| Provider/OAuth/model product UI | `LocalAgentApp/ThirdParty/OpenMinis/Providers/` |
| Swift model/tool executors | `LocalAgentApp/Runtime/OpenMinisModelExecutor.swift`, `OpenMinisToolBatchExecutor.swift` |
| Optional product slices | `LocalAgentApp/ThirdParty/OpenMinis/Voice/`, `Product/`, extension/widget targets |
| Core DEBUG validation helpers | `LocalAgentApp/Debug/OpenMinisPerfTrace.swift`, `OpenMinisAgentRequestTrace.swift` |
| Native iSH source/patches/licenses | `local-ios-agent/ThirdParty/OpenMinisNative/` |
| Native preparation scripts | `local-ios-agent/scripts/native/`, `prepare-ios-native.sh` |
| Shared transcript DTOs | `local-ios-agent/toolkit/Sources/LocalAgentBridge/TranscriptDTOs.swift` |
| Shared model/tool wire values | `local-ios-agent/toolkit/Sources/LocalAgentLLMContracts/` |
| Swift host command handlers | `local-ios-agent/toolkit/Sources/LocalAgentLLMHost/` |
| Sole cloud execution | `local-ios-agent/toolkit/Sources/LocalAgentLLMCloud/` |
| Rust canonical transcript | `local-ios-agent/rust-core/src/conversation/`, `storage/` |
| Rust Prompt/Skill inputs | `local-ios-agent/rust-core/src/agent_input/`, `prompt/`, `skills/` |
| Rust direct loop | `local-ios-agent/rust-core/src/agent_loop/` |
| Rust reliable transport adapter | `local-ios-agent/rust-core/src/host_adapter/` |

---

### Task 1: Migrate the OpenMinis Chat Surface into the LocalAgent Product Shell

**Files:**

- Create: `local-ios-agent/docs/openminis-migration-manifest.md`
- Copy selected source from:
  `OpenMinis/src/ios/Views/Chat/`,
  `OpenMinis/src/ios/Agent/MessageList/`,
  `OpenMinis/src/ios/Agent/Markdown/`,
  `OpenMinis/src/ios/Resources/KaTeX/`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/ThirdParty/OpenMinis/ChatUI/AIChatViewModel.swift`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/ThirdParty/OpenMinis/ChatUI/ChatStore.swift`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/ThirdParty/OpenMinis/Product/OpenMinisProductShellView.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/App/AppShellView.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/App/AppRoute.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Composition/AppContainer.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj/project.pbxproj`
- Test: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Architecture/ShippingTargetOwnershipTests.swift`
- Test: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Presentation/Chat/OpenMinisChatFacadeTests.swift`

**Interfaces:**

- Consumes: existing `AppShellView`, Agent Builder, model/tool/settings
  destinations, and the donor's chat rendering files.
- Produces: a compileable OpenMinis-derived chat surface whose only mutation
  exit is `AIChatViewModel.submit`; later tasks inject `RustAgentCoordinator`.

- [ ] **Step 1: Commit the approved documents and write ownership tests**

Add a source test that loads `project.pbxproj` and checks the stable product
identity:

```swift
func testLocalAgentRemainsTheOnlyShippingApp() throws {
    let project = try String(
        contentsOf: projectFileURL(),
        encoding: .utf8
    )
    XCTAssertTrue(project.contains("productName = LocalAgentApp;"))
    XCTAssertTrue(project.contains("PRODUCT_BUNDLE_IDENTIFIER = com.localagent.app;"))
    XCTAssertFalse(project.contains("productName = Minis;"))
    XCTAssertFalse(project.contains("Minis.xcodeproj"))
}
```

Run:

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build-for-testing \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/localagent-openminis-task1 \
  CODE_SIGNING_ALLOWED=NO
```

Expected: baseline build passes; the new source test is not yet present.

- [ ] **Step 2: Copy only the first chat/UI slice**

Use the donor worktree as a read-only source. Copy chat presentation files,
message-list infrastructure, Markdown renderers, and KaTeX resources into the
matching `ThirdParty/OpenMinis` directories. Exclude
`Views/Chat/Voice/`, `SessionMemoryView.swift`, and
`SessionSkillsView.swift`; Tasks 4 and 13 add those with their working
dependencies.

Add only the packages required by this slice:

```text
https://github.com/swiftlang/swift-cmark
  cmark-gfm
  cmark-gfm-extensions
https://github.com/mgriebling/SwiftMath
  SwiftMath
```

Do not add `SwiftAnthropic` or `RealTimeCutVADLibrary` in this task.

- [ ] **Step 3: Replace the donor agent ViewModel with a presentation facade**

Create the minimal UI-facing type instead of copying the donor's
`runAgentLoop`:

```swift
@MainActor
final class AIChatViewModel: ObservableObject {
    struct Submission: Equatable, Sendable {
        var conversationStreamID: String
        var text: String
        var attachments: [InputAttachment]
    }

    @Published private(set) var messages: [ChatMessage] = []
    @Published var draft = ""
    @Published var inputAttachments: [InputAttachment] = []
    @Published private(set) var isRunning = false

    let conversationStreamID: String
    var submit: @Sendable (Submission) async throws -> Void

    func send() async {
        let submission = Submission(
            conversationStreamID: conversationStreamID,
            text: draft,
            attachments: inputAttachments
        )
        try? await submit(submission)
    }
}
```

Copy presentation-only fields referenced by the migrated Views from the donor
without copying any provider factory, Prompt builder, tool execution,
`runAgentLoop`, Memory injection, or durable `ChatStore` write. Keep
`ChatMessage`, `AssistantBlock`, tool-card, media, Markdown, and accessibility
behavior where they are direct render dependencies.

- [ ] **Step 4: Add a disposable read-only ChatStore**

Keep only session/message read-model rows and presentation metadata:

```swift
@MainActor
final class ChatStore: ObservableObject {
    @Published private(set) var sessions: [ChatSession] = []
    @Published private(set) var messagesByConversation: [String: [ChatMessage]] = [:]

    func projectedMessages(conversationStreamID: String) -> [ChatMessage] {
        messagesByConversation[conversationStreamID, default: []]
    }
}
```

Do not copy donor APIs that send, retry, edit, delete, clear, branch, compact,
sync, or invoke a provider. Task 12 gives `ChatStoreProjectionApplier`
package-internal mutation access; ordinary Views keep read-only access.

- [ ] **Step 5: Put the migrated UI inside the existing shell**

Use `OpenMinisProductShellView` for the chat/session experience while keeping
the LocalAgent `.agents`, `.models`, `.tools`, `.settings`, and `.debug`
destinations and existing Agent Builder/local-model ViewModels. Preserve
`AppShellView` as the App root and `LocalAgentApp.swift` as `@main`.

Update the migration manifest with:

```markdown
## Core chat UI

| OpenMinis source | LocalAgent target | Xcode target/resource/build phase | License |
| --- | --- | --- | --- |
| `src/ios/Views/Chat` | `LocalAgentApp/ThirdParty/OpenMinis/ChatUI/Views` | `LocalAgentApp` Sources | GPLv3 |
| `src/ios/Agent/MessageList` | `LocalAgentApp/ThirdParty/OpenMinis/ChatUI/MessageList` | `LocalAgentApp` Sources | GPLv3 |
| `src/ios/Agent/Markdown` | `LocalAgentApp/ThirdParty/OpenMinis/ChatUI/Markdown` | `LocalAgentApp` Sources | GPLv3 |
| `src/ios/Resources/KaTeX` | `LocalAgentApp/ThirdParty/OpenMinis/Resources/KaTeX` | `LocalAgentApp` Copy Bundle Resources | OpenMinis third-party notice |
```

- [ ] **Step 6: Verify the slice**

Tests prove `send()` invokes the injected closure exactly once and neither
`AIChatViewModel` nor copied chat Views import provider clients or call
`ChatStore` mutation methods.

Run:

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -destination "platform=iOS Simulator,id=$LOCAL_AGENT_PHASE5_IPHONE_UDID" \
  -derivedDataPath /private/tmp/localagent-openminis-task1-tests \
  -only-testing:LocalAgentAppTests/ShippingTargetOwnershipTests \
  -only-testing:LocalAgentAppTests/OpenMinisChatFacadeTests
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add local-ios-agent/docs \
  local-ios-agent/apps/LocalAgentApp
git commit -m "feat: migrate OpenMinis chat UI into LocalAgent"
```

---

### Task 2: Build the Pinned iSH and Rootfs Inputs in the Current Worktree

**Files:**

- Create: `local-ios-agent/ThirdParty/OpenMinisNative/native-sources.lock`
- Copy: donor `deps/ish/` →
  `local-ios-agent/ThirdParty/OpenMinisNative/iSH/`
- Copy: donor `deps/ffmpeg-patch/` →
  `local-ios-agent/ThirdParty/OpenMinisNative/Patches/FFmpeg/`
- Copy: donor `LICENSE`, `THIRD_PARTY_LICENSES.md`, and required nested
  licenses → `local-ios-agent/ThirdParty/OpenMinisNative/Licenses/`
- Create: `local-ios-agent/scripts/native/common.sh`
- Copy and adapt:
  `build_lame.sh`, `build_ffmpeg.sh`, `build_ish.sh`,
  `prepare_alpine_rootfs.sh`, `native_platform.sh`
- Create: `local-ios-agent/scripts/prepare-ios-native.sh`
- Modify: `local-ios-agent/.gitignore`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj/project.pbxproj`
- Test: `local-ios-agent/scripts/test-ios-native-build-contract.sh`

**Interfaces:**

- Consumes: official release archives and the vendored iSH snapshot.
- Produces:
  `ThirdParty/OpenMinisNative/.build/$(PLATFORM_NAME)/...`,
  `.build/resources/alpine-rootfs.zip`, and the Xcode resources/link inputs
  needed by Task 3.

- [ ] **Step 1: Write the source lock and failing digest test**

Use a four-column, shell-readable data file:

```text
alpine-minirootfs|3.21.0-aarch64|https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/alpine-minirootfs-3.21.0-aarch64.tar.gz|f31202c4070c4ef7de9e157e1bd01cb4da3a2150035d74ea5372c5e86f1efac1
lame|3.100|https://sourceforge.net/projects/lame/files/lame/3.100/lame-3.100.tar.gz/download|ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e
ffmpeg|6.1.2|https://ffmpeg.org/releases/ffmpeg-6.1.2.tar.xz|3b624649725ecdc565c903ca6643d41f33bd49239922e45c9b1442c63dca4e38
```

`test-ios-native-build-contract.sh` copies a cached archive, changes one byte,
and asserts `common.sh` returns `native.source_digest_mismatch` before
extraction.

Run:

```bash
bash local-ios-agent/scripts/test-ios-native-build-contract.sh --lock-only
```

Expected: FAIL because the lock helper does not exist.

- [ ] **Step 2: Vendor source inputs, not generated outputs**

Copy the complete iSH source snapshot including nested source currently
obtained through submodules. Do not copy:

```text
deps/platforms/
deps/resources/alpine-rootfs/
deps/resources/alpine-rootfs.zip
deps/ffmpeg-6.1.2/
deps/lame-3.100/
deps/.cache/
```

Copy only build-referenced iSH/FFmpeg patches and license files. Do not copy
the unused donor `proot` tree or `build_proot.sh`.

- [ ] **Step 3: Centralize locked download verification**

Implement one shared shell function used by LAME, FFmpeg, and Alpine:

```bash
verify_sha256() {
  local file="$1"
  local expected="$2"
  local actual
  actual="$(/usr/bin/shasum -a 256 "$file" | /usr/bin/awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    echo "native.source_digest_mismatch: $file" >&2
    return 1
  fi
}
```

Each build script reads its exact URL/version/digest from
`native-sources.lock`, downloads to `.build/downloads/`, verifies before
extracting, and uses `LOCALAGENT_NATIVE_PLATFORM` with accepted values
`iphoneos` or `iphonesimulator`. Device remains the default.

- [ ] **Step 4: Add the one supported preparation command**

`prepare-ios-native.sh` parses:

```text
--platform iphoneos
--platform iphonesimulator
```

It runs LAME → FFmpeg → iSH → Alpine fakefs/rootfs, then checks:

```bash
test -f "$artifact_root/lame/lib/libmp3lame.a"
test -d "$artifact_root/frameworks/FFmpeg.framework"
test -f "$artifact_root/libs/libish.a"
test -d "$artifact_root/resources/RootfsPatch.bundle"
test -f "$native_root/.build/resources/alpine-rootfs.zip"
unzip -l "$native_root/.build/resources/alpine-rootfs.zip" |
  rg 'alpine-rootfs/(data/|meta.db)'
```

Use `xcrun vtool -show-build` or `otool -l` to reject an iphoneos library in
the Simulator output and vice versa.

- [ ] **Step 5: Wire Xcode without auto-downloading during compilation**

Add:

- a `Verify Native Inputs` build phase that checks required files and prints
  either exact command
  `prepare-ios-native.sh --platform iphoneos` or
  `prepare-ios-native.sh --platform iphonesimulator` from `PLATFORM_NAME`;
- platform-specific header/library/framework paths under
  `ThirdParty/OpenMinisNative/.build/$(PLATFORM_NAME)`;
- `alpine-rootfs.zip` and
  `.build/$(PLATFORM_NAME)/resources/RootfsPatch.bundle` to
  `LocalAgentApp` Copy Bundle Resources.

The build phase must fail before Swift compilation when preparation was
skipped. It must not perform network access itself.

- [ ] **Step 6: Run the build contract and current-worktree Simulator build**

Task 2 has not committed its new source lock/scripts yet, so do not create a
fresh worktree here. Run the full digest/artifact/resource contract and one
Simulator build from the current implementation worktree:

```bash
bash local-ios-agent/scripts/test-ios-native-build-contract.sh --lock-only
bash local-ios-agent/scripts/prepare-ios-native.sh --platform iphonesimulator
bash local-ios-agent/scripts/test-ios-native-build-contract.sh
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/localagent-native-simulator \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64
```

Inspect the Simulator App bundle for `alpine-rootfs.zip` and the
Simulator-matching `RootfsPatch.bundle`. Task 16 alone performs the
post-commit clean-worktree Simulator/device regeneration and builds.

- [ ] **Step 7: Update manifest and commit**

Add:

```markdown
## Native iSH/rootfs inputs

| OpenMinis source | LocalAgent target | Xcode target/resource/build phase | License |
| --- | --- | --- | --- |
| `deps/ish` | `ThirdParty/OpenMinisNative/iSH` | Native build input | iSH GPL/LGPL notices |
| `deps/build_{lame,ffmpeg,ish}.sh` | `scripts/native` | Pre-build preparation | GPLv3 script provenance |
| `deps/prepare_alpine_rootfs.sh` | `scripts/native` | Generates App rootfs resource | GPLv3 script provenance |
| `deps/ffmpeg-patch` | `ThirdParty/OpenMinisNative/Patches/FFmpeg` | FFmpeg build input | FFmpeg/OpenMinis notices |
| `LICENSE`, `THIRD_PARTY_LICENSES.md` | `ThirdParty/OpenMinisNative/Licenses` | Distribution resources | Recorded per file |
```

```bash
git add local-ios-agent/ThirdParty \
  local-ios-agent/scripts \
  local-ios-agent/.gitignore \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  local-ios-agent/docs/openminis-migration-manifest.md
git commit -m "build: make OpenMinis native inputs reproducible"
```

---
### Task 3: Migrate iSH, Files, Browser, MCP, Native Tools, and the Final Batch Executor

**Files:**

- Copy donor `src/ios/iSH/`, `src/ios/Agent/ISH/`,
  `src/ios/Agent/Shell/`, `src/ios/Agent/BrowserUse/`,
  `src/ios/Views/Rootfs/`, `src/ios/Views/MCP/`,
  `src/ios/NativeOffloads/`, and `src/ios/default_mount/`
- Copy donor `src/ios/Agent/ToolLoopDetector.swift`
- Extract from donor:
  `AIChatViewModel+ConcurrentTools.swift`,
  `AIChatViewModel+FileTools.swift`,
  `AIChatViewModel+ISHCommand.swift`,
  `AIChatViewModel+Offloading.swift`,
  `AIChatViewModel+ToolDefinitions.swift`,
  `AIChatViewModel+ToolPreflight.swift`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/ThirdParty/OpenMinis/Tools/OpenMinisToolBatchExecutor.swift`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/ThirdParty/OpenMinis/Tools/ToolCallCancellationRegistry.swift`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/ThirdParty/OpenMinis/Tools/ToolLoopDetectorRegistry.swift`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/ThirdParty/OpenMinis/Tools/OpenMinisToolDefinitionSnapshotProvider.swift`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/ThirdParty/OpenMinis/ISH/ToolFileResolver.swift`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/LocalAgentApp-Bridging-Header.h`
- Create: `local-ios-agent/toolkit/Sources/LocalAgentLLMContracts/HostToolBatch.swift`
- Create: `local-ios-agent/toolkit/Sources/LocalAgentLLMHost/ToolBatchExecuting.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Resources/Info.plist`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Settings/PrivacySettingsView.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj/project.pbxproj`
- Test: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Tools/OpenMinisToolBatchExecutorTests.swift`
- Test: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Tools/ToolCallCancellationRegistryTests.swift`
- Test: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Tools/ToolFileResolverTests.swift`
- Test: `local-ios-agent/toolkit/Tests/LocalAgentLLMHostTests/ToolBatchExecutingContractTests.swift`

**Interfaces:**

- Consumes: Task 2 native outputs and donor tool implementations.
- Produces: final Swift `ToolBatchExecuting`, ordered tool schemas, virtual
  file routing, cancellation by batch/call, and a per-run loop detector.

- [ ] **Step 1: Define one shared Swift batch contract and failing tests**

Add to the existing contracts module:

```swift
public struct HostToolCall: Codable, Equatable, Sendable {
    public let callID: String
    public let toolName: String
    public let argumentsJSON: String
}

public struct HostToolBatch: Codable, Equatable, Sendable {
    public let batchID: String
    public let runID: String
    public let orderedCalls: [HostToolCall]
}

public struct HostToolBatchCompletion: Codable, Equatable, Sendable {
    public let batchID: String
    public let runID: String
    public let orderedResults: [HostToolResult]
}
```

Define:

```swift
public protocol ToolBatchExecuting: Sendable {
    func execute(_ batch: HostToolBatch) async -> HostToolBatchCompletion
    func cancel(batchID: String) async
}
```

Tests cover ten-call concurrency, stable order, echoed batch/run identity,
unknown tools, same call ID in two batches, and cancellation before a late PID
registration.

Run:

```bash
swift test --package-path local-ios-agent/toolkit \
  --filter ToolBatchExecutingContractTests
```

Expected: FAIL because the batch values/protocol do not exist.

- [ ] **Step 2: Migrate iSH and product-visible filesystem code**

Copy the listed iSH, terminal, browser, rootfs, MCP, default-mount, and native
offload source into the matching `ThirdParty/OpenMinis` directories. Keep
Objective-C/C source in the `LocalAgentApp` target and import it through the
single bridging header.

Rename product-visible paths and schemes:

```text
/var/minis/                  → /var/localagent/
minis://                     → localagent://
Library/MinisChat/           → Library/LocalAgent/
Minis App / MinisApp         → LocalAgent
```

Do not rename internal iSH C symbols or donor types when product identity is
not exposed.

- [ ] **Step 3: Implement the virtual path boundary**

```swift
enum FileAccess: String, Codable, Sendable {
    case read
    case write
}

enum ResolvedFileBackend: Sendable {
    case guestRootfs(linuxPath: String)
    case hostMount(mount: ToolFileResolver.HostMount, localURL: URL)
}

struct ResolvedToolFile: Sendable {
    let toolPath: String
    let backend: ResolvedFileBackend
    let access: FileAccess
}

struct ToolFileResolver: Sendable {
    enum HostMount: String, Sendable {
        case skills, shared, attachments, mounts
    }

    func resolve(
        _ toolPath: String,
        access: FileAccess
    ) throws -> ResolvedToolFile
}
```

The resolver accepts normalized absolute Linux paths and chooses exactly one
backend:

```text
/tmp, /root, /usr, and every other ordinary guest path
  → iSH rootfs/fakefs and guest syscall semantics

/var/localagent/skills
/var/localagent/shared
/var/localagent/attachments
/var/localagent/mounts
  → Swift-managed host mounts
```

Guest paths retain the complete Linux filesystem surface. Resolve them
through the migrated iSH rootfs/session implementation; allow symbolic links
that remain inside the guest filesystem and apply guest Unix permissions.

For the four host namespaces, map inside Swift, apply the declared mount
read/write policy, and reject traversal or a symbolic-link escape from that
specific mount. Reject unknown `/var/localagent/<namespace>` values. Neither
backend returns a host path to Rust or embeds one in a tool result.

Tests cover:

```text
/tmp/result.txt                              accepted guest read/write
/root/.config/tool.json                     accepted guest read/write
/usr/bin/env                                accepted guest read
/var/localagent/skills/demo/SKILL.md       accepted read
/var/localagent/skills/../shared/secret    rejected traversal
symlink from a Skill into App Group secret rejected
write to a read-only /var/localagent/mounts entry rejected
guest symlink that remains inside rootfs    accepted
guest symlink that escapes guest rootfs     rejected
```

- [ ] **Step 4: Fix cancellation ownership before running tools**

Implement:

```swift
actor ToolCallCancellationRegistry {
    struct Entry {
        var runID: String
        var cancel: @Sendable () async -> Void
        var pids: Set<Int32>
    }

    private var entriesByBatch: [String: [String: Entry]] = [:]
    private var runIDByBatch: [String: String] = [:]
    private var cancelledBatchIDs: Set<String> = []
}
```

The outer key is `batchID`, the inner key is `callID`. `beginBatch` happens
before child tasks. Registering a cancel handle or PID after the batch was
cancelled immediately invokes/cancels it. `finishBatch` removes the batch.

Implement one run-scoped detector registry:

```swift
final class ToolLoopDetectorRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var detectorsByRunID: [String: ToolLoopDetector] = [:]

    func detector(for runID: String) -> ToolLoopDetector
    func remove(runID: String)
}
```

There is no executor-global detector and no Rust detector.

- [ ] **Step 5: Extract the final batch executor directly**

`OpenMinisToolBatchExecutor` conforms to `ToolBatchExecuting` and reuses donor
argument repair, preflight, iSH/file/browser/MCP/media/offload dispatch:

```swift
func execute(_ batch: HostToolBatch) async -> HostToolBatchCompletion {
    await cancellationRegistry.beginBatch(
        batchID: batch.batchID,
        runID: batch.runID
    )
    let ordered = await executeAtMostTenInParallel(batch)
    recordDetectorHistoryInInputOrder(ordered, runID: batch.runID)
    await cancellationRegistry.finishBatch(batchID: batch.batchID)
    return HostToolBatchCompletion(
        batchID: batch.batchID,
        runID: batch.runID,
        orderedResults: ordered
    )
}
```

Each child checks `ToolLoopDetector` immediately before dispatch and writes
into its indexed result slot. Only after all children rejoin does the executor
record results in original call order. Do not mutate `AIChatViewModel.messages`
or `ChatStore`.

Change PID reporting to:

```swift
onProcessStarted: { batchID, callID, pid in
    await cancellationRegistry.record(
        pid: pid,
        batchID: batchID,
        callID: callID
    )
}
```

- [ ] **Step 6: Export one model-visible schema catalog**

`OpenMinisToolDefinitionSnapshotProvider` is the only Swift source for
OpenMinis tool `name`, `description`, and JSON object schema. It contains no
execution mode. The executor and later Rust snapshot consume the same ordered
list.

Keep only native OS permission prompts and deterministic security preflight in
Swift. Ordinary iSH commands do not receive a per-command approval step. A
denied OS permission or failed preflight is an ordered `HostToolResult` with
`isError == true`, not a Rust approval state.

- [ ] **Step 7: Preserve the real iSH security boundary**

In Settings and first use, disclose that guest `curl`, `wget`, `apk`, DNS, and
sockets do not pass through `LocalAgentLLMCloud` egress controls. Keep raw
networking enabled. Add an architecture test that rejects API key/OAuth names
from iSH environment construction and tool-result serialization.

- [ ] **Step 8: Run focused tests**

```bash
swift test --package-path local-ios-agent/toolkit \
  --filter ToolBatchExecutingContractTests
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -destination "platform=iOS Simulator,id=$LOCAL_AGENT_PHASE5_IPHONE_UDID" \
  -derivedDataPath /private/tmp/localagent-openminis-task3 \
  -only-testing:LocalAgentAppTests/OpenMinisToolBatchExecutorTests \
  -only-testing:LocalAgentAppTests/ToolCallCancellationRegistryTests \
  -only-testing:LocalAgentAppTests/ToolFileResolverTests
```

Expected: PASS.

- [ ] **Step 9: Update manifest and commit**

```markdown
## iSH, filesystem, browser, MCP, and tools

| OpenMinis source | LocalAgent target | Xcode target/resource/build phase | License |
| --- | --- | --- | --- |
| `src/ios/iSH`, `src/ios/Agent/ISH`, `src/ios/Agent/Shell` | `LocalAgentApp/ThirdParty/OpenMinis/ISH` | `LocalAgentApp` Sources | GPLv3/iSH notices |
| `src/ios/Agent/BrowserUse`, `src/ios/Views/MCP` | `LocalAgentApp/ThirdParty/OpenMinis/Tools` | `LocalAgentApp` Sources | GPLv3 |
| `src/ios/NativeOffloads` | `LocalAgentApp/ThirdParty/OpenMinis/Tools/NativeOffloads` | `LocalAgentApp` Sources | GPLv3 |
| `src/ios/default_mount` | `LocalAgentApp/ThirdParty/OpenMinis/Resources/default_mount` | Copy Bundle Resources | GPLv3 |
| `src/ios/Views/Rootfs` | `LocalAgentApp/ThirdParty/OpenMinis/UI/Rootfs` | `LocalAgentApp` Sources | GPLv3 |
```

```bash
git add local-ios-agent/apps/LocalAgentApp \
  local-ios-agent/toolkit \
  local-ios-agent/docs/openminis-migration-manifest.md
git commit -m "feat: migrate OpenMinis tools and iSH execution"
```

---

### Task 4: Migrate File-based Skills and Ordered Markdown Prompt Documents

**Files:**

- Copy donor `src/ios/Agent/Session/SkillStore.swift`
- Copy donor `src/ios/Views/Skills/SkillsManagementView.swift`
- Copy donor `src/ios/Views/Chat/SessionSkillsView.swift`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/ThirdParty/OpenMinis/Skills/PromptDocumentStore.swift`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/ThirdParty/OpenMinis/Skills/PromptDocumentsSettingsView.swift`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/RustAgentInputSnapshotProvider.swift`
- Create: `local-ios-agent/toolkit/Sources/LocalAgentBridge/TranscriptDTOs.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/App/AppShellView.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj/project.pbxproj`
- Test: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Skills/SkillStoreMigrationTests.swift`
- Test: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Skills/PromptDocumentStoreTests.swift`
- Test: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Runtime/RustAgentInputSnapshotProviderTests.swift`
- Test: `local-ios-agent/toolkit/Tests/LocalAgentBridgeTests/RunStartSnapshotDTOTests.swift`

**Interfaces:**

- Consumes: Task 3 tool-schema provider and two-domain tool file resolver.
- Produces: exact Swift `RunStartSnapshotDTO` used by Task 6 commands and
  frozen by the Rust run.

- [ ] **Step 1: Define the exact snapshot DTOs and cross-field tests**

```swift
public struct PromptDocumentSnapshotDTO: Codable, Equatable, Sendable {
    public let id: String
    public let source: String
    public let markdown: String
}

public struct RustSkillDescriptorDTO: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let location: String
    public let enabled: Bool
}

public struct ToolDefinitionSnapshotDTO: Codable, Equatable, Sendable {
    public let name: String
    public let description: String
    public let inputSchema: CanonicalJSONValue
}

public struct RunStartSnapshotDTO: Codable, Equatable, Sendable {
    public let orderedPromptDocuments: [PromptDocumentSnapshotDTO]
    public let skillDescriptors: [RustSkillDescriptorDTO]
    public let orderedToolDefinitions: [ToolDefinitionSnapshotDTO]
    public let snapshotDigest: String
}
```

Coding keys use the Rust snake-case names. Digest domain is
`run-start-snapshot:v1` and excludes only `snapshot_digest`.

Tests reject more than 20 descriptors, a non-object tool schema, duplicate
tool names, any host absolute path, and a changed field after digesting.

- [ ] **Step 2: Migrate SkillStore as the sole product store**

Keep donor file, directory, URL, archive, `.skill`, and `.zip` imports;
parsing; validation; edit; enable/disable; session overrides; bundled files;
iSH visibility; and eligible global non-secret sync hooks. Session overrides
remain local while canonical conversations do not sync.

Change every tool-visible root to:

```text
/var/localagent/skills/<skill-id>/SKILL.md
```

Add:

```swift
func rustDescriptors(for conversationStreamID: String?) throws
    -> [RustSkillDescriptorDTO]
```

It applies the existing session override, keeps stable order, returns at most
20 enabled descriptors, and never returns the `SKILL.md` body or host path.
Delete `skillPromptFragment` from the migrated production source.

- [ ] **Step 3: Preserve Claude-style progressive disclosure**

Tests prove:

1. initial snapshot contains only descriptor metadata;
2. the selected descriptor location is read through Task 3 `file_read`;
3. `SKILL.md` becomes an ordinary tool result;
4. `scripts/`, `references/`, and `assets/` are untouched until the Skill
   instructions reference them;
5. the host container/App Group path never enters Rust, logs, or results.

Do not add a Skill loader, Skill execution state, second Skill database, or
recursive preloader in Rust or Swift.

- [ ] **Step 4: Add the Markdown prompt-document store**

```swift
struct PromptDocumentRecord: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var markdown: String
    var isEnabled: Bool
    var sortOrder: Int
}
```

Use `FileManager`, `Codable`, the native document picker, and atomic file
writes. Support import, edit, reorder, enable/disable, and removal. Do not add
a template engine, prompt graph, or another package.

- [ ] **Step 5: Assemble one immutable run-start snapshot**

`RustAgentInputSnapshotProvider` reads ordered enabled prompt documents,
Skill descriptors, and Task 3 tool definitions once:

```swift
func snapshot(
    conversationStreamID: String?
) throws -> RunStartSnapshotDTO
```

The provider computes one canonical digest. It does not render a system
prompt, read Skill bodies, inject Memory, select provider fallback, or include
credentials.

- [ ] **Step 6: Register explicit Xcode membership and run focused suites**

Add every new Skill/Prompt production file to the `LocalAgentApp` Sources
phase and every new App test to the `LocalAgentAppTests` Sources phase.
Register any imported Skill UI resources in Copy Bundle Resources. Confirm
the package products already introduced by Tasks 1–3 are linked to the exact
target that imports them; do not add duplicate package references.

```bash
swift test --package-path local-ios-agent/toolkit \
  --filter RunStartSnapshotDTOTests
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -destination "platform=iOS Simulator,id=$LOCAL_AGENT_PHASE5_IPHONE_UDID" \
  -derivedDataPath /private/tmp/localagent-openminis-task4 \
  -only-testing:LocalAgentAppTests/SkillStoreMigrationTests \
  -only-testing:LocalAgentAppTests/PromptDocumentStoreTests \
  -only-testing:LocalAgentAppTests/RustAgentInputSnapshotProviderTests
```

Expected: PASS.

- [ ] **Step 7: Update manifest and commit**

```markdown
## Skills and prompt documents

| OpenMinis source | LocalAgent target | Xcode target/resource/build phase | License |
| --- | --- | --- | --- |
| `src/ios/Agent/Session/SkillStore.swift` | `LocalAgentApp/ThirdParty/OpenMinis/Skills/SkillStore.swift` | `LocalAgentApp` Sources | GPLv3 |
| `src/ios/Views/Skills/SkillsManagementView.swift` | `LocalAgentApp/ThirdParty/OpenMinis/Skills/SkillsManagementView.swift` | `LocalAgentApp` Sources | GPLv3 |
| `src/ios/Views/Chat/SessionSkillsView.swift` | `LocalAgentApp/ThirdParty/OpenMinis/Skills/SessionSkillsView.swift` | `LocalAgentApp` Sources | GPLv3 |
```

```bash
git add local-ios-agent/apps/LocalAgentApp \
  local-ios-agent/toolkit \
  local-ios-agent/docs/openminis-migration-manifest.md
git commit -m "feat: migrate progressive Skills and prompt documents"
```

---

### Task 5: Migrate Provider/OAuth UX and Integrate Local Model Selection

**Files:**

- Copy selected donor `src/ios/Providers/` product models, configuration
  stores, OAuth managers, and model metadata
- Copy donor `src/ios/Views/Providers/`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/ThirdParty/OpenMinis/Providers/OpenMinisProviderConfigurationAdapter.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Models/ModelCenterView.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Models/ModelCenterViewModel.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Composition/AppModelCenterClient.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj/project.pbxproj`
- Modify: `local-ios-agent/toolkit/Sources/LocalAgentLLMCloud/CloudModelDiscoveryService.swift`
- Create: `local-ios-agent/toolkit/Sources/LocalAgentLLMCloud/OAuthHTTPClient.swift`
- Modify: `local-ios-agent/toolkit/Sources/LocalAgentLLMCloud/CloudHTTPTransport.swift`
- Modify: `local-ios-agent/toolkit/Sources/LocalAgentLLMCloud/ProviderProfile.swift`
- Test: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Providers/OpenMinisProviderConfigurationAdapterTests.swift`
- Test: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Providers/UnifiedModelPickerTests.swift`
- Test: `local-ios-agent/toolkit/Tests/LocalAgentLLMCloudTests/OpenMinisProviderProductMappingTests.swift`
- Test: `local-ios-agent/toolkit/Tests/LocalAgentLLMCloudTests/OAuthHTTPClientTests.swift`

**Interfaces:**

- Consumes: existing `ProviderProfileStore`, credential vault,
  `CloudModelDiscoveryService`, and C++ local-model product state.
- Produces: product configuration and selection only. Task 11 adds actual
  per-run generation/fallback execution.

- [ ] **Step 1: Write the provider product compatibility table**

Add table-driven tests for:

| OpenMinis type | LocalAgent generation codec | Credential owner |
| --- | --- | --- |
| `openAI` | OpenAI Chat Completions | Swift secure store |
| `openAIResponses` | OpenAI Responses | Swift secure store |
| `anthropic` | Anthropic Messages | Swift secure store |
| `gemini` | Gemini Interactions | Swift secure store |
| `openRouter` | OpenAI-compatible preset | Swift secure store |
| `xAI` | existing `XAIAdapter` | Swift secure store/OAuth |
| `kimiCode` | OpenAI-compatible preset | Swift OAuth |
| `antigravity` | Cloud Code envelope around Gemini semantics | Swift OAuth |
| `unsupported` | reject before network | none |

Tests first run donor request/stream fixtures through existing LocalAgent
codecs. OpenRouter and Kimi must not create provider-named generation
adapters. Antigravity's distinct request/response envelope is the only
pre-proven dedicated codec candidate.

- [ ] **Step 2: Migrate product records and UI, not agent network clients**

Keep:

- provider instances and unsupported-type round-trip;
- model groups and fallback order;
- API Key/OAuth/Base URL/`/v1`/protocol-mode settings;
- OAuth login/refresh/logout product behavior;
- custom model, discovery, quick-test, and onboarding UI.

Do not copy `LLMProviderFactory` or donor `AgentProvider` implementations into
the production generation path. Copy a donor network file only when its codec
or OAuth semantics is ported into `LocalAgentLLMCloud` and the donor executor
is removed.

- [ ] **Step 3: Keep every model HTTP request on LocalAgentLLMCloud**

Route model discovery and quick tests through existing
`CloudModelDiscoveryService`/`CloudLLMRuntime`. Route OAuth token requests
through `OAuthHTTPClient`, which uses the same `CloudHTTPTransport` policy
surface with OAuth endpoint profiles. `ASWebAuthenticationSession` remains
the browser UI.

Add a source test that rejects `URLSession.shared`, `.data(for:)`, and
`.bytes(for:)` under the migrated `ThirdParty/OpenMinis/Providers` directory.

- [ ] **Step 4: Keep credentials in one Swift boundary**

`ProviderConfigStore` persists only non-secret configuration IDs and product
metadata. API keys/OAuth tokens use the existing Keychain-backed
`ProviderCredentialStore`/vault. Tests decode the Rust snapshot and host
command values and assert no secret field or token value is present.

- [ ] **Step 5: Merge cloud and local choices in the migrated picker**

Extend `UnifiedModelPicker` to show:

```swift
enum ProductModelSelection: Equatable, Sendable {
    case cloud(providerConfigurationID: String, modelID: String)
    case local(engineID: String, modelID: String)
}
```

Cloud selection writes Swift product metadata. Local selection reuses
`LocalModelStore`, download/installation UI, compatibility checks, and the C++
runtime path. Neither choice starts a model request in this task.

- [ ] **Step 6: Register explicit Xcode membership and run focused suites**

Add the migrated provider production/UI files to `LocalAgentApp` Sources and
the two App tests to `LocalAgentAppTests` Sources. Add provider assets such as
`models-dev-api.json` to Copy Bundle Resources. Verify the
`LocalAgentLLMCloud` and `LocalAgentLLMLocal` package products are linked once
to `LocalAgentApp`; package-owned files and tests remain in SwiftPM targets.

```bash
swift test --package-path local-ios-agent/toolkit \
  --filter OpenMinisProviderProductMappingTests
swift test --package-path local-ios-agent/toolkit \
  --filter OAuthHTTPClientTests
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -destination "platform=iOS Simulator,id=$LOCAL_AGENT_PHASE5_IPHONE_UDID" \
  -derivedDataPath /private/tmp/localagent-openminis-task5 \
  -only-testing:LocalAgentAppTests/OpenMinisProviderConfigurationAdapterTests \
  -only-testing:LocalAgentAppTests/UnifiedModelPickerTests \
  -only-testing:LocalAgentAppTests/ModelCenterViewModelTests
```

Expected: PASS.

- [ ] **Step 7: Update manifest and commit**

```markdown
## Providers, OAuth, and model selection

| OpenMinis source | LocalAgent target | Xcode target/resource/build phase | License |
| --- | --- | --- | --- |
| `src/ios/Providers` product/config/OAuth files | `LocalAgentApp/ThirdParty/OpenMinis/Providers` | `LocalAgentApp` Sources | GPLv3 |
| `src/ios/Views/Providers` | `LocalAgentApp/ThirdParty/OpenMinis/UI/Providers` | `LocalAgentApp` Sources | GPLv3 |
| `src/ios/Resources/models-dev-api.json` | `LocalAgentApp/ThirdParty/OpenMinis/Resources/models-dev-api.json` | Copy Bundle Resources | GPLv3 data provenance |
```

```bash
git add local-ios-agent/apps/LocalAgentApp \
  local-ios-agent/toolkit \
  local-ios-agent/docs/openminis-migration-manifest.md
git commit -m "feat: migrate provider UX and local model selection"
```

---

### Task 6: Make Rust the Idempotent Transcript Writer and Add Replayable Projection

**Files:**

- Create: `local-ios-agent/rust-core/src/agent_input/mod.rs`
- Create: `local-ios-agent/rust-core/src/agent_input/snapshot.rs`
- Create: `local-ios-agent/rust-core/src/conversation/command.rs`
- Create: `local-ios-agent/rust-core/src/conversation/command_receipt.rs`
- Create: `local-ios-agent/rust-core/src/conversation/command_service.rs`
- Create: `local-ios-agent/rust-core/src/conversation/active_runs.rs`
- Create: `local-ios-agent/rust-core/src/conversation/projection_event.rs`
- Create: `local-ios-agent/rust-core/src/conversation/projection_subscription.rs`
- Move: `local-ios-agent/rust-core/src/memory/event_store.rs` →
  `local-ios-agent/rust-core/src/storage/conversation_event_store.rs`
- Move: `local-ios-agent/rust-core/src/memory/in_memory.rs` →
  `local-ios-agent/rust-core/src/storage/in_memory_conversation.rs`
- Split: `local-ios-agent/rust-core/src/memory/sqlite.rs` →
  `local-ios-agent/rust-core/src/storage/sqlite_conversation.rs`
- Modify: `local-ios-agent/rust-core/src/conversation/mod.rs`
- Modify: `local-ios-agent/rust-core/src/core/event.rs`
- Modify: `local-ios-agent/rust-core/src/core/runtime.rs`
- Modify: `local-ios-agent/rust-core/src/storage/mod.rs`
- Modify: `local-ios-agent/rust-core/src/lib.rs`
- Modify: `local-ios-agent/rust-core/src/ffi_bridge.rs`
- Modify: `local-ios-agent/rust-core/tests/contract.rs`
- Modify: `local-ios-agent/rust-core/tests/integration.rs`
- Modify: `local-ios-agent/toolkit/Sources/LocalAgentBridge/TranscriptDTOs.swift`
- Modify: `local-ios-agent/toolkit/Sources/LocalAgentBridge/ConversationBridgeClient.swift`
- Modify: `local-ios-agent/toolkit/Sources/LocalAgentBridge/RustRuntimeClient.swift`
- Modify: `local-ios-agent/toolkit/Sources/LocalAgentBridge/RustAgentOSBridgeGateway.swift`
- Modify: `local-ios-agent/toolkit/Sources/LocalAgentBridge/MockRuntimeClient.swift`
- Modify: `local-ios-agent/toolkit/Sources/CLocalAgentRuntime/include/CLocalAgentRuntime.h`
- Test: `local-ios-agent/rust-core/tests/contract/conversation_command.rs`
- Test: `local-ios-agent/rust-core/tests/integration/conversation_projection.rs`
- Test: `local-ios-agent/toolkit/Tests/LocalAgentBridgeTests/ConversationCommandTests.swift`

**Interfaces:**

- Consumes: Task 4 `RunStartSnapshotDTO` JSON shape and existing canonical
  conversation/runtime events.
- Produces: the only transcript command path and
  `observeTranscriptProjections(subscription_id, stream, cursor)` for Task 12.

- [ ] **Step 1: Write failing Rust command/idempotency tests**

Register the test before running it:

```rust
// rust-core/tests/contract.rs
#[path = "contract/conversation_command.rs"]
mod conversation_command;
```

Mirror Task 4's exact snapshot:

```rust
pub struct PromptDocumentSnapshot {
    pub id: String,
    pub source: String,
    pub markdown: String,
}

pub struct SkillDescriptor {
    pub id: String,
    pub name: String,
    pub description: String,
    pub location: String,
    pub enabled: bool,
}

pub struct ToolDefinitionSnapshot {
    pub name: String,
    pub description: String,
    pub input_schema: serde_json::Value,
}

pub struct RunStartSnapshot {
    pub ordered_prompt_documents: Vec<PromptDocumentSnapshot>,
    pub skill_descriptors: Vec<SkillDescriptor>,
    pub ordered_tool_definitions: Vec<ToolDefinitionSnapshot>,
    pub snapshot_digest: String,
}
```

Define:

```rust
pub struct TranscriptAttachmentReference {
    pub attachment_id: String,
    pub display_name: String,
    pub media_type: String,
    pub modality: String,
    pub content_digest: String,
}

#[serde(tag = "kind", rename_all = "snake_case")]
pub enum TranscriptCommand {
    Send {
        request_id: String,
        conversation_stream_id: String,
        client_message_id: String,
        text: String,
        attachments: Vec<TranscriptAttachmentReference>,
        run_start_snapshot: RunStartSnapshot,
    },
    RetryFrom {
        request_id: String,
        conversation_stream_id: String,
        anchor_event_id: String,
        run_start_snapshot: RunStartSnapshot,
    },
    EditMessage {
        request_id: String,
        conversation_stream_id: String,
        target_event_id: String,
        replacement_text: String,
        replacement_attachments: Vec<TranscriptAttachmentReference>,
        run_start_snapshot: RunStartSnapshot,
    },
    DeleteMessage {
        request_id: String,
        conversation_stream_id: String,
        target_event_id: String,
    },
    ClearConversation {
        request_id: String,
        conversation_stream_id: String,
    },
    CreateBranch {
        request_id: String,
        conversation_stream_id: String,
        anchor_event_id: String,
        new_conversation_stream_id: String,
    },
    ArchiveConversation {
        request_id: String,
        conversation_stream_id: String,
    },
    DeleteConversation {
        request_id: String,
        conversation_stream_id: String,
    },
}
```

Tests prove:

- same `(conversation_stream_id, request_id)` and payload returns the first
  result;
- same key with a changed payload returns
  `conversation.idempotency_conflict`;
- duplicate `Send` writes one user event and schedules one run;
- same stream rejects a second active mutation with `conversation_busy`;
- different streams do not block;
- retry/edit/delete/clear/branch/archive/delete are append-only events.

Run:

```bash
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test contract -- --list | rg '^conversation_command::'
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test contract conversation_command
```

Expected: FAIL because the command service does not exist.

- [ ] **Step 2: Implement the command receipt in the same transaction**

Use digest domain `transcript-command:v1` over the complete tagged command.
Persist:

```rust
pub struct TranscriptCommandResult {
    pub conversation_stream_id: String,
    pub accepted_sequence: u64,
    pub run_id: Option<String>,
}

pub struct TranscriptCommandReceipt {
    pub request_id: String,
    pub command_digest: String,
    pub outcome: StoredTranscriptCommandOutcome,
}
```

SQLite schema:

```sql
create table if not exists conversation_command_receipt (
    conversation_stream_id text not null,
    request_id text not null,
    command_digest text not null,
    outcome_json text not null,
    primary key (conversation_stream_id, request_id)
);
```

Look up the receipt before checking active-run admission. Store accepted and
deterministic rejected outcomes such as `conversation_busy`; do not store
transient I/O/process errors. Commit receipt and canonical events in the same
SQLite/unit-of-work transaction. Command results contain acknowledgement
metadata only, never projections.

- [ ] **Step 3: Move conversation storage out of Memory**

Use `git mv` for the event-store trait and in-memory store. Extract only
conversation tables/methods from `memory/sqlite.rs` into
`storage/sqlite_conversation.rs`; keep one database.

Add the canonical atomic append primitive:

```rust
fn append_transaction(
    &mut self,
    conversation_stream_id: &str,
    expected_next_sequence: u64,
    events: Vec<RuntimeEvent>,
) -> Result<Vec<RuntimeEvent>, AgentError>;
```

It assigns consecutive stream sequences and appends all or none. Update every
production import in this commit and leave no `memory` compatibility re-export
for conversation storage.

- [ ] **Step 4: Write failing replay/feed/cancellation tests**

Register:

```rust
// rust-core/tests/integration.rs
#[path = "integration/conversation_projection.rs"]
mod conversation_projection;
```

```rust
pub struct TranscriptProjectionEvent {
    pub conversation_stream_id: String,
    pub sequence: u64,
    pub event_id: String,
    pub kind: TranscriptProjectionKind,
    pub payload: serde_json::Value,
}

pub struct ObserveTranscriptProjectionsRequest {
    pub subscription_id: String,
    pub conversation_stream_id: String,
    pub after_sequence: u64,
}
```

Tests prove:

- two runs in one conversation share monotonically increasing stream sequence;
- each other conversation starts at sequence 1;
- reconnect after sequence 4 receives 5 onward;
- archive/delete events with no run ID are delivered;
- already-applied sequence is a no-op;
- a gap triggers replay rather than a cursor jump;
- cancelling an idle subscription wakes its receiver and removes its listener;
- cancelling one subscription does not cancel another for the same stream.

Run:

```bash
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test integration -- --list | rg '^conversation_projection::'
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test integration conversation_projection
```

Expected: FAIL because the feed does not exist.

- [ ] **Step 5: Implement register-before-query replay then live**

`observe_transcript_projections`:

1. registers `(subscription_id, conversation_stream_id, wake_handle)`;
2. queries stored canonical events after the cursor;
3. emits them in strict sequence;
4. treats a live notification only as a wake-up;
5. re-queries storage after the last emitted sequence;
6. ends with an error on listener overflow/closure.

Map internal non-row events to `CursorAdvance` so projection sequence remains
gap-free without a second counter.

`cancel_transcript_projection_subscription` sets the subscription cancelled,
wakes an idle receiver, unregisters the listener, and makes the blocking FFI
observation return. Cancellation is idempotent.

- [ ] **Step 6: Add only the required bridge endpoints**

Extend the existing operation enum:

```swift
case transcriptCommand = "transcript_command"
case observeTranscriptProjections = "observe_transcript_projections"
case cancelTranscriptProjectionSubscription =
    "cancel_transcript_projection_subscription"
```

Mirror `TranscriptAttachmentReference`, every tagged `TranscriptCommand`
case, `TranscriptCommandResult`, `TranscriptProjectionEvent`, and
`ObserveTranscriptProjectionsRequest` in `TranscriptDTOs.swift`. Use explicit
snake-case coding keys and the same required fields; do not add a generic
dictionary command body.

Expose:

```swift
func submitTranscriptCommand(
    _ command: TranscriptCommandDTO
) async throws -> TranscriptCommandResultDTO

func observeTranscriptProjections(
    subscriptionID: String,
    conversationStreamID: String,
    afterSequence: UInt64
) -> AsyncThrowingStream<TranscriptProjectionEventDTO, Error>

func cancelTranscriptProjectionSubscription(
    subscriptionID: String
) async
```

Generalize the existing JSON callback wrapper. `onTermination` invokes the C
cancellation endpoint from a separate task before terminating the callback
box; it must not wait for another projection event.

- [ ] **Step 7: Verify cross-language behavior**

```bash
cargo fmt --manifest-path local-ios-agent/rust-core/Cargo.toml -- --check
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test contract conversation_command
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test integration conversation_projection
swift test --package-path local-ios-agent/toolkit \
  --filter ConversationCommandTests
```

Expected: PASS. The idle cancellation test observes both Rust listener count
and Swift detached observation-task count return to zero without publishing an
event.

- [ ] **Step 8: Commit**

```bash
git add local-ios-agent/rust-core/src \
  local-ios-agent/rust-core/tests \
  local-ios-agent/toolkit/Sources/LocalAgentBridge \
  local-ios-agent/toolkit/Sources/CLocalAgentRuntime \
  local-ios-agent/toolkit/Tests/LocalAgentBridgeTests
git commit -m "feat: make Rust own transcript commands and projection"
```

---

### Task 7: Assemble Prompt, Context, Skills, and Minimal Memory Inputs in Rust

**Files:**

- Create: `local-ios-agent/rust-core/src/prompt/snapshot.rs`
- Create: `local-ios-agent/rust-core/src/skills/mod.rs`
- Modify: `local-ios-agent/rust-core/src/agent_input/snapshot.rs`
- Modify: `local-ios-agent/rust-core/src/prompt/mod.rs`
- Modify: `local-ios-agent/rust-core/src/context/assembler.rs`
- Modify: `local-ios-agent/rust-core/src/context/model_input.rs`
- Modify: `local-ios-agent/rust-core/src/memory/provider.rs`
- Modify: `local-ios-agent/rust-core/src/memory/mod.rs`
- Modify: `local-ios-agent/rust-core/src/lib.rs`
- Modify: `local-ios-agent/rust-core/tests/contract.rs`
- Modify: `local-ios-agent/rust-core/tests/integration.rs`
- Test: `local-ios-agent/rust-core/tests/contract/agent_inputs.rs`
- Test: `local-ios-agent/rust-core/tests/integration/prompt_skill_context.rs`

**Interfaces:**

- Consumes: Task 6 accepted/frozen `RunStartSnapshot` and existing Context,
  Prompt, conversation, canonical digest, and `MemoryProvider`.
- Produces: deterministic complete `ModelRequest` input for Task 8.

- [ ] **Step 1: Write failing snapshot and Context tests**

Register both test modules first:

```rust
// rust-core/tests/contract.rs
#[path = "contract/agent_inputs.rs"]
mod agent_inputs;

// rust-core/tests/integration.rs
#[path = "integration/prompt_skill_context.rs"]
mod prompt_skill_context;
```

Tests prove:

- Rust and Swift compute the same `run-start-snapshot:v1` digest;
- ordered prompt documents stay in Swift order;
- required Prompt/Context segments appear exactly once;
- a maximum of 20 enabled Skill descriptors is accepted;
- full `SKILL.md`, scripts, references, and assets are absent;
- descriptor locations must start with `/var/localagent/skills/` and end in
  `/SKILL.md`;
- duplicate tool names and non-object schemas fail before a model call;
- the initial model request includes descriptors and tool schemas exactly once;
- a later ordinary `file_read` result can contain the chosen Skill body;
- after an atomic tool-round commit, the next model request includes those
  tool calls/results from canonical conversation;
- each model turn reruns sensitivity filtering, budget calculation, required
  segment validation, and compaction;
- Prompt documents, Skill descriptors, and tool definitions remain the frozen
  run-start versions while Context changes between turns;
- there is one `MemoryProvider` trait with recall and completed-turn remember
  hooks, one test fake, and no production implementation/wire toggle in this
  phase.

Run:

```bash
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test contract -- --list | rg '^agent_inputs::'
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test integration -- --list | rg '^prompt_skill_context::'
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test contract agent_inputs
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test integration prompt_skill_context
```

Expected: FAIL.

- [ ] **Step 2: Validate only descriptors and ordered schemas**

```rust
pub const MAX_SKILL_DESCRIPTORS: usize = 20;

pub fn validate_skill_descriptors(
    descriptors: &[SkillDescriptor],
) -> Result<(), AgentError>;
```

Do not add `SkillCatalog`, `SkillDocument`, a Skill loader, or a Rust file
resolver. Rust treats `location` as opaque after validating the virtual prefix;
Task 3 resolves it when `file_read` executes.

- [ ] **Step 3: Compile the complete Prompt in Rust**

For every model turn:

1. load the frozen run snapshot;
2. project the current canonical conversation branch;
3. compile ordered prompt Markdown;
4. add descriptor metadata, not Skill bodies;
5. contribute Context segments through existing sensitivity/budget policy;
6. compact through the existing Context path;
7. attach the frozen ordered tool definitions.

Only ordered Prompt documents, Skill descriptors, and tool definitions are
frozen by `RunStartSnapshot`. The complete Context, current conversation,
newly committed tool results, budget, sensitivity filtering, and compaction
output are rebuilt for every `ModelRuntime::generate` call.

Do not call any Swift `SystemPromptBuilder`, `baseSystemPrompt`,
`skillPromptFragment`, MCP prompt fragment, Memory prompt fragment, or
`makeAgentTools`.

- [ ] **Step 4: Evolve the existing MemoryProvider only**

Keep the existing provider ID, contribution, retrieval trace, readiness, and
result types. Evolve the same trait; do not add a parallel memory interface:

```rust
pub struct MemoryQuery {
    pub conversation_stream_id: String,
    pub text: String,
    pub limit: usize,
}

pub struct CompletedTurnMemoryInput {
    pub conversation_stream_id: String,
    pub user_text: String,
    pub assistant_text: String,
    pub tool_results: Vec<serde_json::Value>,
}

pub struct MemoryProviderError {
    pub code: String,
    pub message: String,
}

pub trait MemoryProvider: std::fmt::Debug + Send + Sync {
    fn provider_id(&self) -> MemoryProviderId;
    fn recall(&self, query: &MemoryQuery) -> MemoryQueryResult;
    fn remember_completed_turn(
        &self,
        input: &CompletedTurnMemoryInput,
    ) -> Result<(), MemoryProviderError>;
}
```

Keep one test fake that records both calls. A future configured provider can
be injected into Context/AgentLoop; with no production provider, neither hook
is invoked. Do not add `forget`, HTTP/SQLite/vector/graph adapters, a
`MemoryBackend` alias, or a `memory_enabled` wire field.

- [ ] **Step 5: Verify and commit**

```bash
cargo fmt --manifest-path local-ios-agent/rust-core/Cargo.toml -- --check
cargo clippy --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --all-targets -- -D warnings
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test contract agent_inputs
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test integration prompt_skill_context
git add local-ios-agent/rust-core/src \
  local-ios-agent/rust-core/tests
git commit -m "feat: assemble agent inputs and progressive Skills in Rust"
```

Expected: PASS.

---

### Task 8: Replace the Rust Agent State Machine with a Direct ReAct Loop

**Files:**

- Create: `local-ios-agent/rust-core/src/agent_loop/mod.rs`
- Create: `local-ios-agent/rust-core/src/agent_loop/contracts.rs`
- Create: `local-ios-agent/rust-core/src/agent_loop/runner.rs`
- Create: `local-ios-agent/rust-core/src/agent_loop/cancellation.rs`
- Create: `local-ios-agent/rust-core/src/tool/batch.rs`
- Modify: `local-ios-agent/rust-core/src/conversation/active_runs.rs`
- Modify: `local-ios-agent/rust-core/src/conversation/service.rs`
- Modify: `local-ios-agent/rust-core/src/storage/conversation_event_store.rs`
- Modify: `local-ios-agent/rust-core/src/storage/in_memory_conversation.rs`
- Modify: `local-ios-agent/rust-core/src/storage/sqlite_conversation.rs`
- Modify: `local-ios-agent/rust-core/src/tool/mod.rs`
- Modify: `local-ios-agent/rust-core/src/lib.rs`
- Modify: `local-ios-agent/rust-core/tests/contract.rs`
- Modify: `local-ios-agent/rust-core/tests/integration.rs`
- Test: `local-ios-agent/rust-core/tests/contract/agent_loop_contract.rs`
- Test: `local-ios-agent/rust-core/tests/integration/react_loop.rs`

**Interfaces:**

- Consumes: Task 6 canonical commands/storage and Task 7 Context builder.
- Produces: `ModelRuntime`/`ToolRuntime` traits and `AgentLoopService` used by
  Task 10 host adapters.

- [ ] **Step 1: Lock the small runtime contracts with failing tests**

Register:

```rust
// rust-core/tests/contract.rs
#[path = "contract/agent_loop_contract.rs"]
mod agent_loop_contract;

// rust-core/tests/integration.rs
#[path = "integration/react_loop.rs"]
mod react_loop;
```

```rust
pub struct ModelMessage {
    pub role: String,
    pub content: serde_json::Value,
}

pub struct ModelRequest {
    pub run_id: String,
    pub conversation_stream_id: String,
    pub system_prompt: String,
    pub ordered_messages: Vec<ModelMessage>,
    pub attachment_references: Vec<TranscriptAttachmentReference>,
    pub ordered_tool_definitions: Vec<ToolDefinitionSnapshot>,
}

pub enum ModelEvent {
    TextDelta { text: String },
    ReasoningDelta { text: String },
    ToolCallDelta {
        call_id: String,
        tool_name: String,
        arguments_fragment: String,
    },
    Usage { payload: serde_json::Value },
}

pub trait ModelEventSink {
    fn emit(&mut self, event: ModelEvent) -> Result<(), AgentLoopError>;
}

pub struct ToolCall {
    pub call_id: String,
    pub tool_name: String,
    pub arguments_json: String,
}

pub struct AssistantTurn {
    pub text: String,
    pub reasoning: String,
    pub tool_calls: Vec<ToolCall>,
    pub usage: Option<serde_json::Value>,
}

pub trait ModelRuntime: Send + Sync {
    fn generate(
        &self,
        request: ModelRequest,
        sink: &mut dyn ModelEventSink,
    ) -> Result<AssistantTurn, AgentLoopError>;

    fn cancel(&self, run_id: &str) -> Result<(), AgentLoopError>;
    fn close(&self, run_id: &str) -> Result<(), AgentLoopError>;
}

pub trait ToolRuntime: Send + Sync {
    fn execute_batch(
        &self,
        batch: ToolBatch,
    ) -> Result<ToolBatchResult, AgentLoopError>;

    fn cancel_batch(&self, batch_id: &str) -> Result<(), AgentLoopError>;
}
```

Use:

```rust
pub struct ToolBatch {
    pub batch_id: String,
    pub run_id: String,
    pub ordered_calls: Vec<ToolCall>,
}

pub struct ToolCallResult {
    pub call_id: String,
    pub tool_name: String,
    pub result: serde_json::Value,
    pub is_error: bool,
    pub data_classes: Vec<String>,
    pub highest_sensitivity: String,
}

pub struct ToolBatchResult {
    pub batch_id: String,
    pub run_id: String,
    pub ordered_results: Vec<ToolCallResult>,
}
```

Integration tests cover text-only, one two-tool ordered batch, atomic tool
round, every identity/order mismatch, two concurrent streams, one active run
per stream, and a tool failure leaving no half-round.

- [ ] **Step 2: Add the three required cancellation race tests**

Tests prove:

1. cancellation during model generation calls `ModelRuntime::cancel`;
2. cancellation after the model returns but before tool start prevents
   `execute_batch`;
3. cancellation during a tool batch calls
   `ToolRuntime::cancel_batch(active_batch_id)`.

All three commit no final/tool round. A re-entrant fake proves no Rust mutex is
held across runtime calls.

Run:

```bash
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test contract -- --list | rg '^agent_loop_contract::'
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test integration -- --list | rg '^react_loop::'
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test contract agent_loop_contract
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test integration react_loop
```

Expected: FAIL.

- [ ] **Step 3: Implement one ordinary loop**

```rust
pub const MAX_MODEL_TURNS: usize = 200;

for model_turn in 0..MAX_MODEL_TURNS {
    cancellation.check()?;
    let request = context.build_model_request(&run, model_turn)?;
    let turn = model.generate(request, events)?;
    cancellation.check()?;

    if turn.tool_calls.is_empty() {
        cancellation.commit_if_active(|| {
            transcript.commit_final_turn(&run, &turn)
        })?;
        return Ok(AgentLoopOutcome::Completed);
    }

    validate_calls(&turn.tool_calls, context.tool_definitions())?;
    let batch = ToolBatch::from_turn(&run, &turn);
    let active_batch = cancellation.begin_batch(&batch.batch_id)?;
    let result = tools.execute_batch(batch.clone())?;
    drop(active_batch);
    cancellation.check()?;
    validate_batch_result(&batch, &result)?;
    cancellation.commit_if_active(|| {
        transcript.commit_tool_round(&run, &turn, &result)
    })?;
}

Err(AgentLoopError::max_model_turns(MAX_MODEL_TURNS))
```

One model invocation is one turn; a parallel tool batch is not another turn.
There is no phase enum or configurable run limit.

- [ ] **Step 4: Use one active-run guard and one cancellation record**

`ActiveConversationRuns` maps stream ID to the active run/cancellation record.
The same stream admits at most one run; different streams remain concurrent.

```rust
pub struct RunCancellationRecord {
    pub run_id: String,
    pub token: CancellationToken,
    gate: Mutex<RunCancellationGate>,
}

struct RunCancellationGate {
    active_batch_id: Option<String>,
}
```

`request_cancel` sets the atomic token and copies `active_batch_id` while
locked, then returns. `AgentLoopService::cancel_run` releases every lock before
calling a runtime. `begin_batch` atomically rejects a cancelled run or stores
the batch ID before Swift starts.

- [ ] **Step 5: Commit complete turns atomically**

Streaming text/reasoning/tool arguments update only `ModelEventSink`. A
text-only assistant turn commits once after completion. A tool turn performs
the entire Swift batch, validates batch ID, run ID, count, call ID, tool name,
and order, then commits assistant tool calls and every result in one
`append_transaction`.

On provider/tool/validation/process failure or cancellation, commit none of
that round.

- [ ] **Step 6: Handle process loss conservatively**

On startup:

- a fresh accepted request without `run_started` may be claimed once;
- `run_started` without a terminal event becomes interrupted;
- no unknown external tool effect is automatically replayed;
- every completion/error/cancel/max-turn path releases the stream lease.

`AgentLoopService` calls `ModelRuntime::close(run_id)` exactly once in its
outer cleanup guard after every terminal outcome. This is lifecycle cleanup,
not an Agent phase or another model request.

- [ ] **Step 7: Add the architecture guard and verify**

Read `src/agent_loop` in a test and reject imports/references to:

```text
RunMachine
RunState
Approval
ToolLoopDetector
HostExecutionPhase
ResourceLifecycle
llm_contracts
host_adapter
```

Run:

```bash
cargo fmt --manifest-path local-ios-agent/rust-core/Cargo.toml -- --check
cargo clippy --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --all-targets -- -D warnings
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test contract agent_loop_contract
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test integration react_loop
```

Expected: PASS, including exactly 200 fake model calls in the max-turn test.

- [ ] **Step 8: Commit**

```bash
git add local-ios-agent/rust-core/src/agent_loop \
  local-ios-agent/rust-core/src/conversation \
  local-ios-agent/rust-core/src/storage \
  local-ios-agent/rust-core/src/tool \
  local-ios-agent/rust-core/src/lib.rs \
  local-ios-agent/rust-core/tests
git commit -m "feat: add the direct Rust ReAct loop"
```

---

### Task 9: Extend the Existing Host Envelopes for Whole Model Requests and Tool Batches

**Files:**

- Modify: `local-ios-agent/rust-core/src/llm_contracts/host_command.rs`
- Modify: `local-ios-agent/rust-core/src/llm_contracts/llm_event.rs`
- Modify: `local-ios-agent/rust-core/src/llm_contracts/mod.rs`
- Modify: `local-ios-agent/toolkit/Sources/LocalAgentLLMContracts/LLMHostCommand.swift`
- Modify: `local-ios-agent/toolkit/Sources/LocalAgentLLMContracts/LLMEventEnvelope.swift`
- Modify: `local-ios-agent/toolkit/Sources/LocalAgentLLMContracts/LLMInput.swift`
- Modify: `local-ios-agent/toolkit/Sources/LocalAgentLLMContracts/LLMToolResult.swift`
- Create fixtures:
  `local-ios-agent/toolkit/Tests/LocalAgentLLMContractsTests/Fixtures/HostV2/`
- Modify: `local-ios-agent/rust-core/tests/contract/host_llm_contracts.rs`
- Test: `local-ios-agent/toolkit/Tests/LocalAgentLLMContractsTests/HostEnvelopeV2Tests.swift`

**Interfaces:**

- Consumes: Task 8 logical model/tool values and Task 3 Swift batch values.
- Produces: schema-v2 payloads on the existing envelope/receipt transport for
  Task 10.

- [ ] **Step 1: Add identical cross-language RED fixtures**

Fixtures cover:

1. a complete model request with Rust-built system prompt, ordered messages,
   attachment references, and ordered tools;
2. one `execute_tool_batch` with two calls;
3. one `tool_batch_completed` with two results;
4. active-batch cancellation;
5. invalid command-kind/payload combinations;
6. missing/mixed batch completion;
7. mismatched envelope/completion run ID;
8. mismatched expected/completion batch ID.

Rust and Swift must compute the same canonical digest for valid fixtures and
the same error code for invalid fixtures.

Run:

```bash
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test contract host_llm_contracts
swift test --package-path local-ios-agent/toolkit \
  --filter HostEnvelopeV2Tests
```

Expected: FAIL.

- [ ] **Step 2: Version payloads, not the transport**

Add:

```rust
pub enum HostCommandKind {
    StartGeneration,
    ResumeGeneration,
    CancelGeneration,
    ExecuteToolBatch,
    CancelToolBatch,
    CloseSession,
    CapacityAvailable,
}
```

Add the exact Swift wire mirrors in `LLMInput.swift` and the event-envelope
module:

```swift
public struct HostModelMessage: Codable, Equatable, Sendable {
    public let role: String
    public let content: CanonicalJSONValue
}

public struct HostAttachmentReference: Codable, Equatable, Sendable {
    public let attachmentID: String
    public let displayName: String
    public let mediaType: String
    public let modality: String
    public let contentDigest: String
}

public struct HostToolDefinition: Codable, Equatable, Sendable {
    public let name: String
    public let description: String
    public let inputSchema: CanonicalJSONValue
}

public struct HostModelRequest: Codable, Equatable, Sendable {
    public let runID: String
    public let conversationStreamID: String
    public let systemPrompt: String
    public let orderedMessages: [HostModelMessage]
    public let attachmentReferences: [HostAttachmentReference]
    public let orderedToolDefinitions: [HostToolDefinition]
}

public enum HostModelEvent: Codable, Equatable, Sendable {
    case textDelta(String)
    case reasoningDelta(String)
    case toolCallDelta(
        callID: String,
        toolName: String,
        argumentsFragment: String
    )
    case usage(CanonicalJSONValue)
}
```

These are direct mirrors of Tasks 4, 6, and 8, with explicit snake-case
coding keys. They are provider-neutral and contain no credentials.

Extend schema-v2 `HostCommandPayload` with:

```rust
pub system_prompt: Option<String>,
pub ordered_tool_definitions: Vec<HostToolDefinition>,
pub tool_batch: Option<HostToolBatch>,
pub target_batch_id: Option<String>,
```

Keep the existing envelope ID, command sequence, payload/envelope digest,
disclosure, session handle, host epoch, and copy/acknowledgement behavior.

- [ ] **Step 3: Validate every command-kind/payload combination**

Add matching Rust and Swift `validate_for` functions:

```text
Start/ResumeGeneration
  system_prompt present
  complete messages/tools allowed
  tool_batch and target_batch_id absent

ExecuteToolBatch
  one tool_batch present
  batch.run_id == envelope.run_id
  generation fields and target_batch_id absent

CancelToolBatch
  target_batch_id present
  generation fields and tool_batch absent

CancelGeneration/CloseSession/CapacityAvailable
  all v2 optional/body fields absent
```

Reject invalid combinations as `llm.contract.command_payload_mismatch`
before dispatch or lifecycle mutation.

- [ ] **Step 4: Add one complete batch event**

Add:

```rust
pub enum LLMEventKind {
    // existing model events
    ToolBatchStarted,
    ToolBatchCompleted,
    ToolBatchFailed,
}

pub struct HostToolBatchCompletion {
    pub batch_id: String,
    pub run_id: String,
    pub ordered_results: Vec<HostToolResult>,
}
```

`LLMEventPayload` has one optional `tool_batch_completion`.
`ToolBatchCompleted` must carry exactly one completion and no text, reasoning,
tool-call, usage, model-completion, failure, or close payload. Every other
event must have `tool_batch_completion == None`.

- [ ] **Step 5: Validate events symmetrically before delivery**

Swift validates before computing/enqueueing the outgoing digest. Rust verifies
decode and digest, then calls:

```rust
payload.validate_for(kind, envelope_run_id, expected_batch_id)?;
```

This must run before receipt disposition, lifecycle transition, result-slot
mutation, or `AgentLoop` delivery. A correct digest never bypasses semantic
kind/payload validation.

- [ ] **Step 6: Preserve v1 migration compatibility and verify**

Keep old schema-v1 fixture decoding until Task 15 proves no production caller.
Use schema-specific digest domains:

```text
host-command-payload:v2
host-command-envelope:v2
llm-event-envelope:v2
```

Run the two focused suites again. Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add local-ios-agent/rust-core/src/llm_contracts \
  local-ios-agent/rust-core/tests/contract/host_llm_contracts.rs \
  local-ios-agent/toolkit/Sources/LocalAgentLLMContracts \
  local-ios-agent/toolkit/Tests/LocalAgentLLMContractsTests
git commit -m "feat: carry model requests and tool batches on host envelopes"
```

---

### Task 10: Adapt the Reliable Host Transport and Add Thin Swift Command Handlers

**Files:**

- Create: `local-ios-agent/rust-core/src/host_adapter/mod.rs`
- Move: `local-ios-agent/rust-core/src/execution/host_llm_dispatcher.rs` →
  `local-ios-agent/rust-core/src/host_adapter/dispatcher.rs`
- Move: `local-ios-agent/rust-core/src/execution/host_llm_worker.rs` →
  `local-ios-agent/rust-core/src/host_adapter/event_ingress.rs`
- Create: `local-ios-agent/rust-core/src/host_adapter/model_runtime.rs`
- Create: `local-ios-agent/rust-core/src/host_adapter/tool_runtime.rs`
- Modify: `local-ios-agent/rust-core/src/execution/mod.rs`
- Modify: `local-ios-agent/rust-core/src/ffi_bridge.rs`
- Modify: `local-ios-agent/rust-core/src/lib.rs`
- Modify: `local-ios-agent/rust-core/tests/contract.rs`
- Modify: `local-ios-agent/rust-core/tests/integration.rs`
- Create: `local-ios-agent/toolkit/Sources/LocalAgentLLMHost/ModelGenerationExecuting.swift`
- Create: `local-ios-agent/toolkit/Sources/LocalAgentLLMHost/ModelRuntimeCommandHandler.swift`
- Create: `local-ios-agent/toolkit/Sources/LocalAgentLLMHost/ToolBatchCommandHandler.swift`
- Modify: `local-ios-agent/toolkit/Sources/LocalAgentLLMHost/LLMHostCommandInbox.swift`
- Modify: `local-ios-agent/toolkit/Sources/LocalAgentLLMHost/LLMHostRuntime.swift`
- Modify: `local-ios-agent/toolkit/Sources/LocalAgentLLMHost/LLMHostProductRuntime.swift`
- Modify: `local-ios-agent/toolkit/Sources/LocalAgentLLMHost/LLMEventSequencer.swift`
- Test: `local-ios-agent/rust-core/tests/contract/host_adapter.rs`
- Test: `local-ios-agent/rust-core/tests/integration/host_agent_loop.rs`
- Test: `local-ios-agent/toolkit/Tests/LocalAgentLLMHostTests/ModelRuntimeCommandHandlerTests.swift`
- Test: `local-ios-agent/toolkit/Tests/LocalAgentLLMHostTests/ToolBatchCommandHandlerTests.swift`

**Interfaces:**

- Consumes: Task 8 runtime traits and Task 9 envelope v2.
- Produces: concrete Rust `HostModelRuntime`/`HostToolRuntime` and injected
  Swift handler protocols consumed by Task 11.

- [ ] **Step 1: Write the transport-boundary tests**

Register:

```rust
// rust-core/tests/contract.rs
#[path = "contract/host_adapter.rs"]
mod host_adapter;

// rust-core/tests/integration.rs
#[path = "integration/host_agent_loop.rs"]
mod host_agent_loop;
```

Tests prove:

- `HostModelRuntime: ModelRuntime`;
- `HostToolRuntime: ToolRuntime`;
- one `generate` sends one generation command;
- one `execute_batch` sends one batch and receives one matching completion;
- backpressure/receipt retry cannot duplicate output or tool execution;
- stale epoch, sequence conflict, batch/run mismatch remain rejected;
- model and batch cancellation emit distinct commands;
- every terminal Agent outcome emits one existing `CloseSession`;
- `agent_loop/**` imports no `host_adapter`, `llm_contracts`, or transport type.

Run:

```bash
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test contract -- --list | rg '^host_adapter::'
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test integration -- --list | rg '^host_agent_loop::'
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test contract host_adapter
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test integration host_agent_loop
```

Expected: FAIL.

- [ ] **Step 2: Move and adapt the current transport files**

Use `git mv`. Keep existing:

```text
Condvar/worker-thread waiting
command and event repositories
receipt and duplicate handling
backpressure thresholds
host_process_epoch checks
HostExecutionPhase and ResourceLifecycle transport state
```

Those transport lifecycles remain private to `host_adapter`; do not import them
into `agent_loop`.

- [ ] **Step 3: Implement the two concrete Rust adapters**

`HostModelRuntime::generate` maps one logical `ModelRequest` to schema v2,
dispatches it, streams sequenced model events into `ModelEventSink`, assembles
`AssistantTurn`, and returns only on completed/failed/cancelled.
`HostModelRuntime::close` emits the existing `CloseSession` command exactly
once for the run.

`HostToolRuntime::execute_batch` sends one `ExecuteToolBatch`, waits for the
same `batch_id` and `run_id`, validates Task 9 payload semantics, and returns:

```rust
ToolBatchResult {
    batch_id: completion.batch_id,
    run_id: completion.run_id,
    ordered_results: completion.ordered_results,
}
```

It never executes or reorders tools in Rust.

- [ ] **Step 4: Route cancellation without holding Rust locks**

The existing cancel FFI operation calls `AgentLoopService::cancel_run`.
The service copies the active batch ID under the short cancellation gate,
releases all locks, then emits `CancelToolBatch` or `CancelGeneration`.
`host_adapter` does not infer an Agent phase.

- [ ] **Step 5: Add thin Swift executor protocols and handlers**

```swift
public protocol ModelGenerationExecuting: Sendable {
    func generate(
        _ request: HostModelRequest,
        emit: @escaping @Sendable (HostModelEvent) async throws -> Void
    ) async throws

    func cancel(runID: String) async
}
```

Use Task 9 `HostModelRequest` and `HostModelEvent` directly. Do not introduce
provider-specific request/event models at this boundary.

`ModelRuntimeCommandHandler` routes generation/cancellation only.
`ToolBatchCommandHandler` routes Task 3 `ToolBatchExecuting` only. Neither
stores fallback state, provider candidates, Prompt data, or credentials.

- [ ] **Step 6: Keep one sequenced event path**

Use the existing `LLMEventSequencer` and event callback for model and batch
events. Validate Task 9 event semantics immediately before sequencing.
Preserve copy receipts, event receipts, backpressure, and host epoch.

Run:

```bash
cargo fmt --manifest-path local-ios-agent/rust-core/Cargo.toml -- --check
cargo clippy --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --all-targets -- -D warnings
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test contract host_adapter
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test integration host_agent_loop
swift test --package-path local-ios-agent/toolkit \
  --filter ModelRuntimeCommandHandlerTests
swift test --package-path local-ios-agent/toolkit \
  --filter ToolBatchCommandHandlerTests
swift test --package-path local-ios-agent/toolkit \
  --filter LLMHostRuntimeTests
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add local-ios-agent/rust-core/src \
  local-ios-agent/rust-core/tests \
  local-ios-agent/toolkit/Sources/LocalAgentLLMHost \
  local-ios-agent/toolkit/Tests/LocalAgentLLMHostTests
git commit -m "refactor: adapt reliable host transport to the Rust loop"
```

---

### Task 11: Execute Frozen Cloud/Local Model Plans without a Second Provider Stack

**Files:**

- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/OpenMinisModelExecutor.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/ThirdParty/OpenMinis/Providers/OpenMinisProviderConfigurationAdapter.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Composition/AppBootstrapper.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj/project.pbxproj`
- Modify: `local-ios-agent/toolkit/Sources/LocalAgentLLMCloud/ProviderPreset.swift`
- Modify: `local-ios-agent/toolkit/Sources/LocalAgentLLMCloud/CloudLLMRuntime.swift`
- Modify: `local-ios-agent/toolkit/Sources/LocalAgentLLMCloud/OpenAIChatCompletionsCodec.swift`
- Create only for the proven distinct protocol:
  `local-ios-agent/toolkit/Sources/LocalAgentLLMCloud/AntigravityCloudCodeAdapter.swift`
- Modify: `local-ios-agent/toolkit/Sources/LocalAgentLLMCloud/OfficialCloudCapabilityCatalog.v1.json`
- Test: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Runtime/OpenMinisModelExecutorTests.swift`
- Test: `local-ios-agent/toolkit/Tests/LocalAgentLLMCloudTests/OpenMinisProviderCompatibilityTests.swift`
- Test: `local-ios-agent/toolkit/Tests/LocalAgentLLMCloudTests/SingleCloudTransportTests.swift`

**Interfaces:**

- Consumes: Task 5 product configuration, Task 10
  `ModelGenerationExecuting`, existing cloud/local runtimes, and Task 3 loop
  detector registry.
- Produces: one run-scoped Swift model executor injected at App bootstrap.

- [ ] **Step 1: Prove codec compatibility before adding production code**

Use donor request/stream fixtures for every Task 5 provider. Assert:

- OpenAI/OpenRouter/Kimi use the existing OpenAI-compatible codec with
  endpoint/header/auth presets;
- OpenAI Responses, Anthropic, Gemini, and xAI use existing adapters;
- Antigravity alone needs its Cloud Code outer envelope before Gemini semantic
  decoding;
- unsupported config fails before network;
- exactly one executable adapter is registered per shipped preset.

Run:

```bash
swift test --package-path local-ios-agent/toolkit \
  --filter OpenMinisProviderCompatibilityTests
swift test --package-path local-ios-agent/toolkit \
  --filter SingleCloudTransportTests
```

Expected: FAIL only for the verified missing preset/envelope behavior, not
because provider-named OpenRouter/Kimi adapters are absent.

- [ ] **Step 2: Freeze one non-secret plan per ReAct run**

```swift
struct ProviderRunPlan: Sendable, Equatable {
    let logicalModelID: String
    let orderedCandidates: [ProviderRunCandidate]
}

struct ProviderRunCandidate: Sendable, Equatable {
    let providerConfigurationID: String
    let providerType: ProviderType
    let modelID: String
    let baseURL: URL?
    let presetID: ProviderPresetID
}
```

The first `generate(runID:)` atomically creates the plan from current
settings. Every later generation in that Rust run reuses it. The plan contains
no credential, Prompt, message, tool, or Skill body.

- [ ] **Step 3: Resolve credentials immediately before each attempt**

For each candidate, resolve API Key/OAuth token by stable configuration ID
inside Swift secure storage, then pass it in memory to
`LocalAgentLLMCloud` authorization. Credential rotation can affect the next
request without changing the frozen route. Never serialize it into Rust,
iSH, logs, Skills, or tool results.

- [ ] **Step 4: Keep fallback local to one generate invocation**

Inside each call:

```swift
var hasEmittedModelContent = false
var hasEmittedToolCall = false
```

Mark content before forwarding the first text, reasoning, or tool event.
Retry/fallback only before that point. `CancellationError`,
`Task.isCancelled`, explicit run cancellation, and provider/local cancelled
terminal errors immediately stop and never select another candidate.

Two concurrent generate calls share neither boolean. Do not add a handler
replay dictionary or executor-global emission flag.

- [ ] **Step 5: Route local and cloud through one executor**

Cloud candidates invoke only `LocalAgentLLMCloud`. Local candidates invoke the
existing `LocalAgentLLMLocal`/C++ lifecycle, streaming, cancellation, and usage
path. Both receive the exact Rust `HostModelRequest`; neither rebuilds Prompt,
Skills, Memory, or tool schemas.

- [ ] **Step 6: Port only proven missing codec semantics**

Parameterize the existing OpenAI-compatible route for OpenRouter and Kimi.
Implement `AntigravityCloudCodeAdapter` only for its inspected distinct
project/model/user-agent envelope and unwrap its response before existing
Gemini semantic parsing. Register these preset IDs without creating
OpenRouter/Kimi adapter classes:

```swift
public static let openAICompatible = Self(rawValue: "openai_compatible")
public static let openRouter = Self(rawValue: "openrouter")
public static let kimiCode = Self(rawValue: "kimi_code")
public static let antigravity = Self(rawValue: "antigravity")
```

- [ ] **Step 7: Clean up run-owned resources**

Keep the plan and Task 3 loop detector after a successful tool-call turn.
At App bootstrap, install one cleanup closure on the existing `CloseSession`
command path; it removes the provider plan and the detector for that run.
Rust emits `CloseSession` after final completion, cancellation, max-turn, or
terminal error. `cancel(runID:)` cancels the active task immediately, and the
later close is idempotent. Do not add a run-resource coordinator or another
lifecycle state.

Tests prove changing model/Base URL/fallback group after the first tool call
does not affect the second model turn, while a new run sees new settings.
Cancellation before token one does not start a fallback provider.

- [ ] **Step 8: Register explicit Xcode membership, verify, and commit**

Add `OpenMinisModelExecutor.swift` to `LocalAgentApp` Sources and its App test
to `LocalAgentAppTests` Sources. Verify the App target links the existing
`LocalAgentLLMCloud`, `LocalAgentLLMLocal`, `LocalAgentLLMHost`, and contracts
products exactly once. This task adds no App resource phase entry.

```bash
swift test --package-path local-ios-agent/toolkit \
  --filter OpenMinisProviderCompatibilityTests
swift test --package-path local-ios-agent/toolkit \
  --filter SingleCloudTransportTests
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -destination "platform=iOS Simulator,id=$LOCAL_AGENT_PHASE5_IPHONE_UDID" \
  -derivedDataPath /private/tmp/localagent-openminis-task11 \
  -only-testing:LocalAgentAppTests/OpenMinisModelExecutorTests
git add local-ios-agent/apps/LocalAgentApp \
  local-ios-agent/toolkit
git commit -m "feat: execute frozen provider plans through LocalAgent runtimes"
```

Expected: PASS.

---

### Task 12: Cut the LocalAgent Chat Product over to Rust Commands and Projection

**Files:**

- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/RustAgentCoordinator.swift`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/ChatStoreProjectionApplier.swift`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/ProjectionFeedController.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Composition/AppBootstrapper.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Composition/AppContainer.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/ThirdParty/OpenMinis/ChatUI/AIChatViewModel.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/ThirdParty/OpenMinis/ChatUI/ChatStore.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/ChatInteractionCoordinator.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/AppIntents/AppIntentRouter.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj/project.pbxproj`
- Test: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Runtime/RustAgentCoordinatorTests.swift`
- Test: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Runtime/ChatStoreProjectionApplierTests.swift`
- Test: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Architecture/TranscriptOwnershipTests.swift`
- Test: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Integration/RustReActProductPathTests.swift`

**Interfaces:**

- Consumes: Task 4 snapshot provider, Task 6 commands/projection, Task 10 host
  handlers, Task 11 model executor, and Task 3 tool executor.
- Produces: the complete working core Agent product path inside the only
  shipping LocalAgent App.

- [ ] **Step 1: Write control-flow and feed-ownership tests**

Add the four new test file references and PBXBuildFile entries to the
`LocalAgentAppTests` Sources phase before the RED run. A passing invocation
with zero discovered tests is a failure.

Tests prove:

- send/retry/edit each obtains one complete snapshot and submits one Rust
  command;
- delete/clear/branch/archive/conversation deletion submit Rust commands;
- no command acknowledgement applies a projection;
- every command establishes its conversation feed before entering Rust;
- persistent feeds equal `runningConversations ∪ currentConversation`;
- five background runs plus another current conversation produce six feeds;
- a dormant command may create a seventh temporary feed without capacity/LRU;
- terminal temporary projection closes its feed;
- archive/delete projections work without run ID;
- gap detection reopens from the stored cursor;
- `ExecutionBridgeClient.observeEvents(runID:)` is ephemeral UI only;
- no new-runtime entry point calls a direct transcript `ChatStore` mutation or
  any Swift agent loop.

Run:

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -destination "platform=iOS Simulator,id=$LOCAL_AGENT_PHASE5_IPHONE_UDID" \
  -derivedDataPath /private/tmp/localagent-openminis-task12-red \
  -only-testing:LocalAgentAppTests/RustAgentCoordinatorTests \
  -only-testing:LocalAgentAppTests/ChatStoreProjectionApplierTests \
  -only-testing:LocalAgentAppTests/TranscriptOwnershipTests
```

Expected: FAIL.

- [ ] **Step 2: Construct the one product runtime composition**

Add the three new runtime files to `LocalAgentApp` Sources. Verify existing
bridge/host/cloud/local package products remain linked exactly once. This task
adds no resource entry.

At bootstrap construct once:

```text
RustAgentInputSnapshotProvider
OpenMinisModelExecutor
OpenMinisToolBatchExecutor
ModelRuntimeCommandHandler
ToolBatchCommandHandler
LLMHostProductRuntime
RustAgentCoordinator
```

No temporary fake or alternate agent loop is allowed in production
composition.

- [ ] **Step 3: Implement the thin coordinator**

```swift
@MainActor
final class RustAgentCoordinator: ObservableObject {
    func send(
        requestID: String,
        conversationStreamID: String,
        text: String,
        attachments: [TranscriptAttachmentReferenceDTO]
    ) async throws

    func submit(_ command: TranscriptCommandDTO) async throws
    func cancel(runID: String) async
    func startProjection(conversationStreamID: String) async throws
}
```

It owns no conversation history, provider fallback, Prompt builder, or agent
phase. Send/retry/edit obtain Task 4 snapshot immediately before building the
command. All transcript changes enter this coordinator.

- [ ] **Step 4: Maintain exactly the required persistent and temporary feeds**

```swift
var desired = runningConversationIDs
if let currentConversationID {
    desired.insert(currentConversationID)
}
```

Maximum running conversations remains five, so persistent feeds are at most
six. Start missing feeds and cancel feeds leaving the set unless an accepted
command is awaiting projection.

Before every transcript command, install a feed for its stream. A dormant
stream gets a temporary feed even when six persistent feeds exist. Keep it
until projections apply through `acceptedSequence`, then close it unless it
joined the persistent set. Do not implement LRU, priority, eviction, or a
`projectionFeedCapacity` product limit.

- [ ] **Step 5: Apply canonical projections atomically and idempotently**

Add to the existing Swift read-model database:

```sql
create table if not exists rust_projection_cursor (
    conversation_stream_id text primary key,
    last_sequence integer not null
);
```

`ChatStoreProjectionApplier` is the sole new-runtime writer. Apply the row
change and cursor in one transaction only when
`sequence == last_sequence + 1`. Ignore older/equal events. For a larger
sequence, apply nothing, cancel the feed, and reopen from `last_sequence`.
`CursorAdvance` changes only the cursor.

- [ ] **Step 6: Keep streaming presentation temporary**

Run-scoped model/tool events may update an ephemeral assistant message/tool
card keyed by Rust event ID. Final canonical projection replaces/reconciles
that UI state. It is never written independently to `ChatStore`.

- [ ] **Step 7: Replace every product mutation path**

Wire:

```text
send
retry
edit
delete message
clear
branch
archive
delete conversation
App Intent prompt submission
```

to `RustAgentCoordinator`. Keep title, pin, selected model, and other
non-model-history metadata as direct Swift operations.

- [ ] **Step 8: Prove one complete core product path**

The single integration test performs:

```text
OpenMinis-derived chat UI
→ Rust Send command
→ cloud or local model emits two tool calls
→ one concurrent Swift batch
→ atomic Rust tool round
→ second frozen-provider model turn
→ final Rust assistant commit
→ one-way ChatStore projection
→ rendered final response/tool cards
```

Run:

```bash
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test integration host_agent_loop
swift test --package-path local-ios-agent/toolkit
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -destination "platform=iOS Simulator,id=$LOCAL_AGENT_PHASE5_IPHONE_UDID" \
  -derivedDataPath /private/tmp/localagent-openminis-task12 \
  -only-testing:LocalAgentAppTests/RustAgentCoordinatorTests \
  -only-testing:LocalAgentAppTests/ChatStoreProjectionApplierTests \
  -only-testing:LocalAgentAppTests/TranscriptOwnershipTests \
  -only-testing:LocalAgentAppTests/RustReActProductPathTests
```

Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add local-ios-agent/apps/LocalAgentApp \
  local-ios-agent/toolkit \
  local-ios-agent/rust-core
git commit -m "feat: drive LocalAgent chat from the Rust ReAct core"
```

---

### Task 13: Optional Product Slices — Voice, App Intents, Widget, and Background/Alarms

Task 13 is a catalog of independent optional slices, not a prerequisite for
Tasks 15–16. No slice is selected by default. Before implementation, record
the selected slice IDs in the implementation PR/task description. An
unselected slice copies no source, adds no Xcode target/reference, runs no
slice test, and does not affect core completion.

Each selected slice starts from completed Task 12, has its own RED/GREEN test,
Xcode membership, migration-manifest rows, and commit. Do not batch selected
slices into one commit. A slice selected for the same shipping milestone runs
before Task 15. A slice selected later reruns the Task 15 architecture checks
and the affected Task 16 App validation in its own PR.

If compilation reveals a dependency outside a slice allowlist, stop and add
that exact file to the slice review before copying it. “Reachable” or
“compiler-proven” is not permission to grow the slice silently.

**OpenMinis sources to inspect and selectively copy:**

These are search roots only; the per-slice allowlist below is authoritative
and no directory is copied wholesale.

- `OpenMinis/src/ios/Providers/Voice/`
- `OpenMinis/src/ios/Agent/Speech/`
- `OpenMinis/src/ios/Views/Chat/Voice/`
- `OpenMinis/src/ios/Agent/Background/`
- `OpenMinis/src/ios/Views/Alarms/`
- `OpenMinis/src/ios/AgentWidget/`
- `OpenMinis/src/ios/Agent/Intents/`
- `OpenMinis/src/ios/NativeOffloads/SpeechOffload.h`
- `OpenMinis/src/ios/NativeOffloads/SpeechOffload.m`
- `OpenMinis/src/ios/NativeOffloads/PlayerOffload.h`
- `OpenMinis/src/ios/NativeOffloads/PlayerOffload.m`
- `OpenMinis/src/ios/NativeOffloads/PlayerOffloadBridge.swift`
- `OpenMinis/src/ios/NativeOffloads/AlarmOffload.h`
- `OpenMinis/src/ios/NativeOffloads/AlarmOffload.m`
- `OpenMinis/src/ios/NativeOffloads/AlarmOffloadBridge.swift`
- `OpenMinis/src/ios/NativeOffloads/NotificationOffload.h`
- `OpenMinis/src/ios/NativeOffloads/NotificationOffload.m`
- `OpenMinis/src/ios/Shared/AudioTogglePlaybackIntent.swift`

**Conditional LocalAgent targets (only for selected slices):**

- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/ThirdParty/OpenMinis/Voice/`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Product/Background/`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/UI/Alarms/`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/AppIntents/`
- Create or rename: the `LocalAgentWidget` target inside
  `local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj/project.pbxproj`
- Modify: `local-ios-agent/docs/openminis-migration-manifest.md`

**Conditional tests (only for selected slices):**

- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/VoiceProductTests.swift`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/BackgroundRunBridgeTests.swift`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/AppIntentTranscriptOwnershipTests.swift`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/WidgetProjectionTests.swift`

- [ ] **Slice 13A: Voice**

Selected sources are exactly:

```text
Providers/Voice/**
Agent/Speech/**
Views/Chat/Voice/**
NativeOffloads/SpeechOffload.{h,m}
NativeOffloads/PlayerOffload.{h,m}
NativeOffloads/PlayerOffloadBridge.swift
Shared/AudioTogglePlaybackIntent.swift
```

Add `VoiceProductTests.swift` to `LocalAgentAppTests`, run it first and
confirm RED, then migrate only the reviewed allowlist above. If one of those
files cannot compile without another donor file, add that exact dependency to
the slice review before copying it.

Copy the OpenMinis voice provider, speech, and voice-chat UI from the reviewed
allowlist into the LocalAgent-owned paths. Add the `RealTimeCutVAD` dependency
now, because voice is the first caller.

Preserve OpenMinis recording, transcription, correction, and playback
behavior. Replace any OpenMinis model or agent-loop call with:

```swift
try await rustAgentCoordinator.send(
    requestID: requestID,
    conversationStreamID: conversationStreamID,
    text: correctedTranscript,
    attachments: []
)
```

Voice code may own audio files and temporary UI, but not model history.

Run only:

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -destination "platform=iOS Simulator,id=$LOCAL_AGENT_PHASE5_IPHONE_UDID" \
  -derivedDataPath /private/tmp/localagent-openminis-slice-13a \
  -only-testing:LocalAgentAppTests/VoiceProductTests
```

Update Xcode membership and the manifest, then commit:

```bash
git add local-ios-agent/apps/LocalAgentApp \
  local-ios-agent/docs/openminis-migration-manifest.md
git commit -m "feat: migrate optional OpenMinis voice slice"
```

- [ ] **Slice 13B: Background and alarms**

Selected sources are exactly:

```text
Agent/Background/BackgroundKeepAliveManager.swift
Agent/Background/CacheKeepAliveManager.swift
Views/Settings/EnhancedBackgroundSettingsView.swift
Views/Alarms/AlarmListView.swift
NativeOffloads/AlarmOffload.{h,m}
NativeOffloads/AlarmOffloadBridge.swift
NativeOffloads/NotificationOffload.{h,m}
```

Add `BackgroundRunBridgeTests.swift`, confirm RED, then migrate only these
files. Any additional donor dependency must first be named in the slice
review and added to this allowlist.

Copy only the OpenMinis files reached by background execution, alarm
presentation, notification scheduling, and audio alerts. Rename types,
targets, bundle identifiers, UserDefaults suites, notification categories,
and App Group identifiers to LocalAgent.

Background work must resume or observe the existing Rust run. It must not
construct a second Swift agent loop. Alarm and notification actions that
start a prompt must enter through `RustAgentCoordinator`.

Run only:

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -destination "platform=iOS Simulator,id=$LOCAL_AGENT_PHASE5_IPHONE_UDID" \
  -derivedDataPath /private/tmp/localagent-openminis-slice-13b \
  -only-testing:LocalAgentAppTests/BackgroundRunBridgeTests
```

Update Xcode/manifest and commit:

```bash
git add local-ios-agent/apps/LocalAgentApp \
  local-ios-agent/docs/openminis-migration-manifest.md
git commit -m "feat: migrate optional OpenMinis background alarm slice"
```

- [ ] **Slice 13C: App Intents**

Selected sources are exactly the Swift files under
`OpenMinis/src/ios/Agent/Intents/`:

```text
AskMinisIntent.swift
FollowUpSessionIntent.swift
GetSessionStatusIntent.swift
ListSessionsIntent.swift
MinisShortcutsProvider.swift
ModelSelectionEntity.swift
OpenSessionIntent.swift
QuickTaskIntent.swift
RetryRunIntent.swift
SendPromptIntent.swift
SendPromptResult.swift
SessionEntity.swift
ShortcutRunTracker.swift
UserMessageEntity.swift
```

Add `AppIntentTranscriptOwnershipTests.swift`, confirm RED, and port required
behavior into the existing LocalAgent App Intent types rather than retaining
Minis product names.

Port useful OpenMinis intent entities, parameter handling, and result
presentation into `LocalAgentApp/AppIntents/`. Do not add a second intent
framework or duplicate existing LocalAgent intents.

Intent reads may use projected product data. Transcript mutation must use the
main App Rust runtime. An intent process must never open the canonical Rust
event store directly.

If iOS cannot bring the main App runtime forward for a mutation, the intent
stores only draft input and asks the user to continue in LocalAgent. Do not
introduce an extension command inbox.

Run only:

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -destination "platform=iOS Simulator,id=$LOCAL_AGENT_PHASE5_IPHONE_UDID" \
  -derivedDataPath /private/tmp/localagent-openminis-slice-13c \
  -only-testing:LocalAgentAppTests/AppIntentTranscriptOwnershipTests
```

Update Xcode/manifest and commit:

```bash
git add local-ios-agent/apps/LocalAgentApp \
  local-ios-agent/docs/openminis-migration-manifest.md
git commit -m "feat: migrate optional OpenMinis App Intents slice"
```

- [ ] **Slice 13D: Widget**

Selected sources are exactly:

```text
AgentWidget/Info.plist
AgentWidget/AgentWidget.entitlements
AgentWidget/AgentWidgetBundle.swift
AgentWidget/AgentLiveActivityWidget.swift
Agent/Background/AgentLiveActivityManager.swift
```

Add `WidgetProjectionTests.swift`, confirm RED, and create/rename only the
`LocalAgentWidget` target.

Create or rename the widget target as `LocalAgentWidget`. It reads an App
Group snapshot generated by the main App from Rust projections. The widget
must not contain `ChatStore` mutation code, Rust store access, model provider
code, or tool execution.

Run only:

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -destination "platform=iOS Simulator,id=$LOCAL_AGENT_PHASE5_IPHONE_UDID" \
  -derivedDataPath /private/tmp/localagent-openminis-slice-13d \
  -only-testing:LocalAgentAppTests/WidgetProjectionTests
```

Add widget sources/resources/entitlements to the widget target, the test to
`LocalAgentAppTests`, update the manifest, and commit:

```bash
git add local-ios-agent/apps/LocalAgentApp \
  local-ios-agent/docs/openminis-migration-manifest.md
git commit -m "feat: migrate optional OpenMinis widget slice"
```

---

### Task 14: Optional Product Slices — Share, File Provider, Backup, and Sync

Task 14 follows the same selection rule as Task 13: no slice is selected by
default, no slice blocks Tasks 15–16, and each selected slice has an
independent test, Xcode/resource membership, manifest update, and commit.
There is no “remaining UI,” “reachable settings,” WebApp, diagnostics, or
polish catch-all in this task.

**OpenMinis sources to inspect and selectively copy:**

These are search roots only; the per-slice allowlist below is authoritative
and no directory is copied wholesale.

- `OpenMinis/src/ios/ShareExtension/`
- `OpenMinis/src/ios/FileProvider/`
- the exact sync allowlist in Slice 14D
- `OpenMinis/src/ios/Views/Backup/`
- `OpenMinis/src/ios/Views/Sync/`

**Conditional LocalAgent targets (only for selected slices):**

- Create or rename: LocalAgent-owned Share Extension and File Provider targets
  inside `local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj/project.pbxproj`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Product/Backup/`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Product/Sync/`
- Modify: `local-ios-agent/docs/openminis-migration-manifest.md`

**Conditional tests (only for selected slices):**

- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/ShareExtensionBoundaryTests.swift`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/FileProviderBoundaryTests.swift`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/BackupCanonicalStoreTests.swift`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/SyncWhitelistTests.swift`

- [ ] **Slice 14A: Share Extension**

Selected sources are exactly:

```text
ShareExtension/Info.plist
ShareExtension/ShareExtension.entitlements
ShareExtension/MainInterface.storyboard
ShareExtension/ShareViewModel.swift
ShareExtension/ShareViewController.swift
```

Add `ShareExtensionBoundaryTests.swift`, register it, and confirm RED before
migrating the slice.

Copy the useful OpenMinis share UI, attachment import, and App Group transfer
code. Rename its target and identifiers to LocalAgent.

The extension writes this pending value only:

```swift
struct PendingShareDraft: Codable, Sendable {
    let requestID: String
    let text: String
    let attachments: [PendingAttachmentReference]
    let createdAt: Date
}
```

It does not create conversation messages. The main App displays the draft,
lets the user choose a conversation, and submits the normal Rust command.
Do not build a general command inbox without a production caller.

The extension must not link Rust canonical-store, provider, or tool-execution
products. Run only:

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -destination "platform=iOS Simulator,id=$LOCAL_AGENT_PHASE5_IPHONE_UDID" \
  -derivedDataPath /private/tmp/localagent-openminis-slice-14a \
  -only-testing:LocalAgentAppTests/ShareExtensionBoundaryTests
```

Update the Share target/resources and manifest, then commit:

```bash
git add local-ios-agent/apps/LocalAgentApp \
  local-ios-agent/docs/openminis-migration-manifest.md
git commit -m "feat: migrate optional OpenMinis Share slice"
```

- [ ] **Slice 14B: File Provider**

Selected sources are exactly:

```text
FileProvider/Info.plist
FileProvider/FileProvider.entitlements
FileProvider/FileProviderExtension.swift
FileProvider/FileProviderEnumerator.swift
FileProvider/FileProviderItem.swift
FileProvider/AppGroupChangeWatcher.swift
FileProvider/FPSyncTraceLog.swift
```

Add `FileProviderBoundaryTests.swift`, register it, and confirm RED before
migration.

Copy only the seven File Provider files in the reviewed allowlist above. Its
domains expose only:

```text
shared/
skills/
mounts/
```

Map these through the host-mount branch of Task 3 `ToolFileResolver` and its
mount policy. The extension cannot expose iOS container paths or canonical
transcript storage.

Run only:

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -destination "platform=iOS Simulator,id=$LOCAL_AGENT_PHASE5_IPHONE_UDID" \
  -derivedDataPath /private/tmp/localagent-openminis-slice-14b \
  -only-testing:LocalAgentAppTests/FileProviderBoundaryTests
```

Add the exact File Provider Sources/Resources/Frameworks entries, update the
manifest, then commit:

```bash
git add local-ios-agent/apps/LocalAgentApp \
  local-ios-agent/docs/openminis-migration-manifest.md
git commit -m "feat: migrate optional OpenMinis File Provider slice"
```

- [ ] **Slice 14C: Backup**

Selected donor files are exactly:

```text
Agent/Sync/ICloudBackupManager.swift
Views/Backup/ICloudBackupView.swift
```

Add `BackupCanonicalStoreTests.swift`, register it, and confirm RED. Reuse UI
and file-handling behavior, but route canonical conversation export/import
through the main App Rust runtime.

Reuse OpenMinis backup UI and file-handling behavior. Route canonical
conversation export/import through new synchronous main-App bridge endpoints:

```rust
pub trait CanonicalTranscriptArchive {
    fn export_archive(&self) -> Result<Vec<u8>, ArchiveError>;
    fn import_archive(
        &self,
        request_id: String,
        archive: &[u8],
    ) -> Result<ImportReceipt, ArchiveError>;
}

pub struct ImportReceipt {
    pub request_id: String,
    pub archive_digest: String,
    pub imported_stream_ids: Vec<String>,
}
```

Import uses this exact order:

1. look up `request_id`; the same archive digest returns the first receipt,
   while a different digest returns `archive.idempotency_conflict`;
2. acquire the existing run-admission lock so no new Agent run can start;
3. require zero active runs, otherwise return `archive.active_run`;
4. decode the complete bounded archive and verify version, archive digest,
   event schema, event IDs, per-stream contiguous sequence, and payload
   digests;
5. reject the whole archive with `archive.stream_conflict` if any imported
   `conversation_stream_id` already exists locally—do not merge, overwrite,
   delete, or silently remap;
6. insert every event and the import receipt in one SQLite transaction;
7. commit, release admission, then wake projection listeners for every
   imported stream so Swift replays from its stored cursor.

Any validation, collision, storage, or process failure rolls back all archive
writes. Import runs only while the main App owns the single Rust writer.
Product configuration and user files may remain separate backup sections.

Run only:

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -destination "platform=iOS Simulator,id=$LOCAL_AGENT_PHASE5_IPHONE_UDID" \
  -derivedDataPath /private/tmp/localagent-openminis-slice-14c \
  -only-testing:LocalAgentAppTests/BackupCanonicalStoreTests
```

Add the exact App/Test Sources/Resources entries, update the manifest, then
commit:

```bash
git add local-ios-agent/apps/LocalAgentApp \
  local-ios-agent/rust-core \
  local-ios-agent/toolkit \
  local-ios-agent/docs/openminis-migration-manifest.md
git commit -m "feat: migrate optional OpenMinis backup slice"
```

- [ ] **Slice 14D: Eligible non-conversation sync**

Copy/adapt only these record-agnostic donor inputs:

```text
Agent/Sync/V2/Syncable.swift
Agent/Sync/V2/PortableRecord.swift
Agent/Sync/V2/SyncTransport.swift
Agent/Sync/V2/LANTransport.swift
Agent/Sync/V2/SyncCoreHydrators.swift
Agent/Sync/V2/SyncableTypeRegistry.swift
Agent/Sync/V2/ForceSyncHelper.swift
Views/Sync/CloudSyncSettingsV2View.swift
```

In addition, extract only these named pieces:

```text
from Agent/Sync/V2/SyncedTypes.swift:
  SyncedSkill
  SyncedProviderConfig
  SyncedProviderInstanceV3
  SyncedProviderModelEntryV3
  SyncedProviderModelGroupV3
  → Product/Sync/EligibleSyncedTypes.swift

from Agent/Sync/V2/SyncCore.swift:
  record-agnostic transport, dirty-record upload, portable-record download,
  hydrator dispatch, tombstone dispatch
  → Product/Sync/EligibleProductSyncEngine.swift

from Agent/Sync/V2/SyncV2Bootstrap.swift:
  transport construction and registration for the five eligible types above
  → Product/Sync/EligibleProductSyncBootstrap.swift

from Agent/Sync/V2/UploadPolicy.swift:
  policy shape for skills/provider/product settings only
  → Product/Sync/EligibleUploadPolicy.swift

from Agent/Sync/V2/ICloudSharedZoneTransport.swift:
  CloudKit zone setup, portable-record upload/download, retry, and change token
  for the five eligible types only
  → Product/Sync/EligibleICloudTransport.swift
```

Explicitly do not copy:

```text
Agent/Sync/CloudSyncEngine.swift
Agent/Sync/V2/SyncCore.swift as a complete file
Agent/Sync/V2/SyncedTypes.swift as a complete file
Agent/Sync/V2/SyncV2Bootstrap.swift as a complete file
Agent/Sync/V2/UploadPolicy.swift as a complete file
Agent/Sync/V2/ICloudSharedZoneTransport.swift as a complete file
Agent/Sync/V2/ChatStoreSyncHydrators.swift
Agent/Sync/V2/SessionFileChangeTracker.swift
Agent/Sync/V2/MigrationEngine.swift
Agent/Sync/V2/TombstoneManager.swift
Views/Sync/SyncMigrationDetailView.swift
```

Add `SyncWhitelistTests.swift`, register it, and confirm RED before migration.

Reuse OpenMinis sync UI and transport for:

- global Skill files, descriptors, and global enabled state;
- non-secret provider identifiers, base URLs, model choices, and fallback
  group configuration;
- product settings that contain neither transcript nor credentials.

Do not migrate the conversation portions of `CloudSyncEngine` or
`ChatStoreSyncHydrators`. Keep `Session`, `Message`, `CompactMarker`, and
`SessionFile` synchronization disabled until Rust canonical events have a
separate approved cross-device design. Keep conversation-scoped Skill
overrides local for the same reason. API keys and OAuth tokens remain in local
secure storage and never enter sync payloads.

Run only:

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -destination "platform=iOS Simulator,id=$LOCAL_AGENT_PHASE5_IPHONE_UDID" \
  -derivedDataPath /private/tmp/localagent-openminis-slice-14d \
  -only-testing:LocalAgentAppTests/SyncWhitelistTests
```

Add selected sync files/resources/frameworks to the App target, update the
manifest, then commit:

```bash
git add local-ios-agent/apps/LocalAgentApp \
  local-ios-agent/docs/openminis-migration-manifest.md
git commit -m "feat: migrate optional OpenMinis sync slice"
```

---

### Task 15: Remove Only Proven Zero-Caller Legacy Paths

**Candidate files and modules to inspect, not an unconditional delete list:**

- Rust agent-state candidates:
  `rust-core/src/runtime/run_machine.rs`,
  `rust-core/src/execution/react_worker.rs`,
  `rust-core/src/execution/execution_service.rs`,
  `rust-core/src/execution/tool_approval.rs`, and the generic approval queue
- Rust memory candidates: unused SQLite, HTTP, long-term, graph, and
  orchestration implementations outside the retained `MemoryProvider`
- Swift candidates: legacy `AgentRuntimeService`,
  `ChatInteractionCoordinator`, `RunLifecycleService`,
  `ToolApprovalService`, replaced chat views, and old host aliases
- dependency candidates: `SwiftAnthropic` and any donor package with no
  production caller

**Tests:**

- Create: `local-ios-agent/tests/architecture/test_no_duplicate_agent_paths.sh`
- Create: `local-ios-agent/tests/architecture/test_no_duplicate_transcript_writers.sh`
- Create: `local-ios-agent/tests/architecture/test_no_duplicate_provider_transports.sh`
- Modify: existing Rust and Swift focused suites as each candidate is removed

- [ ] **Step 1: Write architecture checks before deleting anything**

The scripts must fail on production references to:

```text
runAgentLoop
OpenMinis provider factories
OpenMinis SystemPromptBuilder
Swift transcript writes outside ChatStoreProjectionApplier
conversation sync entities Session/Message/CompactMarker/SessionFile
Minis.xcodeproj
OpenMinis app bundle identifiers
```

The provider check allows one cloud HTTP execution root:
`LocalAgentLLMCloud`. The transcript check allows one canonical writer in the
main App Rust runtime and one Swift projection applier.

- [ ] **Step 2: Run the architecture checks and verify RED**

```bash
bash local-ios-agent/tests/architecture/test_no_duplicate_agent_paths.sh
bash local-ios-agent/tests/architecture/test_no_duplicate_transcript_writers.sh
bash local-ios-agent/tests/architecture/test_no_duplicate_provider_transports.sh
```

Expected: at least one check fails while legacy callers remain.

- [ ] **Step 3: Prove replacement and production caller count for one candidate at a time**

Before deleting a candidate:

1. use `rg` to list all production callers;
2. identify the replacement implemented in Tasks 1–12 or an explicitly
   selected Task 13/14 slice;
3. migrate or remove the callers;
4. rerun the candidate's focused tests;
5. delete only after the production caller count is zero.

`execution_service.rs` may still provide event observation. Keep it unless its
remaining responsibility has an already-tested replacement. Apply the same
rule to every memory implementation and Swift service.

- [ ] **Step 4: Delete each independent zero-caller subsystem in a small commit**

Use a separate commit for each independently removable subsystem. A typical
commit is:

```bash
git add local-ios-agent/rust-core local-ios-agent/toolkit \
  local-ios-agent/apps/LocalAgentApp
git commit -m "refactor: remove superseded agent state machinery"
```

Do not combine unrelated deletions. Do not copy the donor app loop merely to
delete it later.

- [ ] **Step 5: Remove unused packages and Xcode references**

Remove a package, framework, build phase, resource, entitlement, or native
artifact only after Xcode and Swift production targets have zero callers.
Remove the corresponding manifest row when the copied source no longer ships.

- [ ] **Step 6: Run architecture and focused regression suites**

```bash
bash local-ios-agent/tests/architecture/test_no_duplicate_agent_paths.sh
bash local-ios-agent/tests/architecture/test_no_duplicate_transcript_writers.sh
bash local-ios-agent/tests/architecture/test_no_duplicate_provider_transports.sh
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml
swift test --package-path local-ios-agent/toolkit
```

Expected: PASS.

- [ ] **Step 7: Commit the architecture checks and final dependency cleanup**

```bash
git add local-ios-agent/tests \
  local-ios-agent/apps/LocalAgentApp \
  local-ios-agent/rust-core \
  local-ios-agent/toolkit \
  local-ios-agent/docs/openminis-migration-manifest.md
git commit -m "refactor: remove duplicate LocalAgent execution paths"
```

---

### Task 16: Verify the Core Clean Checkout, Relaunch Replay, and Product Path

**Tests:**

- Create:
  `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/RelaunchProjectionReplayProductTests.swift`
- Create:
  `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/OpenMinisProductBenchmarkTests.swift`
- Reuse:
  `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/RustReActProductPathTests.swift`
- Port measurement primitives only from:
  `OpenMinis/src/ios/Debug/PerfTrace.swift` and
  `OpenMinis/src/ios/Debug/AgentRequestTrace.swift`
- Create:
  `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Debug/OpenMinisPerfTrace.swift`
- Create:
  `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Debug/OpenMinisAgentRequestTrace.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj/project.pbxproj`
- Modify: documentation only if validation exposes a real build or ownership
  constraint that the plan omitted

- [ ] **Step 1: Add the relaunch/projection replay product test**

Add both new Task 16 tests to the `LocalAgentAppTests` Sources phase before
running them. Recheck that required App resources and package/framework
products remain present once. Step 2 adds exactly two DEBUG-only production
source files and no resource membership.

Test exactly one path:

```text
complete a conversation
→ persist Rust canonical events and Swift cursor
→ terminate projection subscription
→ recreate App services
→ replay after (conversation_stream_id, sequence)
→ cross from replay to live observation without duplicates
→ detect and repair one sequence gap
→ cancel the idle subscription
→ Rust listener and Swift detached-task counts return to zero
```

- [ ] **Step 2: Add one diagnostic product-equivalence benchmark**

Port only the measurement/event primitives required from the two named donor
files. Do not copy `DebugServer`, debug RPC, diagnostics UI, WebApp, benchmark
views, or other “reachable” debug sources.
Add the two helpers to `LocalAgentApp` Sources behind `#if DEBUG` before the
product-test run.

Use the resulting test harness to measure the LocalAgent core path for:

- first visible streaming event;
- ordered concurrent tool-batch duration;
- projection completion;
- cancellation cleanup;
- peak number of active tool processes.

This is a validation benchmark, not a release gate based on fixed timing.
Fail only on incorrect ordering, leaked processes/listeners, missing events,
or an unavailable diagnostic surface.

- [ ] **Step 3: Run the three product-path tests**

There are only three broad product tests:

1. the complete ReAct path created in Task 12;
2. relaunch and projection replay;
3. product-equivalence diagnostics.

All cancellation, race, validation, idempotency, provider, tool, and security
cases remain in their focused task suites.

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -destination "platform=iOS Simulator,id=$LOCAL_AGENT_PHASE5_IPHONE_UDID" \
  -derivedDataPath /private/tmp/localagent-openminis-product-validation \
  -only-testing:LocalAgentAppTests/RustReActProductPathTests \
  -only-testing:LocalAgentAppTests/RelaunchProjectionReplayProductTests \
  -only-testing:LocalAgentAppTests/OpenMinisProductBenchmarkTests
```

Expected: PASS.

- [ ] **Step 4: Commit the core validation harness**

Commit the two registered debug helpers and Task 16 tests so the following
fresh worktree is created from a HEAD that contains every file under
validation:

```bash
git add local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Debug \
  local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  local-ios-agent/docs
git commit -m "test: add LocalAgent core product validation"
```

- [ ] **Step 5: Prove one post-commit clean-worktree native regeneration**

Task 16 is the only task that creates a clean validation worktree. Build both
Apple platforms from the committed `HEAD`:

```bash
validation_parent="$(mktemp -d /private/tmp/localagent-core-validation.XXXXXX)"
validation_worktree="$validation_parent/repo"
git worktree add --detach "$validation_worktree" HEAD

(
  cd "$validation_worktree"
  bash local-ios-agent/scripts/test-ios-native-build-contract.sh --lock-only
  bash local-ios-agent/scripts/prepare-ios-native.sh --platform iphonesimulator
  /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build \
    -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
    -scheme LocalAgentApp \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath /private/tmp/localagent-core-clean-simulator \
    CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64
  test -f /private/tmp/localagent-core-clean-simulator/Build/Products/Debug-iphonesimulator/LocalAgentApp.app/alpine-rootfs.zip
  test -d /private/tmp/localagent-core-clean-simulator/Build/Products/Debug-iphonesimulator/LocalAgentApp.app/RootfsPatch.bundle

  bash local-ios-agent/scripts/prepare-ios-native.sh --platform iphoneos
  /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build \
    -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
    -scheme LocalAgentApp \
    -destination 'generic/platform=iOS' \
    -derivedDataPath /private/tmp/localagent-core-clean-device \
    CODE_SIGNING_ALLOWED=NO
  test -f /private/tmp/localagent-core-clean-device/Build/Products/Debug-iphoneos/LocalAgentApp.app/alpine-rootfs.zip
  test -d /private/tmp/localagent-core-clean-device/Build/Products/Debug-iphoneos/LocalAgentApp.app/RootfsPatch.bundle

  bash local-ios-agent/scripts/test-ios-native-build-contract.sh
  test -z "$(git status --porcelain --untracked-files=no)"
)

git worktree remove --force "$validation_worktree"
rmdir "$validation_parent"
```

Expected:

- every source archive matches the checked-in SHA-256 lock;
- `alpine-rootfs.zip`, iSH, FFmpeg, and LAME outputs regenerate for required
  platforms;
- Xcode Copy Bundle Resources contains the generated rootfs;
- generated products remain ignored;
- no tracked file changes appear.

- [ ] **Step 6: Run all Rust and Swift package validation**

```bash
cargo fmt --manifest-path local-ios-agent/rust-core/Cargo.toml --check
cargo clippy --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --all-targets --all-features -- -D warnings
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --all-targets --all-features
swift test --package-path local-ios-agent/toolkit
```

Expected: PASS.

- [ ] **Step 7: Build and test the shipping App for iPhone and iPad**

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -destination "platform=iOS Simulator,id=$LOCAL_AGENT_PHASE5_IPHONE_UDID" \
  -derivedDataPath /private/tmp/localagent-openminis-final-iphone
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -destination "platform=iOS Simulator,id=$LOCAL_AGENT_PHASE5_IPAD_UDID" \
  -derivedDataPath /private/tmp/localagent-openminis-final-ipad
```

Expected: PASS.

- [ ] **Step 8: Run final source and manifest checks**

```bash
bash local-ios-agent/tests/architecture/test_no_duplicate_agent_paths.sh
bash local-ios-agent/tests/architecture/test_no_duplicate_transcript_writers.sh
bash local-ios-agent/tests/architecture/test_no_duplicate_provider_transports.sh
rg -n "Minis\\.xcodeproj|com\\.openminis|runAgentLoop" local-ios-agent \
  -g '!docs/**' -g '!tests/**'
```

Expected:

- architecture checks pass;
- `rg` finds no production matches;
- each copied OpenMinis source slice has a manifest row naming its LocalAgent
  destination, Xcode target/build phase, and GPL-3.0 license;
- no generated native product is tracked.

- [ ] **Step 9: Confirm a clean implementation worktree**

If Steps 5–8 required a tracked correction, commit it and rerun the failing
step plus every downstream step before this check.

```bash
git status --short
```

Expected: no output.

---

## Execution Checkpoints

The required core execution order is:

```text
Tasks 1–12 → Task 15 → Task 16
```

Task 13/14 slices may run after Task 12 when explicitly selected, but they are
not inserted into or required by that core chain. Run same-milestone slices
before Task 15; treat later selections as independent follow-up work.

Stop for review after these four core checkpoints:

1. **Task 5:** the LocalAgent shipping App owns the migrated chat/product shell,
   iSH/tools/Skills, provider UI, and local-model selection.
2. **Task 8:** the Rust transcript, context, and direct ReAct loop pass focused
   tests without a business state machine.
3. **Task 12:** the complete LocalAgent product path runs through Rust,
   Swift model/tool runtimes, atomic transcript commits, and one-way
   projection.
4. **Task 16:** clean checkout, three product paths, full package tests, and
   iPhone/iPad shipping-App tests pass.

Do not continue across a checkpoint while its focused suite is red.
Each selected optional slice is its own checkpoint and never changes the
meaning of core Task 16 success.

## Explicitly Deferred

The following are not part of this implementation:

- every Task 13/14 slice not explicitly selected in the implementation
  PR/task description;
- broad “remaining UI,” WebApp, settings, diagnostics UI, or polish migration
  without a separately approved exact-file slice;
- cross-device synchronization of canonical conversation events;
- a concrete production memory backend beyond the retained `MemoryProvider`
  interface and test fake;
- enforcement of iSH guest networking at the socket/connect boundary;
- a generic extension command inbox before a real mutation-capable extension
  requires one;
- the later LocalAgent visual/UI/UX redesign;
- a plugin framework or runtime-configurable model-turn limit;
- a second model HTTP transport, transcript store, projection bus, tool
  executor, or agent state machine.

## Final Acceptance Contract

Implementation is complete only when:

- `LocalAgentApp.xcodeproj` is the only shipping App and preserves LocalAgent
  identity;
- OpenMinis code exists only in selective LocalAgent-owned destinations and
  every shipping slice is present in the migration manifest;
- the clean checkout build regenerates pinned iSH/rootfs/FFmpeg/LAME outputs;
- file tools preserve ordinary iSH guest paths such as `/tmp`, `/root`, and
  `/usr`, while `/var/localagent/{skills,shared,attachments,mounts}` uses the
  separate checked host-mount boundary;
- Rust is the only Agent Core and canonical transcript writer;
- Swift provides the product shell plus one model request executor and one
  ordered tool-batch executor;
- cloud HTTP runs only through `LocalAgentLLMCloud`, while the existing C++
  backend remains the local-model path;
- Prompt documents, tool schemas, progressive Skill descriptors, and the
  Swift provider plan are frozen at run start;
- Rust rebuilds complete Context for every model turn from the current
  canonical conversation, including newly committed tool results, and reruns
  budget/sensitivity/compaction;
- `MAX_MODEL_TURNS` is 200 and OpenMinis `ToolLoopDetector` remains run-scoped;
- all transcript mutations enter Rust commands and ChatStore receives only
  idempotent `(conversation_stream_id, sequence)` projections;
- API keys and OAuth tokens never enter Rust snapshots, iSH, files, tools,
  sync, logs, or diagnostics;
- every new Swift App/test/resource has explicit Xcode target membership and
  every new Rust test module is registered and discovered with a nonzero test
  list;
- the three product-path tests and all focused suites pass.

For each explicitly selected Task 13/14 slice only:

- its exact source allowlist, focused test, Xcode/resource membership,
  migration-manifest rows, and independent commit exist;
- extension processes never write canonical transcript or ChatStore;
- if Backup is selected, import requires zero active runs, validates before
  writing, rejects stream conflicts, commits atomically, and wakes projection
  afterward;
- if Sync is selected, only global Skill/non-secret product data syncs and
  conversation/session-override records remain excluded.

## Plan Execution Choice

After this plan is reviewed, execute it in the dedicated implementation
worktree with `superpowers:subagent-driven-development` or
`superpowers:executing-plans`. Run the core chain
`1–12 → 15 → 16`; execute only explicitly selected Task 13/14 slices as
separate commits. Do not implement inside the donor/reference worktree.
