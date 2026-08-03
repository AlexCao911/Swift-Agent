# LocalAgent Convergence Phase 0–1 Evidence and Pure Deletion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish a truthful, reproducible baseline for the current LocalAgent product and remove only code proven to have no shipping production caller, leaving one buildable production system ready for the separate Rust Core 23-to-6 convergence plan.

**Architecture:** Phase 0 records the current Rust, Swift/Xcode, persistence, product-path, and performance reality without repairing the old architecture. Phase 1 deletes isolated zero-production-caller subgraphs without adding replacements or changing live Builder, Agent loop, conversation, Host, storage, or FFI behavior. The plan stops at the Phase 2 Core-shape entry gate defined by the approved design.

**Tech Stack:** Rust 2021/Cargo, Swift 6/SwiftUI, Swift Package Manager, Xcode 26, iOS/iPadOS 17+, Objective-C iSH sources, C++17/llama.cpp, SQLite, shell-based CI, XCTest/Swift Testing, Instruments/xctrace.

**Design Source:** `local-ios-agent/docs/superpowers/specs/2026-08-02-localagent-architecture-convergence-uiux-design.md`

**Scope:** This plan implements only Phase 0 and Phase 1 from the design. Phase 2 Core convergence, Phase 3 flat Agent profiles, Phase 4 conversation-first UIUX, and Phase 5 final cleanup each require a later plan after the preceding gate passes.

## Global Constraints

- `supported_upgrade = ∅`. LocalAgent has never shipped and has no users. Do not add a translator, legacy reader, dual writer, compatibility database, migration facade, or in-App general reset framework.
- Use a dedicated disposable Simulator for reset and measurement. Never erase a daily-use Simulator, a physical device, `booted`, or an unresolved UDID.
- Phase 0 is capped at one engineer-day. It may repair a false CI command or add one focused architecture assertion, but it must not repair or redesign live business behavior.
- Task 6 is capped at half an engineer-day. Collect only the baselines named in that task; do not spend the time-box cataloguing unsupported scale fixtures or instrumentation gaps.
- Phase 1 creates no replacement facade, service, manager, registry, DTO layer, package, event bus, cache, or feature framework.
- A Phase 1 deletion requires evidence that the candidate has no shipping production caller. Test/build callers that exist solely to exercise a non-shipping subsystem are removed with that subsystem.
- Phase 1 defaults to deleting proven zero-caller subgraphs. If the audit instead proves that an entire Rust public root has no production, ABI, build, or retained test caller, delete that root as one buildable slice and update the later 23-to-6 disposition map; do not predetermine the audit result.
- Keep current live Builder, Run, conversation, Host, reliable transport, effect ledger, native permission, App Intent, provider, local-model, attachment, Skill, iSH, Browser, and FFI paths until their owning Phase 2/3/4 vertical replacement slice.
- Do not modify `OpenMinis/`, `pi/`, `.derivedData/`, `.superpowers/`, `audits/`, or developer-local scheme environment values. Those are not implementation inputs.
- Preserve `local-ios-agent/apps/LocalAgentApp` as the only shipping App and preserve OpenMinis-derived license/source provenance.
- Keep the C ABI and wire DTOs platform-neutral: no Apple-only paths or types enter them. Android/Kotlin/JNI remains out of scope.
- Run all Xcode, SwiftPM, and native-preparation commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`; do not mix the Command Line Tools Swift toolchain with the selected Xcode toolchain.
- Every Rust test file remains explicitly registered in `rust-core/tests/{unit,contract,integration,golden,lint}.rs`; zero discovered tests is failure.
- `LocalAgentApp.xcodeproj` uses explicit PBX membership. Every Swift/Objective-C source or test deletion updates `project.pbxproj` in the same commit.
- Run focused tests inside each task and the complete gates only at Phase exits. Do not add a giant product test that repeats focused error, race, cancellation, or validation suites.
- Commit each task separately. A deletion commit must be buildable and independently revertible.

## Execution Workspace

Before Task 1, read and follow `superpowers:using-git-worktrees`, then create an isolated implementation worktree from the commit containing this plan:

```bash
cd /Users/alexandercou/Projects/Alex-agent
git status --short
git worktree add \
  /Users/alexandercou/Projects/Alex-agent/.worktrees/localagent-convergence-phase-0-1 \
  -b codex/localagent-convergence-phase-0-1 \
  master
cd /Users/alexandercou/Projects/Alex-agent/.worktrees/localagent-convergence-phase-0-1
git rev-parse HEAD
```

Expected:

- the new worktree is clean;
- it contains this plan and the approved design;
- developer-local changes from the primary worktree are absent.

Use these required environment inputs for Simulator work:

```bash
: "${LOCAL_AGENT_CONVERGENCE_IPHONE_UDID:?Set a dedicated disposable iPhone Simulator UDID}"
: "${LOCAL_AGENT_CONVERGENCE_IPAD_UDID:?Set a dedicated disposable iPad Simulator UDID}"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun simctl list devices available \
  | rg -F "$LOCAL_AGENT_CONVERGENCE_IPHONE_UDID"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun simctl list devices available \
  | rg -F "$LOCAL_AGENT_CONVERGENCE_IPAD_UDID"
```

Record the resolved device names, OS runtime, and UDIDs in the evidence document before any erase. If either UDID is not an explicitly dedicated test Simulator, stop.

## Evidence Artifact

Phase 0 and Phase 1 maintain one concise ledger:

```text
local-ios-agent/docs/convergence/phase-0-1-evidence.md
```

It contains exactly these sections:

1. environment and baseline commit;
2. 23-root Rust caller/disposition matrix;
3. Swift/Xcode/SwiftPM/source/resource caller matrix;
4. development-data reset inventory;
5. current product smoke paths and known seams;
6. Debug build/launch smoke and Release performance samples/medians;
7. Phase 0/1 change/deletion ledger with scope reason and, for deletions, before/after caller evidence;
8. Phase 2 Core-shape entry checklist.

Raw `.trace`, `.xcresult`, DerivedData, downloaded models, native build products, SQLite databases, and Simulator containers remain under `/private/tmp` or ignored build directories. Commit only commands, metadata, raw numeric samples, medians, conclusions, and stable source evidence.

---

## Phase 0 — Minimal Evidence

### Task 1: Make the Existing Baseline Gate Truthful

**Files:**

- Modify: `scripts/ci/rust-unit.sh`
- Modify: `scripts/ci/rust-contract.sh`
- Create: `local-ios-agent/docs/convergence/phase-0-1-evidence.md`

**Why:** The umbrella CI currently contains one nonexistent Cargo feature/test and one nonexistent unit-test filter. A red command and a zero-test false green cannot be the Phase 0 baseline.

- [ ] **Step 1: Prove the two stale commands before editing**

Run from the repository root:

```bash
rg -n 'builtin-openai-compatible|compiled_list_includes_openai_provider_when_feature_is_enabled' \
  local-ios-agent/rust-core scripts/ci
rg -n 'localhost_transport_uses_content_length_and_does_not_wait_for_eof' \
  local-ios-agent/rust-core scripts/ci
scripts/ci/rust-contract.sh
```

Expected:

- both symbols occur only in CI scripts;
- `rust-contract.sh` fails because `builtin-openai-compatible` is not a declared feature.

- [ ] **Step 2: Remove only the stale invocations**

Change `scripts/ci/rust-unit.sh` to one real command:

```bash
cargo test --test unit -- --test-threads=1
```

Change `scripts/ci/rust-contract.sh` to one real command:

```bash
cargo test --test contract
```

Do not add features, replacement tests, network exceptions, or compatibility aliases.

- [ ] **Step 3: Create the evidence ledger header**

Record:

- `git rev-parse HEAD` on a machine-readable `baseline_sha: <40-hex>` line;
- `rustc --version`, `cargo --version`, `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift --version`, and `xcodebuild -version`;
- macOS version and CPU/RAM summary;
- the two dedicated Simulator identities;
- `supported_upgrade = ∅`;
- the exact verification command set used by this plan.

- [ ] **Step 4: Run the truthful baseline suites**

```bash
CARGO_NET_OFFLINE=true cargo test \
  --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test unit -- --test-threads=1
CARGO_NET_OFFLINE=true cargo test \
  --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test contract
CARGO_NET_OFFLINE=true cargo test \
  --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test lint test_taxonomy -- --nocapture
```

Expected: all commands pass and each reports a nonzero number of tests.

- [ ] **Step 5: Commit**

```bash
git add scripts/ci/rust-unit.sh scripts/ci/rust-contract.sh \
  local-ios-agent/docs/convergence/phase-0-1-evidence.md
git commit -m "test: make convergence baseline gate truthful"
```

### Task 2: Record the Complete Rust 23-Root Caller Matrix

**Files:**

- Modify: `local-ios-agent/docs/convergence/phase-0-1-evidence.md`
- Inspect: `local-ios-agent/rust-core/src/lib.rs`
- Inspect: `local-ios-agent/rust-core/src/**/*.rs`
- Inspect: `local-ios-agent/rust-core/tests/**/*.rs`
- Inspect: `local-ios-agent/toolkit/Sources/CLocalAgentRuntime/include/CLocalAgentRuntime.h`
- Inspect: `local-ios-agent/toolkit/Sources/LocalAgentBridge/RustRuntimeClient.swift`
- Inspect: `local-ios-agent/toolkit/Package.swift`

- [ ] **Step 1: Freeze the root list and source-size baseline**

```bash
sed -n '1,80p' local-ios-agent/rust-core/src/lib.rs
rg --files local-ios-agent/rust-core/src -g '*.rs' | wc -l
rg --files local-ios-agent/rust-core/tests -g '*.rs' | wc -l
rg --files -0 local-ios-agent/rust-core/src -g '*.rs' \
  | xargs -0 wc -l | tail -1
rg --files -0 local-ios-agent/rust-core/tests -g '*.rs' \
  | xargs -0 wc -l | tail -1
```

Expected: `lib.rs` declares exactly the current 23 public roots. Record file and line totals as a baseline, not a deletion target.

- [ ] **Step 2: Generate direct production and test caller evidence**

```bash
rg -n \
  'crate::(agent_input|agent_loop|agent_package|app_service|canonical_digest|context|conversation|core|execution|ffi_bridge|host_adapter|llm_contracts|memory|migration|prompt|protocol|run_snapshot|security|skills|storage|tool|user_customization|utils)\b' \
  local-ios-agent/rust-core/src \
  --glob '!lib.rs'
rg -n -U \
  '(?s)use\s+crate::\{.*?\b(agent_input|agent_loop|agent_package|app_service|canonical_digest|context|conversation|core|execution|ffi_bridge|host_adapter|llm_contracts|memory|migration|prompt|protocol|run_snapshot|security|skills|storage|tool|user_customization|utils)\b.*?\};' \
  local-ios-agent/rust-core/src \
  --glob '!lib.rs'
rg -n \
  'local_ios_agent_runtime::(agent_input|agent_loop|agent_package|app_service|canonical_digest|context|conversation|core|execution|ffi_bridge|host_adapter|llm_contracts|memory|migration|prompt|protocol|run_snapshot|security|skills|storage|tool|user_customization|utils)\b' \
  local-ios-agent/rust-core/tests
rg -n -U \
  '(?s)use\s+local_ios_agent_runtime::\{.*?\b(agent_input|agent_loop|agent_package|app_service|canonical_digest|context|conversation|core|execution|ffi_bridge|host_adapter|llm_contracts|memory|migration|prompt|protocol|run_snapshot|security|skills|storage|tool|user_customization|utils)\b.*?\};' \
  local-ios-agent/rust-core/tests
rg -n 'local_agent_runtime_|liblocal_ios_agent_runtime|RustRuntimeClient' \
  local-ios-agent/toolkit/Sources/CLocalAgentRuntime \
  local-ios-agent/toolkit/Sources/LocalAgentBridge \
  local-ios-agent/toolkit/Package.swift
```

Grouped imports are mandatory evidence. A direct-path query alone misses any root nested under `use crate::{...}` or `use local_ios_agent_runtime::{...}`.

- [ ] **Step 3: Fill all 23 matrix rows**

Use these columns for every root:

| Current root | Direct production caller(s) | ABI/Swift/build caller | Test caller(s) | Phase 1 action | Final design disposition |
| --- | --- | --- | --- | --- | --- |

Treat every previously observed caller as a hypothesis to verify, not as the required conclusion. Classify each root from the captured evidence:

- retain when it has a shipping production, C ABI, Swift, build, or retained-test caller;
- delete a zero-caller subgraph when only part of the root is dead;
- allow whole-root deletion when the root has no production, ABI, Swift, build, resource, or retained-test caller and every test-only caller can be removed with it;
- when a whole root qualifies, add its buildable deletion slice to Phase 1 and update the final 23-to-6 disposition map before implementation.

Record the actual conclusion and its commands. Do not preserve a root merely because the current design expected it to survive, and do not infer reachability from a directory name or a stale test alone.

- [ ] **Step 4: Record the file-level Phase 1 candidates**

Add exact rows for the candidates used by Tasks 7–10, including exported symbols, current test-only callers, and the post-delete zero-caller query. Do not add a speculative candidate without a reproducible query.

- [ ] **Step 5: Verify and commit**

```bash
CARGO_NET_OFFLINE=true cargo test \
  --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test lint test_taxonomy -- --nocapture
git add local-ios-agent/docs/convergence/phase-0-1-evidence.md
git commit -m "docs: record Rust convergence caller matrix"
```

### Task 3: Record Swift, Xcode, SwiftPM, Framework, and Resource Ownership

**Files:**

- Modify: `local-ios-agent/docs/convergence/phase-0-1-evidence.md`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Architecture/ShippingTargetOwnershipTests.swift`
- Inspect: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj/project.pbxproj`
- Inspect: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj/xcshareddata/xcschemes/LocalAgentApp.xcscheme`
- Inspect: `local-ios-agent/toolkit/Package.swift`

- [ ] **Step 1: Generate the ignored Simulator-native inputs**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  local-ios-agent/scripts/prepare-ios-native.sh --platform iphonesimulator
```

Expected: pinned iSH/LAME/FFmpeg/rootfs inputs and `LocalAgentInferenceNative.xcframework` are rebuilt from the clean checkout. They remain ignored and are never staged.

- [ ] **Step 2: Capture the current project graph**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -list -json \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -showBuildSettings \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift package --package-path local-ios-agent/toolkit describe --type json
```

Record:

- exactly two native targets: `LocalAgentApp` and `LocalAgentAppTests`;
- the scheme pre-action and four App build phases;
- all seven local SwiftPM products and three remote Markdown/math products linked by the App;
- the Rust static-library link chain;
- the seven App resource groups/files, including generated rootfs/native inputs;
- that no Share/FileProvider extension target currently exists;
- that FFmpeg/LAME are build-contract inputs but are not proven linked callers merely because a verification script mentions them.

- [ ] **Step 3: Add one exhaustive source-membership assertion**

Extend `ShippingTargetOwnershipTests.swift` with one test that:

1. parses only the `PBXNativeTarget`, `PBXSourcesBuildPhase`, `PBXBuildFile`, `PBXFileReference`, and `PBXGroup` sections;
2. resolves `LocalAgentApp` and `LocalAgentAppTests` by target name, follows each target's build-phase object IDs to its Sources phase, then resolves every build file through its file-reference ID and the complete parent-group `path` chain;
3. normalizes those results to project-relative paths, using `<group>` inheritance and `SOURCE_ROOT` relative to the `.xcodeproj` directory; PBX comments and `name` are display metadata, not path identity;
4. enumerates the App's compilable `.swift`/`.m` files and the test target's `.swift` files as the same project-relative paths;
5. compares filesystem and PBX path sets separately per target, reporting sorted `missing from target` and `unexpected in target` paths;
6. rejects the same resolved path appearing twice in one Sources phase, while explicitly allowing equal basenames in different directories or targets.

Use Foundation plus a lightweight section scanner/`NSRegularExpression`; do not add an Xcode project parser dependency or generated manifest. If the project later adopts `PBXFileSystemSynchronizedRootGroup`, fail with an explicit unsupported-format message until the gate is updated. Do not assert basename uniqueness.

- [ ] **Step 4: Run the architecture test**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -destination "platform=iOS Simulator,id=$LOCAL_AGENT_CONVERGENCE_IPHONE_UDID" \
  -derivedDataPath /private/tmp/localagent-convergence-task3 \
  -only-testing:LocalAgentAppTests/ShippingTargetOwnershipTests
```

Expected: the suite passes, discovers at least the existing ownership tests plus the new exhaustive membership test, and reports no orphan or missing source.

- [ ] **Step 5: Fill the Swift/Xcode matrix**

For every App presentation/runtime group and every SwiftPM target, record:

- shipping route/composition caller;
- PBX/SwiftPM membership;
- resource/framework dependency;
- test-only caller, if any;
- Phase 1 delete/retain decision.

Explicitly mark App Intents as system-discovered and therefore not dead merely because static `rg` finds no caller.

- [ ] **Step 6: Commit**

```bash
git add \
  local-ios-agent/docs/convergence/phase-0-1-evidence.md \
  local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Architecture/ShippingTargetOwnershipTests.swift
git commit -m "test: lock Xcode source ownership baseline"
```

### Task 4: Record the Development-Data Ownership and Reset Inventory

**Files:**

- Modify: `local-ios-agent/docs/convergence/phase-0-1-evidence.md`
- Inspect: current Rust/Swift persistence, Keychain, asset, model, temporary-run, and projection owners discovered by Task 2/3

- [ ] **Step 1: Fill one reset inventory table from verified owners**

Keep this section to one table. Resolve every broad path to the exact current path or namespace discovered in source; do not reproduce the design's future Phase 2/3/4 schedule.

| Category | Current owner/path | Convergence action |
| --- | --- | --- |
| Canonical/runtime data | Exact Rust canonical/runtime stores and Swift provider/model metadata stores | With all Runs stopped, replace Rust canonical/runtime stores with `localagent.sqlite`; rebuild Swift product metadata in its final Swift-owned store; no translator, legacy reader, or dual writer |
| Credentials | Exact Keychain service/record namespace | Retain references used by the final profile schema and delete only orphaned records in that namespace; never bulk-clear Keychain |
| Skills, Prompt documents, and attachments | Exact managed file roots and metadata owners | Keep assets already in the final format or re-import through the product path; no compatibility scanner |
| Local model files | Exact model repository, index, download, and staging paths | Re-download, or let the final repository rebuild its own index; do not migrate the legacy index |
| Run/effect temporary state | Exact provider-plan, lease, receipt/effect, and pending-interaction owners | Stop active work, then clear the complete temporary-state group at cutover |
| Caches/UI projections | Exact Swift projection, browser/WebKit, URLSession, and UI cache owners | Treat as rebuildable and clear at any time; never use them as canonical input |

- [ ] **Step 2: Record the only reset rules**

Record these hard rules:

- the first distributed build is a clean install;
- no reset code ships in the product;
- CI and convergence work use a dedicated erased Simulator;
- no legacy database, JSON, sidecar, profile/component schema, or cache is read, attached, translated, or dual-written after its owning cutover;
- file assets are either already final-format or re-imported, and model files are re-downloaded or indexed by the final repository;
- Keychain cleanup, if ever needed outside Simulator erase, is restricted to the exact service namespace and never clears the whole Keychain.

- [ ] **Step 3: Validate and erase only the dedicated Simulator**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun simctl list devices available \
  | rg -F "$LOCAL_AGENT_CONVERGENCE_IPHONE_UDID"
if DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun simctl list devices \
  | rg -F "$LOCAL_AGENT_CONVERGENCE_IPHONE_UDID" \
  | rg -q '\(Booted\)'; then
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    /usr/bin/xcrun simctl shutdown "$LOCAL_AGENT_CONVERGENCE_IPHONE_UDID"
fi
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun simctl erase "$LOCAL_AGENT_CONVERGENCE_IPHONE_UDID"
```

Expected: an active dedicated Simulator is shut down first; an already-shut-down dedicated Simulator skips shutdown without failing; only the pre-recorded Simulator is erased. Do not run against the iPad yet; it remains a second clean build target.

- [ ] **Step 4: Commit**

```bash
git add local-ios-agent/docs/convergence/phase-0-1-evidence.md
git commit -m "docs: freeze pre-release reset contract"
```

### Task 5: Freeze the Two Product Smoke Paths Without Expanding Them

**Files:**

- Modify: `local-ios-agent/docs/convergence/phase-0-1-evidence.md`
- Verify: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Integration/RustReActProductPathTests.swift`
- Verify: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Integration/RelaunchProjectionReplayProductTests.swift`
- Verify: `local-ios-agent/toolkit/Tests/LocalAgentLLMCloudTests/CloudProductPathIntegrationTests.swift`
- Verify: `local-ios-agent/toolkit/Tests/LocalAgentLLMLocalTests/LocalProductPathIntegrationTests.swift`

- [ ] **Step 1: Run the deterministic App product tests**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -destination "platform=iOS Simulator,id=$LOCAL_AGENT_CONVERGENCE_IPHONE_UDID" \
  -derivedDataPath /private/tmp/localagent-convergence-smoke \
  -only-testing:LocalAgentAppTests/RustReActProductPathTests \
  -only-testing:LocalAgentAppTests/RelaunchProjectionReplayProductTests
```

Expected:

- one two-round/two-tool Rust ReAct path reaches final Swift projection;
- one projection relaunch replays cursor state, repairs a sequence gap, and releases subscriptions;
- exactly two focused product suites run.

- [ ] **Step 2: Run the cloud and local runtime product seams**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path local-ios-agent/toolkit \
  --filter CloudProductPathIntegrationTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path local-ios-agent/toolkit \
  --filter LocalProductPathIntegrationTests
```

Expected: both focused suites pass.

- [ ] **Step 3: Record coverage honestly**

The evidence must state:

- the ReAct App test uses the real Rust runtime/Host/tool composition but a deterministic fake provider route and test model preparer;
- the relaunch test persists the Swift projection store but uses a fake conversation client;
- these are the current Phase 0 smoke paths, not proof of the final Phase 2 composition;
- the later Phase 2 plan must replace the seams with one test using the final runtime composition and one true close/reopen of final `localagent.sqlite` plus projection replay;
- old Builder/binding bootstrap tests are not promoted into future product gates.

- [ ] **Step 4: Commit evidence only**

```bash
git add local-ios-agent/docs/convergence/phase-0-1-evidence.md
git commit -m "docs: freeze current product smoke paths"
```

### Task 6: Record the Lean Phase 0 Performance Baseline

**Files:**

- Modify: `local-ios-agent/docs/convergence/phase-0-1-evidence.md`
- Verify: `local-ios-agent/rust-core/tests/integration/react_loop.rs`

**Time-box:** Complete this task within half an engineer-day. Phase 0 as a whole remains capped at one engineer-day.

**Rule:** Debug proves only that the App builds and launches. All measurements use the Release build. Do not add a benchmark framework, production signpost layer, scale fixture generator, cache, scheduler, or profiling abstraction. Record five raw readings and a median for every Release row; size readings are expected to be identical because they come from one build.

- [ ] **Step 1: Freeze the small measurement environment**

Record only:

- baseline commit;
- dedicated iPhone Simulator model/UDID and iOS runtime;
- macOS, Xcode, Rust, and Swift versions;
- thermal state and other foreground workloads;
- the exact commands below.

The Phase 0 metric table has exactly these rows:

| Metric | Configuration | Samples |
| --- | --- | --- |
| Debug build and launch | Debug | one smoke result; no timing |
| Cold App launch | Release | five raw samples and median |
| Rust runtime initialization | Release | the Rust bridge interval from the same five launch traces and median |
| Idle RSS and CPU activity | Release | five raw samples after a fixed settling interval and median |
| Deterministic first ReAct turn | Rust Release test binary | five raw samples and median |
| Rust archive, linked App executable, App bundle | Release | five readings and median for each |

Do not add warm launch, cloud/local request, conversation-count, event-count, iSH, Browser, local-model activation, or SQLite-transaction rows. Those belong to the final store or their owning runtime/provider slice.

- [ ] **Step 2: Build and launch Debug once**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$LOCAL_AGENT_CONVERGENCE_IPHONE_UDID" \
  -derivedDataPath /private/tmp/localagent-convergence-debug
LOCAL_AGENT_DEBUG_APP=/private/tmp/localagent-convergence-debug/Build/Products/Debug-iphonesimulator/LocalAgentApp.app
test -d "$LOCAL_AGENT_DEBUG_APP"
if ! DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun simctl list devices \
  | rg -F "$LOCAL_AGENT_CONVERGENCE_IPHONE_UDID" \
  | rg -q '\(Booted\)'; then
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    /usr/bin/xcrun simctl boot "$LOCAL_AGENT_CONVERGENCE_IPHONE_UDID"
fi
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun simctl bootstatus "$LOCAL_AGENT_CONVERGENCE_IPHONE_UDID" -b
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun simctl install \
    "$LOCAL_AGENT_CONVERGENCE_IPHONE_UDID" "$LOCAL_AGENT_DEBUG_APP"
LOCAL_AGENT_DEBUG_LAUNCH="$(
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    /usr/bin/xcrun simctl launch --terminate-running-process \
      "$LOCAL_AGENT_CONVERGENCE_IPHONE_UDID" com.localagent.app
)"
LOCAL_AGENT_DEBUG_PID="${LOCAL_AGENT_DEBUG_LAUNCH##*: }"
case "$LOCAL_AGENT_DEBUG_PID" in
  ''|*[!0-9]*) exit 1 ;;
esac
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun simctl terminate \
    "$LOCAL_AGENT_CONVERGENCE_IPHONE_UDID" com.localagent.app
```

Expected: Debug builds, installs, launches with a numeric PID, and terminates. Record pass/fail only; do not repeat or time it.

- [ ] **Step 3: Build Release once**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -configuration Release \
  -destination "platform=iOS Simulator,id=$LOCAL_AGENT_CONVERGENCE_IPHONE_UDID" \
  -derivedDataPath /private/tmp/localagent-convergence-release
LOCAL_AGENT_RELEASE_APP=/private/tmp/localagent-convergence-release/Build/Products/Release-iphonesimulator/LocalAgentApp.app
test -d "$LOCAL_AGENT_RELEASE_APP"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun simctl uninstall \
    "$LOCAL_AGENT_CONVERGENCE_IPHONE_UDID" com.localagent.app
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun simctl install \
    "$LOCAL_AGENT_CONVERGENCE_IPHONE_UDID" "$LOCAL_AGENT_RELEASE_APP"
```

Expected: one Release build succeeds and replaces the Debug App on the dedicated Simulator.

- [ ] **Step 4: Measure Release cold launch and Rust initialization five times**

Create five uniquely named App Launch traces:

```bash
LOCAL_AGENT_TRACE_DIR="$(
  mktemp -d /private/tmp/localagent-convergence-traces.XXXXXX
)"
for SAMPLE in 1 2 3 4 5; do
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    /usr/bin/xcrun simctl terminate \
      "$LOCAL_AGENT_CONVERGENCE_IPHONE_UDID" com.localagent.app 2>/dev/null || true
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    /usr/bin/xcrun xctrace record \
      --template 'App Launch' \
      --device "$LOCAL_AGENT_CONVERGENCE_IPHONE_UDID" \
      --time-limit 15s \
      --output "$LOCAL_AGENT_TRACE_DIR/release-launch-$SAMPLE.trace" \
      --launch -- "$LOCAL_AGENT_RELEASE_APP"
done
```

Inspect/export the five traces using the same Instruments view. Record total cold-launch duration and the symbol interval rooted at `local_agent_runtime_bridge_new_with_config` for every sample, plus each median. Keep traces outside Git. The Release dSYM must resolve this symbol in all five traces; otherwise Task 6 fails and Phase 0 does not close. Do not omit the required metric or add a new instrumentation layer to work around failed symbolication.

- [ ] **Step 5: Measure Release idle RSS and CPU activity**

Launch once, wait the same 30-second settling interval, then collect five process samples five seconds apart:

```bash
LOCAL_AGENT_RELEASE_LAUNCH="$(
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    /usr/bin/xcrun simctl launch --terminate-running-process \
      "$LOCAL_AGENT_CONVERGENCE_IPHONE_UDID" com.localagent.app
)"
LOCAL_AGENT_RELEASE_PID="${LOCAL_AGENT_RELEASE_LAUNCH##*: }"
case "$LOCAL_AGENT_RELEASE_PID" in
  ''|*[!0-9]*) exit 1 ;;
esac
sleep 30
for SAMPLE in 1 2 3 4 5; do
  /bin/ps -o pid=,rss=,%cpu=,etime= -p "$LOCAL_AGENT_RELEASE_PID"
  sleep 5
done
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun simctl terminate \
    "$LOCAL_AGENT_CONVERGENCE_IPHONE_UDID" com.localagent.app
```

Record the five RSS and CPU values and their medians. Do not activate iSH, Browser, or a local model in this task.

- [ ] **Step 6: Measure one deterministic Release ReAct turn**

Build the existing offline integration test once, capture the emitted test executable path, and run only the direct text-turn test five times:

```bash
LOCAL_AGENT_REACT_BUILD_LOG=/private/tmp/localagent-react-release-build.log
CARGO_NET_OFFLINE=true cargo test \
  --release \
  --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test integration \
  --no-run 2>&1 | tee "$LOCAL_AGENT_REACT_BUILD_LOG"
LOCAL_AGENT_REACT_TEST_BIN="$(
  sed -n 's/^  Executable .* (\(.*\/integration-[^)]*\))$/\1/p' \
    "$LOCAL_AGENT_REACT_BUILD_LOG" \
    | tail -1
)"
test -n "$LOCAL_AGENT_REACT_TEST_BIN"
test -x "$LOCAL_AGENT_REACT_TEST_BIN"
for SAMPLE in 1 2 3 4 5; do
  /usr/bin/time -p "$LOCAL_AGENT_REACT_TEST_BIN" \
    --exact react_loop::text_only_turn_commits_once_and_closes_the_model
done
```

Record the five elapsed values and median as a stable offline Rust ReAct first-turn proxy. It is not a cloud-provider latency measurement.

- [ ] **Step 7: Record Release binary sizes five times**

```bash
for SAMPLE in 1 2 3 4 5; do
  /usr/bin/stat -f '%z' \
    local-ios-agent/rust-core/target/xcode-ios/liblocal_ios_agent_runtime.a
  /usr/bin/stat -f '%z' \
    /private/tmp/localagent-convergence-release/Build/Products/Release-iphonesimulator/LocalAgentApp.app/LocalAgentApp
  /usr/bin/du -sk \
    /private/tmp/localagent-convergence-release/Build/Products/Release-iphonesimulator/LocalAgentApp.app
done
```

Record five Rust archive-byte, linked-App-executable-byte, and App-bundle-KiB readings plus each median. All five should match; a mismatch means the artifact changed during measurement and the run is invalid.

- [ ] **Step 8: Commit**

```bash
git add local-ios-agent/docs/convergence/phase-0-1-evidence.md
git commit -m "docs: record lean LocalAgent convergence baselines"
```

---

## Phase 1 — Pure Deletion

Tasks 7–13 are deletion candidates, not predetermined outcomes. In every task, Step 1 is a hard evidence gate: if it finds a production, ABI, build, resource, or retained-test caller not already classified in Task 2/3, stop that deletion, record `retain/skip` and the caller in the ledger, and continue to the next candidate. Never edit around a newly discovered caller merely to make the planned deletion pass.

### Task 7: Delete the Obsolete Agent-Package Export and Upgrade Subgraph

**Files:**

- Delete: `local-ios-agent/rust-core/src/agent_package/upgrade_planner.rs`
- Delete: `local-ios-agent/rust-core/src/agent_package/exporter.rs`
- Delete: `local-ios-agent/rust-core/src/agent_package/reader.rs`
- Modify: `local-ios-agent/rust-core/src/agent_package/mod.rs`
- Modify: `local-ios-agent/rust-core/tests/contract/agent_package_agent_os.rs`
- Delete: `local-ios-agent/rust-core/tests/golden/agent_package_export.rs`
- Modify: `local-ios-agent/rust-core/tests/golden.rs`
- Modify: `local-ios-agent/docs/convergence/phase-0-1-evidence.md`

**Retain:** installer, manifest, lockfile, validator, and host-binding state still used by the old production Builder/binding path.

- [ ] **Step 1: Re-run the candidate caller proof**

```bash
rg -n \
  '\b(AgentProfileUpgradePlanner|AgentProfileUpgradeReport|ComponentUpgradeIssue|ComponentUpgradeOperation|ComponentVersionStatus|RuntimeComponentCatalog|AgentPackageExporter|ExportedAgentPackage|AgentPackageReader|PackageInspectReport|PackagePath)\b' \
  local-ios-agent/rust-core/src \
  local-ios-agent/rust-core/tests \
  local-ios-agent/toolkit/Sources \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp
```

Expected: upgrade symbols occur only in their source/re-export; export/reader symbols occur only in their source/re-export and the listed contract/golden tests.

`AgentPackageReader` also appears as a string in the architecture lint that forbids Context from depending on package readers. That negative guard is not a caller and remains in place.

- [ ] **Step 2: Delete the obsolete subgraph and its tests**

Remove the three modules and re-exports. In `agent_package_agent_os.rs`, delete only the private schema-v1 reader, export round-trip, and reader path-traversal tests; retain install, validation, and no-side-effect coverage. Remove the golden module registration with its file.

- [ ] **Step 3: Verify zero symbols and retained package behavior**

```bash
! rg -n \
  '\b(AgentProfileUpgradePlanner|AgentProfileUpgradeReport|ComponentUpgradeIssue|ComponentUpgradeOperation|ComponentVersionStatus|RuntimeComponentCatalog|AgentPackageExporter|ExportedAgentPackage|AgentPackageReader|PackageInspectReport|PackagePath)\b' \
  local-ios-agent/rust-core/src \
  local-ios-agent/rust-core/tests/{unit,contract,integration,golden}
CARGO_NET_OFFLINE=true cargo test \
  --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test contract agent_package -- --nocapture
CARGO_NET_OFFLINE=true cargo test \
  --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test golden -- --nocapture
CARGO_NET_OFFLINE=true cargo test \
  --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test lint test_taxonomy -- --nocapture
```

Expected: all pass; install/validator behavior remains; deleted symbols have zero hits.

- [ ] **Step 4: Update ledger and commit**

```bash
git add -A local-ios-agent/rust-core \
  local-ios-agent/docs/convergence/phase-0-1-evidence.md
git commit -m "refactor: delete obsolete agent package export paths"
```

### Task 8: Delete the Generic Protocol Registry and Lifecycle Subgraph

**Files:**

- Delete: `local-ios-agent/rust-core/src/protocol/archive.rs`
- Delete: `local-ios-agent/rust-core/src/protocol/definition.rs`
- Delete: `local-ios-agent/rust-core/src/protocol/host_capability.rs`
- Delete: `local-ios-agent/rust-core/src/protocol/instance.rs`
- Delete: `local-ios-agent/rust-core/src/protocol/plugin_module.rs`
- Delete: `local-ios-agent/rust-core/src/protocol/runtime_plugin_registry.rs`
- Delete: `local-ios-agent/rust-core/src/protocol/schema_version.rs`
- Delete: `local-ios-agent/rust-core/src/protocol/snapshot.rs`
- Delete: `local-ios-agent/rust-core/src/protocol/typed_registry.rs`
- Modify: `local-ios-agent/rust-core/src/protocol/ids.rs`
- Modify: `local-ios-agent/rust-core/src/protocol/mod.rs`
- Delete: `local-ios-agent/rust-core/tests/contract/protocol_registry.rs`
- Modify: `local-ios-agent/rust-core/tests/contract/protocol_lifecycle.rs`
- Modify: `local-ios-agent/rust-core/tests/contract.rs`
- Modify: `local-ios-agent/docs/convergence/phase-0-1-evidence.md`

**Retain:** `protocol::binding`, `BindingId`, `InstanceId`, `ComponentBinding`, and `SlotKey`, because the old production profile path still imports them.

- [ ] **Step 1: Prove the retained and deleted halves**

```bash
rg -n '\b(ComponentBinding|BindingId|InstanceId|SlotKey)\b' \
  local-ios-agent/rust-core/src/user_customization \
  local-ios-agent/rust-core/src/protocol
rg -n \
  '\b(RuntimePluginRegistry|PluginRegistryBuilder|TypedRegistry|PluginModule|ComponentInstance|SnapshotRecord|ComponentArchive|DefinitionCompatibility|HostCapabilityManifest)\b' \
  local-ios-agent/rust-core/src local-ios-agent/rust-core/tests
```

Expected: the first query proves the live retained binding values; the second shows only protocol self-references and protocol contract tests.

- [ ] **Step 2: Delete the registry/lifecycle modules**

Reduce `protocol/mod.rs` to `binding`, `ids`, and their retained exports. Reduce `ids.rs` to `BindingId` and `InstanceId`. In `protocol_lifecycle.rs`, retain only the binding test. Delete the registry test and its explicit `contract.rs` registration.

- [ ] **Step 3: Verify**

```bash
! rg -n \
  '\b(RuntimePluginRegistry|PluginRegistryBuilder|TypedRegistry|PluginModule|ComponentInstance|SnapshotRecord|ComponentArchive|DefinitionCompatibility|HostCapabilityManifest)\b' \
  local-ios-agent/rust-core/src local-ios-agent/rust-core/tests
CARGO_NET_OFFLINE=true cargo test \
  --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test contract protocol_lifecycle -- --nocapture
CARGO_NET_OFFLINE=true cargo test \
  --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test lint test_taxonomy -- --nocapture
CARGO_NET_OFFLINE=true cargo build \
  --manifest-path local-ios-agent/rust-core/Cargo.toml
```

Expected: retained binding test and crate build pass; deleted symbols have zero hits.

- [ ] **Step 4: Update ledger and commit**

```bash
git add -A local-ios-agent/rust-core \
  local-ios-agent/docs/convergence/phase-0-1-evidence.md
git commit -m "refactor: delete generic protocol registry"
```

### Task 9: Delete Test-Only Context, Prompt, and Storage Abstractions

**Files:**

- Delete: `local-ios-agent/rust-core/src/context/debug_snapshot.rs`
- Modify: `local-ios-agent/rust-core/src/context/mod.rs`
- Modify: `local-ios-agent/rust-core/tests/unit/context_compaction.rs`
- Delete: `local-ios-agent/rust-core/src/prompt/archive.rs`
- Modify: `local-ios-agent/rust-core/src/prompt/mod.rs`
- Modify: `local-ios-agent/rust-core/tests/contract/prompt_archive_agent_os.rs`
- Delete: `local-ios-agent/rust-core/src/storage/repository.rs`
- Delete: `local-ios-agent/rust-core/src/storage/migration.rs`
- Modify: `local-ios-agent/rust-core/src/storage/mod.rs`
- Modify: `local-ios-agent/rust-core/tests/contract/storage_transaction.rs`
- Modify: `local-ios-agent/docs/convergence/phase-0-1-evidence.md`

**Retain:** live Context graph/assembler/preview, immutable Prompt documents/compilation, concrete SQLite stores, transaction behavior, and current runtime recovery.

- [ ] **Step 1: Prove test-only use**

```bash
rg -n \
  '\b(PromptDebugSnapshot|CompiledPromptArchive|StorageRepository|RepositoryName|MigrationPlan|MigrationStep)\b' \
  local-ios-agent/rust-core/src local-ios-agent/rust-core/tests
```

Expected: definitions/re-exports plus only the listed unit/contract tests.

- [ ] **Step 2: Delete types and only their assertions**

Remove module declarations/re-exports. Remove the `PromptDebugSnapshot` assertion from `context_compaction.rs`. In `prompt_archive_agent_os.rs`, delete every test/helper/import that uses `CompiledPromptArchive`; rewrite `prompt_redaction_preserves_source_map_offsets_and_whitespace` to assert directly on `CompiledPrompt`, and retain the Prompt document/compiler/preview cases. Remove only repository/migration cases and imports from `storage_transaction.rs`.

- [ ] **Step 3: Verify retained behavior**

```bash
! rg -n \
  '\b(PromptDebugSnapshot|CompiledPromptArchive|StorageRepository|RepositoryName|MigrationPlan|MigrationStep)\b' \
  local-ios-agent/rust-core/src local-ios-agent/rust-core/tests
CARGO_NET_OFFLINE=true cargo test \
  --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test unit context_compaction -- --nocapture
CARGO_NET_OFFLINE=true cargo test \
  --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test contract prompt_archive -- --nocapture
CARGO_NET_OFFLINE=true cargo test \
  --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test contract storage_transaction -- --nocapture
```

Expected: Context compaction, Prompt compilation, and transaction suites still pass.

- [ ] **Step 4: Update ledger and commit**

```bash
git add -A local-ios-agent/rust-core \
  local-ios-agent/docs/convergence/phase-0-1-evidence.md
git commit -m "refactor: delete test-only core abstractions"
```

### Task 10: Delete Test-Only Security and Builder Helpers

**Files:**

- Delete: `local-ios-agent/rust-core/src/security/runtime_secret_prompt.rs`
- Modify: `local-ios-agent/rust-core/src/security/mod.rs`
- Modify: `local-ios-agent/rust-core/tests/contract/security_data_egress.rs`
- Delete: `local-ios-agent/rust-core/src/user_customization/component_test_harness.rs`
- Delete: `local-ios-agent/rust-core/src/user_customization/settings_schema.rs`
- Modify: `local-ios-agent/rust-core/src/user_customization/mod.rs`
- Modify: `local-ios-agent/rust-core/tests/contract/user_component.rs`
- Modify: `local-ios-agent/rust-core/tests/contract/agent_builder_assembly_graph_agent_os.rs`
- Modify: `local-ios-agent/docs/convergence/phase-0-1-evidence.md`

**Retain:** current cloud/transport security contracts, Swift native permission/effect enforcement, and the live old Builder/component graph until Phase 3.

- [ ] **Step 1: Prove test-only use**

```bash
rg -n \
  '\b(RuntimeSecretPrompt|ComponentTestHarness|ComponentDryRunReport|UserSettingsSchema|SettingsFieldDescriptor|SettingsControlKind|SettingsValueRange|SettingsOptionDescriptor)\b' \
  local-ios-agent/rust-core/src local-ios-agent/rust-core/tests
```

Expected: definitions/re-exports and only the three listed contract tests.

- [ ] **Step 2: Delete helpers and their isolated assertions**

Do not alter live egress policy, component catalog, profile assembly, or Save/publish paths.

- [ ] **Step 3: Verify**

```bash
! rg -n \
  '\b(RuntimeSecretPrompt|ComponentTestHarness|ComponentDryRunReport|UserSettingsSchema|SettingsFieldDescriptor|SettingsControlKind|SettingsValueRange|SettingsOptionDescriptor)\b' \
  local-ios-agent/rust-core/src local-ios-agent/rust-core/tests
CARGO_NET_OFFLINE=true cargo test \
  --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test contract security_data_egress -- --nocapture
CARGO_NET_OFFLINE=true cargo test \
  --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test contract user_component -- --nocapture
CARGO_NET_OFFLINE=true cargo test \
  --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test contract agent_builder_assembly_graph -- --nocapture
```

- [ ] **Step 4: Update ledger and commit**

```bash
git add -A local-ios-agent/rust-core \
  local-ios-agent/docs/convergence/phase-0-1-evidence.md
git commit -m "refactor: delete test-only security builder helpers"
```

### Task 11: Delete Swift Bridge Mock Clients and Dead DTOs

**Files:**

- Delete: `local-ios-agent/toolkit/Sources/LocalAgentBridge/AgentPackageClient.swift`
- Delete: `local-ios-agent/toolkit/Sources/LocalAgentBridge/RunSnapshotClient.swift`
- Modify: `local-ios-agent/toolkit/Sources/LocalAgentBridge/AgentOSDTOs.swift`
- Modify: `local-ios-agent/toolkit/Tests/LocalAgentBridgeTests/AgentOSDTOTests.swift`
- Modify: `local-ios-agent/docs/convergence/phase-0-1-evidence.md`

**Delete DTOs:** `PackageBindingPreparationDTO`, `PackageInspectReportDTO`, `PackageInstallRequestDTO`, `PackageInstallPreviewUIModel`, `PackageInstallOperationUIModel`, `RunSnapshotPreviewUIModel`, and `RunSnapshotReadinessUIModel`.

- [ ] **Step 1: Prove no App/production caller**

```bash
rg -n -w \
  'PackageBindingPreparationDTO|AgentPackageClient|MockAgentPackageClient|PackageInspectReportDTO|PackageInstallRequestDTO|PackageInstallPreviewUIModel|PackageInstallOperationUIModel|RunSnapshotClient|MockRunSnapshotClient|RunSnapshotPreviewUIModel|RunSnapshotReadinessUIModel' \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp \
  local-ios-agent/toolkit/Sources \
  local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests \
  local-ios-agent/toolkit/Tests \
  --glob '*.swift'
```

Expected: no App production hit; only the two mock-client files, DTO declarations, and one composite DTO test.

- [ ] **Step 2: Delete the mock clusters**

Remove the package/snapshot assertions from the composite test. Keep and rename its permission-readiness part as a focused permission test.

- [ ] **Step 3: Verify SwiftPM auto-discovery and zero symbols**

```bash
! rg -n -w \
  'PackageBindingPreparationDTO|AgentPackageClient|MockAgentPackageClient|PackageInspectReportDTO|PackageInstallRequestDTO|PackageInstallPreviewUIModel|PackageInstallOperationUIModel|RunSnapshotClient|MockRunSnapshotClient|RunSnapshotPreviewUIModel|RunSnapshotReadinessUIModel' \
  local-ios-agent/toolkit/Sources local-ios-agent/toolkit/Tests \
  --glob '*.swift'
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path local-ios-agent/toolkit \
  --filter LocalAgentBridgeTests
```

Expected: zero deleted-symbol hits and the Bridge test target passes.

- [ ] **Step 4: Update ledger and commit**

```bash
git add -A local-ios-agent/toolkit \
  local-ios-agent/docs/convergence/phase-0-1-evidence.md
git commit -m "refactor: delete unused bridge mock clients"
```

### Task 12: Delete Unreachable Swift Runtime Islands and Inline-Card Leaves

**Files:**

- Delete: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/RuntimeStreamBuffer.swift`
- Delete: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Runtime/RuntimeStreamBufferTests.swift`
- Delete: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Runtime/AgentRunViewModel.swift`
- Delete: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Presentation/Runtime/AgentRunViewModelTests.swift`
- Delete: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/State/RuntimeEventReducer.swift`
- Delete: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/State/RuntimeEventReducerTests.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/RunInlineCards.swift`
- Delete: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Presentation/Chat/RunInlineCardsTests.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj/project.pbxproj`
- Modify: `local-ios-agent/docs/convergence/phase-0-1-evidence.md`

**Remove from `RunInlineCards.swift`:** `RunInlineCardProjection`, `RunInlineCardActionStateReducer`, `RunInlineCardView`, and `RunInlineCardChrome`.

**Retain:** `RunInlineCardState`, action/value types, `RunInlineCardActionHandler`, `NativeInteractionBroker`, `AgentViewState`, `MessageContent`, `ReasoningTagParser`, `RuntimeProjectionModel`, and debug UI. These still have production callers or carry live chat value types.

- [ ] **Step 1: Re-run symbol evidence**

```bash
rg -n -w \
  'RuntimeStreamBuffer|AgentRunViewModel|AgentRunPhase|RuntimeEventReducer|RunInlineCardView|RunInlineCardChrome|RunInlineCardProjection|RunInlineCardActionStateReducer' \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp \
  local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests \
  --glob '*.swift'
rg -n -w \
  'RunInlineCardActionHandler|RunInlineCardState|RunInlineCardAction|AgentMessageViewState|AttachmentDraftViewState|RuntimeProjectionModel' \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp \
  --glob '*.swift'
```

Expected: first group is declaration/test-only; second group proves retained production use.

- [ ] **Step 2: Delete files/leaves and update PBX membership**

Remove every corresponding `PBXBuildFile`, `PBXFileReference`, group entry, and Sources membership entry. Do not renumber unrelated PBX IDs and do not modify the shared scheme.

- [ ] **Step 3: Verify source membership and retained interaction behavior**

```bash
! rg -n -w \
  'RuntimeStreamBuffer|AgentRunViewModel|AgentRunPhase|RuntimeEventReducer|RunInlineCardView|RunInlineCardChrome|RunInlineCardProjection|RunInlineCardActionStateReducer' \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp \
  local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests \
  --glob '*.swift'
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -destination "platform=iOS Simulator,id=$LOCAL_AGENT_CONVERGENCE_IPHONE_UDID" \
  -derivedDataPath /private/tmp/localagent-convergence-task12 \
  -only-testing:LocalAgentAppTests/ShippingTargetOwnershipTests \
  -only-testing:LocalAgentAppTests/NativeInteractionBrokerTests \
  -only-testing:LocalAgentAppTests/OpenMinisChatFacadeTests
```

Expected: PBX/filesystem membership remains exact and retained chat/native-interaction suites pass.

- [ ] **Step 4: Update ledger and commit**

```bash
git add -A \
  local-ios-agent/apps/LocalAgentApp \
  local-ios-agent/docs/convergence/phase-0-1-evidence.md
git commit -m "refactor: delete unreachable Swift runtime islands"
```

### Task 13: Delete the Non-Shipping LiteRT Backend

**Files:**

- Delete: `local-ios-agent/inference/backends/litert/`
- Delete: `local-ios-agent/inference/tests/litert_active_generation_contract.cpp`
- Delete: `local-ios-agent/inference/tests/litert_backend_contract.cpp`
- Delete: `local-ios-agent/inference/tests/litert_lm_vendor_smoke.cpp`
- Delete: `local-ios-agent/inference/tests/litert_quiesce_wait_contract.cpp`
- Modify: `local-ios-agent/inference/core/engine_registry.cpp`
- Modify: `local-ios-agent/inference/core/model_config.cpp`
- Modify: `local-ios-agent/inference/tests/engine_registry_contract.cpp`
- Modify: `local-ios-agent/inference/tests/model_config_contract.cpp`
- Modify: `local-ios-agent/scripts/run-local-inference-cpp-contracts.sh`
- Modify: `local-ios-agent/docs/model-providers/cpp-inference-backend-architecture.md`
- Modify: `local-ios-agent/docs/convergence/phase-0-1-evidence.md`

**Retain:** C ABI, engine interface/registry, mock test engine, llama.cpp backend, multimodal llama.cpp path, local model download/lifecycle, and future-backend extension seam.

- [ ] **Step 1: Prove shipping absence and non-shipping build/test reachability**

```bash
rg -n -i 'LOCAL_AGENT_ENABLE_LITERT|backends/litert|litert_' \
  local-ios-agent/scripts \
  local-ios-agent/inference \
  local-ios-agent/toolkit \
  local-ios-agent/apps/LocalAgentApp
! rg -n 'LOCAL_AGENT_ENABLE_LITERT|backends/litert' \
  local-ios-agent/scripts/build-local-agent-inference-xcframework.sh \
  local-ios-agent/inference/release-engines.json \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj/project.pbxproj
```

Expected: LiteRT is exercised only by its optional C++ build/test branches and is absent from the shipping XCFramework allowlist/project.

- [ ] **Step 2: Delete the whole non-shipping slice**

Remove LiteRT descriptor/factory/model-format branches and all LiteRT flags/tests from the C++ contract script. Keep `release-engines.json` unchanged with the sole `llama_cpp` entry. Update only the current C++ backend architecture document; historical plans/specs remain historical records.

- [ ] **Step 3: Verify the retained C++ and App link contracts**

```bash
! rg -n -i 'LOCAL_AGENT_ENABLE_LITERT|backends/litert|litert_' \
  local-ios-agent/scripts \
  local-ios-agent/inference \
  local-ios-agent/toolkit \
  local-ios-agent/apps/LocalAgentApp \
  local-ios-agent/docs/model-providers/cpp-inference-backend-architecture.md
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  local-ios-agent/scripts/prepare-ios-native.sh --platform iphonesimulator
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  local-ios-agent/scripts/prepare-ios-native.sh --platform iphoneos
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  local-ios-agent/scripts/run-local-inference-cpp-contracts.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  local-ios-agent/scripts/test-local-inference-app-link.sh
```

Expected: no active LiteRT code/build/test/doc hit; C++ contracts and simulator/device App link checks pass with llama.cpp.

- [ ] **Step 4: Update ledger and commit**

```bash
git add -A \
  local-ios-agent/inference \
  local-ios-agent/scripts/run-local-inference-cpp-contracts.sh \
  local-ios-agent/docs/model-providers/cpp-inference-backend-architecture.md \
  local-ios-agent/docs/convergence/phase-0-1-evidence.md
git commit -m "refactor: delete non-shipping LiteRT backend"
```

### Task 14: Close Phase 1 and Hand Off the Phase 2 Core-Shape Gate

**Files:**

- Modify: `local-ios-agent/docs/convergence/phase-0-1-evidence.md`

- [ ] **Step 1: Run the complete Rust gate**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  scripts/ci/agent-os-all.sh
```

Expected: unit, lint, contract, golden, integration, Rust staticlib, and SwiftPM Bridge gates pass with nonzero tests.

- [ ] **Step 2: Run focused logic suites on iPhone; clean-build and launch on iPad**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  local-ios-agent/scripts/prepare-ios-native.sh --platform iphonesimulator
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -destination "platform=iOS Simulator,id=$LOCAL_AGENT_CONVERGENCE_IPHONE_UDID" \
  -derivedDataPath /private/tmp/localagent-convergence-final-iphone \
  -only-testing:LocalAgentAppTests/ShippingTargetOwnershipTests \
  -only-testing:LocalAgentAppTests/RustReActProductPathTests \
  -only-testing:LocalAgentAppTests/RelaunchProjectionReplayProductTests

LOCAL_AGENT_IPAD_DERIVED_DATA="$(
  mktemp -d /private/tmp/localagent-convergence-final-ipad.XXXXXX
)"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$LOCAL_AGENT_CONVERGENCE_IPAD_UDID" \
  -derivedDataPath "$LOCAL_AGENT_IPAD_DERIVED_DATA"
LOCAL_AGENT_IPAD_APP="$LOCAL_AGENT_IPAD_DERIVED_DATA/Build/Products/Debug-iphonesimulator/LocalAgentApp.app"
test -d "$LOCAL_AGENT_IPAD_APP"
if ! DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun simctl list devices \
  | rg -F "$LOCAL_AGENT_CONVERGENCE_IPAD_UDID" \
  | rg -q '\(Booted\)'; then
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    /usr/bin/xcrun simctl boot "$LOCAL_AGENT_CONVERGENCE_IPAD_UDID"
fi
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun simctl bootstatus "$LOCAL_AGENT_CONVERGENCE_IPAD_UDID" -b
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun simctl install \
    "$LOCAL_AGENT_CONVERGENCE_IPAD_UDID" "$LOCAL_AGENT_IPAD_APP"
LOCAL_AGENT_IPAD_LAUNCH="$(
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    /usr/bin/xcrun simctl launch --terminate-running-process \
      "$LOCAL_AGENT_CONVERGENCE_IPAD_UDID" com.localagent.app
)"
LOCAL_AGENT_IPAD_PID="${LOCAL_AGENT_IPAD_LAUNCH##*: }"
case "$LOCAL_AGENT_IPAD_PID" in
  ''|*[!0-9]*) exit 1 ;;
esac
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun simctl terminate \
    "$LOCAL_AGENT_CONVERGENCE_IPAD_UDID" com.localagent.app
```

Expected: the architecture suite and two product paths pass once on iPhone. A fresh DerivedData directory produces an iPad build that installs, launches with a numeric PID, and terminates. Split-view, sidebar, and size-class behavior waits for the real Phase 4 UIUX suite.

- [ ] **Step 3: Re-run every deletion proof**

Run the post-delete `rg` query from Tasks 7–13. Record command, zero-hit result, files/LOC removed, retained owner, and passing suite in the deletion ledger. Do not use total deleted lines as the completion metric.

- [ ] **Step 4: Record the Phase 2 entry checklist**

Mark Phase 0 and Phase 1 complete only if all prior tasks pass. Add the following unchecked Phase 2 gate rows without implementing them:

- `lib.rs` declares six structural roots and only `ffi` is external/public;
- checked import DAG is acyclic and follows the approved dependency direction;
- one concrete `LocalAgentStore` over `localagent.sqlite` owns Rust persistence;
- shipping open/recovery failure blocks mutation; no in-memory production fallback;
- only `ModelRuntime`, `ToolRuntime`, and `MemoryProvider` remain as runtime dynamic ports outside the private transitional Builder;
- all baseline Rust roots have a closed moved/private/deleted disposition, including any whole-root deletion discovered in Phase 0;
- exactly one production Agent loop, canonical conversation path, and Host transport path remain;
- old `execution`/`RunMachine` cannot accept a production Run;
- no fixed polling/timer loop remains idle;
- no legacy migration root, FFI operation, startup reader, sidecar attach, or translator remains;
- the private old Builder may remain only as the sole Builder under `profile` until Phase 3.

Reference the six-row ownership/reset table from Task 4; do not copy a future reset schedule, create Phase 2 stubs, or move modules in this task.

- [ ] **Step 5: Review the plan evidence against the approved design**

Check:

```bash
! rg -n '\b(TBD|TODO)\b' \
  local-ios-agent/docs/convergence/phase-0-1-evidence.md
LOCAL_AGENT_CONVERGENCE_BASELINE_SHA="$(
  awk '/^baseline_sha: / {print $2}' \
    local-ios-agent/docs/convergence/phase-0-1-evidence.md
)"
test "${#LOCAL_AGENT_CONVERGENCE_BASELINE_SHA}" -eq 40
git diff --name-only "$LOCAL_AGENT_CONVERGENCE_BASELINE_SHA"...HEAD
git status --short
git diff --check
git diff --check "$LOCAL_AGENT_CONVERGENCE_BASELINE_SHA"...HEAD
```

Expected:

- no unresolved placeholder;
- manual review confirms no compatibility translator, dual-write task, or second production path;
- every baseline-to-HEAD change belongs to Phase 0 evidence/gates or a caller-proven Phase 1 deletion and has a concise reason in the deletion ledger;
- an unanticipated registration, manifest, build, or test file is allowed when required to keep an in-scope deletion buildable, but its reason must be recorded;
- there is no unrelated feature change or new replacement abstraction;
- no generated artifacts staged.

- [ ] **Step 6: Commit the gate evidence**

```bash
git add local-ios-agent/docs/convergence/phase-0-1-evidence.md
git commit -m "docs: close convergence evidence and deletion phases"
```

## Phase 0/1 Completion Criteria

This plan is complete only when:

1. the evidence ledger contains all eight required sections and every command/result is reproducible;
2. all 23 Rust roots have caller and final-disposition rows;
3. Xcode/SwiftPM/source/resource ownership is explicit and filesystem/PBX membership matches;
4. one six-row ownership/reset table covers canonical/runtime data, credentials, assets, models, temporary Run/effect state, and rebuildable projections/caches without a translator or reset framework;
5. the two current product paths pass and their test seams are documented honestly;
6. Debug build/launch smoke and the lean Release cold-launch, Rust-init, idle RSS/CPU, deterministic ReAct-turn, and binary-size baselines are recorded within the time-box;
7. every Phase 1 candidate has before/after zero-production-caller evidence;
8. live Builder, Agent loop, conversation, Host, storage, transport, and FFI behavior was not bulk-deleted or duplicated;
9. the complete Rust/SwiftPM gate and the three focused App suites pass on iPhone, while a clean iPad build/install/launch passes without repeating Host/Rust logic tests;
10. every baseline-to-HEAD changed path is traceable to an in-scope evidence/deletion-ledger reason, with no unrelated feature work;
11. the next implementation artifact is a separate Phase 2 plan, beginning from the Core-shape checklist rather than extending this plan.
