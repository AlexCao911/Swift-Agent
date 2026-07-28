# OpenMinis Product Trunk with Rust ReAct Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the OpenMinis iOS/iPadOS product as the Swift app trunk while making the existing Rust core the sole owner of the direct ReAct agent loop, prompt/context assembly, transcript, and tool-batch validation; reuse OpenMinis UI, provider configuration, Skills UX, iSH runtime, and tool execution; retain the current C++ local inference backend and the existing reliable Rust/Swift transport.

**Architecture:** Rust runs one ordinary bounded `model → ordered tool batch → model` loop and persists canonical conversation events. Swift receives complete model requests or complete tool batches through the existing host envelopes, executes them with `LocalAgentLLMCloud`/the C++ local runtime or OpenMinis tools/iSH, and sends ordered results back through the existing event/receipt channel. OpenMinis `ChatStore` is an idempotent read model keyed by `(conversation_stream_id, sequence)` and never drives the loop or writes canonical transcript state.

**Tech Stack:** Rust 2021, serde/serde_json, rusqlite, C FFI; Swift 6, Swift Concurrency, SwiftPM, XCTest; OpenMinis iOS/iPadOS Xcode app and iSH/proot submodules; current C++ `LocalAgentInferenceNative` XCFramework; SQLite; Xcode/iOS Simulator.

## Global Constraints

- OpenMinis commit `9cf3a855fecd27bb5735b84cacbd56852a3ab8dd` is the product baseline. Do not selectively copy features into `local-ios-agent/apps/LocalAgentApp`.
- OpenMinis is GPLv3. Task 1 is a hard product/legal gate. Stop before importing source if GPLv3 distribution obligations have not been accepted.
- Work in an isolated root-repository worktree on branch `codex/openminis-rust-react`; do not alter the current dirty checkout or the nested source clone at `/Users/alexandercou/Projects/Alex-agent/OpenMinis`.
- Preserve the existing wire transport: `HostCommandEnvelope`, `LLMEventEnvelope`, command/event IDs, sequence checks, canonical digests, receipts, backpressure, and host process epoch. The new runtime contracts are logical interfaces over that transport, not a second protocol.
- Delete the Agent business state machine only after all production callers use the direct loop. Preserve transport lifecycle state required for reliability.
- Rust is the only assembler of the complete system prompt, messages, context, Skills content, memory contributions, and model-visible tool definitions.
- Rust is the only canonical transcript writer. Swift may render optimistic streaming state in memory, but durable `ChatStore` changes must come from Rust projection events.
- Swift owns model retry/fallback, tool concurrency, tool argument repair, tool preflight, iSH process management, and product UI.
- `LocalAgentLLMCloud` remains the only cloud HTTP execution stack. OpenMinis retains settings, OAuth, provider/model catalog, Base URL, and product interactions.
- The only Rust tool runtime API is one ordered batch call. No tool execution-mode enum crosses the Rust/Swift boundary.
- iSH raw guest networking remains enabled by default to match OpenMinis. It is an independent high-privilege network path and is not covered by `LocalAgentLLMCloud` SSRF/egress controls. The UI must disclose this; phase 1 adds no per-command approval and claims no string-based network sandbox.
- Phase 1 disables cross-device sync for `Session`, `Message`, `CompactMarker`, and `SessionFile`. Do not add a `ChatStore → Rust` import path.
- Projection identity is exactly `(conversation_stream_id, sequence)`. `run_id` identifies one execution only. Do not create a global projection cursor or projection bus.
- Secrets never enter Rust prompt/context, iSH files, iSH environment variables, tool arguments/results, or logs. Provider sync continues to follow OpenMinis's existing Swift-only secret handling.
- Keep the implementation small: two agent runtime traits (`ModelRuntime`, `ToolRuntime`), one optional memory trait (`MemoryBackend`), concrete prompt/skill snapshots, and no speculative plugin framework.

## Definition of Done

- The shipping `Minis` target starts the Rust runtime and uses the C++ local model or `LocalAgentLLMCloud` through the existing host transport.
- A Rust-owned ReAct loop completes text-only and multi-tool runs, validates ordered batch results, stops on cancellation/tool-loop/max-turn conditions, and contains no approval/run-state machine.
- OpenMinis executes a whole tool batch with up to ten concurrent calls and owns one cancellation handle plus every iSH PID for each call.
- Send, retry, edit, delete, clear, branch, archive, and conversation deletion enter Rust first and are projected idempotently into `ChatStore`.
- Prompt Markdown documents and OpenMinis Skills are passed as ordered snapshots to Rust; the new model path never invokes OpenMinis prompt/Skill/memory injection.
- Provider settings/OAuth/Base URL remain OpenMinis product features while every cloud request is executed by `LocalAgentLLMCloud`.
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
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/conversation/projection_event.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/conversation/mod.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/core/event.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/core/runtime.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/ffi_bridge.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/toolkit/Sources/LocalAgentBridge/RustAgentOSBridgeGateway.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/toolkit/Sources/LocalAgentBridge/ConversationBridgeClient.swift`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/toolkit/Sources/LocalAgentBridge/TranscriptDTOs.swift`
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
  - no projection API accepts `run_id` as its cursor.

- [ ] Add Swift bridge tests proving every transcript mutation maps to one `transcriptCommand` request and title/pin/model selection are absent from that enum.

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

### GREEN: add one logical command endpoint over the existing gateway

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
    },
    RetryFrom {
        request_id: String,
        conversation_stream_id: String,
        anchor_event_id: String,
    },
    EditMessage {
        request_id: String,
        conversation_stream_id: String,
        target_event_id: String,
        replacement_text: String,
        replacement_attachments: Vec<TranscriptAttachmentReference>,
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

- [ ] Return:

```rust
pub struct TranscriptCommandResult {
    pub conversation_stream_id: String,
    pub accepted_sequence: u64,
    pub run_id: Option<String>,
    pub projection_events: Vec<TranscriptProjectionEvent>,
}

pub struct TranscriptProjectionEvent {
    pub conversation_stream_id: String,
    pub sequence: u64,
    pub event_id: String,
    pub kind: TranscriptProjectionKind,
    pub payload: serde_json::Value,
}
```

- [ ] Use the existing event storage sequence for the specified stream. Do not add a global counter table.

- [ ] Add only one gateway operation:

```swift
case transcriptCommand = "transcript_command"
```

- [ ] Replace the mutation methods on `ConversationBridgeClient` with:

```swift
func submitTranscriptCommand(
    _ command: TranscriptCommandDTO
) async throws -> TranscriptCommandResultDTO
```

Keep read methods needed by the UI. Remove `renameSession` from the new canonical transcript route; title remains Swift product metadata.

- [ ] Keep the legacy methods temporarily behind current callers. Mark them `@available(*, deprecated, message: "Use submitTranscriptCommand")` and delete them in Task 14.

- [ ] Run the three focused commands again.

Expected: PASS.

- [ ] Commit:

```bash
git add local-ios-agent/rust-core/src/conversation \
  local-ios-agent/rust-core/src/core/event.rs \
  local-ios-agent/rust-core/src/core/runtime.rs \
  local-ios-agent/rust-core/src/ffi_bridge.rs \
  local-ios-agent/rust-core/tests \
  local-ios-agent/toolkit/Sources/LocalAgentBridge \
  local-ios-agent/toolkit/Tests/LocalAgentBridgeTests/ConversationCommandTests.swift
git commit -m "feat: make Rust own transcript commands and projection"
```

---

## Task 4: Move Conversation Persistence Out of `memory` and Define the Minimal Extension Inputs

**Files:**

- Move: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/memory/event_store.rs` → `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/storage/conversation_event_store.rs`
- Move: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/memory/in_memory.rs` → `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/storage/in_memory_conversation.rs`
- Split: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/memory/sqlite.rs`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/storage/sqlite_conversation.rs`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/prompt/snapshot.rs`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/skills/mod.rs`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/skills/catalog.rs`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/memory/backend.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/memory/contribution.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/memory/mod.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/storage/mod.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/prompt/mod.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/context/assembler.rs`
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
  - enabled Skills expose only descriptor metadata until explicitly loaded,
  - at most 20 enabled Skills contribute full `SKILL.md` content,
  - memory can be absent without changing loop behavior,
  - `memory` exports no conversation event store.

- [ ] Use these exact public types:

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

pub struct SkillDocument {
    pub descriptor: SkillDescriptor,
    pub markdown: String,
}

pub struct MemoryQuery {
    pub conversation_stream_id: String,
    pub query: String,
    pub limit: usize,
}

pub struct MemoryContribution {
    pub id: String,
    pub text: String,
    pub source: String,
    pub sensitivity: MemorySensitivity,
}

pub enum MemorySensitivity {
    Public,
    Normal,
    Sensitive,
    Secret,
}

pub trait MemoryBackend: Send + Sync {
    fn recall(&self, query: &MemoryQuery) -> Result<Vec<MemoryContribution>, AgentError>;
    fn remember(&self, contribution: &MemoryContribution) -> Result<(), AgentError>;
    fn forget(&self, id: &str) -> Result<(), AgentError>;
}
```

- [ ] Run:

```bash
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --test contract agent_inputs
```

Expected: FAIL.

### GREEN: move, do not duplicate

- [ ] Use `git mv` for the in-memory and trait files.
- [ ] Extract only conversation tables/methods from `memory/sqlite.rs` into `storage/sqlite_conversation.rs`; do not create a second SQLite database.
- [ ] Add these deprecated compatibility re-exports for Tasks 4–13, then remove them in Task 14:

```rust
#[deprecated(note = "use storage::ConversationEventStore")]
pub use crate::storage::ConversationEventStore as EventStore;
#[deprecated(note = "use storage::InMemoryConversationStore")]
pub use crate::storage::InMemoryConversationStore as InMemoryEventStore;
#[deprecated(note = "use storage::SqliteConversationStore")]
pub use crate::storage::SqliteConversationStore as SqliteEventStore;
```
- [ ] Implement deterministic prompt compilation by iterating the input `Vec<PromptDocumentSnapshot>` without slot sorting.
- [ ] Implement `SkillCatalog` as a concrete collection with:

```rust
pub fn descriptors(&self) -> &[SkillDescriptor];
pub fn load_enabled(&self, ids: &[String]) -> Result<Vec<SkillDocument>, AgentError>;
```

No plugin registry or backend trait is needed for Skills.

- [ ] Replace the current builder/confidence/provider graph in `memory/contribution.rs` with the concrete contribution and sensitivity types above. Update `context/assembler.rs` to consume them directly.
- [ ] Make memory an `Option<Arc<dyn MemoryBackend>>`. Stop exporting the old `MemoryProvider` API in Task 4, add only a test fake, and do not add m_flow, Memori, or Graphify adapters.

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
git commit -m "refactor: separate conversation storage from memory inputs"
```

---

## Task 5: Implement the Direct Rust ReAct Loop

**Files:**

- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/agent_loop/mod.rs`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/agent_loop/contracts.rs`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/agent_loop/runner.rs`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/tool/batch.rs`
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
    ) -> Result<Vec<ToolCallResult>, AgentLoopError>;

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
    pub tools: Vec<ToolDefinition>,
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
```

- [ ] Add integration tests covering:

  1. text-only completion calls the model once and never calls tools;
  2. two tool calls become one `execute_batch` call in model order;
  3. ordered results are appended and cause exactly one next model turn;
  4. mismatched batch ID, count, call ID, tool name, or result order fails the run;
  5. cancellation calls the active runtime cancel method;
  6. `max_model_turns` ends a loop after the configured count;
  7. a repeated tool signature is rejected by a small `ToolLoopDetector` port;
  8. the `agent_loop` source contains no `RunState`, `RunMachine`, `Approval`, `HostExecutionPhase`, or `ResourceLifecycle` dependency.

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
for model_turn in 0..config.max_model_turns {
    cancellation.check()?;
    let request = context.build_model_request(&run, model_turn)?;
    let turn = model.generate(request, events)?;
    transcript.append_assistant_turn(&run, &turn)?;

    if turn.tool_calls.is_empty() {
        return Ok(AgentLoopOutcome::Completed);
    }

    loop_detector.observe(&turn.tool_calls)?;
    validate_calls(&turn.tool_calls, context.tool_definitions())?;
    let batch = ToolBatch::from_turn(&run, &turn);
    let results = tools.execute_batch(batch.clone())?;
    validate_ordered_results(&batch, &results)?;
    transcript.append_tool_results(&run, results)?;
}
Err(AgentLoopError::max_model_turns(config.max_model_turns))
```

- [ ] Do not add an agent phase enum. Cancellation, model error, tool error, loop detection, and max-turn termination are normal return branches.
- [ ] Use the existing context assembler, prompt compiler, tool registry, canonical digest, and conversation services.
- [ ] Configure a conservative production default of 16 model turns; keep it one immutable run configuration value.
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
  4. a cancellation command for an active batch.

- [ ] Assert both languages produce the same canonical envelope digest.
- [ ] Assert old schema-v1 fixture decoding still works during migration.
- [ ] Assert a reordered tool result list changes the digest and is rejected by the Rust batch validator.
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
```

`messages` remains the complete Rust-assembled message list. Do not let Swift prepend another system message.

- [ ] Remove the current schema-v1 prohibition on non-empty attachment references. Schema v2 digests attachment metadata in Rust and resolves the bytes from stable IDs only inside Swift.

- [ ] Add:

```rust
pub struct HostToolBatch {
    pub batch_id: String,
    pub ordered_calls: Vec<HostToolCall>,
}

pub struct HostToolCall {
    pub call_id: String,
    pub tool_name: String,
    pub arguments_json: String,
}
```

- [ ] Add event kinds:

```rust
ToolBatchStarted,
ToolBatchCompleted,
ToolBatchFailed,
```

- [ ] Add an optional typed batch completion to `LLMEventPayload`:

```rust
pub tool_batch_completion: Option<HostToolBatchCompletion>,
```

with `batch_id` and `ordered_results`. Do not send one event per executed tool result.

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
  - one `execute_batch` call sends one whole batch command and returns one ordered result vector;
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
- [ ] Replace `HostToolBatchExecutor::execute_tool` and the sequential loop in `process_tool_batch` with the `HostToolRuntime` command/response path.
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
  4. return ordered results without reordering or executing any tool in Rust.

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

### RED: enforce complete input and safe retry

- [ ] Add a `ModelGenerationExecuting` test fake and tests proving:

  - the executor receives exactly the Rust-provided system prompt, ordered messages, and ordered tools;
  - attachment bytes are resolved from stable Swift-owned IDs immediately before provider/local execution and are never persisted in Rust;
  - no Swift prompt builder is invoked;
  - a failure before the first text/reasoning/tool event may retry or select the next configured model;
  - after the first text, reasoning, or tool event, failure is returned without replay;
  - Rust never receives or selects the provider fallback candidate list;
  - cancellation stops the active provider/local task;
  - tool batch commands are passed as one ordered value and emit one batch completion.

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

- [ ] Route `StartGeneration`/`ResumeGeneration` to `ModelRuntimeCommandHandler`.
- [ ] Route `ExecuteToolBatch`/`CancelToolBatch` to `ToolBatchCommandHandler`.
- [ ] Track:

```swift
private var hasEmittedModelContent = false
```

Set it on the first text delta, reasoning delta, or tool-call event. The retry/fallback loop may continue only while it is false.

- [ ] Keep fallback ordering and model/provider configuration inside the injected Swift executor. The host envelope contains only the selected logical request, never provider candidates or credentials.
- [ ] Use `LLMEventSequencer` for batch events as well as model events. Do not create a second Swift callback.
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
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/Chat/AIChatViewModel+ConcurrentTools.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/Chat/AIChatViewModel+ISHCommand.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/Chat/AIChatViewModel+ToolPreflight.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/Chat/AIChatViewModel+FileTools.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/Chat/AIChatViewModel+Offloading.swift`
- Test: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/MinisTests/OpenMinisToolBatchExecutorTests.swift`
- Test: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/MinisTests/ToolCallCancellationRegistryTests.swift`

### RED: reproduce the current cancellation defect

- [ ] Add tests with two simultaneous fake iSH calls and prove the current singular `runningCommandPid` cannot cancel both.
- [ ] Add executor tests proving:

  - at most ten independent calls are active;
  - argument repair and preflight happen before execution;
  - result order matches input order even when completion order differs;
  - an unknown tool and a preflight rejection return model-visible error results;
  - cancelling one batch invokes every per-call cancellation handle and every recorded PID;
  - no executor method writes `AIChatViewModel.messages` or `ChatStore`;
  - `ToolLoopDetector` is consulted before dispatch.

- [ ] Run:

```bash
OPENMINIS_TEST_UDID="$OPENMINIS_IPHONE_UDID" \
  bash local-ios-agent/scripts/run-openminis-tests.sh \
  MinisTests/OpenMinisToolBatchExecutorTests \
  MinisTests/ToolCallCancellationRegistryTests
```

Expected: FAIL.

### GREEN: extract pure execution from chat mutation

- [ ] Implement an actor:

```swift
actor ToolCallCancellationRegistry {
    struct Entry {
        var cancel: @Sendable () async -> Void
        var pids: Set<Int32>
    }

    private var entries: [String: Entry] = [:] // keyed by call ID
}
```

- [ ] Implement `OpenMinisToolBatchExecutor: ToolBatchExecuting` with:

  - the existing `maxConcurrentTools = 10`,
  - the existing argument repair and `ToolPreflight`,
  - existing native offload/file/iSH tool implementations,
  - `withTaskGroup` concurrency,
  - indexed result slots so output order equals call order,
  - one cancellation registry entry per call.

- [ ] Change the iSH PID callback to:

```swift
onProcessStarted: { callId, pid in
    await cancellationRegistry.record(pid: pid, for: callId)
}
```

Allow multiple PIDs per call. Do not preserve the computed “set” backed by one PID.

- [ ] Return only `HostToolBatchCompletion`. Remove message/ChatStore writes from the extracted execution path; legacy `AIChatViewModel` callers may adapt returned results until Task 10 replaces the loop.
- [ ] Keep path traversal, symlink, mount permission, and native-offload checks in their current Swift execution layer.
- [ ] Run the same two test identifiers through `run-openminis-tests.sh`.

Expected: PASS.

- [ ] Commit:

```bash
git add OpenMinis/src/ios/Agent/LocalRuntime \
  OpenMinis/src/ios/Agent/Chat \
  OpenMinis/src/ios/MinisTests/OpenMinisToolBatchExecutorTests.swift \
  OpenMinis/src/ios/MinisTests/ToolCallCancellationRegistryTests.swift
git commit -m "refactor: expose OpenMinis tools as cancellable batches"
```

---

## Task 10: Make the OpenMinis App Start and Render the Rust Agent Loop

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

  - `send` submits `TranscriptCommandDTO.send` and does not directly append a durable user message;
  - retry, edit, delete, clear, branch, archive, and conversation deletion each submit their matching Rust command before a durable `ChatStore` change;
  - the coordinator observes Rust model/projection events and updates UI state;
  - `ChatStoreProjectionApplier` ignores an event whose sequence is at or below the stored sequence for its conversation;
  - the same projection event replayed after app restart is a no-op;
  - two runs in one conversation share one projection cursor;
  - title, pin, and model selection remain direct Swift metadata operations;
  - `AIChatViewModel.runAgentLoop` is not called on the Rust runtime path.

- [ ] Add a source architecture test that rejects direct calls to transcript-changing `ChatStore` methods from the new runtime files and from send/retry/edit/delete/clear/branch entry points.
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

- [ ] Construct `LLMHostProductRuntime`, `ModelRuntimeCommandHandler`, and `OpenMinisToolBatchExecutor` once in `LocalRuntimeBootstrap`.
- [ ] Implement `RustAgentCoordinator` as the small UI-facing facade:

```swift
@MainActor
final class RustAgentCoordinator: ObservableObject {
    func submit(_ command: TranscriptCommandDTO) async throws
    func cancel(runId: String) async
}
```

It owns no conversation history and no agent loop.

- [ ] Replace the call from OpenMinis send/retry paths into `runAgentLoop` with the corresponding Rust command.
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

## Task 11: Feed Markdown Prompts and OpenMinis Skills into Rust Exactly Once

**Files:**

- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/Session/PromptDocumentStore.swift`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/LocalRuntime/RustAgentInputSnapshotProvider.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/Session/SkillStore.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Views/Skills/SkillsManagementView.swift`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Views/Settings/PromptDocumentsSettingsView.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Views/ContentView.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/Chat/AIChatViewModel.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/Chat/AIChatViewModel+Fallback.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/Chat/AIChatViewModel+ToolDefinitions.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/toolkit/Sources/LocalAgentBridge/RuntimeDTOs.swift`
- Test: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/MinisTests/PromptDocumentStoreTests.swift`
- Test: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/MinisTests/RustAgentInputSnapshotProviderTests.swift`
- Test: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/MinisTests/RustPromptOwnershipTests.swift`
- Test: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/tests/integration/prompt_skill_context.rs`

### RED: catch double injection

- [ ] Add tests proving:

  - Markdown prompt documents can be imported, edited, reordered, enabled, and removed;
  - the snapshot preserves the UI order and contains Markdown, not a Swift-rendered system prompt;
  - enabled Skill descriptors come from `SkillStore`, including `name`, `description`, and file location;
  - only the Rust-selected Skill documents are loaded in full and the selection is capped at 20;
  - the complete model request contains each prompt/Skill marker exactly once;
  - `SystemPromptBuilder.identitySection`, `baseSystemPrompt`, `skillPromptFragment`, `loadGlobalMemoryFragment`, `memoryStatusFragment`, and `makeAgentTools` are not called on the Rust path;
  - provider fallback receives the same frozen Rust `ModelRequest` rather than rebuilding a prompt in Swift.

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
func rustDocument(id: String) throws -> RustSkillDocumentDTO
```

Reuse existing upload/import/archive/edit/enable/session-override and sync behavior. Do not create a second Skills database.

- [ ] `RustAgentInputSnapshotProvider` returns:

```swift
struct RustAgentInputSnapshot {
    var promptDocuments: [PromptDocumentSnapshotDTO]
    var skillDescriptors: [RustSkillDescriptorDTO]
    var memoryEnabled: Bool
}
```

The memory flag decides whether Rust calls its optional `MemoryBackend`; Swift contributes no memory text.

- [ ] On the Rust runtime path, remove calls to:

```text
SystemPromptBuilder
skillPromptFragment
OpenMinis memory injection
MCP prompt fragments
makeAgentTools
```

The Rust model request already contains the final system prompt and model-visible tools.

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
  local-ios-agent/toolkit/Sources/LocalAgentBridge/RuntimeDTOs.swift \
  local-ios-agent/rust-core/tests/integration/prompt_skill_context.rs
git commit -m "feat: assemble prompts and Skills once in Rust"
```

---

## Task 12: Use OpenMinis Provider UX with `LocalAgentLLMCloud` as the Only HTTP Runtime

**Files:**

- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/LocalRuntime/OpenMinisModelExecutor.swift`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/LocalRuntime/OpenMinisProviderConfigurationAdapter.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Providers/ProviderConfigStore.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/Chat/AIChatViewModel+ProviderFactory.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/OpenMinis/src/ios/Agent/Chat/AIChatViewModel+Fallback.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/toolkit/Sources/LocalAgentLLMCloud/ProviderPreset.swift`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/toolkit/Sources/LocalAgentLLMCloud/CloudLLMRuntime.swift`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/toolkit/Sources/LocalAgentLLMCloud/OpenAICompatibleAdapter.swift`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/toolkit/Sources/LocalAgentLLMCloud/OpenRouterAdapter.swift`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/toolkit/Sources/LocalAgentLLMCloud/KimiCodeAdapter.swift`
- Create: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/toolkit/Sources/LocalAgentLLMCloud/AntigravityAdapter.swift`
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
| `openRouter` | `OpenRouterAdapter` | Swift Keychain/LocalAgentLLMCloud |
| `xAI` | `XAIAdapter` | Swift Keychain/LocalAgentLLMCloud |
| `kimiCode` | `KimiCodeAdapter` | Swift OAuth/LocalAgentLLMCloud |
| `antigravity` | `AntigravityAdapter` | Swift OAuth/LocalAgentLLMCloud |
| `unsupported` | explicit unsupported error before network | none |

- [ ] Add tests proving:

  - provider/model/Base URL/group fallback configured in OpenMinis maps to one `LocalAgentLLMCloud` request;
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

Expected: FAIL because OpenRouter, Kimi Code, Antigravity, and generic OpenAI-compatible configuration are not all represented in `LocalAgentLLMCloud`.

### GREEN: port codecs, not network clients

- [ ] Reuse `ProviderConfigStore` UI, model lists, groups, OAuth flows, Keychain storage, validation screens, and custom Base URL editing.
- [ ] `OpenMinisProviderConfigurationAdapter` maps non-secret configuration into a `ProviderProfile`.
- [ ] Resolve the selected credential through the OpenMinis Keychain/OAuth store inside `OpenMinisModelExecutor`, then hand it to `LocalAgentLLMCloud`'s credential/authorization boundary in memory. Never serialize it into Rust DTOs.
- [ ] Implement missing provider semantics by porting only request/response/SSE codec behavior into `LocalAgentLLMCloud`. Do not call OpenMinis provider network objects from the new runtime path.
- [ ] Share `OpenAIChatCompletionsCodec` through `OpenAICompatibleAdapter`; provider-specific adapters supply endpoint, headers, model quirks, and semantic adapter IDs.
- [ ] Add these exact preset IDs:

```swift
public static let openAICompatible = Self(rawValue: "openai_compatible")
public static let openRouter = Self(rawValue: "openrouter")
public static let kimiCode = Self(rawValue: "kimi_code")
public static let antigravity = Self(rawValue: "antigravity")
```

- [ ] Register exactly one adapter per shipped preset in `CloudLLMRuntime.shipped()` and add all four preset IDs to `OfficialCloudCapabilityCatalog.v1.json` with their implemented semantic adapter IDs.
- [ ] Implement fallback in `OpenMinisModelExecutor`, obeying Task 8's pre-output-only replay rule.
- [ ] Keep the old OpenMinis provider factory only for non-agent previews during migration; architecture tests must reject it from `RustAgentCoordinator`.
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

## Task 14: Delete the Replaced State Machine, Approval Flow, and Concrete Memory Backends

**Files to delete after production-call proof:**

- Delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/runtime/run_machine.rs`
- Delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/runtime/checkpoint.rs`
- Delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/runtime/effect.rs`
- Delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/execution/react_worker.rs`
- Delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/execution/tool_loop.rs`
- Delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/execution/tool_approval.rs`
- Delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/execution/execution_plan.rs`
- Delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/execution/execution_planner.rs`
- Delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/execution/execution_service.rs`
- Delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/execution/run_lifecycle.rs`
- Delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/security/approval.rs`
- Delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/security/approval_protocol.rs`
- Delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/security/approval_queue.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/security/manager.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/security/policy.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/security/data_egress.rs`
- Delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/tool/router.rs`
- Delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/tool/execution_request.rs`
- Delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/tool/recipe.rs`
- Delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/tool/recipe_compiler.rs`
- Delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/tool/compiled_recipe.rs`
- Modify: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/tool/registry.rs`
- Delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/memory/audit.rs`
- Delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/memory/blob.rs`
- Delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/memory/branch_summary.rs`
- Delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/memory/context_policy.rs`
- Delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/memory/http_connector.rs`
- Delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/memory/long_term.rs`
- Delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/memory/memory_candidate.rs`
- Delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/memory/profile.rs`
- Delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/memory/provider.rs`
- Delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/memory/resolver.rs`
- Delete legacy parts after the Task 4 split: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/src/memory/sqlite.rs`
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
- Delete: `/Users/alexandercou/Projects/Alex-agent/.worktrees/openminis-rust-react/local-ios-agent/rust-core/tests/contract/security_approval_protocol.rs`
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

  - delete if it belongs to the replaced agent path;
  - retain only if it is a non-agent product safety check or necessary transport lifecycle;
  - do not keep compatibility shims with no production caller.

- [ ] Add lint tests requiring:

  - no `RunMachine` or agent approval bridge symbol;
  - no `execute_tool` single-call host trait;
  - `memory/mod.rs` exports only `MemoryBackend`, `MemoryQuery`, `MemoryContribution`, and `MemorySensitivity`;
  - `agent_loop` has no state-machine or transport dependency;
  - `host_adapter` contains the retained receipt/epoch/backpressure lifecycle;
  - OpenMinis has no callable Swift-owned agent loop.

- [ ] Run the lints.

Expected: FAIL while legacy code is present.

### GREEN: delete only after callers are gone

- [ ] Delete the listed state-machine, old loop, approval, and memory implementation files.
- [ ] Remove `approveTool`, pending approval DTOs, and approval FFI exports from the Agent bridge.
- [ ] Reduce Rust `PolicyDecision` to `Allow` or `Deny`; a policy never suspends a run. Remove approval grants from data-egress decisions and return a direct denial error when policy rejects an operation.
- [ ] Reduce `tool/registry.rs` to the stable model-visible name/description/JSON schema used by `AgentLoop` validation. Remove the recipe compiler/router/execution-request path now that Swift/OpenMinis executes tools.
- [ ] Remove approval-only `HostExecutionPhase` variants. Retain transport lifecycle variants used by active host session cleanup, receipts, cancellation, or backpressure.
- [ ] Keep non-interactive security checks: path traversal, symlink resolution, mount permissions, native-offload permissions, cloud SSRF/egress policy, digest validation, secret isolation, and loop/max-turn limits.
- [ ] Remove tool schema execution/approval metadata that Swift does not need. Keep only model-visible schema plus stable tool name/ID required for Rust validation.
- [ ] Delete old memory tests that test removed concrete backends. Retain one fake-backed `MemoryBackend` contract test.
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

- [ ] Commit:

```bash
git add -A local-ios-agent/rust-core \
  local-ios-agent/toolkit \
  OpenMinis/src/ios/Agent/Chat \
  OpenMinis/src/ios/MinisTests
git commit -m "refactor: remove legacy loop approval and memory machinery"
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
  10. cancellation terminates model and all tool processes.

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
4. **After Task 10:** OpenMinis is demonstrably the product trunk and Rust owns control/transcript.
5. **After Task 13:** prompt/provider/sync/iSH security boundaries match the approved design.
6. **After Task 15:** legacy machinery is removed and the full iPhone/iPad suite passes.

## Explicitly Deferred

- Cross-device conversation sync. A later design may sync Rust canonical events directly.
- A socket/connect-level iSH network policy. Raw guest networking is disclosed and enabled by default in this phase.
- Concrete m_flow, Memori, Graphify, or other memory backends. Only `MemoryBackend` and its test fake ship.
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
