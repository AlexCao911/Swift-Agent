# OpenMinis Product Trunk with Rust ReAct Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the OpenMinis iOS/iPadOS product as the Swift app trunk while making the existing Rust core the sole owner of the direct ReAct agent loop, prompt/context assembly, transcript, and tool-batch validation; reuse OpenMinis UI, provider configuration, Skills UX, iSH runtime, and tool execution; retain the current C++ local inference backend and the existing reliable Rust/Swift transport.

**Architecture:** Swift starts a run with one digest-verified snapshot of ordered prompt documents, Skill descriptors, and current OpenMinis tool schemas. Rust freezes that input, runs one ordinary bounded `model → ordered tool batch → model` loop, and persists canonical conversation events; Swift executes complete model requests or tool batches through the existing host envelopes with `LocalAgentLLMCloud`/the C++ local runtime or OpenMinis tools/iSH. OpenMinis `ChatStore` is an idempotent read model keyed by `(conversation_stream_id, sequence)` and catches up from the Rust canonical store before live projection delivery.

**Tech Stack:** Rust 2021, serde/serde_json, rusqlite, C FFI; Swift 6, Swift Concurrency, SwiftPM, XCTest; OpenMinis iOS/iPadOS Xcode app and iSH/proot submodules; current C++ `LocalAgentInferenceNative` XCFramework; SQLite; Xcode/iOS Simulator.

## Global Constraints

- OpenMinis commit `9cf3a855fecd27bb5735b84cacbd56852a3ab8dd` is the product baseline. Do not selectively copy features into `local-ios-agent/apps/LocalAgentApp`.
- OpenMinis is GPLv3. Task 1 is a hard product/legal gate. Stop before importing source if GPLv3 distribution obligations have not been accepted.
- Work in an isolated root-repository worktree on branch `codex/openminis-rust-react`; do not alter the current dirty checkout or the nested source clone at `/Users/alexandercou/Projects/Alex-agent/OpenMinis`.
- Preserve the existing wire transport: `HostCommandEnvelope`, `LLMEventEnvelope`, command/event IDs, sequence checks, canonical digests, receipts, backpressure, and host process epoch. The new runtime contracts are logical interfaces over that transport, not a second protocol.
- Delete the Agent business state machine only after all production callers use the direct loop. Preserve transport lifecycle state required for reliability.
- Rust is the only assembler of the complete system prompt, messages, context, Skill descriptors/file-tool results, and model-visible tool definitions. Swift supplies one frozen run-start snapshot of ordered prompt documents, Skill descriptors, and OpenMinis-owned tool schemas; Rust does not maintain a second static schema catalog.
- Rust receives at most 20 enabled Skill descriptors. Full `SKILL.md` files are never preloaded into context; the model reads a relevant file through the ordinary file tool.
- Rust is the only canonical transcript writer. Swift may render optimistic streaming state in memory, but durable `ChatStore` changes must come from Rust projection events.
- A tool round is one Rust storage transaction: assistant tool calls and the complete validated tool-result batch commit together or neither commits.
- Swift owns model retry/fallback, tool concurrency, tool argument repair, tool preflight, iSH process management, and product UI.
- `LocalAgentLLMCloud` remains the only cloud HTTP execution stack. OpenMinis retains settings, OAuth, provider/model catalog, Base URL, and product interactions.
- Swift freezes one non-secret `ProviderRunPlan` on the first model generation of each Rust run and reuses it across every ReAct turn. API keys/OAuth tokens are excluded from the plan and resolved from secure storage immediately before each request attempt.
- The only Rust tool runtime API is one ordered batch call. No tool execution-mode enum crosses the Rust/Swift boundary.
- iSH raw guest networking remains enabled by default to match OpenMinis. It is an independent high-privilege network path and is not covered by `LocalAgentLLMCloud` SSRF/egress controls. The UI must disclose this; phase 1 adds no per-command approval and claims no string-based network sandbox.
- Phase 1 disables cross-device sync for `Session`, `Message`, `CompactMarker`, and `SessionFile`. Do not add a `ChatStore → Rust` import path.
- Projection identity is exactly `(conversation_stream_id, sequence)`. `run_id` identifies one execution only. Do not create a global projection cursor or projection bus.
- Projection delivery has one logical path: command responses acknowledge acceptance, while `observeTranscriptProjections(subscriptionId:conversationStreamId:afterSequence:)` replays canonical per-conversation events and then continues live. It does not use the run-scoped execution observer. Cancelling the Swift stream must cancel and wake the matching Rust subscription even if no event ever arrives.
- OpenMinis owns the sole `ToolLoopDetector`. Rust owns only the fixed `MAX_MODEL_TURNS: usize = 16` bound.
- Secrets never enter Rust prompt/context, iSH files, iSH environment variables, tool arguments/results, or logs. Provider sync continues to follow OpenMinis's existing Swift-only secret handling.
- Transcript commands are durably idempotent by `(conversation_stream_id, request_id, canonical_command_digest)`. One conversation has at most one active Agent run; different conversations may run concurrently.
- Keep the implementation small: two agent runtime traits (`ModelRuntime`, `ToolRuntime`), the existing unwired optional `MemoryProvider` trait, one per-stream active-run guard, one run-scoped cancellation record, concrete prompt/skill/tool snapshots, and no speculative plugin framework. Do not add a memory-enabled wire flag until a production memory provider is selected.

## Definition of Done

- The shipping `Minis` target starts the Rust runtime and uses the C++ local model or `LocalAgentLLMCloud` through the existing host transport.
- A Rust-owned ReAct loop completes text-only and multi-tool runs, validates batch ID plus ordered results, stops safely at all model/tool cancellation boundaries and the max-turn bound, and contains no approval/run-state machine.
- OpenMinis executes a whole tool batch with up to ten concurrent calls and owns one cancellation handle plus every iSH PID for each call.
- Send, retry, edit, delete, clear, branch, archive, and conversation deletion enter Rust first, are request-idempotent, and are projected idempotently into `ChatStore`.
- On startup and after any sequence gap, Swift resumes the relevant conversation projection feed from its stored per-stream cursor before applying live events. The persistent feed set is exactly `SessionConcurrencyManager.runningSessions ∪ currentConversation`, so OpenMinis's five concurrent runs require at most six feeds. A command targeting a dormant stream may temporarily use an available slot, but every feed is released when it leaves that set or its awaited command projection is applied.
- Prompt Markdown documents, at most 20 OpenMinis Skill descriptors, and the current OpenMinis tool name/description/JSON schemas enter Rust once as a digest-verified run-start snapshot; full Skill files are read on demand with the file tool, and the new model path never invokes OpenMinis prompt/Skill/memory injection.
- Provider settings/OAuth/Base URL remain OpenMinis product features while every cloud request is executed by `LocalAgentLLMCloud`.
- A provider/model/Base URL/fallback setting change during a tool round affects only the next run; the active run keeps its frozen non-secret route while credentials remain late-bound.
- Conversation CloudKit sync is disabled; Skills/provider product data sync still works.
- API keys/OAuth tokens cannot be observed from Rust, iSH, tool results, or logs; provider sync remains inside OpenMinis's existing Swift-only secret controls.
- Rust, SwiftPM, OpenMinis unit tests, architecture lints, and the iPhone/iPad simulator smoke suite pass.

---

## Task 1: Create the Isolated Worktree and Import the Approved OpenMinis Baseline

**Files:**

- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/THIRD_PARTY_OPENMINIS.md`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/.gitmodules`
- Import: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/**`
- Preserve: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/LICENSE`
- Test: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/scripts/test-openminis-provenance.sh`

### Gate

- [ ] Record product/legal approval that distributing the combined app under GPLv3-compatible terms is acceptable.
- [ ] If approval is absent, stop this implementation. Do not import or adapt OpenMinis source.

### Worktree

- [ ] Use `superpowers:using-git-worktrees` to create:

```bash
git -C /Users/alexandercou/Projects/Alex-agent worktree add \
  /Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react \
  -b codex/openminis-rust-react
```

- [ ] Set the execution root:

```bash
cd /Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react
```

- [ ] Verify the source clone is clean and pinned:

```bash
git -C /Users/alexandercou/Projects/Alex-agent/OpenMinis status --short
git -C /Users/alexandercou/Projects/Alex-agent/OpenMinis rev-parse HEAD
```

Expected: no status output and exactly `9cf3a855fecd27bb5735b84cacbd56852a3ab8dd`.

### RED: provenance test

- [ ] Add `local-ios-agent/scripts/test-openminis-provenance.sh` with checks for:

```bash
#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
test "$(sed -n 's/^Upstream-Commit: //p' "$repo_root/THIRD_PARTY_OPENMINIS.md")" = \
  "9cf3a855fecd27bb5735b84cacbd56852a3ab8dd"
test -f "$repo_root/OpenMinis/LICENSE"
grep -q "GNU GENERAL PUBLIC LICENSE" "$repo_root/OpenMinis/LICENSE"
git -C "$repo_root" submodule status OpenMinis/deps/ish | grep -q "de124dd"
git -C "$repo_root" submodule status OpenMinis/deps/proot | grep -q "8cf13e"
```

- [ ] Run:

```bash
bash local-ios-agent/scripts/test-openminis-provenance.sh
```

Expected: FAIL because the baseline has not been imported into the root repository.

### GREEN: import, do not hand-copy

- [ ] Import the exact tracked tree from the clean source clone with `git archive`; do not copy its nested `.git` directory:

```bash
mkdir OpenMinis
git -C /Users/alexandercou/Projects/Alex-agent/OpenMinis archive \
  9cf3a855fecd27bb5735b84cacbd56852a3ab8dd \
  | tar -x -C OpenMinis
```

- [ ] Remove the imported nested `.gitmodules` file from the imported tree and add equivalent root entries:

```ini
[submodule "OpenMinis/deps/ish"]
	path = OpenMinis/deps/ish
	url = https://github.com/OpenMinis/ish-arm64.git
	branch = master
[submodule "OpenMinis/deps/proot"]
	path = OpenMinis/deps/proot
	url = https://github.com/OpenMinis/proot.git
	branch = master
```

- [ ] Add the root-level submodules, then pin them to the upstream gitlink commits:

```bash
git submodule add https://github.com/OpenMinis/ish-arm64.git OpenMinis/deps/ish
git -C OpenMinis/deps/ish checkout de124dd66124a15239cea1465164f74980ada245
git submodule add https://github.com/OpenMinis/proot.git OpenMinis/deps/proot
git -C OpenMinis/deps/proot checkout 8cf13e997cdc9472997aae19df8050c073c9a86c
```

- [ ] Write `THIRD_PARTY_OPENMINIS.md`:

```markdown
# OpenMinis provenance

Upstream: https://github.com/OpenMinis/OpenMinis
Upstream-Commit: 9cf3a855fecd27bb5735b84cacbd56852a3ab8dd
License: GNU General Public License v3.0

This tree is the product baseline for the iOS/iPadOS application. Local
modifications are maintained in this repository. The iSH and proot source trees
remain pinned root-level git submodules at the commits recorded by upstream.
```

- [ ] Run:

```bash
bash local-ios-agent/scripts/test-openminis-provenance.sh
git status --short
```

Expected: PASS; imported OpenMinis files, `.gitmodules`, provenance document, and the test are the only intentional changes.

- [ ] Commit:

```bash
git add .gitmodules THIRD_PARTY_OPENMINIS.md OpenMinis local-ios-agent/scripts/test-openminis-provenance.sh
git commit -m "build: adopt pinned OpenMinis product trunk"
```

---

## Task 2: Link the Existing Rust/Swift/C++ Runtime into the OpenMinis App

**Files:**

- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Minis.xcodeproj/project.pbxproj`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Minis.xcodeproj/xcshareddata/xcschemes/Minis.xcscheme`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/LocalRuntime/LocalRuntimeBootstrap.swift`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/MinisTests/LocalRuntimeLinkageTests.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/scripts/build-local-inference-xcode.sh`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/scripts/run-openminis-tests.sh`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/scripts/test-openminis-linkage.sh`

### RED: prove the OpenMinis target cannot see the local runtime

- [ ] Add:

```swift
import XCTest
@testable import Minis
import LocalAgentBridge
import LocalAgentLLMHost

final class LocalRuntimeLinkageTests: XCTestCase {
    func testProductRuntimeTypesAreLinkedIntoMinis() {
        XCTAssertEqual(LocalRuntimeBootstrap.runtimeOwner, "rust")
        XCTAssertEqual(LocalRuntimeBootstrap.localInferenceOwner, "cpp")
    }
}
```

- [ ] Add the empty production symbol without imports:

```swift
enum LocalRuntimeBootstrap {
    static let runtimeOwner = "rust"
    static let localInferenceOwner = "cpp"
}
```

- [ ] Run the `MinisTests/LocalRuntimeLinkageTests` test plan through `xcodebuild`.

Expected: FAIL because the `Minis` project has no local Swift package products.

### GREEN: add the local package and native pre-action

- [ ] Add a local Swift package reference from `OpenMinis/src/ios/Minis.xcodeproj` to:

```text
../../../local-ios-agent/toolkit
```

- [ ] Link all six products below to the `Minis` app target. Link `LocalAgentBridge`, `LocalAgentLLMContracts`, and `LocalAgentLLMHost` directly to `MinisTests`:

```text
LocalAgentBridge
LocalAgentLLMContracts
LocalAgentLLMCore
LocalAgentLLMLocal
LocalAgentLLMCloud
LocalAgentLLMHost
```

- [ ] Add the existing Rust archive pre-action to the shared `Minis` scheme:

```bash
"${SRCROOT}/../../../local-ios-agent/scripts/build-local-inference-xcode.sh"
```

- [ ] Update `build-local-inference-xcode.sh` only where it currently assumes `LocalAgentApp`; the script must derive the SDK/architecture from Xcode variables and continue staging the Rust static library under `rust-core/target/xcode-ios`.

- [ ] Import `LocalAgentBridge` and `LocalAgentLLMHost` in `LocalRuntimeBootstrap.swift`. Add a process-lifetime owner:

```swift
import LocalAgentBridge
import LocalAgentLLMHost

@MainActor
final class LocalRuntimeBootstrap {
    static let shared = LocalRuntimeBootstrap()
    static let runtimeOwner = "rust"
    static let localInferenceOwner = "cpp"

    private var productRuntime: LLMHostProductRuntime?

    func install(_ runtime: LLMHostProductRuntime) {
        precondition(productRuntime == nil)
        productRuntime = runtime
    }
}
```

- [ ] Create `test-openminis-linkage.sh` to:

  1. resolve an available iOS simulator,
  2. build the Rust archive,
  3. build `Minis`,
  4. run only `LocalRuntimeLinkageTests`.

- [ ] Create `run-openminis-tests.sh` as the common exact test entry point. It requires `OPENMINIS_TEST_UDID`, accepts one or more XCTest identifiers, converts them to `-only-testing:` arguments, and runs:

```bash
xcodebuild test \
  -project OpenMinis/src/ios/Minis.xcodeproj \
  -scheme Minis \
  -destination "platform=iOS Simulator,id=$OPENMINIS_TEST_UDID" \
  -derivedDataPath "${OPENMINIS_DERIVED_DATA:-/private/tmp/openminis-tests-$OPENMINIS_TEST_UDID}" \
  -only-testing:MinisTests/LocalRuntimeLinkageTests
```

The real script substitutes the provided identifiers for the final line and prints a clear usage error when the UDID or identifiers are missing.

- [ ] Run:

```bash
bash local-ios-agent/scripts/test-openminis-linkage.sh
```

Expected: PASS with the existing C++ XCFramework and Rust static library linked into OpenMinis.

- [ ] Commit:

```bash
git add OpenMinis/src/ios/Minis.xcodeproj OpenMinis/src/ios/Agent/LocalRuntime \
  OpenMinis/src/ios/MinisTests/LocalRuntimeLinkageTests.swift \
  local-ios-agent/scripts/build-local-inference-xcode.sh \
  local-ios-agent/scripts/run-openminis-tests.sh \
  local-ios-agent/scripts/test-openminis-linkage.sh
git commit -m "build: link local agent runtime into Minis"
```

---

## Task 3: Establish Rust-Owned Conversation Commands and One-Way Projection

**Files:**

- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/conversation/command.rs`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/conversation/command_service.rs`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/conversation/command_receipt.rs`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/conversation/projection_event.rs`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/conversation/projection_subscription.rs`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/agent_input/snapshot.rs`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/agent_input/mod.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/conversation/mod.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/core/event.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/core/runtime.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/lib.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/ffi_bridge.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/memory/in_memory.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/memory/sqlite.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/toolkit/Sources/LocalAgentBridge/RustAgentOSBridgeGateway.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/toolkit/Sources/LocalAgentBridge/RustRuntimeClient.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/toolkit/Sources/LocalAgentBridge/ConversationBridgeClient.swift`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/toolkit/Sources/LocalAgentBridge/TranscriptDTOs.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/toolkit/Sources/CLocalAgentRuntime/include/CLocalAgentRuntime.h`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/toolkit/Sources/LocalAgentBridge/MockRuntimeClient.swift`
- Test: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/tests/contract/conversation_command.rs`
- Test: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/tests/integration/conversation_projection.rs`
- Test: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/toolkit/Tests/LocalAgentBridgeTests/ConversationCommandTests.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/tests/contract.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/tests/integration.rs`

### RED: lock the identity and ownership rules

- [ ] Add Rust tests proving:

  - all commands use a stable `conversation_stream_id`,
  - two runs in one conversation produce one monotonically increasing per-stream sequence,
  - a second conversation starts at its own sequence 1,
  - retry/edit/delete/clear are append-only canonical events rather than in-place database mutations,
  - projection replay of an already applied `(stream, sequence)` is a no-op,
  - `observe_transcript_projections(stream, after_sequence)` replays every canonical projection after the cursor in strict sequence and then remains live,
  - archive/delete projections are observable even though they have no `run_id`,
  - a reconnect after sequence 4 receives 5 onward without a gap or duplicate,
  - the projection API accepts no `run_id`,
  - cancelling a projection subscription while it is idle wakes its blocking receiver, unregisters its listener, and returns from the FFI observation call,
  - cancelling one subscription does not stop another subscription observing the same conversation,
  - an unknown or already-finished `subscription_id` can be cancelled idempotently,
  - the same `(conversation_stream_id, request_id)` plus the same canonical command payload returns the first stored `TranscriptCommandResult`,
  - reusing that key with a different canonical payload returns `conversation.idempotency_conflict`,
  - a duplicated `Send` writes one user message, records one run request, and starts at most one run even after an FFI retry or process restart.

- [ ] Add Swift bridge tests proving every transcript mutation maps to one `transcriptCommand` request, title/pin/model selection are absent from that enum, and projection observation is keyed by conversation stream rather than run.

- [ ] Run:

```bash
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test contract conversation_command
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test integration conversation_projection
swift test --package-path local-ios-agent/toolkit \
  --filter ConversationCommandTests
```

Expected: FAIL because the command and projection contracts do not exist.

### GREEN: add idempotent commands and one replay-then-live projection feed

- [ ] Implement the minimum Rust contract:

```rust
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
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

- [ ] Define attachment metadata without passing file bytes into Rust:

```rust
pub struct TranscriptAttachmentReference {
    pub attachment_id: String,
    pub display_name: String,
    pub media_type: String,
    pub modality: String,
    pub content_digest: String,
}
```

Swift resolves the stable attachment ID only when it performs a model request or tool operation.

- [ ] Define the exact run-start input in `agent_input/snapshot.rs`:

```rust
pub struct RunStartSnapshot {
    pub ordered_prompt_documents: Vec<PromptDocumentSnapshot>,
    pub skill_descriptors: Vec<SkillDescriptor>,
    pub ordered_tool_definitions: Vec<ToolDefinitionSnapshot>,
    pub snapshot_digest: String,
}

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
```

The digest domain is `run-start-snapshot:v1` and covers every field except `snapshot_digest`, preserving vector order. Rust recomputes it, rejects a mismatch, rejects more than 20 Skill descriptors, and rejects duplicate tool names or a non-object JSON schema. The snapshot contains no provider candidate, credential, full `SKILL.md`, executable callback, Swift-rendered system prompt, or memory toggle.

- [ ] Mirror these types exactly as `RunStartSnapshotDTO`, `PromptDocumentSnapshotDTO`, `RustSkillDescriptorDTO`, and `ToolDefinitionSnapshotDTO` in `TranscriptDTOs.swift`. Only `Send`, `RetryFrom`, and `EditMessage` DTO cases contain `runStartSnapshot`.

- [ ] Return:

```rust
pub struct TranscriptCommandResult {
    pub conversation_stream_id: String,
    pub accepted_sequence: u64,
    pub run_id: Option<String>,
}

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

pub struct CancelTranscriptProjectionSubscriptionRequest {
    pub subscription_id: String,
}
```

- [ ] Map every canonical conversation event to exactly one `TranscriptProjectionEvent` with the same stream sequence. Internal events such as `run_requested` that do not mutate transcript rows use `TranscriptProjectionKind::CursorAdvance`; Swift applies no row change but advances the cursor. This keeps the feed gap-free without inventing a projection sequence.
- [ ] Compute `command_digest` with `CanonicalDigestV1` domain `transcript-command:v1` over the complete tagged command, including its run-start snapshot. Persist this idempotency receipt in the same SQLite database and unit of work as the command's canonical events, but not as a transcript event:

```rust
pub struct TranscriptCommandReceipt {
    pub request_id: String,
    pub command_digest: String,
    pub outcome: StoredTranscriptCommandOutcome,
}

pub enum StoredTranscriptCommandOutcome {
    Accepted(TranscriptCommandResult),
    Rejected { code: String, message: String },
}
```

```sql
create table if not exists conversation_command_receipt (
    conversation_stream_id text not null,
    request_id text not null,
    command_digest text not null,
    outcome_json text not null,
    primary key (conversation_stream_id, request_id)
);
```

Use primary key `(conversation_stream_id, request_id)`. Serialize command handling per conversation stream and look up the receipt before the active-run check: an exact duplicate replays the stored accepted result or rejection; a digest mismatch returns `conversation.idempotency_conflict`. Store deterministic rejections such as `conversation_busy`; do not store transient storage/process errors. Only a fresh accepted outcome may append transcript events or a `run_requested` event. The post-commit scheduler appends `run_started` before the first model request and starts only that fresh run. On restart, a request with no `run_started` may be claimed once; a started but nonterminal run is marked interrupted and is never automatically replayed, avoiding duplicate external tool effects. Replaying the FFI command itself never schedules another run.

- [ ] `TranscriptCommandResult` is only an acknowledgement. Never embed projections in the command response.
- [ ] Use the existing event storage sequence for the specified stream. Do not add a global counter table.

- [ ] Add exactly three conversation gateway operations:

```swift
case transcriptCommand = "transcript_command"
case observeTranscriptProjections = "observe_transcript_projections"
case cancelTranscriptProjectionSubscription =
    "cancel_transcript_projection_subscription"
```

- [ ] Generalize the gateway's existing typed callback wrapper without changing its reliability semantics:

```swift
func stream<Request: Encodable, Event: Decodable>(
    _ operation: RustAgentOSOperation,
    _ request: Request,
    as eventType: Event.Type
) -> AsyncThrowingStream<Event, Error>
```

Keep `.observeEvents` routed to the existing run-event C callback. Add `local_agent_runtime_bridge_observe_transcript_projections_streaming` and `local_agent_runtime_bridge_cancel_transcript_projection_subscription` plus their `RustRuntimeCFunctionTable` entries. The projection stream may reuse the existing JSON decoding/error wrapper, but its `onTermination` must call the cancellation function with its own `subscription_id`; merely terminating the callback box is insufficient because Rust may be blocked with no next event.

- [ ] Replace the mutation methods on `ConversationBridgeClient` with:

```swift
func submitTranscriptCommand(
    _ command: TranscriptCommandDTO
) async throws -> TranscriptCommandResultDTO

func observeTranscriptProjections(
    subscriptionId: String,
    conversationStreamId: String,
    afterSequence: UInt64
) -> AsyncThrowingStream<TranscriptProjectionEventDTO, Error>

func cancelTranscriptProjectionSubscription(
    subscriptionId: String
) async
```

Keep read methods needed by the UI. Remove `renameSession` from the new canonical transcript route; title remains Swift product metadata.

- [ ] Implement the projection operation over the canonical conversation store, not `ExecutionService.observe_event_stream(run_id, ...)`: register `(subscription_id, conversation_stream_id, wake_handle)` before reading, query and emit stored projections after `afterSequence` in strict order, then use each live notification only to query the canonical store again after the last emitted sequence. Never trust a notification payload as the source event. Listener overflow/closure terminates the stream with an error so Swift reconnects from its durable cursor; it never silently drops a wake-up. Any reconnect creates a fresh subscription ID and follows the same replay-first algorithm.
- [ ] The cancellation operation marks only the matching subscription cancelled, wakes the receiver that is blocked waiting for a live notification, unregisters the canonical-store listener, removes the subscription registry entry, and lets the streaming FFI call return. Do not wait for a future projection. Both natural stream completion and explicit cancellation run the same idempotent unregister cleanup.
- [ ] In Swift, allocate one UUID before starting each projection observation. `AsyncThrowingStream.onTermination` invokes `cancelTranscriptProjectionSubscription(subscriptionId:)` from a separate task and then terminates the callback box; it must not queue cancellation on the detached task currently blocked inside the observation FFI call.
- [ ] Add bridge tests that submit a command, verify its response contains no projection payload, reconnect from a saved cursor, and receive the resulting projections exactly once in strict sequence. Add a test proving a runless archive event is delivered. Add an idle-feed cancellation test that waits until both the Rust listener/subscription count and the Swift detached projection-task count return to zero without publishing an event; expose counters only through test fixtures.

- [ ] Keep the legacy methods temporarily behind current callers. Mark them `@available(*, deprecated, message: "Use submitTranscriptCommand")` and delete them in Task 14.

- [ ] Run the three focused commands again.

Expected: PASS.

- [ ] Commit:

```bash
git add local-ios-agent/rust-core/src/conversation \
  local-ios-agent/rust-core/src/agent_input \
  local-ios-agent/rust-core/src/core/event.rs \
  local-ios-agent/rust-core/src/core/runtime.rs \
  local-ios-agent/rust-core/src/lib.rs \
  local-ios-agent/rust-core/src/ffi_bridge.rs \
  local-ios-agent/rust-core/src/memory/in_memory.rs \
  local-ios-agent/rust-core/src/memory/sqlite.rs \
  local-ios-agent/rust-core/tests \
  local-ios-agent/toolkit/Sources/LocalAgentBridge \
  local-ios-agent/toolkit/Sources/CLocalAgentRuntime/include/CLocalAgentRuntime.h \
  local-ios-agent/toolkit/Tests/LocalAgentBridgeTests/ConversationCommandTests.swift
git commit -m "feat: make Rust own transcript commands and projection"
```

---

## Task 4: Move Conversation Persistence and Add Minimal Prompt/Skill/Memory Inputs

**Files:**

- Move: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/memory/event_store.rs` → `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/storage/conversation_event_store.rs`
- Move: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/memory/in_memory.rs` → `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/storage/in_memory_conversation.rs`
- Split: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/memory/sqlite.rs`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/storage/sqlite_conversation.rs`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/prompt/snapshot.rs`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/skills/mod.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/agent_input/snapshot.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/memory/provider.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/memory/mod.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/storage/mod.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/prompt/mod.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/lib.rs`
- Update imports: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/core/runtime.rs`
- Update imports: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/ffi_bridge.rs`
- Update imports: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/conversation/runtime_branch_reader.rs`
- Update imports: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/core/session_tree.rs`
- Test: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/tests/contract/agent_inputs.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/tests/contract.rs`

### RED: specify small, concrete inputs

- [ ] Add tests proving:

  - prompt documents preserve the exact Swift-provided order,
  - Rust accepts at most 20 enabled Skill descriptors,
  - neither the Rust Skill module nor the input snapshot exposes full `SKILL.md` content,
  - Rust rejects a bad run-start snapshot digest, duplicate tool names, and non-object JSON schemas,
  - a fake can implement the existing `MemoryProvider` without selecting a concrete backend,
  - `memory/mod.rs` exports no second `MemoryBackend` trait,
  - `memory` exports no conversation event store.

- [ ] Reuse `PromptDocumentSnapshot` and `SkillDescriptor` from Task 3. Evolve only the existing memory query so the optional provider has the conversation and limit it needs:

```rust
pub struct MemoryQuery {
    pub conversation_stream_id: String,
    pub text: String,
    pub limit: usize,
}
```

Keep the existing `MemoryProvider::provider_id()` and `MemoryProvider::query(&MemoryQuery) -> MemoryQueryResult` contract and the existing `MemoryContribution` type. Do not add `remember`/`forget` methods without a production caller, and do not create a parallel memory trait.

- [ ] Run:

```bash
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test contract agent_inputs
```

Expected: FAIL.

### GREEN: move, do not duplicate

- [ ] Use `git mv` for the in-memory and trait files.
- [ ] Extract only conversation tables/methods, including Task 3 command receipts, from `memory/sqlite.rs` into `storage/sqlite_conversation.rs`; do not create a second SQLite database.
- [ ] Update every listed production import to the new `storage` names in the same commit. Do not leave `memory` compatibility re-exports.
- [ ] Implement deterministic prompt compilation by iterating the input `Vec<PromptDocumentSnapshot>` without slot sorting.
- [ ] Keep Skills to one module and one validation function:

```rust
pub const MAX_SKILL_DESCRIPTORS: usize = 20;

pub fn validate_skill_descriptors(
    descriptors: &[SkillDescriptor],
) -> Result<(), AgentError>;
```

Reject more than 20 descriptors at the Rust boundary. Do not add `SkillCatalog`, `SkillDocument`, a Skill loader, or any API that reads `SKILL.md`; the existing file tool is the only progressive-disclosure path.

- [ ] Keep `MemoryProvider` as the sole optional memory boundary and add only a test fake. Leave it unwired from the production context/loop in this phase; do not add a run-start flag, rewire the old memory graph, or add m_flow, Memori, or Graphify adapters in Task 4.

- [ ] Run:

```bash
cargo fmt --manifest-path local-ios-agent/rust-core/Cargo.toml -- --check
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test contract agent_inputs
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test contract conversation_command
```

Expected: PASS.

- [ ] Commit:

```bash
git add local-ios-agent/rust-core/src local-ios-agent/rust-core/tests
git commit -m "refactor: move conversation storage and add minimal agent inputs"
```

---

## Task 5: Implement the Direct Rust ReAct Loop

**Files:**

- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/agent_loop/mod.rs`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/agent_loop/contracts.rs`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/agent_loop/runner.rs`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/agent_loop/active_runs.rs`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/agent_loop/cancellation.rs`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/tool/batch.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/conversation/service.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/storage/conversation_event_store.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/storage/in_memory_conversation.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/storage/sqlite_conversation.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/tool/mod.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/lib.rs`
- Test: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/tests/contract/agent_loop_contract.rs`
- Test: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/tests/integration/react_loop.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/tests/contract.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/tests/integration.rs`

### RED: specify loop behavior without a run-state enum

- [ ] Add contract tests for these exact interfaces:

```rust
pub trait ModelEventSink {
    fn emit(&mut self, event: ModelEvent) -> Result<(), AgentLoopError>;
}

pub trait ModelRuntime: Send + Sync {
    fn generate(
        &self,
        request: ModelRequest,
        sink: &mut dyn ModelEventSink,
    ) -> Result<AssistantTurn, AgentLoopError>;

    fn cancel(&self, run_id: &str) -> Result<(), AgentLoopError>;
}

pub trait ToolRuntime: Send + Sync {
    fn execute_batch(
        &self,
        batch: ToolBatch,
    ) -> Result<ToolBatchResult, AgentLoopError>;

    fn cancel_batch(&self, batch_id: &str) -> Result<(), AgentLoopError>;
}
```

- [ ] The request/result structs must be:

```rust
pub struct ModelRequest {
    pub run_id: String,
    pub conversation_stream_id: String,
    pub system_prompt: String,
    pub messages: Vec<ModelMessage>,
    pub tools: Vec<ToolDefinitionSnapshot>,
}

pub struct AssistantTurn {
    pub message_id: String,
    pub text: String,
    pub reasoning: String,
    pub tool_calls: Vec<ToolCall>,
}

pub struct ToolBatch {
    pub batch_id: String,
    pub run_id: String,
    pub ordered_calls: Vec<ToolCall>,
}

pub struct ToolCallResult {
    pub call_id: String,
    pub tool_name: String,
    pub model_text: String,
    pub is_error: bool,
}

pub struct ToolBatchResult {
    pub batch_id: String,
    pub ordered_results: Vec<ToolCallResult>,
}
```

- [ ] Add integration tests covering:

  1. text-only completion calls the model once and never calls tools;
  2. two tool calls become one `execute_batch` call in model order;
  3. a validated assistant tool-call plus ordered result batch commits atomically and causes exactly one next model turn;
  4. mismatched batch ID, count, call ID, tool name, or result order fails the run;
  5. different conversation streams can run concurrently, but a second `Send` or `RetryFrom` on the same stream returns `conversation_busy` before appending or executing anything;
  6. the fixed `MAX_MODEL_TURNS` ends a loop after 16 model calls;
  7. a tool-runtime failure leaves no canonical assistant tool-call or tool-result record;
  8. a valid batch commits the assistant tool calls and all tool results in one storage transaction;
  9. streaming text/reasoning/tool events remain ephemeral until a final turn or complete tool round commits;
  10. cancellation while the model is running calls `ModelRuntime::cancel` and commits no final/tool round;
  11. cancellation after the model returns but before tool dispatch prevents `execute_batch`;
  12. cancellation during tool execution calls `ToolRuntime::cancel_batch` with the active batch ID and commits no tool round;
  13. edit/delete/clear/branch/archive/conversation deletion on a busy stream returns `conversation_busy` without mutation; the UI may explicitly cancel and retry;
  14. an active-run lease is released on completion, error, max-turn, and cancellation;
  15. startup claims an unstarted canonical run once but marks a previously started nonterminal run interrupted without replaying model/tools;
  16. `AgentLoopService::cancel_run` never holds the active-run map lock or cancellation gate while calling either runtime, and a re-entrant fake runtime cannot deadlock it;
  17. the `agent_loop` source contains no `RunState`, `RunMachine`, `Approval`, `ToolLoopDetector`, `HostExecutionPhase`, or `ResourceLifecycle` dependency.

- [ ] Run:

```bash
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test contract agent_loop_contract
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test integration react_loop
```

Expected: FAIL.

### GREEN: implement one ordinary bounded loop

- [ ] Implement `AgentLoop::run` as a `for` loop:

```rust
pub const MAX_MODEL_TURNS: usize = 16;

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
    let batch_result = tools.execute_batch(batch.clone())?;
    drop(active_batch);
    cancellation.check()?;
    validate_batch_result(&batch, &batch_result)?;
    cancellation.commit_if_active(|| {
        transcript.commit_tool_round(&run, &turn, &batch_result)
    })?;
}
Err(AgentLoopError::max_model_turns(MAX_MODEL_TURNS))
```

- [ ] Do not add an agent phase enum. Cancellation, model error, tool error, and max-turn termination are normal return branches.
- [ ] Add a minimal `ActiveConversationRuns` guarded map from `conversation_stream_id` to `ActiveRunEntry { run_id, cancellation: Arc<RunCancellationRecord> }`. `try_acquire` returns an RAII lease; a duplicate command receipt is resolved before this check, different streams do not block one another, and dropping the lease removes only the matching `(stream, run)` pair. `cancellation_for_run(run_id)` clones the record and releases the map lock before returning it; this map never calls a runtime.
- [ ] Before exposing the FFI command endpoint at startup, resolve canonical nonterminal runs using Task 3's conservative rule: acquire a lease and start a never-started request once; append an interrupted terminal event for any `run_started` record without a terminal event. Do not reconstruct an in-flight tool batch.
- [ ] The first fresh run-producing command acquires the stream lease before its canonical command transaction and transfers that lease to the scheduled `AgentLoop`. If acquisition or the transaction fails, write nothing and release the lease. Every other transcript mutation on that active stream returns `conversation_busy`; explicit cancellation is the only operation allowed through the guard. A deliberate UI retry after cancellation uses a new `request_id`; replaying the busy request ID returns its stored busy outcome.
- [ ] Use this run-scoped cancellation record, not a phase/state enum:

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

`CancellationToken` is one `AtomicBool`, not a lifecycle enum. The record contains no runtime reference and never makes a Swift/FFI call. Its cancellation method is limited to the short critical section:

```rust
fn request_cancel(&self) -> Option<String> {
    let gate = self.gate.lock().expect("cancellation gate poisoned");
    self.token.cancel();
    gate.active_batch_id.clone()
}
```

`AgentLoopService::cancel_run(run_id)` owns the `ModelRuntime` and `ToolRuntime` references. It clones the record from `ActiveConversationRuns`, calls `request_cancel()`, releases every Rust lock, and only then calls `ToolRuntime::cancel_batch(batch_id)` when a batch was returned or `ModelRuntime::cancel(run_id)` otherwise. Cancellation between model completion and `begin_batch` therefore sets the token and prevents the batch from starting. `begin_batch(batch_id)` holds the gate only while atomically rejecting an already-cancelled run or recording that batch before Swift can start it. `commit_if_active` may hold the same gate while checking the token and running the short transcript transaction: a cancellation linearized first forbids the commit; a commit linearized first means the canonical turn had already completed.
- [ ] Treat `ModelRuntime::cancel(run_id)` as idempotent provider/run-resource cleanup even when no model request is active. On tool error, max-turn, or any abnormal exit without an active batch, the loop wrapper calls it before releasing the stream lease; this also releases the Swift run-scoped detector. Normal final completion is cleaned by `OpenMinisModelExecutor` after a no-tool model turn.
- [ ] Implement `commit_tool_round` in `conversation/service.rs` as one event-store/SQLite transaction containing the assistant tool-call event and every ordered tool-result event. A failed or cancelled batch performs no canonical write for that round.
- [ ] Add one storage primitive used by both the in-memory and SQLite stores:

```rust
fn append_transaction(
    &mut self,
    conversation_stream_id: &str,
    expected_next_sequence: u64,
    events: Vec<RuntimeEvent>,
) -> Result<Vec<RuntimeEvent>, AgentError>;
```

It checks the expected sequence before writing and either appends every event with consecutive per-stream sequences or appends none.
- [ ] Treat `ModelEventSink` output as transient UI/telemetry. Only `commit_final_turn` or `commit_tool_round` creates transcript events.
- [ ] Use the existing context assembler, prompt compiler, canonical digest, and conversation services. Build the tool validation index only from the frozen `RunStartSnapshot.ordered_tool_definitions`; do not fall back to a Rust-owned static tool catalog.
- [ ] Keep `MAX_MODEL_TURNS` as the single compile-time Rust loop bound. Do not add a per-run configuration field.
- [ ] Reuse OpenMinis `ToolLoopDetector` only in the Swift batch executor; do not port or duplicate it in Rust.
- [ ] Keep the old `execution/react_worker.rs` alive until Task 14, but add an architecture lint ensuring new production composition selects `agent_loop::AgentLoop`.

- [ ] Run:

```bash
cargo fmt --manifest-path local-ios-agent/rust-core/Cargo.toml -- --check
cargo clippy --manifest-path local-ios-agent/rust-core/Cargo.toml --all-targets -- -D warnings
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test contract agent_loop_contract
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test integration react_loop
```

Expected: PASS.

- [ ] Commit:

```bash
git add local-ios-agent/rust-core/src/agent_loop \
  local-ios-agent/rust-core/src/tool \
  local-ios-agent/rust-core/src/lib.rs \
  local-ios-agent/rust-core/tests
git commit -m "feat: add minimal Rust ReAct agent loop"
```

---

## Task 6: Evolve the Existing Host Envelopes for Complete Model Requests and Tool Batches

**Files:**

- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/llm_contracts/host_command.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/llm_contracts/llm_event.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/llm_contracts/mod.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/toolkit/Sources/LocalAgentLLMContracts/LLMHostCommand.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/toolkit/Sources/LocalAgentLLMContracts/LLMEventEnvelope.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/toolkit/Sources/LocalAgentLLMContracts/LLMInput.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/toolkit/Sources/LocalAgentLLMContracts/LLMToolResult.swift`
- Test: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/tests/contract/host_llm_contracts.rs`
- Test: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/toolkit/Tests/LocalAgentLLMContractsTests/HostEnvelopeTests.swift`
- Test fixtures: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/toolkit/Tests/LocalAgentLLMContractsTests/Fixtures`

### RED: cross-language wire fixtures

- [ ] Add identical Rust and Swift JSON fixtures for:

  1. a complete model request containing `system_prompt`, ordered messages, attachment references, and ordered tool definitions;
  2. an `execute_tool_batch` command with two ordered calls;
  3. a `tool_batch_completed` event with two ordered results;
  4. a cancellation command for an active batch;
  5. invalid command/payload combinations for every command kind;
  6. invalid event/payload combinations: missing batch completion, completion on a model event, mismatched run ID, mismatched expected batch ID, and batch completion mixed with text/tool-call/model-completion fields.

- [ ] Assert both languages produce the same canonical envelope digest.
- [ ] Assert old schema-v1 fixture decoding still works during migration.
- [ ] Assert a reordered tool result list changes the digest and is rejected by the Rust batch validator.
- [ ] Assert Swift outbound and Rust inbound validators accept/reject the same event fixtures with `llm.contract.event_payload_mismatch`.
- [ ] Run:

```bash
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test contract host_llm_contracts
swift test --package-path local-ios-agent/toolkit \
  --filter HostEnvelopeTests
```

Expected: FAIL because the current envelopes only model generation lifecycle and individual tool results.

### GREEN: version the current payload, not the transport

- [ ] Add command kinds to the existing `HostCommandKind`:

```rust
ExecuteToolBatch,
CancelToolBatch,
```

Retain `StartGeneration`, `ResumeGeneration`, `CancelGeneration`, `CloseSession`, and `CapacityAvailable`.

- [ ] Extend `HostCommandPayload` schema version 2 with optional typed fields:

```rust
pub system_prompt: Option<String>,
pub ordered_tool_definitions: Vec<HostToolDefinition>,
pub tool_batch: Option<HostToolBatch>,
pub target_batch_id: Option<String>,
```

`messages` remains the complete Rust-assembled message list. Do not let Swift prepend another system message.

- [ ] Remove the current schema-v1 prohibition on non-empty attachment references. Schema v2 digests attachment metadata in Rust and resolves the bytes from stable IDs only inside Swift.

- [ ] Add:

```rust
pub struct HostToolBatch {
    pub batch_id: String,
    pub run_id: String,
    pub ordered_calls: Vec<HostToolCall>,
}

pub struct HostToolCall {
    pub call_id: String,
    pub tool_name: String,
    pub arguments_json: String,
}
```

- [ ] Add `HostCommandPayload::validate_for(kind, envelope_run_id)` in Rust and the matching Swift validator. Enforce these exact combinations before digest acceptance or dispatch:

  - `StartGeneration`/`ResumeGeneration`: `system_prompt` is present, `tool_batch` and `target_batch_id` are absent; `messages` and `ordered_tool_definitions` are the complete Rust-built inputs.
  - `ExecuteToolBatch`: `tool_batch` is present, its `run_id` equals the envelope `run_id`, `target_batch_id` and `system_prompt` are absent, and generation-only message/tool-definition fields are empty.
  - `CancelToolBatch`: `target_batch_id` is present, `tool_batch` and `system_prompt` are absent, and generation-only fields are empty.
  - `CancelGeneration`, `CloseSession`, and `CapacityAvailable`: all schema-v2 optional fields are absent and generation-only collections are empty.

Reject `ExecuteToolBatch` without a batch, a generation command carrying a batch, a mismatched batch/envelope run ID, and any mixed payload with `llm.contract.command_payload_mismatch`.

- [ ] Add event kinds:

```rust
ToolBatchStarted,
ToolBatchCompleted,
ToolBatchFailed,
```

- [ ] Add an optional typed batch completion to `LLMEventPayload`:

```rust
pub tool_batch_completion: Option<HostToolBatchCompletion>,

pub struct HostToolBatchCompletion {
    pub batch_id: String,
    pub run_id: String,
    pub ordered_results: Vec<HostToolResult>,
}
```

Mirror `HostToolBatchCompletion` exactly in Swift. Do not send one event per executed tool result.
- [ ] Add `LLMEventPayload::validate_for(kind, envelope_run_id, expected_batch_id)` in Rust and the matching Swift `validate(for:envelopeRunID:expectedBatchID:)`. Enforce:

  - `ToolBatchCompleted` carries exactly one `tool_batch_completion`;
  - its `run_id` equals the envelope `run_id`;
  - its `batch_id` equals the non-optional active `expected_batch_id`;
  - text, reasoning/tool-call fields, token usage, model `completion`, failure, and close fields are absent; existing command/operation correlation IDs remain governed by the unchanged transport correlation rules;
  - every other model or tool event has `tool_batch_completion == nil`.

Reject a missing/mixed completion or either identity mismatch with `llm.contract.event_payload_mismatch`.
- [ ] Swift validates immediately before computing the outgoing v2 event digest and enqueueing the event. Rust verifies decoding and the canonical digest, then invokes the same validator with the batch awaited by `HostToolRuntime`; validation must finish before receipts, transport lifecycle transitions, result-slot mutation, or delivery to `AgentLoop`. A valid digest never bypasses semantic validation.

- [ ] Keep all existing envelope identity fields, sequence semantics, receipt dispositions, digest verification, backpressure behavior, and `host_process_epoch`.
- [ ] Make canonical digest domains schema-specific (`host-command-payload:v2`, `llm-event-envelope:v2`) while preserving v1 decoding until Task 14.
- [ ] Run the two focused suites.

Expected: PASS.

- [ ] Commit:

```bash
git add local-ios-agent/rust-core/src/llm_contracts \
  local-ios-agent/rust-core/tests/contract/host_llm_contracts.rs \
  local-ios-agent/toolkit/Sources/LocalAgentLLMContracts \
  local-ios-agent/toolkit/Tests/LocalAgentLLMContractsTests
git commit -m "feat: carry model requests and tool batches on host envelopes"
```

---

## Task 7: Isolate the Reliable Transport as the Rust `host_adapter`

**Files:**

- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/host_adapter/mod.rs`
- Move: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/execution/host_llm_dispatcher.rs` → `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/host_adapter/dispatcher.rs`
- Move: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/execution/host_llm_worker.rs` → `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/host_adapter/event_ingress.rs`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/host_adapter/model_runtime.rs`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/host_adapter/tool_runtime.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/execution/mod.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/lib.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/ffi_bridge.rs`
- Test: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/tests/contract/host_adapter.rs`
- Test: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/tests/integration/host_agent_loop.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/tests/contract.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/tests/integration.rs`

### RED: prove the layer boundary

- [ ] Add tests proving:

  - `HostModelRuntime` implements `agent_loop::ModelRuntime`;
  - `HostToolRuntime` implements `agent_loop::ToolRuntime`;
  - one `generate` call sends one generation command and blocks only its Rust worker thread until a terminal model event;
  - one `execute_batch` call sends one whole batch command with the same run ID and returns one `ToolBatchResult` containing the same batch ID and ordered results;
  - a receipt retry/backpressure event cannot duplicate model output or tool execution;
  - stale host epoch and sequence conflicts remain rejected;
  - model cancellation and batch cancellation produce different host commands;
  - `agent_loop/**` imports no `host_adapter`, `llm_contracts`, `Host*`, or transport repository type.

- [ ] Add an architecture test that reads `src/agent_loop` and fails on those forbidden imports.
- [ ] Run:

```bash
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test contract host_adapter
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test integration host_agent_loop
```

Expected: FAIL.

### GREEN: adapt the current dispatcher and ingress

- [ ] Use `git mv` for the dispatcher and worker files so history is preserved.
- [ ] Keep their `Condvar`/worker-thread mechanism, receipts, backpressure thresholds, repository transactions, epoch checks, and necessary `HostExecutionPhase`/`ResourceLifecycle` transport states.
- [ ] At event ingress, run Task 6's `LLMEventPayload::validate_for` after digest verification and before any transport state transition or model/tool result delivery. Pass the active batch ID awaited by `HostToolRuntime`; an invalid event becomes a terminal contract error and never fills a result slot.
- [ ] Replace `HostToolBatchExecutor::execute_tool` and the sequential loop in `process_tool_batch` with the `HostToolRuntime` command/response path.
- [ ] Route the existing `cancel_run` FFI operation to `AgentLoopService::cancel_run(run_id)`. The service obtains the run-scoped record, copies its optional active batch ID under the short gate, releases all locks, and only then emits `CancelGeneration` or `CancelToolBatch`; the bridge does not infer a phase.
- [ ] Remove approval outcomes from the new adapter. A Swift preflight rejection is an ordinary `ToolCallResult { is_error: true }`.
- [ ] Have `HostModelRuntime::generate`:

  1. map the logical `ModelRequest` into a schema-v2 `HostCommandEnvelope`,
  2. dispatch through the existing callback,
  3. consume sequenced model events into the supplied `ModelEventSink`,
  4. assemble `AssistantTurn`,
  5. return only after `GenerationCompleted`, `Failed`, or `Cancelled`.

- [ ] Have `HostToolRuntime::execute_batch`:

  1. send `ExecuteToolBatch`,
  2. await the matching batch ID,
  3. map exactly one `ToolBatchCompleted` event,
  4. return `ToolBatchResult { batch_id, ordered_results }` without reordering or executing any tool in Rust.

- [ ] Re-export old `execution::host_llm_*` names temporarily for current tests and callers. Remove the aliases in Task 14.
- [ ] Run:

```bash
cargo fmt --manifest-path local-ios-agent/rust-core/Cargo.toml -- --check
cargo clippy --manifest-path local-ios-agent/rust-core/Cargo.toml --all-targets -- -D warnings
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test contract host_adapter
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test integration host_agent_loop
```

Expected: PASS.

- [ ] Commit:

```bash
git add local-ios-agent/rust-core/src local-ios-agent/rust-core/tests
git commit -m "refactor: adapt reliable host transport to the direct loop"
```

---

## Task 8: Add the Swift Model and Tool Batch Command Handlers

**Files:**

- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/toolkit/Sources/LocalAgentLLMHost/LLMHostCommandInbox.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/toolkit/Sources/LocalAgentLLMHost/LLMHostRuntime.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/toolkit/Sources/LocalAgentLLMHost/LLMHostProductRuntime.swift`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/toolkit/Sources/LocalAgentLLMHost/ModelRuntimeCommandHandler.swift`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/toolkit/Sources/LocalAgentLLMHost/ToolBatchCommandHandler.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/toolkit/Sources/LocalAgentLLMHost/LLMEventSequencer.swift`
- Test: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/toolkit/Tests/LocalAgentLLMHostTests/ModelRuntimeCommandHandlerTests.swift`
- Test: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/toolkit/Tests/LocalAgentLLMHostTests/ToolBatchCommandHandlerTests.swift`

### RED: enforce complete input without duplicating fallback state

- [ ] Add a `ModelGenerationExecuting` test fake and tests proving:

  - the executor receives exactly the Rust-provided system prompt, ordered messages, and ordered tools;
  - attachment bytes are resolved from stable Swift-owned IDs immediately before provider/local execution and are never persisted in Rust;
  - no Swift prompt builder is invoked;
  - the handler forwards model events and terminal errors without implementing retry/fallback or storing replay eligibility;
  - Rust never receives or selects the provider fallback candidate list;
  - cancellation stops the active provider/local task;
  - tool batch commands retain `runID`, are passed as one ordered value, and emit one batch completion echoing both `batchID` and `runID`.

- [ ] Define the Swift-only protocols:

```swift
public protocol ModelGenerationExecuting: Sendable {
    func generate(
        _ request: HostModelRequest,
        emit: @escaping @Sendable (HostModelEvent) async throws -> Void
    ) async throws
    func cancel(runId: String) async
}

public protocol ToolBatchExecuting: Sendable {
    func execute(_ batch: HostToolBatch) async -> HostToolBatchCompletion
    func cancel(batchId: String) async
}
```

- [ ] Run:

```bash
swift test --package-path local-ios-agent/toolkit \
  --filter ModelRuntimeCommandHandlerTests
swift test --package-path local-ios-agent/toolkit \
  --filter ToolBatchCommandHandlerTests
```

Expected: FAIL.

### GREEN: dispatch existing envelopes to injected executors

- [ ] Route `StartGeneration`/`ResumeGeneration`/`CancelGeneration` to `ModelRuntimeCommandHandler`.
- [ ] Route `ExecuteToolBatch`/`CancelToolBatch` to `ToolBatchCommandHandler`.
- [ ] Keep `ModelRuntimeCommandHandler` as a thin dispatcher. It owns no `hasEmittedModelContent` field or per-run replay dictionary. Fallback ordering, replay eligibility, and model/provider configuration belong only to the single `OpenMinisModelExecutor.generate` invocation in Task 11.
- [ ] The host envelope contains only the selected logical request, never provider candidates or credentials.
- [ ] Use `LLMEventSequencer` for batch events as well as model events. Do not create a second Swift callback.
- [ ] Before `LLMEventSequencer` emits any v2 event, invoke Task 6's Swift event validator. For `ToolBatchCompleted`, pass the original `HostToolBatch.batchID` and reject a handler completion whose batch or run identity differs before it reaches the sequencer.
- [ ] Preserve all current event receipt and backpressure handling.
- [ ] Run both focused suites and the existing host runtime suite.

```bash
swift test --package-path local-ios-agent/toolkit \
  --filter ModelRuntimeCommandHandlerTests
swift test --package-path local-ios-agent/toolkit \
  --filter ToolBatchCommandHandlerTests
swift test --package-path local-ios-agent/toolkit \
  --filter LLMHostRuntimeTests
```

Expected: PASS.

- [ ] Commit:

```bash
git add local-ios-agent/toolkit/Sources/LocalAgentLLMHost \
  local-ios-agent/toolkit/Tests/LocalAgentLLMHostTests
git commit -m "feat: handle Rust model and tool batch commands in Swift"
```

---

## Task 9: Extract OpenMinis Tool Execution into an Ordered Batch Executor

**Files:**

- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/LocalRuntime/OpenMinisToolBatchExecutor.swift`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/LocalRuntime/ToolCallCancellationRegistry.swift`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/LocalRuntime/ToolLoopDetectorRegistry.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/Chat/AIChatViewModel+ConcurrentTools.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/Chat/AIChatViewModel+ISHCommand.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/Chat/AIChatViewModel+ToolPreflight.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/Chat/AIChatViewModel+FileTools.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/Chat/AIChatViewModel+Offloading.swift`
- Test: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/MinisTests/OpenMinisToolBatchExecutorTests.swift`
- Test: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/MinisTests/ToolCallCancellationRegistryTests.swift`
- Test: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/MinisTests/ToolLoopDetectorRegistryTests.swift`

### RED: reproduce the current cancellation defect

- [ ] Add tests with two simultaneous fake iSH calls and prove the current singular `runningCommandPid` cannot cancel both.
- [ ] Add executor tests proving:

  - at most ten independent calls are active;
  - argument repair and preflight happen before execution;
  - result order matches input order even when completion order differs;
  - the completion echoes the input `batchID` and `runID`;
  - an unknown tool and a preflight rejection return model-visible error results;
  - cancelling one batch invokes every per-call cancellation handle and every recorded PID;
  - cancellation arriving after batch registration but before a child handle/PID is installed still cancels that late registration;
  - two concurrent batches using the same call ID keep separate entries and cancelling one does not affect the other;
  - no executor method writes `AIChatViewModel.messages` or `ChatStore`;
  - `ToolLoopDetector` is consulted before each call, but after concurrent execution it records completed results in original call order rather than child-task completion order;
  - reversing the child-task completion order produces the same detector history and warnings;
  - two runs that issue identical calls have independent detector histories;
  - completing or cancelling run A removes only run A's detector and cannot alter run B.

- [ ] Run:

```bash
OPENMINIS_TEST_UDID="$OPENMINIS_IPHONE_UDID" \
  bash local-ios-agent/scripts/run-openminis-tests.sh \
  MinisTests/OpenMinisToolBatchExecutorTests \
  MinisTests/ToolCallCancellationRegistryTests \
  MinisTests/ToolLoopDetectorRegistryTests
```

Expected: FAIL.

### GREEN: extract pure execution from chat mutation

- [ ] Implement an actor:

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

The outer key is `batchID`; the inner key is `callID`. Call `beginBatch(batchID:runID:)` before creating child tasks. `cancel(batchId:)` first marks that batch cancelled, then drains only its entries and returns its run ID. Any handle/PID registered after that mark is cancelled immediately instead of escaping. `finishBatch` removes the batch maps after every child has terminated.

- [ ] Implement one shared, run-scoped registry:

```swift
final class ToolLoopDetectorRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var detectorsByRunID: [String: ToolLoopDetector] = [:]

    func detector(for runID: String) -> ToolLoopDetector
    func remove(runID: String)
}
```

`detector(for:)` returns the same detector only within one run. Each child task calls `check` immediately before dispatch and writes its result into the indexed slot, but it must not call `record`. After all children settle and results are restored to input order, the batch executor calls `record` for those completed results in that original order and attaches any warning to the matching result. A cancelled batch is discarded and its detector is removed, so it needs no completion-order history. `LocalRuntimeBootstrap` injects this same registry into `OpenMinisToolBatchExecutor` and `OpenMinisModelExecutor`; do not put a singleton detector on the executor itself.

- [ ] Implement `OpenMinisToolBatchExecutor: ToolBatchExecuting` with:

  - the existing `maxConcurrentTools = 10`,
  - the existing argument repair and `ToolPreflight`,
  - existing native offload/file/iSH tool implementations,
  - `withTaskGroup` concurrency,
  - indexed result slots so output order equals call order,
  - ordered detector recording after the task group settles,
  - batch registration before `withTaskGroup`,
  - one cancellation registry entry per `(batchID, callID)`,
  - the `HostToolBatch.runID` passed to both registries.

- [ ] Change the iSH PID callback to:

```swift
onProcessStarted: { batchId, callId, pid in
    await cancellationRegistry.record(
        pid: pid,
        batchId: batchId,
        callId: callId
    )
}
```

Allow multiple PIDs per call. Do not preserve the computed “set” backed by one PID.

- [ ] Return one `HostToolBatchCompletion` containing the input `batchID`, input `runID`, and ordered results. Remove message/ChatStore writes from the extracted execution path; legacy `AIChatViewModel` callers may adapt returned results until Task 12 replaces the loop.
- [ ] `cancel(batchId:)` obtains the batch's `runID`, cancels all entries, and removes that run's detector. `OpenMinisModelExecutor` removes the same detector when a model generation finishes with no tool call, exhausts fallback with an error, or receives `cancel(runId:)`. Removal is idempotent.
- [ ] Keep path traversal, symlink, mount permission, and native-offload checks in their current Swift execution layer.
- [ ] Run the same two test identifiers through `run-openminis-tests.sh`.

Expected: PASS.

- [ ] Commit:

```bash
git add OpenMinis/src/ios/Agent/LocalRuntime \
  OpenMinis/src/ios/Agent/Chat \
  OpenMinis/src/ios/MinisTests/OpenMinisToolBatchExecutorTests.swift \
  OpenMinis/src/ios/MinisTests/ToolCallCancellationRegistryTests.swift \
  OpenMinis/src/ios/MinisTests/ToolLoopDetectorRegistryTests.swift
git commit -m "refactor: expose OpenMinis tools as cancellable batches"
```

---

## Task 10: Feed Markdown Prompts and Progressive Skill Descriptors into Rust

**Files:**

- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/Session/PromptDocumentStore.swift`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/LocalRuntime/RustAgentInputSnapshotProvider.swift`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/LocalRuntime/OpenMinisToolDefinitionSnapshotProvider.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/Session/SkillStore.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Views/Skills/SkillsManagementView.swift`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Views/Settings/PromptDocumentsSettingsView.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Views/ContentView.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/Chat/AIChatViewModel.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/Chat/AIChatViewModel+Fallback.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/Chat/AIChatViewModel+ToolDefinitions.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/toolkit/Sources/LocalAgentBridge/TranscriptDTOs.swift`
- Test: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/MinisTests/PromptDocumentStoreTests.swift`
- Test: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/MinisTests/RustAgentInputSnapshotProviderTests.swift`
- Test: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/MinisTests/RustPromptOwnershipTests.swift`
- Test: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/tests/integration/prompt_skill_context.rs`

### RED: catch double injection

- [ ] Add tests proving:

  - Markdown prompt documents can be imported, edited, reordered, enabled, and removed;
  - the snapshot preserves the UI order and contains Markdown, not a Swift-rendered system prompt;
  - enabled Skill descriptors come from `SkillStore`, including `name`, `description`, and file location;
  - at most 20 descriptors enter Rust and no full `SKILL.md` body is present in the initial model request;
  - the snapshot contains the current ordered OpenMinis tool name/description/input JSON schema and no executable implementation;
  - `Send`, `RetryFrom`, and `EditMessage` each carry the snapshot through `TranscriptCommandDTO` into Rust exactly once;
  - Swift and Rust compute the same `run-start-snapshot:v1` digest, and Rust rejects any post-digest field mutation;
  - changing OpenMinis tool availability before the next run changes the next snapshot but not the snapshot frozen for an active run;
  - when the model selects a relevant descriptor, it reads that descriptor's location through the ordinary file tool and the returned content appears as an ordinary tool result on the next turn;
  - the complete model request contains each prompt/Skill descriptor marker exactly once;
  - `SystemPromptBuilder.identitySection`, `baseSystemPrompt`, `skillPromptFragment`, `loadGlobalMemoryFragment`, `memoryStatusFragment`, and `makeAgentTools` are not called on the Rust path;

- [ ] Run:

```bash
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test integration prompt_skill_context
```

```bash
OPENMINIS_TEST_UDID="$OPENMINIS_IPHONE_UDID" \
  bash local-ios-agent/scripts/run-openminis-tests.sh \
  MinisTests/PromptDocumentStoreTests \
  MinisTests/RustAgentInputSnapshotProviderTests \
  MinisTests/RustPromptOwnershipTests
```

Expected: FAIL.

### GREEN: reuse the OpenMinis product facilities

- [ ] Implement `PromptDocumentStore` with the same native document picker/editor/storage patterns used by `SkillStore`, but keep the data model minimal:

```swift
struct PromptDocumentRecord: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var markdown: String
    var isEnabled: Bool
    var sortOrder: Int
}
```

No template engine or prompt graph is needed.

- [ ] Add to `SkillStore`:

```swift
func rustDescriptors(for sessionId: String?) -> [RustSkillDescriptorDTO]
```

Return at most 20 enabled descriptors after applying the existing session override. Reuse existing upload/import/archive/edit/enable/session-override and sync behavior. Do not add `rustDocument`, a second Skills database, or a proactive full-file injection path.

- [ ] `RustAgentInputSnapshotProvider` returns the Task 3 wire type:

```swift
struct RunStartSnapshotDTO {
    var promptDocuments: [PromptDocumentSnapshotDTO]
    var skillDescriptors: [RustSkillDescriptorDTO]
    var orderedToolDefinitions: [ToolDefinitionSnapshotDTO]
    var snapshotDigest: String
}
```

This phase leaves the existing Rust `MemoryProvider` interface available for a later concrete backend but does not call it from context assembly or carry a memory toggle over the wire. Add that wiring only when a production provider exists.

- [ ] Extract the model-visible schema portion of the current OpenMinis tool definitions into `OpenMinisToolDefinitionSnapshotProvider`. It is the sole static source for tool name, description, and input JSON schema. Existing legacy `makeAgentTools()` may delegate to it during migration, but the Rust runtime path calls only the snapshot provider and Rust stores no duplicate static schema list.
- [ ] Compute `snapshotDigest` with the Task 3 canonical field order and `run-start-snapshot:v1` domain. `RustAgentInputSnapshotProvider` returns one complete immutable value; focused bridge tests may submit it directly. Task 12 makes `RustAgentCoordinator` obtain that value immediately before `Send`, `RetryFrom`, or `EditMessage`. Rust recomputes the digest, stores the accepted snapshot with the run request, and uses that same value for every context build and tool-call validation in the run.

- [ ] Keep each descriptor's `location` readable by the existing OpenMinis file tool. The agent decides relevance and issues `file_read`; Rust treats the returned `SKILL.md` body exactly like any other tool result.

- [ ] On the Rust runtime path, remove calls to:

```text
SystemPromptBuilder
skillPromptFragment
OpenMinis memory injection
MCP prompt fragments
legacy makeAgentTools prompt path
```

The Rust model request already contains the final system prompt and model-visible tools.

- [ ] Add an architecture test proving `RunStartSnapshot`/`RunStartSnapshotDTO` has no memory flag and the production `AgentLoop`/context path does not call `MemoryProvider` in this phase.
- [ ] Leave those helpers only where still needed for unrelated product previews. Delete unreachable loop-only helpers in Task 14.
- [ ] Run the Rust test and repeat the three-test `run-openminis-tests.sh` command above.

Expected: PASS.

- [ ] Commit:

```bash
git add OpenMinis/src/ios/Agent/Session \
  OpenMinis/src/ios/Agent/LocalRuntime \
  OpenMinis/src/ios/Agent/Chat \
  OpenMinis/src/ios/Views \
  OpenMinis/src/ios/MinisTests \
  local-ios-agent/toolkit/Sources/LocalAgentBridge/TranscriptDTOs.swift \
  local-ios-agent/rust-core/tests/integration/prompt_skill_context.rs
git commit -m "feat: assemble prompts and Skills once in Rust"
```

---

## Task 11: Use OpenMinis Provider UX with `LocalAgentLLMCloud` as the Only HTTP Runtime

**Files:**

- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/LocalRuntime/OpenMinisModelExecutor.swift`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/LocalRuntime/OpenMinisProviderConfigurationAdapter.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Providers/ProviderConfigStore.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/Chat/AIChatViewModel+ProviderFactory.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/Chat/AIChatViewModel+Fallback.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/toolkit/Sources/LocalAgentLLMCloud/ProviderPreset.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/toolkit/Sources/LocalAgentLLMCloud/CloudLLMRuntime.swift`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/toolkit/Sources/LocalAgentLLMCloud/OpenAICompatibleAdapter.swift`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/toolkit/Sources/LocalAgentLLMCloud/AntigravityCloudCodeAdapter.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/toolkit/Sources/LocalAgentLLMCloud/OpenAIChatCompletionsCodec.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/toolkit/Sources/LocalAgentLLMCloud/ProviderValidationService.swift`
- Test: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/MinisTests/OpenMinisProviderConfigurationAdapterTests.swift`
- Test: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/MinisTests/OpenMinisModelExecutorTests.swift`
- Test: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/toolkit/Tests/LocalAgentLLMCloudTests/OpenMinisProviderCompatibilityTests.swift`
- Test: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/toolkit/Tests/LocalAgentLLMCloudTests/SingleCloudTransportTests.swift`

### RED: create a provider compatibility matrix

- [ ] Add table-driven tests for every OpenMinis `ProviderType`:

| OpenMinis type | Local runtime adapter | Authentication owner |
|---|---|---|
| `openAI` | `OpenAICompatibleAdapter` | Swift Keychain/LocalAgentLLMCloud |
| `openAIResponses` | `OpenAIResponsesAdapter` | Swift Keychain/LocalAgentLLMCloud |
| `anthropic` | `AnthropicMessagesAdapter` | Swift Keychain/LocalAgentLLMCloud |
| `gemini` | `GeminiInteractionsAdapter` | Swift Keychain/LocalAgentLLMCloud |
| `openRouter` | parameterized `OpenAICompatibleAdapter` | Swift Keychain/LocalAgentLLMCloud |
| `xAI` | `XAIAdapter` | Swift Keychain/LocalAgentLLMCloud |
| `kimiCode` | parameterized `OpenAICompatibleAdapter` | Swift OAuth/LocalAgentLLMCloud |
| `antigravity` | `AntigravityCloudCodeAdapter` | Swift OAuth/LocalAgentLLMCloud |
| `unsupported` | explicit unsupported error before network | none |

- [ ] Add tests proving:

  - OpenMinis request/stream fixtures are first exercised against the existing OpenAI Responses, OpenAI Chat Completions, Anthropic, and Gemini codecs;
  - OpenAI, OpenRouter, and Kimi Code reuse one configurable OpenAI-compatible adapter with preset-specific endpoint/header/auth inputs;
  - Antigravity alone requires a dedicated Cloud Code envelope adapter because OpenMinis wraps requests and responses in its documented custom envelope;
  - provider/model/Base URL/group fallback configured in OpenMinis maps to one `LocalAgentLLMCloud` request;
  - every fallback attempt receives the same frozen Rust `ModelRequest` and never rebuilds prompt, Skills, memory, or tool schemas in Swift;
  - the first `generate(runId:)` freezes logical model, per-candidate Base URL, and fallback candidate order in one non-secret `ProviderRunPlan`;
  - after a first model turn emits tool calls, changing the selected model, Base URL, or fallback group does not change the second model turn for that run;
  - a new run created after the setting change receives the new provider plan;
  - credentials are absent from `ProviderRunPlan` and are resolved again immediately before every local/cloud attempt;
  - final completion, explicit cancellation, and terminal error each remove the run plan, while a tool-call turn retains it;
  - each `OpenMinisModelExecutor.generate` invocation owns its own local `hasEmittedModelContent` value;
  - two concurrent generate calls do not share fallback eligibility;
  - a non-cancellation failure before the first text/reasoning/tool event may retry, while any such event permanently disables replay for that invocation;
  - `CancellationError`, Swift task cancellation, and an explicit `cancel(runId:)` terminate immediately before or after the first event and never start another provider;
  - cancelling before the first token leaves the fallback provider invocation count at zero;
  - API key and OAuth token are resolved only inside Swift immediately before authorization;
  - no provider candidate list or credential appears in the host command sent by Rust;
  - no OpenMinis provider client executes `URLSession` on the Rust runtime path;
  - one provider has exactly one executable `CloudProviderAdapter`;
  - arbitrary compatible Base URLs still pass `CloudTransportPolicy` and SSRF/egress validation;
  - local model selection routes to the existing C++ `LocalAgentLLMLocal` runtime and never enters cloud transport.

- [ ] Run:

```bash
swift test --package-path local-ios-agent/toolkit \
  --filter OpenMinisProviderCompatibilityTests
swift test --package-path local-ios-agent/toolkit \
  --filter SingleCloudTransportTests
```

```bash
OPENMINIS_TEST_UDID="$OPENMINIS_IPHONE_UDID" \
  bash local-ios-agent/scripts/run-openminis-tests.sh \
  MinisTests/OpenMinisProviderConfigurationAdapterTests \
  MinisTests/OpenMinisModelExecutorTests
```

Expected: FAIL because a configurable OpenAI-compatible product route and the verified Antigravity Cloud Code envelope are not represented in `LocalAgentLLMCloud`.

### GREEN: port codecs, not network clients

- [ ] Reuse `ProviderConfigStore` UI, model lists, groups, OAuth flows, Keychain storage, validation screens, and custom Base URL editing.
- [ ] `OpenMinisProviderConfigurationAdapter` maps non-secret configuration into a `ProviderProfile` and can freeze this Swift-only value on the first model request for a run:

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

The plan contains no API key, OAuth token, rendered prompt, messages, or tool schemas. It stays in Swift and never crosses the host envelope.
- [ ] Store `ProviderRunPlan` in `OpenMinisModelExecutor` by `runID`, protected by the same actor/lock used for active provider tasks. The first `generate` atomically creates it from current settings; every later `generate` in the same ReAct run reuses it. Fallback eligibility flags remain local to each `generate` invocation, but the candidate list, logical model, model IDs, and Base URLs come only from the run plan. Do not add a second registry type or persistence table.
- [ ] Resolve the selected credential through the OpenMinis Keychain/OAuth store inside `OpenMinisModelExecutor`, then hand it to `LocalAgentLLMCloud`'s credential/authorization boundary in memory. Never serialize it into Rust DTOs.
- [ ] For each request attempt, resolve the current API key/OAuth token using the candidate's stable configuration ID immediately before authorization. Credential rotation during a run therefore takes effect on the next request without changing the frozen non-secret route.
- [ ] Implement missing provider semantics by porting only request/response/SSE codec behavior into `LocalAgentLLMCloud`. Do not call OpenMinis provider network objects from the new runtime path.
- [ ] Parameterize `OpenAICompatibleAdapter` with preset ID, endpoint, headers, authentication mode, and semantic adapter ID. Reuse it for OpenAI Chat Completions, OpenRouter, and Kimi Code.
- [ ] Implement `AntigravityCloudCodeAdapter` from the distinct envelope already present in `OpenMinis/src/ios/Providers/Antigravity/AntigravityProvider.swift`: wrap the inner request with project/model/user-agent fields and unwrap the response envelope before feeding Gemini-compatible events to the existing semantic layer.
- [ ] Do not add provider-named adapter types for OpenRouter or Kimi Code.
- [ ] Add these exact preset IDs:

```swift
public static let openAICompatible = Self(rawValue: "openai_compatible")
public static let openRouter = Self(rawValue: "openrouter")
public static let kimiCode = Self(rawValue: "kimi_code")
public static let antigravity = Self(rawValue: "antigravity")
```

- [ ] Register exactly one adapter per shipped preset in `CloudLLMRuntime.shipped()` and add all four preset IDs to `OfficialCloudCapabilityCatalog.v1.json` with their implemented semantic adapter IDs.
- [ ] Implement fallback only inside `OpenMinisModelExecutor.generate`, iterating the frozen `ProviderRunPlan.orderedCandidates`. Use local `var hasEmittedModelContent = false` and `var hasEmittedToolCall = false` values captured by that invocation's emit closure; mark `hasEmittedModelContent` before forwarding the first text, reasoning, or tool event. Retry/fallback only while that value is false. In the error path, check cancellation before the generic provider-failure branch: `CancellationError`, `Task.isCancelled`, the executor's explicit run-cancel marker, and a provider/local-runtime cancelled terminal error are always rethrown as cancellation and never advance to the next candidate. Do not add shared replay eligibility or a replay dictionary keyed by run.
- [ ] Keep the run plan after a successful generation that emitted a tool call. Remove the plan and active task/cancel entry when a generation produces the final no-tool turn, `cancel(runId:)` is called, or fallback ends in a terminal error. `cancel(runId:)` cancels the active task before the atomic cleanup. The abnormal-exit `ModelRuntime::cancel(run_id)` rule in Task 5 makes tool errors and max-turn exits use the same idempotent cleanup.
- [ ] Inject the Task 9 `ToolLoopDetectorRegistry` into `OpenMinisModelExecutor`. Remove `runID` when generation completes with `hasEmittedToolCall == false`, when fallback is exhausted, or when `cancel(runId:)` is called. A generation that emits tool calls retains the detector for the following batch.
- [ ] Keep the old OpenMinis provider factory only for non-agent previews during migration. The final App cutover task adds the architecture assertion that rejects it from `RustAgentCoordinator`.
- [ ] Run the two SwiftPM commands and repeat the two-test `run-openminis-tests.sh` command above.

Expected: PASS.

- [ ] Commit:

```bash
git add OpenMinis/src/ios/Agent/LocalRuntime \
  OpenMinis/src/ios/Providers \
  OpenMinis/src/ios/Agent/Chat/AIChatViewModel+ProviderFactory.swift \
  OpenMinis/src/ios/Agent/Chat/AIChatViewModel+Fallback.swift \
  OpenMinis/src/ios/MinisTests \
  local-ios-agent/toolkit/Sources/LocalAgentLLMCloud \
  local-ios-agent/toolkit/Tests/LocalAgentLLMCloudTests
git commit -m "feat: combine OpenMinis provider UX with one cloud runtime"
```

---

## Task 12: Make the OpenMinis App Start and Render the Rust Agent Loop

This final cutover depends on the Task 10 snapshot provider and Task 11 model/provider executor. Do not create temporary substitutes for either dependency.

**Files:**

- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/LocalRuntime/LocalRuntimeBootstrap.swift`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/LocalRuntime/RustAgentCoordinator.swift`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/LocalRuntime/ChatStoreProjectionApplier.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/Chat/AIChatViewModel.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/Chat/AIChatViewModel+Persistence.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/Chat/AIChatViewModel+BackgroundTask.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/Session/SessionForkManager.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/Chat/ChatStore.swift`
- Test: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/MinisTests/RustAgentCoordinatorTests.swift`
- Test: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/MinisTests/ChatStoreProjectionApplierTests.swift`
- Test: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/MinisTests/TranscriptOwnershipTests.swift`

### RED: lock the product control flow

- [ ] Add tests proving:

  - `send` obtains one complete Task 10 `RunStartSnapshotDTO`, submits `TranscriptCommandDTO.send`, and does not directly append a durable user message;
  - retry and edit receive the same complete snapshot shape; delete, clear, branch, archive, and conversation deletion each submit their matching Rust command before a durable `ChatStore` change;
  - a transcript command acknowledgement never applies a `ChatStore` projection;
  - app startup's persistent feed set equals `SessionConcurrencyManager.runningSessions ∪ currentConversation`, including the case of five background runs plus a different current conversation, and never exceeds six;
  - a dormant historical conversation catches up from its stored cursor when opened rather than owning a permanent feed;
  - applying an archive or delete terminal projection immediately cancels that conversation's subscription while retaining its cursor;
  - changing the current conversation cancels the old current feed immediately unless that conversation remains in `runningSessions` or is awaiting an already-accepted command projection;
  - no LRU, eviction order, or feed-priority policy exists;
  - every `TranscriptCommandDTO` establishes a feed for its `conversationStreamId` before it enters Rust, including archive/delete from the session list;
  - a dormant command target may use an available temporary feed, but when all six slots are occupied the coordinator returns `projectionFeedCapacity` before calling Rust;
  - a temporary archive/delete feed remains alive until its terminal projection is applied, then closes immediately;
  - archive/delete and other runless projections arrive through the conversation feed;
  - the coordinator never uses `ExecutionBridgeClient.observeEvents(runId:)` for transcript projection;
  - `ChatStoreProjectionApplier` ignores an event whose sequence is at or below the stored sequence for its conversation;
  - an event at exactly `lastSequence + 1` applies atomically;
  - an event above `lastSequence + 1` changes neither rows nor cursor and causes a catch-up restart from the stored cursor;
  - the same projection event replayed after app restart is a no-op;
  - two runs in one conversation share one projection cursor;
  - title, pin, and model selection remain direct Swift metadata operations;
  - `AIChatViewModel.runAgentLoop` is not called on the Rust runtime path.

- [ ] Add source architecture tests that reject:

  - direct calls to transcript-changing `ChatStore` methods from the new runtime files and from send/retry/edit/delete/clear/branch entry points;
  - the legacy OpenMinis provider factory from `RustAgentCoordinator`;
  - construction of `RustAgentCoordinator` without the concrete Task 10 snapshot provider and Task 11 `OpenMinisModelExecutor`.

- [ ] Run:

```bash
OPENMINIS_TEST_UDID="$OPENMINIS_IPHONE_UDID" \
  bash local-ios-agent/scripts/run-openminis-tests.sh \
  MinisTests/RustAgentCoordinatorTests \
  MinisTests/ChatStoreProjectionApplierTests \
  MinisTests/TranscriptOwnershipTests
```

Expected: FAIL.

### GREEN: replace control, preserve UI

- [ ] Construct the Task 10 `RustAgentInputSnapshotProvider`, Task 11 `OpenMinisModelExecutor`, `LLMHostProductRuntime`, `ModelRuntimeCommandHandler`, and Task 9 `OpenMinisToolBatchExecutor` once in `LocalRuntimeBootstrap`.
- [ ] Implement `RustAgentCoordinator` as the small UI-facing facade:

```swift
enum RustAgentCoordinatorError: Error, Equatable {
    case projectionFeedCapacity
}

@MainActor
final class RustAgentCoordinator: ObservableObject {
    func submit(_ command: TranscriptCommandDTO) async throws
    func cancel(runId: String) async
    func startProjection(conversationStreamId: String) async throws
}
```

It owns no conversation history and no agent loop.

- [ ] Replace the call from OpenMinis send/retry paths into `runAgentLoop` with snapshot creation followed by the corresponding Rust command.
- [ ] Treat `submitTranscriptCommand` results as acceptance metadata only. Feed `ChatStoreProjectionApplier` exclusively from `ConversationBridgeClient.observeTranscriptProjections`.
- [ ] `ExecutionBridgeClient.observeEvents(runId:)` may continue to drive ephemeral text/reasoning/tool-status UI for an active run, but it never advances the transcript cursor or mutates durable `ChatStore` rows.
- [ ] Keep projection cursor rows for every previously seen conversation. Reconcile persistent subscriptions after every running/current change using only:

```swift
var desiredFeedStreams = SessionConcurrencyManager.shared.runningSessions
if let currentConversationID {
    desiredFeedStreams.insert(currentConversationID)
}
let maxProjectionFeeds = SessionConcurrencyManager.shared.maxConcurrent + 1 // 6
```

Start missing feeds and cancel feeds that leave `desiredFeedStreams` and have no accepted command awaiting projection; do not implement LRU, eviction, priority, or a second concurrency manager.
- [ ] Before submitting any `TranscriptCommandDTO`, call `ensureProjectionFeed(conversationStreamId:)` for its stream, insert the cursor row at 0 when absent, and install the observation task before invoking Rust. This includes send, retry, edit, message delete, clear, branch, archive, and conversation delete; it is not limited to run-producing commands. The observer's register-before-query replay rule makes a command racing listener registration lossless.
- [ ] A dormant command target that is not in the persistent set may occupy an unused temporary slot. Enforce one hard limit of six total feeds. If all six are already required by the persistent set or other pending commands, phase 1 immediately returns `RustAgentCoordinatorError.projectionFeedCapacity` before `submitTranscriptCommand` and does not call Rust. After an accepted command, keep the temporary feed until `ChatStoreProjectionApplier` has atomically applied through `TranscriptCommandResult.acceptedSequence`; archive/delete specifically wait for their terminal projection. Then cancel and await that feed unless the stream has joined the persistent set. A rejected Rust command releases its temporary feed immediately.
- [ ] Reconnecting always creates a fresh subscription ID and passes the last committed Swift cursor.
- [ ] Apply only `sequence == last_sequence + 1`. If the feed emits `sequence > last_sequence + 1`, cancel and await termination of that observation without applying the event, then immediately reopen it with `afterSequence: last_sequence`; never jump the cursor. The Rust operation replays canonical events before resuming live delivery.
- [ ] On projection stream error or listener overflow, release the old subscription and reopen from the same last committed cursor after 250 ms, then 1 s, then 2 s for subsequent failures; reset to 250 ms after the next applied event. Do not fall back to the run observer or command response.
- [ ] After applying an archive or conversation-deletion terminal projection, cancel and await that stream's subscription immediately. Retain its cursor row so reopening or recovery resumes from the last applied sequence without a permanent listener.
- [ ] Preserve existing OpenMinis rendering, attachments UI, tool blocks, background-task behavior, title generation UI, provider picker, session list, and iPad layout.
- [ ] Streaming text/reasoning/tool status may update an ephemeral UI message. It must carry the Rust event ID and be reconciled by the final projection, not persisted independently.
- [ ] Add one SQLite projection cursor table to the existing OpenMinis database:

```sql
create table if not exists rust_projection_cursor (
    conversation_stream_id text primary key,
    last_sequence integer not null
);
```

This is per-stream state, not a global cursor.

- [ ] Make `ChatStoreProjectionApplier` the sole new-runtime caller of transcript row insert/update/delete methods. Apply the event and cursor advance in one `ChatStore` transaction.
- [ ] Apply `CursorAdvance` by changing only the cursor in that transaction.
- [ ] Do not add `ChatStore → Rust` reconciliation. If Rust has no canonical conversation, display it as unavailable rather than importing Swift rows.
- [ ] Remove the Swift invocation of the old `runAgentLoop`; leave its body temporarily unreachable until Task 14.
- [ ] Run the complete `MinisTests` target to catch direct-ChatStore regressions:

```bash
OPENMINIS_TEST_UDID="$OPENMINIS_IPHONE_UDID" \
  bash local-ios-agent/scripts/run-openminis-tests.sh MinisTests
```

Expected: PASS.

- [ ] Commit:

```bash
git add OpenMinis/src/ios/Agent/LocalRuntime \
  OpenMinis/src/ios/Agent/Chat \
  OpenMinis/src/ios/Agent/Session/SessionForkManager.swift \
  OpenMinis/src/ios/MinisTests
git commit -m "feat: drive the OpenMinis product from the Rust loop"
```

---

## Task 13: Disable Conversation Sync and Make the iSH Security Boundary Explicit

**Files:**

- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/Sync/CloudSyncEngine.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/Sync/SyncDirtyScanner.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/Sync/V2/UploadPolicy.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/Sync/V2/ChatStoreSyncHydrators.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/Sync/V2/SyncCore.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/Sync/V2/MigrationEngine.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/Sync/V2/ICloudSharedZoneTransport.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Views/Settings/CloudSyncSettingsView.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Views/Sync/CloudSyncSettingsV2View.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Views/Settings/MountedFoldersSettingsView.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/iSH/ISHKernel.m`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/LocalRuntime/GuestRuntimeSecurityPolicy.swift`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Views/Settings/GuestNetworkingDisclosureView.swift`
- Test: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/MinisTests/ConversationSyncDisabledTests.swift`
- Test: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/MinisTests/GuestRuntimeSecurityPolicyTests.swift`
- Test: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/MinisTests/SecretIsolationTests.swift`

### RED: encode the real boundary

- [ ] Add sync tests proving:

  - `Session`, `Message`, `CompactMarker`, `SessionFile`, and their V2 variants are never enqueued, uploaded, downloaded, merged, restored, or deleted remotely;
  - already-present remote records of those types are ignored without touching `ChatStore`;
  - Skills and provider configuration records remain eligible;
  - no code path imports remote `ChatStore` messages into Rust.

- [ ] Add security tests proving:

  - raw guest networking defaults to enabled;
  - the settings UI states that iSH `curl`, `wget`, and `apk` have an independent network path not covered by cloud-model egress protection;
  - API keys/OAuth tokens are absent from iSH environment, files, command arguments, tool results, and logs;
  - `/var/minis/skills` is read-only to tools unless the product editor performs the write;
  - `/var/minis/shared`, session workspaces, and user-mounted folders use explicit declared read/write permissions;
  - `..` traversal and symlink escape are rejected before native offload or host file access;
  - no per-command approval prompt is introduced.

- [ ] Run:

```bash
OPENMINIS_TEST_UDID="$OPENMINIS_IPHONE_UDID" \
  bash local-ios-agent/scripts/run-openminis-tests.sh \
  MinisTests/ConversationSyncDisabledTests \
  MinisTests/GuestRuntimeSecurityPolicyTests \
  MinisTests/SecretIsolationTests
```

Expected: FAIL.

### GREEN: disable the four record types at every sync edge

- [ ] Define one constant:

```swift
private static let disabledConversationRecordTypes: Set<String> = [
    "Session", "Message", "CompactMarker", "SessionFile",
    "SessionV2", "MessageV2", "CompactMarkerV2", "SessionFileV2"
]
```

- [ ] Apply it at dirty scanning, upload construction, remote hydration, deletion handling, full-sync restore, V2 sync, and sync settings. Do not leave a hidden restore path.
- [ ] Remove the “sync sessions” toggle from the product UI for phase 1 and explain that conversations remain device-local.
- [ ] Do not delete existing remote CloudKit records automatically; ignoring them is reversible and avoids destructive behavior.

### GREEN: disclose rather than pretend to sandbox iSH networking

- [ ] Implement:

```swift
struct GuestRuntimeSecurityPolicy {
    static let rawNetworkingEnabledByDefault = true
    static let cloudEgressPolicyCoversGuestNetworking = false
}
```

- [ ] Keep the existing system DNS and `8.8.8.8`/`8.8.4.4` fallback behavior in `ISHKernel.m`.
- [ ] Add a persistent Settings disclosure and first-use disclosure for guest networking. Do not claim `LocalAgentLLMCloud` policies cover iSH sockets.
- [ ] Centralize mount declarations in `GuestRuntimeSecurityPolicy` and call the existing traversal/symlink/native-offload checks from the batch executor.
- [ ] Add secret-name and secret-value redaction at the model executor/tool-result boundary. A tool result containing a credential value becomes an error and is never sent to Rust.
- [ ] Repeat the three-test `run-openminis-tests.sh` command above.

Expected: PASS.

- [ ] Commit:

```bash
git add OpenMinis/src/ios/Agent/Sync \
  OpenMinis/src/ios/Views \
  OpenMinis/src/ios/iSH/ISHKernel.m \
  OpenMinis/src/ios/Agent/LocalRuntime/GuestRuntimeSecurityPolicy.swift \
  OpenMinis/src/ios/MinisTests
git commit -m "fix: isolate conversation sync and disclose guest networking"
```

---

## Task 14: Audit Legacy Candidates and Remove Only Zero-Caller Subsystems

**Candidate files — listing is not deletion authorization:**

- Candidate delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/runtime/run_machine.rs`
- Candidate delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/runtime/checkpoint.rs`
- Candidate delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/runtime/effect.rs`
- Candidate delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/execution/react_worker.rs`
- Candidate delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/execution/tool_loop.rs`
- Candidate delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/execution/tool_approval.rs`
- Candidate delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/execution/execution_plan.rs`
- Candidate delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/execution/execution_planner.rs`
- Modify and retain: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/execution/execution_service.rs`
- Candidate delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/execution/run_lifecycle.rs`
- Candidate delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/security/approval.rs`
- Candidate delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/security/approval_protocol.rs`
- Candidate delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/security/approval_queue.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/security/manager.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/security/policy.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/security/data_egress.rs`
- Candidate delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/tool/router.rs`
- Candidate delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/tool/execution_request.rs`
- Candidate delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/tool/recipe.rs`
- Candidate delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/tool/recipe_compiler.rs`
- Candidate delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/tool/compiled_recipe.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/tool/registry.rs`
- Candidate delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/memory/audit.rs`
- Candidate delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/memory/blob.rs`
- Candidate delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/memory/branch_summary.rs`
- Candidate delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/memory/context_policy.rs`
- Candidate delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/memory/http_connector.rs`
- Candidate delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/memory/long_term.rs`
- Candidate delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/memory/memory_candidate.rs`
- Candidate delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/memory/profile.rs`
- Modify and retain: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/memory/provider.rs`
- Candidate delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/memory/resolver.rs`
- Candidate delete after the Task 4 split: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/memory/sqlite.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/runtime/mod.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/execution/mod.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/memory/mod.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/security/mod.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/tool/mod.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/ffi_bridge.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/toolkit/Sources/LocalAgentBridge/RustAgentOSBridgeGateway.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/toolkit/Sources/LocalAgentBridge/ExecutionBridgeClient.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/toolkit/Sources/LocalAgentBridge/RuntimeDTOs.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/toolkit/Sources/LocalAgentBridge/RustRuntimeClient.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/toolkit/Sources/LocalAgentBridge/MockRuntimeClient.swift`
- Candidate delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/tests/contract/security_approval_protocol.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/tests/contract/security_data_egress.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/tests/contract/security_manager.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/Chat/AIChatViewModel.swift` — delete `runAgentLoop` and `launchRerunAgentLoop`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/Chat/AIChatViewModel+Fallback.swift` — delete `streamWithAutoRetry`, `streamWithGroupFallback`, and `streamWithGroupFallbackUntilContent`
- Test: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/tests/lint/minimal_agent_architecture.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/tests/lint.rs`
- Test: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/MinisTests/LegacyAgentLoopRemovalTests.swift`

### RED: prove nothing production-reachable needs the old systems

- [ ] Before deletion, run:

```bash
rg -n "RunMachine|ExecutionReactWorker|ApprovalRequired|approve_tool|approveTool|SuspendedForToolApproval|HostToolBatchExecutor|skillPromptFragment\\(|loadGlobalMemoryFragment\\(" \
  local-ios-agent/rust-core/src \
  local-ios-agent/toolkit/Sources \
  OpenMinis/src/ios
```

- [ ] Classify every match:

  - mark a candidate removable only when production caller count is zero and a named replacement is already tested;
  - retain only if it is a non-agent product safety check or necessary transport lifecycle;
  - do not keep compatibility shims with no production caller.

- [ ] Create four independent audit groups and do not combine their deletion decisions:

  1. Agent loop/state machine: `run_machine`, `react_worker`, `tool_loop`, `checkpoint`, `effect`.
  2. Approval bridge/security queue: approval protocol/queue plus Swift/Rust FFI approval entry points.
  3. Tool recipe/router path: recipe compiler, router, and execution request.
  4. Concrete memory graph: resolver/HTTP/blob/long-term/profile/audit modules; `provider.rs` remains the single optional interface.

- [ ] Retain `execution_service.rs`. Current `ffi_bridge.rs` uses its event observation and external completion methods. Refactor it to keep `observe_events`, `observe_event_stream`, `record_external_event`, and `record_external_completed`, while removing fields/methods belonging only to a zero-caller tool loop, approval service, or run lifecycle.

- [ ] Add lint tests requiring:

  - no `RunMachine` or agent approval bridge symbol;
  - no `execute_tool` single-call host trait;
  - `memory/mod.rs` exports the existing `MemoryProvider`, exports no `MemoryBackend`, and every remaining concrete memory export has a recorded production caller;
  - `agent_loop` has no state-machine or transport dependency;
  - `host_adapter` contains the retained receipt/epoch/backpressure lifecycle;
  - OpenMinis has no callable Swift-owned agent loop.

- [ ] Run the lints.

Expected: FAIL only for a candidate group whose replacement is active but whose old production symbols remain.

### GREEN: remove one audited group at a time

- [ ] For each audit group, run `rg` against `rust-core/src`, `toolkit/Sources`, and `OpenMinis/src/ios`, excluding the candidate files themselves. Delete only files with zero production callers; otherwise leave that group unchanged and create no deletion commit for it.
- [ ] After each group, run its focused contract/integration tests and commit that group separately before starting the next group.
- [ ] Remove `approveTool`, pending approval DTOs, and approval FFI exports from the Agent bridge.
- [ ] Reduce Rust `PolicyDecision` to `Allow` or `Deny`; a policy never suspends a run. Remove approval grants from data-egress decisions and return a direct denial error when policy rejects an operation.
- [ ] Reduce `tool/registry.rs` to validation/indexing of the frozen `RunStartSnapshot.ordered_tool_definitions`. It must not contain a second static OpenMinis schema catalog. Remove the recipe compiler/router/execution-request path now that Swift/OpenMinis executes tools.
- [ ] Remove approval-only `HostExecutionPhase` variants. Retain transport lifecycle variants used by active host session cleanup, receipts, cancellation, or backpressure.
- [ ] Keep non-interactive security checks: path traversal, symlink resolution, mount permissions, native-offload permissions, cloud SSRF/egress policy, digest validation, secret isolation, and loop/max-turn limits.
- [ ] Remove tool schema execution/approval metadata that Swift does not need. Keep only model-visible schema plus stable tool name/ID required for Rust validation.
- [ ] Delete an old memory test only when its concrete backend was removed. Retain one fake-backed `MemoryProvider` contract test and every test for a still-reachable module.
- [ ] Delete old OpenMinis prompt reconstruction, model loop, and direct tool-to-ChatStore code that is now unreachable.
- [ ] Run:

```bash
cargo fmt --manifest-path local-ios-agent/rust-core/Cargo.toml -- --check
cargo clippy --manifest-path local-ios-agent/rust-core/Cargo.toml --all-targets -- -D warnings
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml --all-targets
swift test --package-path local-ios-agent/toolkit
```

```bash
OPENMINIS_TEST_UDID="$OPENMINIS_IPHONE_UDID" \
  bash local-ios-agent/scripts/run-openminis-tests.sh \
  MinisTests/LegacyAgentLoopRemovalTests
```

Expected: PASS.

- [ ] Commit each proven removal separately:

```bash
git add -A local-ios-agent/rust-core
git commit -m "refactor: remove zero-caller legacy agent loop"

git add -A local-ios-agent/rust-core local-ios-agent/toolkit
git commit -m "refactor: remove zero-caller approval bridge"

git add -A local-ios-agent/rust-core
git commit -m "refactor: remove zero-caller tool recipe path"

git add -A local-ios-agent/rust-core
git commit -m "refactor: remove zero-caller memory backends"

git add -A local-ios-agent/rust-core OpenMinis/src/ios/Agent/Chat OpenMinis/src/ios/MinisTests
git commit -m "refactor: retain minimal execution event observation"
```

---

## Task 15: Prove the Full iPhone/iPad Product Cutover

**Files:**

- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/scripts/test-openminis-rust-react-product.sh`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/docs/openminis-runtime-operations.md`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/README.md`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/README.md`
- Test: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/MinisTests/RustReactProductPathTests.swift`
- Test: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/MinisUITests/RustAgentSmokeTests.swift`

### RED: one product-path suite

- [ ] Add an integration test that exercises:

  1. create conversation;
  2. send a user message;
  3. Rust assembles prompt/context/tools;
  4. local C++ fake model emits two tool calls;
  5. OpenMinis executes the batch out of order internally;
  6. Rust receives ordered results and performs the next model turn;
  7. final assistant output is persisted by Rust and projected once;
  8. app relaunch replays no duplicate messages;
  9. retry and edit both create new canonical events;
  10. cancellation terminates the model and all tool processes, and cancellation before the first token never starts a fallback provider;
  11. a simulated host exit between tool-call streaming and batch completion leaves neither assistant tool calls nor tool results in the canonical transcript;
  12. app relaunch from a stale projection cursor replays the missing conversation events before live delivery, and an injected sequence gap is pulled rather than skipped;
  13. retrying the same `Send` FFI payload with the same request ID returns the original result and starts one run, while a changed payload returns idempotency conflict;
  14. two simultaneous sends on one conversation execute at most one model/tool path and the other returns `conversation_busy`, while two conversations run concurrently;
  15. model-phase, model-to-tool boundary, and tool-phase cancellation races commit no post-cancel final/tool round;
  16. two runs with identical tools retain independent `ToolLoopDetector` histories and both registries are empty after termination;
  17. out-of-order child completion still records `ToolLoopDetector` history in original call order;
  18. the Rust model request uses the digest-verified prompt/Skill/tool snapshot frozen at run start even if Swift settings change mid-run;
  19. after a tool-call turn, changing provider/model/Base URL/fallback settings does not alter that run's second model turn, a new run sees the change, and each attempt still resolves the current credential;
  20. cancelling an idle projection feed with no new event returns its FFI observer and leaves zero Rust listeners/subscriptions and zero Swift projection tasks;
  21. five background runs plus a different current conversation own exactly six feeds; changing the current conversation reconciles the direct set without LRU;
  22. every transcript command establishes its feed before entering Rust, a seventh dormant command target is rejected before canonical mutation, and an archive/delete temporary feed closes only after its terminal projection applies;
  23. a digest-valid `ToolBatchCompleted` with missing/mixed completion or mismatched batch/run identity is rejected before transport state mutation or AgentLoop result delivery.

- [ ] Add UI smoke tests for:

  - iPhone chat send/tool/final flow;
  - iPad split-view chat flow;
  - provider/API Key/Base URL configuration screen;
  - Skills import/enable screen;
  - Prompt Markdown import/reorder screen;
  - iSH guest-network disclosure;
  - conversation sync shown as device-local.

- [ ] Run the product script before implementing it.

Expected: FAIL because the consolidated script and smoke fixtures do not exist.

### GREEN: consolidate verification

- [ ] Implement `test-openminis-rust-react-product.sh` with:

```bash
#!/bin/bash
set -euo pipefail

cargo fmt --manifest-path local-ios-agent/rust-core/Cargo.toml -- --check
cargo clippy --manifest-path local-ios-agent/rust-core/Cargo.toml --all-targets -- -D warnings
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml --all-targets
swift test --package-path local-ios-agent/toolkit
bash local-ios-agent/scripts/test-openminis-provenance.sh
bash local-ios-agent/scripts/test-openminis-linkage.sh
```

Then select one available iPhone simulator and one available iPad simulator and run the focused `MinisTests`/`MinisUITests` on both. The script must fail if no matching simulator is available; it must not silently skip a platform.

- [ ] Run the full script:

```bash
bash local-ios-agent/scripts/test-openminis-rust-react-product.sh
```

Expected: PASS.

- [ ] Run a real-device build without signing:

```bash
xcodebuild build \
  -project OpenMinis/src/ios/Minis.xcodeproj \
  -scheme Minis \
  -sdk iphoneos \
  CODE_SIGNING_ALLOWED=NO
```

Expected: PASS.

- [ ] Write `openminis-runtime-operations.md` covering:

  - product boot ownership;
  - Rust/Swift/C++ responsibilities;
  - provider credentials and Base URL handling;
  - guest networking disclosure;
  - device-local conversation limitation;
  - cancellation and crash-recovery behavior;
  - how to update the pinned OpenMinis baseline and its submodules.

- [ ] Update READMEs so `OpenMinis/src/ios/Minis.xcodeproj` is the only shipping iOS/iPadOS app path. Mark `local-ios-agent/apps/LocalAgentApp` as a non-shipping legacy test fixture for this phase; do not present it as a second product path.
- [ ] Review the final diff:

```bash
git status --short
git diff --stat master...HEAD
git diff --check
```

- [ ] Request code review with `superpowers:requesting-code-review`.
- [ ] Address review findings, rerun the full product script, and use `superpowers:verification-before-completion` before claiming success.
- [ ] Commit:

```bash
git add local-ios-agent/scripts/test-openminis-rust-react-product.sh \
  local-ios-agent/docs/openminis-runtime-operations.md \
  local-ios-agent/README.md README.md \
  OpenMinis/src/ios/MinisTests/RustReactProductPathTests.swift \
  OpenMinis/src/ios/MinisUITests/RustAgentSmokeTests.swift
git commit -m "test: verify OpenMinis product with Rust ReAct core"
```

---

## Execution Checkpoints

Stop and review at these boundaries:

1. **After Task 2:** GPL acceptance, source provenance, submodules, and OpenMinis linkage are correct.
2. **After Task 5:** the minimal direct Rust loop and canonical transcript contracts are accepted before transport work.
3. **After Task 8:** the existing reliable wire carries complete model requests and batches without a second protocol.
4. **After Task 11:** snapshot and provider/model dependencies are complete without temporary App stubs.
5. **After Task 12:** OpenMinis is demonstrably the product trunk and Rust owns control/transcript.
6. **After Task 13:** prompt/provider/sync/iSH security boundaries match the approved design.
7. **After Task 15:** every zero-caller legacy group is removed, required event observation is retained, and the full iPhone/iPad suite passes.

## Explicitly Deferred

- Cross-device conversation sync. A later design may sync Rust canonical events directly.
- A socket/connect-level iSH network policy. Raw guest networking is disclosed and enabled by default in this phase.
- New m_flow, Memori, Graphify, or other memory integrations. This phase reuses the existing `MemoryProvider` with a test fake; an existing concrete module remains only when Task 14 proves a production caller still needs it.
- A general Rust plugin system, distributed tool runtime, or user-authored native tool execution mode.
- A global projection cursor, reverse ChatStore import, or bidirectional database reconciliation.
- Per-command approval prompts. Safety in this phase is enforced through fixed boundaries and validation, not an approval state machine.
- Deletion of `local-ios-agent/apps/LocalAgentApp`; it remains only as a legacy test fixture until its 40 app-specific tests are migrated or retired in a separate cleanup.

## Final Acceptance Commands

```bash
bash local-ios-agent/scripts/test-openminis-rust-react-product.sh
git diff --check
rg -n "RunMachine|ExecutionReactWorker|approve_tool|approveTool|SuspendedForToolApproval" \
  local-ios-agent/rust-core/src \
  local-ios-agent/toolkit/Sources \
  OpenMinis/src/ios
```

Expected:

- product script exits 0;
- `git diff --check` emits no output;
- the final `rg` emits no production symbol matches.
