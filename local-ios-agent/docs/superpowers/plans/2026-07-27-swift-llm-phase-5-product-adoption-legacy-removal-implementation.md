# Swift LLM Phase 5 Product Adoption and Legacy Removal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete one Phase 5 refactor that makes the Swift-owned LLM system the only iPhone/iPad product path, migrates complete portable Agent Profiles from old stores, and removes V1 execution plus Rust provider/model/inference ownership.

**Architecture:** Reuse the Phase 1-4 contracts, stores, local/cloud runtimes, host-binding saga, and host session bridge. Rust keeps Agent semantics and one durable migration record per legacy source; Swift owns every concrete target, credential, capability, parameter, and runtime decision. The final tree deletes V1 execution and Rust LLM ownership but retains two narrow read-only translation boundaries: one copies the complete provider-neutral Agent Profile graph into a hidden V2 successor, and the existing Agent Package reader converts known schema-v1 wire directly to a V2 manifest. Neither can execute V1 or reconstruct a provider.

**Tech Stack:** Rust 2021, `serde`, `rusqlite`, existing Agent OS SQLite aggregate and C ABI bridge, Swift 6, SwiftPM, SwiftUI, Observation, Foundation actors and `AsyncSequence`, Apple SQLite3, Security/Keychain, existing C++ v2 local inference XCFramework, Swift Testing, Cargo tests, Xcode iPhone/iPad Simulator tests, and shell contract runners.

**Design authority:** `docs/superpowers/specs/2026-07-10-swift-llm-system-design.md`, especially Architectural Boundary, Swift Ownership, Provider Profile, Egress and Approval, Capability Matrix, Parameter System, Agent Profile/Package Portability, Migration from the Current Codebase, Phase 5: Product Adoption and Legacy Removal, and the Phase 5 acceptance criteria. Phase 1-4 implementation evidence in that document remains authoritative and must not be redefined here.

## Global Constraints

- Work only in `/Users/alexandercou/Projects/Alex-agent/.worktrees/llm-runtime-provider-design/local-ios-agent` on `codex/llm-runtime-provider-design`.
- Execute sequentially with one Agent. Do not dispatch subagents and do not implement tasks concurrently.
- Use strict RED/GREEN/REFACTOR for every behavior change. No production edit is allowed before the focused test fails for the intended reason.
- Reuse the existing `LocalAgentLLMContracts`, `LocalAgentLLMCore`, `LocalAgentLLMLocal`, `LocalAgentLLMCloud`, `LocalAgentLLMHost`, `LLMStore`, `AgentHostBindingSaga`, and Phase 4 Rust host worker. Do not add another control-plane target, database, networking layer, provider registry, model router, or dependency.
- Target iOS/iPadOS 17+ and macOS 14+ test hosts. The same product model is used on iPhone and iPad; only the existing adaptive presentation differs.
- Rust remains the provider-neutral Agent kernel. It owns Agent policy, context/memory/tool assembly, portable `LLMSlotV2` requirements, the durable global run lease, the resumable worker, tool orchestration, and normalized Agent events.
- Swift remains the sole owner of local/cloud target selection, Provider Profiles, Base URLs, API keys, credential generations, model IDs, capabilities, parameter schemas and mappings, egress decisions, local installations, C++ sessions, cloud sessions, and provider-private continuation.
- C++ remains local-inference-only. Phase 5 changes no model format, download behavior, cloud behavior, Agent Profile, tool execution, or credential behavior in C++.
- The App creates one `HostProcessEpoch` per launch and supplies it to Rust, the host bridge, local/cloud prepared sessions, commands, and events. Durable `AgentHostConfiguration`, `HostBindingTuple`, targets, and restored selection records contain no epoch and remain valid across launches; a new prepared session uses the current epoch.
- One Agent Profile revision selects exactly one immutable `LLMTargetRevision`. Model Center manages available targets; it does not set a global active provider or mutate the target of an in-flight run.
- Target defaults and Agent-specific overrides use canonical Swift semantic parameter IDs. The UI renders only the selected target's supported parameter schema; unsupported or incompatible values fail before binding publication.
- API key text is transient UI memory, is converted once to `SecretBytes`, and is immediately handed to the existing credential creation saga. It is never written to app state, logs, UserDefaults, Rust, snapshots, diagnostics, previews, or tests.
- The cloud approval UI displays only exact origin and the existing safe summaries. It never renders or persists raw prompt, attachment, tool-result, API key, provider request, or provider response bodies.
- The official local catalog remains the only local model source in V1. Phase 5 adds no arbitrary file import, Hugging Face browser, or additional model format.
- The seven shipped cloud presets remain OpenAI, Anthropic, Gemini, xAI/Grok, DeepSeek, MiniMax, and GLM. Phase 5 adds no eighth adapter and no generic unsealed HTTP client.
- The Phase 4 global single-run rule remains. Phase 5 adds no multi-Agent or multi-generation concurrency.
- Local model files remain on disk across target switches. Only the target used by the current session enters RAM; deletion remains an explicit user action and loaded/in-use deletion remains rejected.
- Cloud remains stateless/no-storage by default. Provider-side state remains an explicit immutable Profile-revision choice with the existing retention approval.
- Every cloud start/resume uses the exact Rust-frozen semantic turn and existing disclosure/egress checks. App-authored copies of model input, tool schema, source revisions, or disclosure are forbidden.
- Migration never changes a V1 row in place. It creates a distinct V2 successor revision, stages and verifies its exact Swift binding, activates that binding, and only then marks the separate migration record `migrated`.
- Each recognized legacy source has one durable `LegacyProfileMigrationRecord` keyed by Rust-computed `legacy-profile-source:v1`. Its state is `pending`, `migrated`, or `archived`; a pending record may hold one resumable attempt. Do not persist a second migration state object.
- Before Task 9 removes V1 execution, any failed migration leaves the V1 record and route unchanged. A hidden or abandoned V2 successor is never selected implicitly.
- No plaintext legacy secret is imported. The translator allowlists the complete portable Agent Profile graph—profile identity/revision, component bindings, tool bindings, memory binding, voice binding, and LLM requirements—while discarding concrete provider/model/credential/path data. A redacted model hint may be shown, but never selects a target.
- Do not delete the legacy route, reader, writer, resolver, Rust provider/model/inference modules, or temporary architecture allowlist until the translator, migration record, direct-upgrade, failure-injection, and parity tests pass in the same working tree.
- The final binary must pass a direct old-version-to-final-Phase-5 upgrade fixture; no intermediate app release or prior migration run is assumed.
- In the final tree, production contains no automatic fallback and no `legacy_v1` execution. The only retained legacy boundaries are the isolated Agent Profile translator, the private Agent Package schema-v1 reader, and the existing host-binding migration flow with its single durable record.
- Retain the provider-neutral Rust `ExecutionModelClient` contract and test fakes only. Production model work is dispatched solely through the durable Phase 4 host command/event bridge.
- Preserve existing Phase 4 crash safety, sequencing, cancellation, cleanup, tool-loop, and recovery contracts. Phase 5 changes product adoption and legacy ownership, not bridge semantics.
- Each task ends with focused tests, its stated regression gate, `git diff --check`, and one reviewable commit.

## Scope and Non-Goals

Phase 5 contains only:

1. the missing product-safe seam from Rust's frozen preparation turn into Swift cloud reservation;
2. Swift product inventory and exact target/binding persistence;
3. iPhone/iPad Model Center and Provider Profile approval UI;
4. exact target and parameter selection in Agent Builder;
5. crash-safe explicit V1-to-V2 migration with one durable per-source record;
6. product bootstrap/hydration onto the host route;
7. parity proof, direct old-store upgrade, and deletion of the V1 Rust LLM path.

It does not add cloud attachment byte upload, arbitrary local imports, new provider adapters, persisted provider-private continuation, background generation, new C++ engines, multi-Agent concurrency, parallel tool execution, a new database, or a new architecture layer.

## Phase 5 Requirement Mapping

| 2026-07-10 design requirement | Implemented and verified by |
|---|---|
| Replace current `ModelRoutingClient` behavior with the Swift LLM system | Tasks 3-4 |
| Remove provider construction from `AppBootstrapper` and `RustRuntimeConfiguration` | Tasks 8-9 |
| Move Agent-to-model composition to Swift `AgentHostConfiguration` | Tasks 2 and 5 |
| Migrate each retained `legacy_v1` profile only after the Swift binding is staged and verified; pre-cutover failures leave the V1 record and route intact | Tasks 6-7 |
| Remove production Rust `ModelBinding`, Provider Registry, local LLM provider, and `InferenceRouter` after parity | Task 9 |
| Retain only the provider-neutral Agent model-client trait and test fakes in Rust | Task 9 |
| Delete the old product route after migration instead of maintaining indefinite dual execution | Tasks 8-9 |
| Migrate Swift and Rust authoritative stores to explicit V3 schemas before new Phase 5 records | Tasks 3 and 5 |
| Bind legacy identity with registered `legacy-profile-source:v1` and keep durable bindings epoch-independent | Tasks 6-7 |
| Preserve direct upgrades from old releases with a read-only, provider-neutral, complete Agent Profile translator; migrate no legacy plaintext secret and do not turn development environment providers into user profiles | Tasks 6, 9-10 |
| Translate schema-v1 Agent Packages directly into the V2 public manifest without retaining `PackageModelBinding` | Task 9 |
| Deliver Model Center UI, migration, and legacy cleanup on both iPhone and iPad | Tasks 4, 6-7, and 10 |

## Single Phase Cutover

```text
Tasks 1-7
  build and verify the complete V2 product and migration path
  keep V1 execution only while the replacement is incomplete
  persist one pending | migrated | archived record per legacy-profile-source:v1
          |
          v
Tasks 8-9
  switch the App to host_slot_v2 only
  delete V1 execution/provider/model/inference code
  retain only the read-only profile and package translators
          |
          v
Task 10
  prove direct old-store -> final Phase 5 migration
  run the final iPhone/iPad and architecture gate
```

These are implementation dependencies, not separate product releases. Task 9 may delete V1 execution only after the same tree passes the migration and direct-upgrade gates. The retained Agent Profile translator makes the final binary safe for users upgrading directly from an old store without introducing a compatibility router; the package reader independently translates known schema-v1 package wire directly to V2.

## File Structure

Phase 5 adds only product-facing coordinators and migration records around existing modules:

```text
rust-core/src/user_customization/
  agent_profile.rs                 durable V2 profile revisions
rust-core/src/storage/
  sqlite_runtime_state.rs          atomic runtime V2 -> V3 migration + authority
rust-core/src/llm_contracts/
  profile_migration.rs             V1 -> hidden V2 successor saga
rust-core/src/migration/
  mod.rs
  legacy_agent_profile_translator.rs
                                    isolated read-only portable profile translator
rust-core/src/agent_package/
  reader.rs                         private schema-v1 wire -> V2 translator
rust-core/tests/contract/
  agent_profile_sqlite.rs
  llm_profile_migration.rs
rust-core/tests/integration/
  phase_five_product_path.rs
rust-core/tests/lint/
  llm_phase_five_architecture.rs

toolkit/Sources/LocalAgentLLMCore/
  LLMStoreSchema.swift             atomic Swift store V2 -> V3 migration
  LLMStore.swift                   targets + active binding projections
toolkit/Sources/LocalAgentLLMHost/
  FrozenPreparationTurn.swift      conversion from Rust preview to Swift turn
toolkit/Sources/LocalAgentLLMLocal/
  LocalLLMSubsystem.swift          product inventory/delete facade
toolkit/Sources/LocalAgentLLMCloud/
  CloudLLMSubsystem.swift          profile/model/validation product facade

apps/LocalAgentApp/LocalAgentApp/Composition/
  AppBootstrapper.swift
  AppContainer.swift
  AppModelCenterClient.swift
  HostBoundAgentBuilderClient.swift
apps/LocalAgentApp/LocalAgentApp/Runtime/
  AppCloudApprovalBroker.swift
  AppLLMHostRouting.swift
  LegacyLLMMigrationCoordinator.swift
apps/LocalAgentApp/LocalAgentApp/Presentation/Models/
  ModelCenterView.swift
  ModelCenterViewModel.swift
  ProviderProfileEditorView.swift
  CloudApprovalSheet.swift
apps/LocalAgentApp/LocalAgentApp/Presentation/AgentBuilder/
  AgentBuilderView.swift
  AgentBuilderViewModel.swift
  AgentLLMConfigurationView.swift

scripts/
  run-llm-phase-5-contracts.sh
```

`FrozenPreparationTurn.swift` is a converter inside the existing host target, not a new runtime. `AppModelCenterClient` is the replacement test seam for the existing `ModelRoutingClient`; both never coexist after Task 4. `LegacyLLMMigrationCoordinator` exists only to drive the existing Rust/Swift saga and is not a second binding store. The retained Profile translator lives in Rust because Rust owns the Agent Profile schema; it uses an isolated migration document rather than the deleted production `ModelBinding` types. The existing package reader is the only other legacy-wire boundary.

---

### Task 1: Make Cloud Reservation Consume the Rust-Frozen Initial Turn

**Files:**
- Modify: `rust-core/src/run_snapshot/preparation_preview.rs`
- Modify: `rust-core/src/run_snapshot/snapshot_service.rs`
- Modify: `rust-core/src/ffi_bridge.rs`
- Modify: `rust-core/tests/contract/run_preparation.rs`
- Modify: `rust-core/tests/integration/host_llm_ffi.rs`
- Modify: `toolkit/Sources/LocalAgentBridge/AgentOSDTOs.swift`
- Create: `toolkit/Sources/LocalAgentLLMHost/FrozenPreparationTurn.swift`
- Modify: `toolkit/Sources/LocalAgentLLMHost/CloudHostSessionDriver.swift`
- Modify: `toolkit/Sources/LocalAgentLLMHost/LLMHostProductRuntime.swift`
- Modify: `toolkit/Sources/LocalAgentLLMHost/LLMRunPreparationBridge.swift`
- Modify: `toolkit/Tests/LocalAgentBridgeTests/RustRuntimeClientContractTests.swift`
- Modify: `toolkit/Tests/LocalAgentLLMHostTests/LLMHostPreparationTests.swift`
- Modify: `toolkit/Tests/LocalAgentLLMHostTests/LLMHostProductPathTests.swift`
- Modify: `apps/LocalAgentApp/LocalAgentApp/Runtime/AppLLMHostRouting.swift`
- Modify: `apps/LocalAgentApp/LocalAgentAppTests/Integration/LLMHostCompositionTests.swift`

**Interfaces:**
- Extend `RunPreparationPreview`/`RunPreparationPreviewDTO` with one `FrozenInitialTurn` containing only the already canonical `HostCommandPayload` and `GenerationDisclosureDocument`.
- The preview turn is produced from the same `FrozenGenerationTurn` already retained by `RunSnapshotService`; FFI does not accept a Swift-authored payload or digest.
- Swift recomputes and checks `host-command-payload:v1`, `agent-input:v1`, `source-revisions:v1`, and `generation-disclosure:v1` before constructing `CloudGenerationTurnRequest`.
- Phase 5 has no signed Tool Manifest verification chain. Rust freezes `safeDisplaySummary.triggeringToolDisplayKeys` as empty, and `CloudHostSessionDriver` always supplies `signedToolDisplayKeys: []`. Swift rejects a frozen initial disclosure with non-empty tool display keys.
- Approval UI uses one localized generic tool label when tool-result disclosure requires an explanation. Function-schema text, native-tool title/description/metadata, and tool output are never trusted display-key sources.
- `CloudHostSessionReserver` derives canonical input, tool schema, source revisions, attachment identities, semantic history, and initial disclosure from the frozen preview. Only the resolved Swift `GenerationConfiguration` is added by Swift.
- Remove the `context: (preparationID, proposedRunID) -> CloudSessionPreparationContext` closure from `LLMHostProductRuntime.startCloud`, `AppLLMHostSelection`, and `AppHostRunStarter`.
- Local reservation continues to use the same preview for requirements/capability binding and still receives the actual turn through the committed start command. It does not duplicate local generation input during reservation.
- A future signed Tool Manifest design may enable specific display keys. Phase 5 adds no manifest signature, digest, display-key field, or verification abstraction.

- [ ] **Step 1: Write failing Rust and Swift tests**

Add a Rust contract assertion:

```rust
#[test]
fn preview_returns_the_exact_rust_frozen_turn() {
    let harness = PreparationHarness::host_slot_v2();
    let preview = harness.preview("private user text").unwrap();

    assert_eq!(
        preview.frozen_initial_turn.payload.agent_input_digest().unwrap(),
        preview.binding.model_input_digest()
    );
    assert_eq!(
        preview.frozen_initial_turn.payload.tool_schema_digest,
        preview.binding.tool_schema_digest()
    );
    assert_eq!(
        preview.frozen_initial_turn.payload.source_revisions_digest,
        preview.binding.source_revisions_digest()
    );
    assert_eq!(
        preview.frozen_initial_turn.disclosure.expected_digest().unwrap(),
        preview.binding.initial_disclosure_digest()
    );
    assert!(preview
        .frozen_initial_turn
        .disclosure
        .safe_display_summary
        .triggering_tool_display_keys
        .is_empty());
    assert!(!preview.frozen_initial_turn.payload.messages.is_empty());
}
```

Add Swift product-path tests:

```swift
@Test
func cloudReservationUsesPreviewTurnWithoutAnAppContextClosure() async throws {
    let harness = try HostProductHarness.cloud()
    let run = try await harness.product.startCloud(
        harness.startRequest,
        subsystem: harness.cloud,
        configuration: harness.configuration,
        target: harness.target
    )

    #expect(run.runId == harness.proposedRunID)
    #expect(await harness.transport.lastSemanticInput == "private user text")
}

@Test
func alteredPreviewPayloadFailsBeforeEgressOrProviderOpen() async throws {
    let harness = try HostProductHarness.cloud(
        previewMutation: { $0.replacingFirstMessage(with: "different") }
    )

    await #expect(throws: LLMHostFailure.self) {
        try await harness.start()
    }
    #expect(await harness.approvalPrompt.requestCount == 0)
    #expect(await harness.transport.requestCount == 0)
}

@Test
func functionSchemaCannotInjectATrustedToolDisplayKey() throws {
    let preview = Fixtures.preview(
        toolSchemaDisplayText: "attacker-controlled"
    )

    let request = try FrozenPreparationTurn.cloudRequest(
        preview: preview,
        resolvedParameters: .fixture
    )
    #expect(request.signedToolDisplayKeys.isEmpty)
    #expect(request.disclosure.safeDisplaySummary.triggeringToolDisplayKeys.isEmpty)
}

@Test
func nonEmptyFrozenToolDisplayKeysFailBeforeApprovalOrTransport() async throws {
    let harness = try HostProductHarness.cloud(
        previewMutation: { $0.withTriggeringToolDisplayKey("contacts.search") }
    )

    await #expect(throws: LLMHostFailure.self) {
        try await harness.start()
    }
    #expect(await harness.approvalPrompt.requestCount == 0)
    #expect(await harness.transport.requestCount == 0)
}
```

- [ ] **Step 2: Run RED**

```bash
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml \
  --test contract run_preparation -- --nocapture
swift test --package-path toolkit --filter LLMHostPreparationTests
swift test --package-path toolkit --filter LLMHostProductPathTests
```

Expected: Rust fails because the preview has no frozen turn; Swift fails because cloud start still requires an App context closure.

- [ ] **Step 3: Expose the existing frozen document and add one converter**

Use the existing contract types:

```rust
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct FrozenInitialTurn {
    pub payload: HostCommandPayload,
    pub disclosure: GenerationDisclosureDocument,
}
```

```swift
public struct FrozenInitialTurnDTO: Codable, Equatable, Sendable {
    public let payload: HostCommandPayload
    public let disclosure: GenerationDisclosure
}

package enum FrozenPreparationTurn {
    package static func cloudRequest(
        preview: RunPreparationPreviewDTO,
        resolvedParameters: GenerationConfiguration
    ) throws -> CloudGenerationTurnRequest
}
```

The converter parses `toolSchemaJSON` into the existing `CanonicalJSONValue`, converts semantic messages without loss, and refuses unknown content kinds, non-empty tool display-key sets, or attachments whose identities do not match the frozen source revision document. It sets `signedToolDisplayKeys` to the empty set and does not accept replacement input from the App.

- [ ] **Step 4: Run GREEN and Phase 4 regressions**

```bash
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml \
  --test contract run_preparation -- --nocapture
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml \
  --test integration host_llm_ffi -- --nocapture
swift test --package-path toolkit --filter LLMHostPreparationTests
swift test --package-path toolkit --filter LLMHostProductPathTests
swift test --package-path toolkit --filter CloudLLMRuntimeTests
git diff --check
```

Expected: all pass; the fake cloud transport receives exactly the Rust-frozen text and no App context closure remains.

- [ ] **Step 5: Commit**

```bash
git add rust-core/src/run_snapshot/preparation_preview.rs \
  rust-core/src/run_snapshot/snapshot_service.rs rust-core/src/ffi_bridge.rs \
  rust-core/tests/contract/run_preparation.rs rust-core/tests/integration/host_llm_ffi.rs \
  toolkit/Sources/LocalAgentBridge/AgentOSDTOs.swift \
  toolkit/Sources/LocalAgentLLMHost \
  toolkit/Tests/LocalAgentBridgeTests/RustRuntimeClientContractTests.swift \
  toolkit/Tests/LocalAgentLLMHostTests \
  apps/LocalAgentApp/LocalAgentApp/Runtime/AppLLMHostRouting.swift \
  apps/LocalAgentApp/LocalAgentAppTests/Integration/LLMHostCompositionTests.swift
git commit -m "fix: bind cloud reservation to rust preview"
```

---

### Task 2: Make the Existing Swift LLM Store the Exact Target and Binding Authority

**Files:**
- Modify: `toolkit/Sources/LocalAgentLLMCore/LLMStoreSchema.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCore/LLMStore.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCore/AgentHostBindingSaga.swift`
- Modify: `toolkit/Tests/LocalAgentLLMCoreTests/LLMStoreTests.swift`
- Modify: `toolkit/Tests/LocalAgentLLMCoreTests/AgentHostBindingSagaTests.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCloud/ProviderProfileStore.swift`
- Modify: `toolkit/Tests/LocalAgentLLMCloudTests/ProviderProfileStoreTests.swift`
- Modify: `toolkit/Sources/LocalAgentLLMLocal/LocalLLMSubsystem.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCloud/CloudLLMSubsystem.swift`
- Modify: `toolkit/Tests/LocalAgentLLMLocalTests/LocalLLMSubsystemTests.swift`
- Modify: `toolkit/Tests/LocalAgentLLMCloudTests/CloudProductPathIntegrationTests.swift`

**Interfaces:**
- Add immutable target revision CRUD to the existing `LLMStore`; do not add a second target repository.
- Add a public, secret-free `ActiveAgentHostBinding` projection carrying exact `AgentHostConfiguration`, `HostBindingTuple`, and selected `LLMTargetReference`.
- Add `publishTarget`, `target(reference:)`, `targets()`, and `activeHostBindings()` to `LLMStore`.
- Move `llm_target_revisions` ownership out of `ProviderProfileStore`; it continues to own Provider Profile revisions/state only.
- Both local and cloud subsystems receive the same `LLMStore` instance from App composition. Standalone test/tool bootstrap overloads open the same database path; product bootstrap creates and injects the actor once.
- `LLMStore` opens/migrates the existing schema transactionally before local or cloud code uses target tables. No new database file or schema fork is introduced.
- Active binding hydration rejects a missing target revision, mismatched target reference, mismatched binding hash, or unknown record schema rather than repairing by guess.

- [ ] **Step 1: Write failing store and reopen tests**

```swift
@Test
func targetRevisionIsImmutableAndReopensWithActiveBinding() async throws {
    let url = temporarySQLiteURL()
    let first = try LLMStore(fileURL: url)
    let target = Fixtures.localTarget(revision: 4)
    try await first.publishTarget(target)
    try await Fixtures.activateBinding(store: first, target: target)

    let reopened = try LLMStore(fileURL: url)
    #expect(await reopened.target(reference: target.reference) == target)
    #expect(await reopened.activeHostBindings().map(\.configuration.selectedTarget) == [
        target.reference
    ])
}

@Test
func providerProfileStoreCannotBecomeASecondTargetAuthority() async throws {
    let profileStore = try Fixtures.profileStore()
    #expect(profileStore is ProviderProfileStore)
    // Compile-time contract: target publication exists only on LLMStore.
}
```

Add conflict, rollback, future-schema, missing-target, and duplicate-revision-different-payload cases.

- [ ] **Step 2: Run RED**

```bash
swift test --package-path toolkit --filter LLMStoreTests
swift test --package-path toolkit --filter ProviderProfileStoreTests
swift test --package-path toolkit --filter LocalLLMSubsystemTests
swift test --package-path toolkit --filter CloudProductPathIntegrationTests
```

Expected: fail because `LLMStore` does not expose targets/active bindings and each subsystem currently opens its own binding store.

- [ ] **Step 3: Add the minimal public projections and shared injection**

```swift
public struct ActiveAgentHostBinding: Equatable, Sendable {
    public let configuration: AgentHostConfiguration
    public let binding: HostBindingTuple

    public var targetReference: LLMTargetReference {
        configuration.selectedTarget
    }
}

public actor LLMStore {
    public func publishTarget(_ target: LLMTargetRevision) throws
    public func target(reference: LLMTargetReference) -> LLMTargetRevision?
    public func targets() -> [LLMTargetRevision]
    public func activeHostBindings() throws -> [ActiveAgentHostBinding]
}
```

`publishTarget` uses `INSERT` followed by exact replay comparison. `activeHostBindings` joins only validated in-memory records loaded from SQLite and rechecks `agentHostConfigurationDigest`; it returns no credentials, origins, provider-private fields, installation paths, or secrets.

Add package bootstrap overloads accepting `llmStore: LLMStore`, and have `AppBootstrapper` use those overloads in Task 7. Do not introduce a store service locator.

- [ ] **Step 4: Run GREEN and storage migrations**

```bash
swift test --package-path toolkit --filter LLMStoreTests
swift test --package-path toolkit --filter AgentHostBindingSagaTests
swift test --package-path toolkit --filter LLMStoreSchemaV2Tests
swift test --package-path toolkit --filter ProviderProfileStoreTests
swift test --package-path toolkit --filter LocalLLMSubsystemTests
swift test --package-path toolkit --filter CloudProductPathIntegrationTests
git diff --check
```

Expected: all pass; one SQLite file reopens with exact targets and active bindings, and `ProviderProfileStore` no longer caches or writes targets.

- [ ] **Step 5: Commit**

```bash
git add toolkit/Sources/LocalAgentLLMCore \
  toolkit/Tests/LocalAgentLLMCoreTests \
  toolkit/Sources/LocalAgentLLMCloud/ProviderProfileStore.swift \
  toolkit/Sources/LocalAgentLLMCloud/CloudLLMSubsystem.swift \
  toolkit/Sources/LocalAgentLLMLocal/LocalLLMSubsystem.swift \
  toolkit/Tests/LocalAgentLLMCloudTests \
  toolkit/Tests/LocalAgentLLMLocalTests
git commit -m "feat: persist exact swift llm targets"
```

---

### Task 3: Expose Product-Safe Local, Cloud, Credential, and Approval Operations

**Files:**
- Modify: `toolkit/Sources/LocalAgentLLMLocal/LocalModelStore.swift`
- Modify: `toolkit/Sources/LocalAgentLLMLocal/ModelDownloadCoordinator.swift`
- Modify: `toolkit/Sources/LocalAgentLLMLocal/LocalModelDeletionService.swift`
- Modify: `toolkit/Sources/LocalAgentLLMLocal/LocalDiskPolicy.swift`
- Modify: `toolkit/Sources/LocalAgentLLMLocal/LocalLLMSubsystem.swift`
- Create: `toolkit/Sources/LocalAgentLLMLocal/LocalModelProductState.swift`
- Modify: `toolkit/Tests/LocalAgentLLMLocalTests/LocalModelStoreTests.swift`
- Modify: `toolkit/Tests/LocalAgentLLMLocalTests/LocalLLMSubsystemTests.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCore/LLMStoreSchema.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCore/LLMStore.swift`
- Modify: `toolkit/Tests/LocalAgentLLMCoreTests/LLMStoreTests.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCloud/ProviderProfile.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCloud/ProviderProfileStore.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCloud/ProviderCredentialStore.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCloud/CredentialOperationReconciler.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCloud/PreparedCloudSession.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCloud/ProviderValidationService.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCloud/CloudCapabilityCatalog.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCloud/CloudModelDiscoveryService.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCloud/CloudLLMSubsystem.swift`
- Create: `toolkit/Sources/LocalAgentLLMCloud/CloudModelProductState.swift`
- Modify: `toolkit/Tests/LocalAgentLLMCloudTests/ProviderProfileStoreTests.swift`
- Modify: `toolkit/Tests/LocalAgentLLMCloudTests/ProviderCredentialStoreTests.swift`
- Move: `toolkit/Tests/LocalAgentLLMCloudTests/LLMStoreSchemaV2Tests.swift` to `toolkit/Tests/LocalAgentLLMCloudTests/LLMStoreSchemaV3Tests.swift`
- Modify: `toolkit/Tests/LocalAgentLLMCloudTests/CloudModelDiscoveryTests.swift`
- Modify: `toolkit/Tests/LocalAgentLLMCloudTests/CloudProductPathIntegrationTests.swift`
- Create: `apps/LocalAgentApp/LocalAgentApp/Runtime/AppCloudApprovalBroker.swift`
- Create: `apps/LocalAgentApp/LocalAgentApp/Presentation/Models/CloudApprovalSheet.swift`
- Modify: `apps/LocalAgentApp/LocalAgentApp/App/AppShellView.swift`
- Create: `apps/LocalAgentApp/LocalAgentAppTests/Runtime/AppCloudApprovalBrokerTests.swift`
- Modify: `apps/LocalAgentApp/LocalAgentApp.xcodeproj/project.pbxproj`

**Interfaces:**
- Add a secret-free `LocalModelProductState` projection with official model revision, installation ID/state, received/expected bytes, installed bytes, required bytes, and safe repair action. Add `LocalDiskProductState` with important-usage available bytes, current reservations, and installed-model bytes. Neither contains an absolute path.
- Add subsystem methods for `inventory`, `enqueue`, `pause`, `resume`, `cancel`, and guarded `delete`; each delegates to the existing coordinator/store/deletion/disk policy.
- Add a coalescing state-change signal from `ModelDownloadCoordinator`; consumers reread the SQLite-backed inventory after a signal, so the signal never carries authoritative progress or model paths.
- Add secret-free `CloudProviderProductState` and `CloudModelProductState` projections with preset/profile revision, redacted origin, retention mode, validation freshness, model ID, capability snapshot, and parameter schema.
- Add list methods to the existing Provider Profile/catalog stores. Do not expose raw catalog envelopes, provider response bodies, credential generations, or keys to the App.
- Product credential operations call the existing `ProviderCredentialStore.createSlot`, `rotateCredential`, and `beginCredentialDeletion` sagas. They accept `SecretBytes`, not `String`.
- Advance the shared Swift `LLMStore` to `user_version = 3` before writing `creating`. `LLMStoreSchema.migrateToCurrent` performs existing V1→V2 and new V2→V3 steps sequentially; every store opener calls that one helper instead of calling `migrateToVersionTwo` directly.
- The V2→V3 transaction rebuilds only `provider_profile_revisions`, changes that table's authoritative envelope/row constraint to record schema 3, converts every V2 active/archived envelope to the tagged V3 lifecycle with no creation operation, restores its indexes, and sets `user_version`/meta version to 3 last. Unchanged tables keep their existing record schema.
- Injected failure after every V3 migration statement rolls back to an intact, reopenable V2 database. Populated V2 active/archived Profile rows, targets, host bindings, credential rows, and validation rows survive exact reopen; `user_version = 4` is rejected as future.
- Initial Profile creation persists a validated `provider_profile_revisions` row with lifecycle `creating` and a stable creation operation ID before calling `createSlot`. The operation ID is internal lifecycle metadata in the row's versioned `record_json`, not a field on the public active Profile value. `prepareCreatingRevision` accepts a proposed random ID and returns the already persisted ID on exact retry. The same ID binds the pending Profile revision to credential creation; no new table is added.
- After `createSlot` completes, `ProviderProfileStore.activateCreatingRevision` verifies the exact operation ID and active credential slot, then activates the immutable revision and creates its profile-state row in one SQLite transaction.
- Startup first reconciles incomplete credential operations, then reconciles `creating` Profile revisions. An active matching slot completes Profile activation; an absent/rolled-back slot archives the creating revision. A completed credential operation is therefore still discoverable through the pending Profile revision.
- Add one `AppCloudApprovalBroker` actor implementing the existing `CloudLLMApprovalPrompting` protocol. It serializes prompts and awaits one decision from the existing adaptive App shell.
- `CloudApprovalSheet` displays exact scheme/host/port or `EgressApprovalDisplaySummary`; denial completes the awaiting continuation with `.deny`. App backgrounding or sheet dismissal also denies.

- [ ] **Step 1: Write failing inventory, secret-lifetime, and prompt tests**

```swift
@Test
func localInventoryNeverExposesAnAbsolutePath() async throws {
    let subsystem = try await LocalSubsystemHarness.installed()
    let state = try await subsystem.inventory()

    #expect(state.count == 1)
    #expect(state[0].installationID == "installation-1")
    #expect(!String(describing: state[0]).contains("/private/"))
}

@Test
func appApprovalBrokerSerializesPromptsAndDeniesDismissal() async {
    let broker = AppCloudApprovalBroker()
    async let first = broker.requestOriginApproval(.fixture, profileName: "OpenAI")
    async let second = broker.requestScopeApproval(origin: .fixture, summary: .fixture)

    #expect(await broker.pendingCount == 1)
    await broker.dismissCurrent()
    #expect(await first == .deny)
    #expect(await broker.pendingCount == 1)
    await broker.respond(.allow)
    #expect(await second == .allow)
}

@Test
func creatingAProfileConsumesSecretBytesWithoutPersistingPlaintext() async throws {
    let harness = try CloudProductHarness.make()
    let secret = SecretBytes(utf8: "not-a-real-key")
    try await harness.createProfile(secret: secret)

    #expect(!harness.sqliteBytes.contains(Data("not-a-real-key".utf8)))
    #expect(!harness.logs.contains("not-a-real-key"))
}

@Test
func completedCredentialIsRecoveredFromTheCreatingProfileRevision() async throws {
    let harness = try CloudProductHarness.make(
        crashAfter: .credentialCreationCompleted
    )
    await #expect(throws: SimulatedCrash.self) {
        try await harness.createProfile(secret: SecretBytes(utf8: "not-a-real-key"))
    }

    let reopened = try await harness.reopenAndReconcile()
    #expect(try await reopened.profile.lifecycle == .active)
    #expect(try await reopened.credentialSlot.lifecycle == .active)
    #expect(try reopened.persistedCreationOperationID() == harness.operationID)
}

@Test
func populatedVersionTwoMigratesToTaggedVersionThreeAndReopens() async throws {
    let fixture = try LLMStoreV2Fixture.withActiveAndArchivedProfiles()
    let before = fixture.expectedPublicState

    let store = try ProviderProfileStore(
        fileURL: fixture.url,
        originValidator: FixtureOriginValidator()
    )

    #expect(await store.schemaVersionForTesting() == 3)
    #expect(await store.publicStateForTesting() == before)
    #expect(try fixture.profileRecordSchemas() == [3, 3])
    #expect(try fixture.creationOperationIDs() == [nil, nil])
}

@Test
func everyVersionThreeMigrationBoundaryRollsBackToIntactVersionTwo() throws {
    for boundary in 0..<LLMStoreSchema.versionThreeMigrationStatementCount {
        let fixture = try LLMStoreV2Fixture.withActiveAndArchivedProfiles()
        let before = try fixture.rawDatabaseProjection()

        #expect(throws: LLMStoreSchemaError.self) {
            try LLMStoreSchema.migrateToCurrent(
                fixture.connection,
                failVersionThreeAfterStatement: boundary
            )
        }

        #expect(try LLMStoreSchema.userVersion(fixture.connection) == 2)
        #expect(try fixture.rawDatabaseProjection() == before)
    }
}

@Test
func versionFourIsRejectedAsFuture() throws {
    let fixture = try LLMStoreV2Fixture.withActiveAndArchivedProfiles()
    try fixture.connection.execute("PRAGMA user_version = 4")

    #expect(throws: LLMStoreSchemaError.self) {
        try LLMStoreSchema.migrateToCurrent(fixture.connection)
    }
}
```

Move the existing schema fixture helpers with the renamed suite and add
`LLMStoreV2Fixture` there. It creates a real user-version-2 database through
the existing V2 migration, inserts active/archived V2 envelopes and unchanged
dependent rows, and exposes only the raw projections used above.

Run the same creation harness at three bounded crash points: after the
`creating` revision is durable, after the credential operation is staged, and
after the credential slot is active but before Profile activation. Reopen must
converge to one active revision/slot or one archived creating revision, never an
undiscoverable completed credential.

- [ ] **Step 2: Run RED**

```bash
swift test --package-path toolkit --filter LLMStoreSchemaV3Tests
swift test --package-path toolkit --filter LocalLLMSubsystemTests
swift test --package-path toolkit --filter CloudProductPathIntegrationTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:LocalAgentAppTests/AppCloudApprovalBrokerTests
```

Expected: the schema suite fails because current version is 2 and no V2→V3
conversion exists; product tests fail because the facades, creation lifecycle,
and App approval broker do not exist.

- [ ] **Step 3: Add thin facades over existing actors**

```swift
public struct LocalModelProductState: Equatable, Sendable, Identifiable {
    public let id: String
    public let modelRevision: LocalModelRevisionID
    public let state: LocalInstallationState
    public let receivedBytes: UInt64
    public let expectedBytes: UInt64
    public let requiredBytes: UInt64
}

public struct LocalDiskProductState: Equatable, Sendable {
    public let availableImportantUsageBytes: UInt64
    public let reservedBytes: UInt64
    public let installedBytes: UInt64
}

public struct CloudProviderProductState: Equatable, Sendable, Identifiable {
    public let id: String
    public let revision: UInt64
    public let presetID: ProviderPresetID
    public let displayOrigin: String
    public let retentionMode: ProviderRetentionMode
    public let validation: ProviderValidationStatus
}
```

Use one schema entry point:

```swift
package enum LLMStoreSchema {
    package static let currentVersion = 3

    package static func migrateToCurrent(
        _ database: SQLiteConnection,
        failVersionThreeAfterStatement: Int? = nil
    ) throws {
        let version = try userVersion(database)
        guard version <= currentVersion else {
            throw LLMStoreSchemaError(
                code: "llm_store.future_schema",
                message: "LLM store schema is newer than this runtime"
            )
        }
        try ensureBaseSchema(database)
        if try userVersion(database) == 1 {
            try migrateToVersionTwo(database)
        }
        if try userVersion(database) == 2 {
            try migrateToVersionThree(
                database,
                failAfterStatement: failVersionThreeAfterStatement
            )
        }
    }
}

private enum PersistedProviderProfileLifecycleV3: Codable, Equatable {
    case creating(operationID: String)
    case active
    case archived
}

private struct PersistedProfileRevisionV3: Codable {
    let recordSchemaVersion: Int
    let revision: ProviderProfileRevision
    let origin: EgressOrigin
    let lifecycle: PersistedProviderProfileLifecycleV3
}
```

The migration decodes each V2 `PersistedProfileRevision` with the existing V2
decoder and encodes the V3 envelope; it does not rewrite JSON with SQL string
operations. All current store openers call `migrateToCurrent`.

Keep orchestration in the subsystem methods. Do not mirror store state in the App client. The creation path is exactly:

```swift
let operationID = try await profileStore.prepareCreatingRevision(
    revision,
    proposedOperationID: UUID().uuidString
)
try await credentialStore.createSlot(
    credentialRef: revision.credentialRef,
    initialSecret: secret,
    operationID: operationID
)
try await profileStore.activateCreatingRevision(
    profileID: revision.profileID,
    revision: revision.revision,
    operationID: operationID,
    credentialStore: credentialStore
)
```

Reconciliation uses the same methods idempotently. Do not add best-effort post-failure deletion as the primary cleanup mechanism.

- [ ] **Step 4: Run GREEN and security regressions**

```bash
swift test --package-path toolkit --filter LLMStoreSchemaV3Tests
swift test --package-path toolkit --filter LLMStoreTests
swift test --package-path toolkit --filter LocalLLMSubsystemTests
swift test --package-path toolkit --filter LocalModelDeletionServiceTests
swift test --package-path toolkit --filter CloudProductPathIntegrationTests
swift test --package-path toolkit --filter ProviderCredentialStoreTests
swift test --package-path toolkit --filter ProviderEgressPolicyTests
swift test --package-path toolkit --filter CloudModelDiscoveryTests
git diff --check
```

Expected: all pass; the App receives only safe product projections and approval continuations always terminate.

- [ ] **Step 5: Commit**

```bash
git add toolkit/Sources/LocalAgentLLMLocal \
  toolkit/Tests/LocalAgentLLMLocalTests \
  toolkit/Sources/LocalAgentLLMCore toolkit/Tests/LocalAgentLLMCoreTests \
  toolkit/Sources/LocalAgentLLMCloud \
  toolkit/Tests/LocalAgentLLMCloudTests \
  apps/LocalAgentApp/LocalAgentApp/Runtime/AppCloudApprovalBroker.swift \
  apps/LocalAgentApp/LocalAgentApp/Presentation/Models/CloudApprovalSheet.swift \
  apps/LocalAgentApp/LocalAgentApp/App/AppShellView.swift \
  apps/LocalAgentApp/LocalAgentAppTests/Runtime/AppCloudApprovalBrokerTests.swift \
  apps/LocalAgentApp/LocalAgentApp.xcodeproj/project.pbxproj
git commit -m "feat: expose swift llm product operations"
```

---

### Task 4: Replace the Legacy Model Center with Local and Cloud Swift Product UI

**Files:**
- Modify: `apps/LocalAgentApp/LocalAgentApp/Presentation/Models/ModelCenterViewModel.swift`
- Modify: `apps/LocalAgentApp/LocalAgentApp/Presentation/Models/ModelCenterView.swift`
- Create: `apps/LocalAgentApp/LocalAgentApp/Presentation/Models/ProviderProfileEditorView.swift`
- Create: `apps/LocalAgentApp/LocalAgentApp/Composition/AppModelCenterClient.swift`
- Modify: `apps/LocalAgentApp/LocalAgentApp/Composition/AppContainer.swift`
- Modify: `apps/LocalAgentApp/LocalAgentApp/App/AppRoute.swift`
- Modify: `apps/LocalAgentApp/LocalAgentApp/App/AppShellViewModel.swift`
- Modify: `apps/LocalAgentApp/LocalAgentApp/Presentation/Settings/PrivacySettingsView.swift`
- Modify: `apps/LocalAgentApp/LocalAgentAppTests/Presentation/Models/ModelCenterViewModelTests.swift`
- Create: `apps/LocalAgentApp/LocalAgentAppTests/Presentation/Models/ProviderProfileEditorTests.swift`
- Modify: `apps/LocalAgentApp/LocalAgentApp.xcodeproj/project.pbxproj`

**Interfaces:**
- Replace `ModelRoutingClient` with `ModelCenterClient`; delete `RuntimeModelRoutingClient`.
- `ModelCenterClient` lists official local models/installations, cloud Provider Profiles/models, immutable target revisions, capability summaries, and parameter schemas. It exposes explicit local download actions and cloud create/edit/validate/archive/credential actions.
- Model Center creates reusable `LLMTargetRevision` records. It does not call Rust `setProvider`, create a chat session, or mark one global model active.
- Local rows show official catalog identity, download/install state, byte progress, pause/resume/cancel/delete actions, disk requirement, and loaded/in-use deletion errors.
- Cloud rows show one of seven presets, exact redacted origin, credential presence without value/generation, validation state, discovered or manual model IDs, retention mode, and revalidation action.
- The Provider Profile editor accepts preset, exact HTTPS Base URL, API key, retention mode, and model selection. Editing immutable configuration publishes a new Profile revision; it never mutates an old revision.
- Target default controls render from `LLMParameterSchema`. Switching model preserves only compatible semantic IDs and visibly reports removed overrides.
- Remove Model Center's global temperature/top-p sliders and “active provider” row. Privacy Settings summarizes the selected active Agent's host target, not a global Rust provider.

- [ ] **Step 1: Replace legacy tests with failing product tests**

```swift
@MainActor
@Test
func selectingAModelCreatesOneImmutableTargetRevision() async throws {
    let client = ModelCenterClientSpy()
    let viewModel = ModelCenterViewModel(client: client)
    await viewModel.createTarget(from: .localModel("official-1"))

    #expect(client.publishedTargets.count == 1)
    #expect(viewModel.selectedTarget == client.publishedTargets.only.reference)
}

@MainActor
@Test
func incompatibleParametersAreDroppedAndReportedOnModelChange() async throws {
    let client = ModelCenterClientSpy(
        schemas: [.modelA: .temperatureAndTopP, .modelB: .reasoningOnly]
    )
    let viewModel = ModelCenterViewModel(client: client)
    viewModel.targetDefaults = .temperature(0.7)

    await viewModel.selectModel(.modelB)

    #expect(viewModel.targetDefaults.parameters.isEmpty)
    #expect(viewModel.parameterNotice == "Temperature is not supported by this model.")
}

@MainActor
@Test
func profileEditorNeverRehydratesAPIKeyText() async throws {
    let client = ModelCenterClientSpy(existingCredential: true)
    let viewModel = ProviderProfileEditorViewModel(client: client)
    await viewModel.load(profileID: "profile", revision: 2)

    #expect(viewModel.apiKey.isEmpty)
    #expect(viewModel.hasStoredCredential)
}
```

- [ ] **Step 2: Run RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:LocalAgentAppTests/ModelCenterViewModelTests \
  -only-testing:LocalAgentAppTests/ProviderProfileEditorTests
```

Expected: fail because the current Model Center still projects Rust providers and owns global sliders/selection.

- [ ] **Step 3: Implement the smallest product client and adaptive screens**

```swift
protocol ModelCenterClient: Sendable {
    var updates: AsyncStream<Void> { get }
    func snapshot() async throws -> ModelCenterSnapshot
    func enqueueLocalModel(_ id: LocalModelRevisionID) async throws
    func pauseLocalModel(installationID: String) async throws
    func resumeLocalModel(installationID: String) async throws
    func cancelLocalModel(installationID: String) async throws
    func deleteLocalModel(installationID: String) async throws
    func publishProviderProfile(_ draft: ProviderProfileProductDraft) async throws
    func validateProviderModel(_ selection: CloudModelSelection) async throws
    func publishTarget(_ target: LLMTargetRevision) async throws
}
```

`AppModelCenterClient` delegates directly to the local/cloud subsystems and shared `LLMStore`; it contains no cached database copy. The view model coalesces `updates` and reloads the complete snapshot, so background download progress becomes visible without making the event signal authoritative. Use the existing iPhone `TabView` and iPad `NavigationSplitView`; within Model Center, use sections or a compact local/cloud picker rather than a new navigation framework.

- [ ] **Step 4: Run GREEN on iPhone and iPad**

```bash
for DEVICE in 'iPhone 16 Pro' 'iPad Pro 13-inch (M4)'; do
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
    -project apps/LocalAgentApp/LocalAgentApp.xcodeproj \
    -scheme LocalAgentApp \
    -destination "platform=iOS Simulator,name=$DEVICE" \
    -only-testing:LocalAgentAppTests/ModelCenterViewModelTests \
    -only-testing:LocalAgentAppTests/ProviderProfileEditorTests
done
rg -n 'setProvider|RuntimeModelRoutingClient|rustProviderSelections' \
  apps/LocalAgentApp/LocalAgentApp apps/LocalAgentApp/LocalAgentAppTests
git diff --check
```

Expected: both destinations pass; the source scan returns no matches, and no UI action writes an API key outside Keychain.

- [ ] **Step 5: Commit**

```bash
git add apps/LocalAgentApp/LocalAgentApp/Presentation/Models \
  apps/LocalAgentApp/LocalAgentApp/Composition/AppModelCenterClient.swift \
  apps/LocalAgentApp/LocalAgentApp/Composition/AppContainer.swift \
  apps/LocalAgentApp/LocalAgentApp/App \
  apps/LocalAgentApp/LocalAgentApp/Presentation/Settings/PrivacySettingsView.swift \
  apps/LocalAgentApp/LocalAgentAppTests/Presentation/Models \
  apps/LocalAgentApp/LocalAgentApp.xcodeproj/project.pbxproj
git commit -m "feat: adopt swift llm model center"
```

---

### Task 5: Publish Durable V2 Agent Profiles with Exact Swift Host Bindings

**Files:**
- Modify: `rust-core/src/user_customization/agent_profile.rs`
- Modify: `rust-core/src/user_customization/mod.rs`
- Modify: `rust-core/src/user_customization/builder_resolver.rs`
- Modify: `rust-core/src/app_service.rs`
- Modify: `rust-core/src/llm_contracts/host_binding_service.rs`
- Modify: `rust-core/src/run_snapshot/resolver.rs`
- Modify: `rust-core/src/run_snapshot/snapshot_service.rs`
- Modify: `rust-core/src/ffi_bridge.rs`
- Modify: `rust-core/src/storage/runtime_state.rs`
- Modify: `rust-core/src/storage/sqlite_runtime_state.rs`
- Create: `rust-core/tests/contract/agent_profile_sqlite.rs`
- Modify: `rust-core/tests/contract/runtime_state_migration.rs`
- Modify: `rust-core/tests/contract/agent_builder_agent_os.rs`
- Modify: `rust-core/tests/integration/app_service_builder_publish.rs`
- Modify: `rust-core/tests/integration/ffi_bridge.rs`
- Modify: `toolkit/Sources/LocalAgentBridge/AgentBuilderClient.swift`
- Modify: `toolkit/Sources/LocalAgentBridge/AgentOSDTOs.swift`
- Modify: `toolkit/Tests/LocalAgentBridgeTests/AgentBuilderClientTests.swift`
- Create: `apps/LocalAgentApp/LocalAgentApp/Composition/HostBoundAgentBuilderClient.swift`
- Create: `apps/LocalAgentApp/LocalAgentApp/Presentation/AgentBuilder/AgentLLMConfigurationView.swift`
- Modify: `apps/LocalAgentApp/LocalAgentApp/Presentation/AgentBuilder/AgentBuilderDraftModels.swift`
- Modify: `apps/LocalAgentApp/LocalAgentApp/Presentation/AgentBuilder/AgentBuilderView.swift`
- Modify: `apps/LocalAgentApp/LocalAgentApp/Presentation/AgentBuilder/AgentBuilderViewModel.swift`
- Modify: `apps/LocalAgentApp/LocalAgentAppTests/Presentation/AgentBuilder/AgentBuilderViewModelTests.swift`
- Create: `apps/LocalAgentApp/LocalAgentAppTests/Integration/HostBoundAgentPublishTests.swift`
- Modify: `apps/LocalAgentApp/LocalAgentApp.xcodeproj/project.pbxproj`

**Interfaces:**
- Extend the existing `UnifiedRuntimeStateRepository` with Agent Profile aggregate publication, exact lookup, latest lookup, and host-binding transition methods. `InMemoryRuntimeStateStore` and `SqliteRuntimeStateStore` implement the same methods; do not add an `AgentProfileRepository` wrapper enum or second repository trait.
- Replace production `InMemoryAgentProfileRepository` dependencies in App service, resolver, snapshot, and host-binding services with `Arc<dyn UnifiedRuntimeStateRepository>`. Tests use `InMemoryRuntimeStateStore`; SQLite reopen tests use `SqliteRuntimeStateStore::open`.
- Advance the unified Rust runtime store from schema 2 to schema 3 before any Profile write. A new database is created directly at the complete V3 schema; an existing V2 database runs one `BEGIN IMMEDIATE` migration that creates `agent_component_revisions`, `agent_profile_revisions`, and `legacy_profile_migration_records` plus their exact indexes, then updates `runtime_state_meta.schema_version` to 3 last.
- Move all schema creation out of unconditional `CREATE TABLE IF NOT EXISTS` startup behavior. Existing V1 sidecar import first converges to V2 through the current path, then the same open advances V2→V3. Future version 4 is rejected before mutation.
- `legacy_profile_migration_records` is created empty in Task 5 so Task 6 adds only repository behavior and rows, not DDL. No second migration table or sidecar is introduced.
- Failure injection after every V3 DDL/index statement rolls back to an exact reopenable V2 store. Existing lease, preparation, worker, session, outbox, event, snapshot, and conversation state must survive V2→V3 unchanged.
- Persist immutable Agent Profile revisions and the component revision records required to resolve them in the same Rust SQLite authority. Profile publication and component publication commit through one aggregate repository transaction; do not open a second SQLite connection as an independent profile authority.
- Add `build_agent_v2`/`BuildAgentV2RequestDTO`. It accepts only portable `AgentLLMRequirements` and Agent-owned draft content; it never accepts target ID, provider, model ID, API key, Base URL, installation, engine, or Swift parameter values.
- New profiles are created as `host_slot_v2` with `PendingHostBinding`. The legacy builder remains only for Task 6 migration fixtures until cleanup.
- `HostBoundAgentBuilderClient` selects one existing exact `LLMTargetRevision`, validates the target capability/parameter schema in Swift, asks Rust to create the pending V2 revision, and drives the existing prepare → Swift stage → Rust commit → Swift activate → Rust confirm saga.
- `AgentHostConfiguration.parameterOverrides` contains the capability-checked Agent overrides. Rust sees only the requirements hash and opaque binding tuple/hash.
- Publication success is returned to the UI only after both stores report the same active binding. A crash/retry reuses stable operation IDs and reconciles; it does not publish a second revision.
- Rename the bridge-level builder seam to `PortableAgentBuilderClient`; it accepts only the Rust-owned draft/requirements and returns the pending V2 subject. The App-level `AgentBuilderPublishing` seam composes that client with exact Swift target selection and host binding. `AgentLLMSelectionDraft` remains an App value and is never encoded over Rust FFI.

- [ ] **Step 1: Write failing durable-reopen and App saga tests**

```rust
#[test]
fn v2_profile_and_components_reopen_from_agent_sqlite() {
    let path = temp_agent_sqlite();
    let first = SqliteRuntimeStateStore::open(&path).unwrap();
    let profile = publish_v2_profile(&first, "profile-a", 3);
    drop(first);

    let reopened = SqliteRuntimeStateStore::open(&path).unwrap();
    let loaded = reopened
        .agent_profile_exact(&AgentProfileId::new("profile-a"), AgentProfileVersion::new(3))
        .unwrap()
        .expect("persisted profile must exist");
    assert_eq!(loaded, profile);
    assert!(loaded.llm_slot().is_some());
    assert!(loaded.legacy_model_binding().is_none());
}

#[test]
fn populated_runtime_v2_migrates_atomically_to_complete_v3() {
    let fixture = RuntimeV2Fixture::with_host_state();
    let expected = fixture.host_state_projection();

    let store = SqliteRuntimeStateStore::open(fixture.path()).unwrap();

    assert_eq!(store.schema_version().unwrap(), 3);
    assert_eq!(store.host_state_projection().unwrap(), expected);
    assert_eq!(
        store.v3_table_names().unwrap(),
        [
            "agent_component_revisions",
            "agent_profile_revisions",
            "legacy_profile_migration_records",
        ]
    );
}

#[test]
fn every_runtime_v3_migration_boundary_rolls_back_to_v2() {
    for index in 0..runtime_v3_migration_statement_count() {
        let fixture = RuntimeV2Fixture::with_host_state();
        let before = fixture.raw_projection();

        let error = SqliteRuntimeStateStore::open_with_migration_failure(
            fixture.path(),
            RuntimeStateMigrationFailurePoint::AfterVersionThreeStatement(index),
        )
        .unwrap_err();

        assert_eq!(error.code(), "runtime_state.migration_injected_failure");
        assert_eq!(fixture.schema_version(), 2);
        assert_eq!(fixture.raw_projection(), before);
    }
}

#[test]
fn runtime_schema_v4_is_rejected_before_mutation() {
    let fixture = RuntimeV2Fixture::with_host_state();
    fixture.set_schema_version(4);
    let before = fixture.raw_projection();

    let error = SqliteRuntimeStateStore::open(fixture.path()).unwrap_err();

    assert_eq!(error.code(), "runtime_state.schema_future");
    assert_eq!(fixture.raw_projection(), before);
}
```

Define `RuntimeV2Fixture` in `runtime_state_migration.rs` using the exact V2
DDL already frozen by the existing migration tests; it inserts one row in each
host lifecycle table so rollback/state-preservation assertions are not
empty-set checks.

```swift
@MainActor
@Test
func publishWaitsForExactHostBindingActivation() async throws {
    let harness = HostBoundAgentPublishHarness()
    let viewModel = harness.viewModel
    await viewModel.selectTarget(harness.target.reference)
    viewModel.setParameter(.reasoningEffort, .text("high"))

    await viewModel.publishCurrentDraft()

    #expect(viewModel.lifecycle == .published(profileRevisionId: 2))
    #expect(harness.rust.confirmedBinding == harness.swift.activeBinding)
    #expect(harness.rust.receivedProviderFields.isEmpty)
}
```

Add crash points after Rust pending revision, Swift stage, Rust commit, Swift activation, and before Rust confirmation. Replaying the same operation must converge to one V2 revision and one binding.

- [ ] **Step 2: Run RED**

```bash
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml \
  --test contract runtime_state_migration -- --nocapture
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml \
  --test contract agent_profile_sqlite -- --nocapture
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml \
  --test integration app_service_builder_publish -- --nocapture
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:LocalAgentAppTests/HostBoundAgentPublishTests
```

Expected: migration tests fail because runtime schema is fixed at 2 and startup
creates tables implicitly; Profile tests fail because profiles/components are
in-memory; the App builder still publishes a legacy concrete model binding.

- [ ] **Step 3: Extend the existing aggregate repository and reuse the binding saga**

```rust
pub trait UnifiedRuntimeStateRepository: Send + Sync + 'static {
    fn publish_agent_profile_aggregate(
        &self,
        operation: ProfilePublicationOperation,
    ) -> Result<AgentProfileReference, RuntimeStateError>;

    fn agent_profile_exact(
        &self,
        id: &AgentProfileId,
        version: AgentProfileVersion,
    ) -> Result<Option<AgentProfile>, RuntimeStateError>;

    fn transition_agent_profile_host_binding(
        &self,
        transition: AgentProfileHostBindingTransition,
    ) -> Result<AgentProfile, RuntimeStateError>;
}
```

Set `RUNTIME_STATE_SCHEMA_VERSION` to 3 and route every open through one
version switch:

```rust
match current_schema_version(connection)? {
    None => create_current_v3_schema(connection)?,
    Some(1) => {
        migrate_legacy_sidecar_to_v2(connection, path, failure)?;
        migrate_runtime_v2_to_v3(connection, failure)?;
    }
    Some(2) => migrate_runtime_v2_to_v3(connection, failure)?,
    Some(3) => {}
    Some(version) => return Err(unsupported_or_future(version)),
}
```

The three V3 tables are declared only in the V3 baseline/migration statements.
Do not leave them in a common `CREATE TABLE IF NOT EXISTS` batch.

Add the aggregate methods to the existing trait in `storage/runtime_state.rs`;
do not introduce another generic repository abstraction.
`publish_agent_profile_aggregate` writes the immutable Profile revision and
every required component revision in one in-memory lock or SQLite transaction.
SQLite rows carry a record schema, tagged binding schema, immutable revision
JSON, and canonical digest. Unknown schemas fail closed.

The App coordinator uses existing bridge operations:

```swift
protocol AgentBuilderPublishing: Sendable {
    func availableTargets() async throws -> [AgentLLMTargetOption]
    func publish(
        draft: AgentBuilderDraft,
        llm: AgentLLMSelectionDraft
    ) async throws -> PublishedAgentSelection
}

let pending = try await rust.buildAgentV2(portableDraft)
let operation = try await rust.prepareProfilePublish(pending.subject)
let receipt = try await bindingSaga.stageHostBinding(
    operation.stageRequest(configuration: configuration)
)
let link = try await rust.commitProfilePublish(operation.commit(receipt))
try await bindingSaga.activateHostBinding(
    operationToken: operation.token,
    binding: receipt.binding
)
try await rust.confirmHostBindingActivation(link.confirmation(receipt))
```

- [ ] **Step 4: Run GREEN and binding regressions**

```bash
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml \
  --test contract runtime_state_migration -- --nocapture
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml \
  --test contract agent_profile_sqlite -- --nocapture
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml \
  --test contract agent_builder_agent_os -- --nocapture
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml \
  --test contract host_binding_saga -- --nocapture
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml \
  --test integration app_service_builder_publish -- --nocapture
swift test --package-path toolkit --filter AgentBuilderClientTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:LocalAgentAppTests/HostBoundAgentPublishTests
git diff --check
```

Expected: all pass; populated V2 stores reopen as V3 without state loss, the
three future Task 5/6 tables exist exactly once, new Profiles reopen as V2
binding records inside the V3 store, and the App reports publication only
after exact binding activation.

- [ ] **Step 5: Commit**

```bash
git add rust-core/src/user_customization rust-core/src/app_service.rs \
  rust-core/src/llm_contracts/host_binding_service.rs \
  rust-core/src/run_snapshot rust-core/src/ffi_bridge.rs \
  rust-core/src/storage/runtime_state.rs rust-core/src/storage/sqlite_runtime_state.rs \
  rust-core/tests/contract rust-core/tests/integration \
  toolkit/Sources/LocalAgentBridge toolkit/Tests/LocalAgentBridgeTests \
  apps/LocalAgentApp/LocalAgentApp/Composition/HostBoundAgentBuilderClient.swift \
  apps/LocalAgentApp/LocalAgentApp/Presentation/AgentBuilder \
  apps/LocalAgentApp/LocalAgentAppTests/Presentation/AgentBuilder \
  apps/LocalAgentApp/LocalAgentAppTests/Integration/HostBoundAgentPublishTests.swift \
  apps/LocalAgentApp/LocalAgentApp.xcodeproj/project.pbxproj
git commit -m "feat: publish durable host-bound agent profiles"
```

---

### Task 6: Implement Explicit Crash-Safe Legacy Profile Migration

**Files:**
- Modify: `contracts/canonical-digest-v1/registry.json`
- Create: `contracts/canonical-digest-v1/fixtures/legacy-profile-source-v1.json`
- Modify: `rust-core/src/canonical_digest.rs`
- Create: `rust-core/src/llm_contracts/profile_migration.rs`
- Modify: `rust-core/src/llm_contracts/mod.rs`
- Create: `rust-core/src/migration/mod.rs`
- Create: `rust-core/src/migration/legacy_agent_profile_translator.rs`
- Modify: `rust-core/src/lib.rs`
- Modify: `rust-core/src/llm_contracts/host_binding_service.rs`
- Modify: `rust-core/src/user_customization/agent_profile.rs`
- Modify: `rust-core/src/storage/runtime_state.rs`
- Modify: `rust-core/src/storage/sqlite_runtime_state.rs`
- Modify: `rust-core/src/ffi_bridge.rs`
- Create: `rust-core/tests/contract/llm_profile_migration.rs`
- Modify: `rust-core/tests/contract/host_binding_saga.rs`
- Modify: `rust-core/tests/contract/canonical_digest_v1.rs`
- Create: `rust-core/tests/integration/llm_profile_migration_ffi.rs`
- Modify: `toolkit/Sources/LocalAgentBridge/AgentOSDTOs.swift`
- Modify: `toolkit/Sources/LocalAgentBridge/RustAgentOSBridgeGateway.swift`
- Modify: `toolkit/Sources/LocalAgentBridge/RustRuntimeClient.swift`
- Create: `apps/LocalAgentApp/LocalAgentApp/Runtime/LegacyLLMMigrationCoordinator.swift`
- Create: `apps/LocalAgentApp/LocalAgentAppTests/Runtime/LegacyLLMMigrationCoordinatorTests.swift`
- Modify: `apps/LocalAgentApp/LocalAgentApp.xcodeproj/project.pbxproj`

**Interfaces:**
- Register `legacy-profile-source:v1` in the shared registry and the Rust digest implementation. It covers source Profile ID, source revision, historical record schema version, and the complete immutable legacy source record. Rust computes it after the source passes validation; Swift receives the lowercase digest only as opaque identity and never implements, recomputes, or interprets this domain.
- Add one persisted `LegacyProfileMigrationRecord` per `legacy-profile-source:v1` digest. Its state is `pending { attempt }`, `migrated { successor }`, or `archived`; write the table created by Task 5 and do not issue DDL or add another migration table.
- `attempt` is optional and contains only the stable attempt ID, hidden V2 successor, and host-binding operation identity needed for crash recovery. Abandoning an incomplete attempt tombstones its hidden successor and clears `attempt`, returning the same source record to plain `pending`.
- Swift binding state remains in the existing `LLMStore`; Rust does not copy `binding_staged` or `swift_activated`.
- `LegacyAgentProfileTranslator` reads only known legacy record schemas and produces a complete provider-neutral draft: original profile identity/revision, display metadata, component bindings, tool bindings, memory binding, voice binding, and portable LLM requirements. It skips the concrete legacy model/provider binding subtree without constructing a provider, credential, URL, engine, or local path.
- `begin_legacy_profile_migration` reads an exact V1 revision through that translator and creates a hidden `PendingHostBinding` V2 successor. It never overwrites or disables V1.
- Swift chooses one exact existing target; migration never guesses or falls back from legacy provider/model hints.
- The existing host-binding saga stages and commits the V2 successor, then Swift activates the exact binding. Migration does not call the ordinary Rust confirmation separately. `complete_legacy_profile_migration` accepts the exact activation confirmation and, in one `agent.sqlite` aggregate transaction, activates the Rust cross-link, marks V2 active/visible, and changes the source migration record to `migrated`. The immutable V1 source row is not rewritten.
- A crash after Swift activation but before `complete_legacy_profile_migration` leaves Rust V2 hidden/host-unbound and V1 runnable; startup reconciliation reads the pending attempt, observes the exact active Swift tuple, and retries finalization. Abandoning tombstones only the hidden successor and clears the attempt; it does not alter V1.
- Startup reconciliation reports the exact next action. It never infers success from target name, provider name, model ID, or a nearby binding.
- The complete translated component/tool/memory/voice graph stays inside Rust and is used there to create the hidden V2 successor. Swift receives only migration subject/source digest, display metadata, portable LLM requirements, record state, and optional non-secret model-family/model-ID hints.
- The migration DTO contains no component graph, tool schema, memory/voice binding, credential reference/value, Base URL, local path, engine ID, provider request field, or development environment provider.
- A known legacy schema with an unknown portable Agent field fails closed and preserves the source. A concrete legacy binding field is deliberately ignored; a plaintext secret outside that ignored subtree is rejected. Migration never imports an environment-derived provider.

- [ ] **Step 1: Write failing state-machine and crash tests**

```rust
#[test]
fn every_pre_activation_failure_keeps_v1_runnable() {
    for point in MigrationCrashPoint::before_completion() {
        let mut harness = MigrationHarness::legacy_v1();
        harness.inject(point);
        assert!(harness.migrate().is_err());

        let v1 = harness.repository.exact("profile-a", 1).unwrap();
        assert_eq!(v1.binding_schema(), LLMBindingSchema::LegacyV1);
        assert!(harness.legacy_route_is_runnable("profile-a", 1));
        assert!(!harness.v2_successor_is_visible());
    }
}

#[test]
fn completion_activates_exact_v2_then_supersedes_v1_atomically() {
    let mut harness = MigrationHarness::legacy_v1();
    let completed = harness.migrate().unwrap();

    assert!(matches!(
        completed.migration_state,
        LegacyProfileMigrationState::Migrated { .. }
    ));
    assert_eq!(completed.successor_state, AgentProfileHostBindingState::Active);
    assert!(!harness.legacy_route_is_selectable("profile-a", 1));
}

#[test]
fn translator_preserves_the_complete_portable_agent_profile_graph() {
    let legacy = fixtures::legacy_profile_with_components_tools_memory_and_voice();
    let translated = LegacyAgentProfileTranslator::translate_known_profile(&legacy).unwrap();

    assert_eq!(translated.source_profile_id, legacy.profile_id);
    assert_eq!(translated.source_revision, legacy.revision);
    assert_eq!(translated.component_bindings, legacy.component_bindings);
    assert!(translated.has_component_kind(ComponentKind::ToolRecipe));
    assert!(translated.has_component_kind(ComponentKind::MemoryProfile));
    assert!(translated.has_component_kind(ComponentKind::VoiceProfile));
    assert_eq!(translated.llm_slot.requirements(), legacy.portable_requirements());
    assert_no_concrete_model_or_provider_fields(&translated);
}

#[test]
fn every_legacy_source_has_one_durable_migration_record() {
    let repository = MigrationHarness::mixed_legacy_sources().repository;
    assert!(repository.record_for("pending-source").unwrap().state.is_pending());
    assert!(repository.record_for("migrated-source").unwrap().state.is_migrated());
    assert!(repository.record_for("archived-source").unwrap().state.is_archived());
    assert_eq!(repository.duplicate_source_digest_count(), 0);
}

#[test]
fn legacy_source_digest_binds_the_complete_immutable_record() {
    let source = fixtures::legacy_profile_with_components_tools_memory_and_voice();
    let digest = LegacyAgentProfileTranslator::source_digest(&source).unwrap();

    assert!(CanonicalDigestV1::registered_domains()
        .contains("legacy-profile-source:v1"));
    assert_ne!(
        digest,
        LegacyAgentProfileTranslator::source_digest(
            &source.with_component_revision_incremented()
        )
        .unwrap()
    );
}
```

```swift
@Test
func migrationNeverUsesLegacyHintAsAutomaticTargetSelection() async throws {
    let harness = LegacyMigrationHarness(
        hint: .init(modelID: "gpt-4.1", providerFamily: "openai")
    )
    await #expect(throws: LegacyMigrationError.self) {
        try await harness.coordinator.migrate(
            profileID: "legacy",
            revision: 1,
            selectedTarget: nil
        )
    }
    #expect(harness.modelCenter.targetSelections.isEmpty)
}
```

- [ ] **Step 2: Run RED**

```bash
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml \
  --test contract canonical_digest_v1 -- --nocapture
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml \
  --test contract llm_profile_migration -- --nocapture
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml \
  --test integration llm_profile_migration_ffi -- --nocapture
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:LocalAgentAppTests/LegacyLLMMigrationCoordinatorTests
```

Expected: canonical tests fail because `legacy-profile-source:v1` is
unregistered; migration tests fail because no persisted migration record or
App coordinator exists.

- [ ] **Step 3: Implement the saga by composing existing primitives**

```rust
pub(crate) struct PortableLegacyAgentProfileDraft {
    pub source_profile_id: AgentProfileId,
    pub source_revision: AgentProfileVersion,
    pub template_id: AgentTemplateId,
    pub display_name: String,
    pub component_bindings: Vec<ComponentBinding>,
    pub llm_slot: LLMSlotV2,
    pub redacted_model_hint: Option<String>,
}

pub struct LegacyProfileMigrationRecord {
    pub source_profile_id: AgentProfileId,
    pub source_revision: AgentProfileVersion,
    pub source_digest: String,
    pub state: LegacyProfileMigrationState,
}

pub enum LegacyProfileMigrationState {
    Pending {
        attempt: Option<LegacyProfileMigrationAttempt>,
    },
    Migrated {
        successor: AgentProfileSubject,
    },
    Archived,
}

pub struct LegacyProfileMigrationAttempt {
    pub attempt_id: String,
    pub successor: AgentProfileSubject,
    pub host_binding_operation_id: String,
}
```

`PortableLegacyAgentProfileDraft` never crosses FFI. Tool, memory, and voice
bindings remain typed entries in `component_bindings`; Rust validates and
publishes that complete graph before projecting the small Swift action DTO.
The source digest is computed over a typed canonical document with:

```rust
#[derive(Serialize)]
struct LegacyProfileSourceV1<'a> {
    source_profile_id: &'a str,
    source_revision: u64,
    source_schema_version: u32,
    source_record: &'a serde_json::Value,
}
```

Add `legacy-profile-source:v1` as the only new Phase 5 digest domain. The shared
golden fixture is recomputed by the Rust typed builder; Swift does not gain a
builder for this opaque identity. The registered-domain count advances from 34
to 35. No `tool-display-keys:v1` domain exists in Phase 5.

```swift
enum LegacyMigrationRecordStateDTO: String, Codable, Sendable {
    case pending
    case migrated
    case archived
}

struct LegacyMigrationActionDTO: Codable, Equatable, Sendable {
    let migrationSubject: String
    let sourceDigest: String
    let displayName: String
    let requirements: AgentLLMRequirementsDTO
    let redactedModelHint: String?
    let state: LegacyMigrationRecordStateDTO
}
```

Use one Rust aggregate transaction to insert the source record as `pending`. Beginning an attempt transactionally creates the hidden successor and fills `pending.attempt`. Finalization transactionally activates the cross-link, exposes the successor, and changes the same record to `migrated`. Explicit archive changes the same record to `archived`. Cross-store steps remain the existing digest-bound host-binding saga. Do not create a second binding hash, migration table, or Swift migration store.

- [ ] **Step 4: Run GREEN, restart recovery, and legacy-preservation tests**

```bash
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml \
  --test contract canonical_digest_v1 -- --nocapture
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml \
  --test contract llm_profile_migration -- --nocapture
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml \
  --test contract host_binding_saga -- --nocapture
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml \
  --test integration llm_profile_migration_ffi -- --nocapture
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:LocalAgentAppTests/LegacyLLMMigrationCoordinatorTests
git diff --check
```

Expected: all crash points converge; V1 remains runnable until exact V2 activation and final completion.

- [ ] **Step 5: Commit**

```bash
git add contracts/canonical-digest-v1 rust-core/src/canonical_digest.rs \
  rust-core/src/llm_contracts rust-core/src/migration rust-core/src/lib.rs \
  rust-core/src/user_customization \
  rust-core/src/storage rust-core/src/ffi_bridge.rs \
  rust-core/tests/contract rust-core/tests/integration \
  toolkit/Sources/LocalAgentBridge \
  apps/LocalAgentApp/LocalAgentApp/Runtime/LegacyLLMMigrationCoordinator.swift \
  apps/LocalAgentApp/LocalAgentAppTests/Runtime/LegacyLLMMigrationCoordinatorTests.swift \
  apps/LocalAgentApp/LocalAgentApp.xcodeproj/project.pbxproj
git commit -m "feat: migrate legacy llm profiles safely"
```

---

### Task 7: Hydrate Exact Bindings and Gate Migration Before Cutover

**Files:**
- Modify: `apps/LocalAgentApp/LocalAgentApp/Composition/AppBootstrapper.swift`
- Modify: `apps/LocalAgentApp/LocalAgentApp/Composition/AppContainer.swift`
- Modify: `apps/LocalAgentApp/LocalAgentApp/Runtime/AppLLMHostRouting.swift`
- Modify: `apps/LocalAgentApp/LocalAgentApp/App/LocalAgentApp.swift`
- Modify: `apps/LocalAgentApp/LocalAgentApp/App/AppShellViewModel.swift`
- Modify: `apps/LocalAgentApp/LocalAgentAppTests/Integration/LLMHostCompositionTests.swift`
- Create: `apps/LocalAgentApp/LocalAgentAppTests/Integration/LLMProductBootstrapTests.swift`
- Create: `rust-core/tests/integration/phase_five_product_path.rs`
- Modify: `rust-core/tests/integration.rs`
- Create: `rust-core/tests/fixtures/migration/legacy-local-profile.json`
- Create: `rust-core/tests/fixtures/migration/legacy-cloud-profile.json`
- Create: `rust-core/tests/fixtures/migration/legacy-mock-profile.json`
- Create: `rust-core/tests/fixtures/migration/direct-upgrade-complete-profile.json`
- Create: `scripts/run-llm-phase-5-contracts.sh`

**Interfaces:**
- `AppBootstrapper` opens one shared `LLMStore`, constructs the approval broker before cloud bootstrap, injects the store into local/cloud, boots the host runtime, reconciles pending host-binding operations and migration records, and hydrates exact active bindings before runs are enabled.
- Startup scans recognized legacy sources and creates any missing `pending` migration records before presenting migration actions. `migrated` and `archived` are terminal for that exact source digest; a changed source digest is a new migration subject.
- `AppLLMHostSelectionRegistry` becomes a read-through in-memory index of validated `ActiveAgentHostBinding` plus exact `LLMTargetRevision`; SQLite remains authority.
- Hydration rejects a missing/changed target, binding hash mismatch, non-active Provider Profile, missing local installation, stale cloud validation, or unsupported parameters. It never substitutes another target.
- Durable binding hydration performs no epoch check. After hydration, each new local/cloud preparation, session, command, and event is bound to the current App-owned epoch through the existing Phase 4 contracts.
- The App shell loads an exact active Agent Profile revision from Rust instead of hardcoding `profile_1@1`.
- The migration-capable product route continues to use `LLMProductRunRouter`: V2 through host, explicitly unmigrated V1 through legacy. Route lookup remains exact and there is no fallback on errors.
- The single Phase 5 runner initially includes local/cloud final-response and one tool-loop parity fixture, complete profile-graph preservation, direct old-store import, every migration crash point, restart hydration, global lease contention, record reopen, and V1 failure preservation. Tasks 8-10 append their gates to this same script.

- [ ] **Step 1: Write failing bootstrap and parity tests**

```swift
@Test
func bootstrapHydratesOnlyExactActiveBindings() async throws {
    let harness = try ProductBootstrapHarness.persistedLocalBinding()
    let container = try await harness.reopen()

    let selection = await container.llmHostSelections?.selection(
        profileID: harness.profileID,
        revision: harness.profileRevision
    )
    #expect(selection != nil)
    #expect(await container.hostRunStarter?.canStart == true)
}

@Test
func bootstrapDoesNotReplaceAMissingTarget() async throws {
    let harness = try ProductBootstrapHarness.bindingWithDeletedTarget()
    let container = try await harness.reopen()

    #expect(await container.llmHostSelections?.count == 0)
    #expect(container.readinessIssues.contains("execution.host_binding_not_configured"))
}

@Test
func durableBindingHydratesAcrossLaunchEpochsAndNewSessionUsesCurrentEpoch() async throws {
    let harness = try ProductBootstrapHarness.persistedLocalBinding(
        originalEpoch: "old-epoch"
    )
    let container = try await harness.reopen(currentEpoch: "new-epoch")
    let selection = try #require(await container.llmHostSelections?.only)

    #expect(selection.binding == harness.persistedBinding)
    let session = try await selection.prepareFixtureSession()
    #expect(session.hostProcessEpoch == "new-epoch")
}

@Test
func bootstrapFromOldStoreExposesOnlyTheMinimalMigrationAction() async throws {
    let harness = try ProductBootstrapHarness.directOldStoreUpgrade()
    let container = try await harness.reopen()
    let action = try #require(await container.legacyMigration?.pendingActions().only)

    #expect(action.migrationSubject == harness.sourceSubject)
    #expect(action.displayName == "Imported Agent")
    #expect(action.requirements == harness.expectedRequirements)
    #expect(action.redactedModelHint == "gpt-4.1")
}
```

Rust end-to-end parity:

```rust
#[test]
fn migrated_local_and_cloud_fixtures_match_legacy_agent_outcomes() {
    for fixture in ["legacy-local-profile.json", "legacy-cloud-profile.json"] {
        let parity = PhaseFiveParityHarness::from_fixture(fixture);
        assert_eq!(parity.legacy_final_text(), parity.migrated_v2_final_text());
        assert_eq!(parity.legacy_tool_effects(), parity.migrated_v2_tool_effects());
    }
}

#[test]
fn direct_old_store_startup_preserves_the_complete_graph_inside_rust() {
    let mut harness =
        PhaseFiveParityHarness::from_fixture("direct-upgrade-complete-profile.json");
    let action = harness.startup().unwrap().single_pending_action();
    let successor = harness.migrate(action.subject, harness.exact_target()).unwrap();

    assert_eq!(successor.component_bindings(), harness.expected_component_bindings());
    assert!(successor.has_component_kind(ComponentKind::ToolRecipe));
    assert!(successor.has_component_kind(ComponentKind::MemoryProfile));
    assert!(successor.has_component_kind(ComponentKind::VoiceProfile));
    assert_eq!(successor.llm_slot().requirements(), harness.expected_requirements());
    assert_eq!(harness.migration_record_count(), 1);
}
```

- [ ] **Step 2: Run RED**

```bash
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml \
  --test integration phase_five_product_path -- --nocapture
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:LocalAgentAppTests/LLMProductBootstrapTests \
  -only-testing:LocalAgentAppTests/LLMHostCompositionTests
```

Expected: fail because product bootstrap does not share/hydrate target and binding state.

- [ ] **Step 3: Wire the existing stores and runtimes in dependency order**

```swift
let llmStore = try LLMStore(fileURL: databaseURL)
let approvalBroker = AppCloudApprovalBroker()
let local = try await LocalLLMSubsystem.bootstrap(..., llmStore: llmStore)
let cloud = try await CloudLLMSubsystem.bootstrap(
    ...,
    llmStore: llmStore,
    approvalPrompt: approvalBroker
)
let host = try await LLMHostProductRuntime.bootstrap(...)
let migrationActions = try await rust.reconcileLegacyProfileMigrations()
await legacyMigration.install(actions: migrationActions)
try await selections.hydrate(
    bindings: llmStore.activeHostBindings(),
    targets: llmStore.targets(),
    local: local,
    cloud: cloud
)
```

Do not install `hostRunStarter` until migration reconciliation and binding hydration finish. This is the only startup migration wiring; Task 10 must not reimplement it. A degraded App may display recovery state, but it may not silently install the Rust mock provider as a product model.

- [ ] **Step 4: Create and run the single Phase 5 gate**

`scripts/run-llm-phase-5-contracts.sh` starts as the migration/cutover gate:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IPHONE_UDID="${LOCAL_AGENT_PHASE5_IPHONE_UDID:-}"
IPAD_UDID="${LOCAL_AGENT_PHASE5_IPAD_UDID:-}"
DERIVED_DATA="${LOCAL_AGENT_PHASE5_DERIVED_DATA:-/private/tmp/local-agent-phase5-derived}"
unset OPENAI_API_KEY ANTHROPIC_API_KEY GEMINI_API_KEY XAI_API_KEY
unset DEEPSEEK_API_KEY MINIMAX_API_KEY ZHIPUAI_API_KEY

LOCAL_AGENT_PHASE4_IPHONE_UDID="$IPHONE_UDID" \
LOCAL_AGENT_PHASE4_IPAD_UDID="$IPAD_UDID" \
  "$ROOT/scripts/run-llm-phase-4-contracts.sh"

for UDID in "$IPHONE_UDID" "$IPAD_UDID"; do
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
      -project "$ROOT/apps/LocalAgentApp/LocalAgentApp.xcodeproj" \
      -scheme LocalAgentApp \
      -destination "platform=iOS Simulator,id=$UDID" \
      -derivedDataPath "$DERIVED_DATA-$UDID" \
      -only-testing:LocalAgentAppTests/ModelCenterViewModelTests \
      -only-testing:LocalAgentAppTests/ProviderProfileEditorTests \
      -only-testing:LocalAgentAppTests/AppCloudApprovalBrokerTests \
      -only-testing:LocalAgentAppTests/HostBoundAgentPublishTests \
      -only-testing:LocalAgentAppTests/LegacyLLMMigrationCoordinatorTests \
      -only-testing:LocalAgentAppTests/LLMProductBootstrapTests
done
```

Phase 4 validates the two mapped UDIDs and already runs all Cargo, SwiftPM,
C++, App-link, and Phase 1-4 gates against the current tree. Do not repeat those
commands in the Phase 5 runner. The loop above adds only Phase 5 App groups.

```bash
LOCAL_AGENT_PHASE5_IPHONE_UDID="<available iPhone UDID>" \
LOCAL_AGENT_PHASE5_IPAD_UDID="<available iPad UDID>" \
  scripts/run-llm-phase-5-contracts.sh
git diff --check
```

Expected: the migration gate passes while tests still prove V1 survives every failed migration before cutover.

- [ ] **Step 5: Commit**

```bash
git add apps/LocalAgentApp/LocalAgentApp/Composition \
  apps/LocalAgentApp/LocalAgentApp/Runtime/AppLLMHostRouting.swift \
  apps/LocalAgentApp/LocalAgentApp/App \
  apps/LocalAgentApp/LocalAgentAppTests \
  rust-core/tests/integration rust-core/tests/fixtures/migration \
  scripts/run-llm-phase-5-contracts.sh
git commit -m "feat: hydrate llm bindings and gate migration"
```

---

### Task 8: Switch the App Product to the Host-Only Route

**Files:**
- Modify: `toolkit/Sources/LocalAgentLLMHost/LLMHostProductRuntime.swift`
- Modify: `toolkit/Tests/LocalAgentLLMHostTests/LLMHostProductPathTests.swift`
- Modify: `toolkit/Sources/LocalAgentBridge/RuntimeClient.swift`
- Modify: `toolkit/Sources/LocalAgentBridge/RustRuntimeClient.swift`
- Modify: `toolkit/Sources/LocalAgentBridge/MockRuntimeClient.swift`
- Modify: `toolkit/Tests/LocalAgentBridgeTests/RustRuntimeClientContractTests.swift`
- Modify: `apps/LocalAgentApp/LocalAgentApp/Composition/AppBootstrapper.swift`
- Modify: `apps/LocalAgentApp/LocalAgentApp/Composition/AppContainer.swift`
- Modify: `apps/LocalAgentApp/LocalAgentApp/Runtime/AppLLMHostRouting.swift`
- Modify: `apps/LocalAgentApp/LocalAgentApp/Runtime/AgentRuntimeService.swift`
- Modify: `apps/LocalAgentApp/LocalAgentApp/State/AgentViewState.swift`
- Modify: `apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/AgentViewModel.swift`
- Modify: `apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/ChatView.swift`
- Modify: `apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/ChatManagementSheets.swift`
- Modify: `apps/LocalAgentApp/LocalAgentAppTests/Runtime/AgentRuntimeServiceTests.swift`
- Modify: `apps/LocalAgentApp/LocalAgentAppTests/Integration/LLMHostCompositionTests.swift`
- Modify: `scripts/run-llm-phase-5-contracts.sh`

**Precondition:**
- `scripts/run-llm-phase-5-contracts.sh` passes on the current tree.
- The direct-upgrade fixture preserves the complete portable profile and the migration fixture inventory has exactly one durable record per recognized source digest.
- No task may satisfy this precondition by deleting a failing fixture.

**Interfaces:**
- Delete `LLMProductRunRouter` and `ProfileExecutionRouteClient` from product use. `AppHostRunStarter` is the only `LLMProductRunStarting` implementation installed in production.
- `AgentRuntimeService` requires a `ChatInteractionCoordinating` instance. Remove the optional coordinator and all direct `sendMessage`, legacy streaming, tool-continuation, and provider-selection fallback branches.
- Remove `selectProvider` from `AgentRuntimeServicing`, `AgentViewModel`, and chat UI.
- Remove global `ModelSettingsViewState`, `ExecutionOptionsDTO.temperature/topP`, runtime option mutation, Model Settings sheet, and any state restoration of those fields. Per-Agent `AgentHostConfiguration` is the only parameter source.
- Narrow `RuntimeClient` product dependencies to provider-neutral conversation/tool/debug operations. Remove `ProviderControllingRuntimeClient`, `RuntimeOptionsControllingRuntimeClient`, and direct provider/model send APIs from production protocols; test-only fakes live in test targets.
- Starting an Agent without an exact active V2 binding fails with `execution.host_binding_not_configured` and routes the user to Agent configuration. It never falls back to a mock/local/cloud provider.
- Append `AgentRuntimeServiceTests` to the Phase 5 App-test loop and add the no-fallback source scan. Do not add a separate SwiftPM run: the mapped Phase 4 runner already executes the complete current Swift package suite, including `LLMHostProductPathTests`.

- [ ] **Step 1: Write failing host-only product tests**

```swift
@Test
func productionServiceSourceHasNoOptionalCoordinatorOrLegacySendBranch() throws {
    let projectDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: projectDirectory
            .appendingPathComponent("LocalAgentApp/Runtime/AgentRuntimeService.swift"),
        encoding: .utf8
    )
    #expect(!source.contains("coordinator: (any ChatInteractionCoordinating)?"))
    #expect(!source.contains("LEGACY_COMPATIBILITY_STREAMING_PATH"))
}

@Test
func missingHostBindingFailsWithoutLegacyOrMockFallback() async throws {
    let harness = HostOnlyAppHarness.missingBinding()
    await #expect(throws: LLMHostFailure.self) {
        try await harness.send("hello")
    }
    #expect(harness.legacyStartCount == 0)
    #expect(harness.mockProviderCount == 0)
}
```

Add source-shape assertions that `ModelRoutingClient`, `selectProvider`, optional `ChatInteractionCoordinating`, global temperature/top-p controls, and `LLMProductRunRouter` no longer occur in App/production Swift sources.

- [ ] **Step 2: Run RED**

```bash
swift test --package-path toolkit --filter LLMHostProductPathTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:LocalAgentAppTests/AgentRuntimeServiceTests \
  -only-testing:LocalAgentAppTests/LLMHostCompositionTests
```

Expected: fail because the router, optional coordinator, provider selection, and direct legacy paths still exist; the test itself continues to compile after the initializer becomes non-optional.

- [ ] **Step 3: Delete the old App branches**

The final service initializer is explicit:

```swift
actor AgentRuntimeService: AgentRuntimeServicing {
    init(
        conversation: any ConversationBridgeClient,
        execution: any ExecutionBridgeClient,
        coordinator: any ChatInteractionCoordinating,
        toolDriver: any HostToolDriving
    )
}
```

Conversation history, pending approval, cancellation, debug, and tool UI remain provider-neutral bridge operations. Only model generation and continuation branches are deleted. Do not replace the removed code with a compatibility adapter that still calls `RustRuntimeClient.sendMessage`.

In `run-llm-phase-5-contracts.sh`, add
`-only-testing:LocalAgentAppTests/AgentRuntimeServiceTests` to the existing
iPhone/iPad loop and fail when the production source scan finds a removed
symbol:

```bash
if rg -n 'ModelRoutingClient|ProviderControllingRuntimeClient|LLMProductRunRouter|LEGACY_COMPATIBILITY_STREAMING_PATH' \
  "$ROOT/apps/LocalAgentApp/LocalAgentApp" "$ROOT/toolkit/Sources"; then
  echo "legacy Swift LLM product route remains" >&2
  exit 1
fi
```

- [ ] **Step 4: Run GREEN and no-fallback checks**

```bash
swift test --package-path toolkit --filter LLMHostProductPathTests
swift test --package-path toolkit --filter RustRuntimeClientContractTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:LocalAgentAppTests/AgentRuntimeServiceTests \
  -only-testing:LocalAgentAppTests/LLMHostCompositionTests
rg -n 'ModelRoutingClient|ProviderControllingRuntimeClient|LLMProductRunRouter|LEGACY_COMPATIBILITY_STREAMING_PATH' \
  apps/LocalAgentApp/LocalAgentApp toolkit/Sources
git diff --check
```

Expected: tests pass and `rg` returns no production matches.

- [ ] **Step 5: Commit**

```bash
git add toolkit/Sources/LocalAgentLLMHost toolkit/Tests/LocalAgentLLMHostTests \
  toolkit/Sources/LocalAgentBridge toolkit/Tests/LocalAgentBridgeTests \
  apps/LocalAgentApp/LocalAgentApp apps/LocalAgentApp/LocalAgentAppTests \
  scripts/run-llm-phase-5-contracts.sh
git commit -m "refactor: switch app to host-only llm route"
```

---

### Task 9: Remove Rust Provider, Model Binding, Inference, and V1 Execution Code

**Files:**
- Delete: `rust-core/src/core/desktop_minicpm.rs`
- Delete: `rust-core/src/core/local_llm.rs`
- Delete: `rust-core/src/core/openai_chat.rs`
- Delete: `rust-core/src/core/provider.rs`
- Delete: `rust-core/src/core/provider_profile.rs`
- Delete: `rust-core/src/core/provider_registry.rs`
- Modify: `rust-core/src/core/mod.rs`
- Modify: `rust-core/src/core/runtime.rs`
- Delete: `rust-core/src/inference/backend.rs`
- Delete: `rust-core/src/inference/events.rs`
- Delete: `rust-core/src/inference/fake_backend.rs`
- Delete: `rust-core/src/inference/generation_session.rs`
- Delete: `rust-core/src/inference/loaded_model.rs`
- Delete: `rust-core/src/inference/router.rs`
- Delete: `rust-core/src/inference/usage.rs`
- Delete: `rust-core/src/inference/mod.rs`
- Delete: `rust-core/src/model/generation_profile.rs`
- Delete: `rust-core/src/model/model_binding.rs`
- Delete: `rust-core/src/model/model_catalog_service.rs`
- Delete: `rust-core/src/model/model_descriptor.rs`
- Delete: `rust-core/src/model/provider_account.rs`
- Delete: `rust-core/src/model/provider_definition.rs`
- Delete: `rust-core/src/model/mod.rs`
- Modify: `rust-core/src/agent_package/manifest.rs`
- Modify: `rust-core/src/agent_package/reader.rs`
- Modify: `rust-core/src/agent_package/validator.rs`
- Modify: `rust-core/src/agent_package/exporter.rs`
- Modify: `rust-core/src/agent_package/installer.rs`
- Modify: `rust-core/src/agent_package/mod.rs`
- Modify: `rust-core/src/llm_contracts/profile_migration.rs`
- Modify: `rust-core/src/migration/mod.rs`
- Modify: `rust-core/src/migration/legacy_agent_profile_translator.rs`
- Modify: `rust-core/src/lib.rs`
- Modify: `rust-core/src/app_service.rs`
- Modify: `rust-core/src/user_customization/agent_profile.rs`
- Modify: `rust-core/src/run_snapshot/resolved_bindings.rs`
- Modify: `rust-core/src/run_snapshot/resolver.rs`
- Modify: `rust-core/src/run_snapshot/snapshot.rs`
- Modify: `rust-core/src/run_snapshot/snapshot_service.rs`
- Modify: `rust-core/src/execution/react_worker.rs`
- Modify: `rust-core/src/execution/execution_service.rs`
- Modify: `rust-core/src/execution/context_input.rs`
- Delete: `rust-core/src/execution/inference_settings.rs`
- Modify: `rust-core/src/execution/mod.rs`
- Modify: `rust-core/src/ffi_bridge.rs`
- Delete: `rust-core/tests/fixtures/architecture/legacy_llm_allowlist.txt`
- Delete: `rust-core/tests/contract/inference_backend_agent_os.rs`
- Delete: `rust-core/tests/contract/model_inference_security_contract.rs`
- Delete: `rust-core/tests/unit/local_llm_backend.rs`
- Delete: `rust-core/tests/unit/local_llm_provider.rs`
- Delete: `rust-core/tests/unit/provider_registry.rs`
- Modify: `rust-core/tests/contract/llm_profile_migration.rs`
- Modify: `rust-core/tests/contract/agent_package_agent_os.rs`
- Modify: `rust-core/tests/integration/llm_profile_migration_ffi.rs`
- Modify: `rust-core/tests/contract.rs`
- Modify: `rust-core/tests/unit.rs`
- Modify: `rust-core/tests/integration/ffi_bridge.rs`
- Modify: `rust-core/tests/lint/architecture_agent_os.rs`
- Modify: `rust-core/tests/lint/llm_phase_two_architecture.rs`
- Modify: `rust-core/tests/lint/llm_phase_three_architecture.rs`
- Modify: `rust-core/tests/lint/llm_phase_four_architecture.rs`
- Create: `rust-core/tests/lint/llm_phase_five_architecture.rs`
- Modify: `rust-core/tests/lint.rs`
- Modify: `toolkit/Sources/LocalAgentBridge/RustRuntimeClient.swift`
- Modify: `toolkit/Sources/CLocalAgentRuntime/include/CLocalAgentRuntime.h`
- Modify: `toolkit/Sources/CLocalAgentRuntime/CLocalAgentRuntime.c`
- Modify: `apps/LocalAgentApp/LocalAgentApp/Composition/AppBootstrapper.swift`
- Modify: `apps/LocalAgentApp/LocalAgentApp/Runtime/LegacyLLMMigrationCoordinator.swift`
- Modify: `apps/LocalAgentApp/LocalAgentAppTests/Runtime/LegacyLLMMigrationCoordinatorTests.swift`
- Modify: `apps/LocalAgentApp/LocalAgentAppTests/Integration/RustRuntimeAppIntegrationTests.swift`
- Modify: `scripts/run-llm-phase-5-contracts.sh`

**Precondition:**
- `scripts/run-llm-phase-5-contracts.sh` passes on the current tree, including the complete direct-upgrade fixture.
- Task 8 host-only tests pass on the current tree.
- Every retained migration fixture has exactly one durable migration record.

**Interfaces:**
- `AgentRuntimeConfig` becomes provider-free and contains only the remaining Agent conversation/tool services. Agent prompts, policies, and context come from durable Agent Profile/component revisions; remove global runtime model options as well as provider, registry, active provider, provider cancellation, provider replay, direct model send, and provider selection state.
- Rename any route-neutral cancellation type that still carries `Provider` in its name.
- Production `ExecutionService` no longer owns `ExecutionWorkerDependencies.model` or invokes `ExecutionReactWorker` for start. The Phase 4 host worker/outbox is the only production model execution.
- Retain `ExecutionModelClient`, `ExecutionModelTurn`, and test fakes for provider-neutral Agent kernel tests. Do not retain `ModelProvider`, Provider Registry, Rust local provider, OpenAI codec, model catalog, or `InferenceRouter`.
- `AgentProfile` stores one `LLMSlotV2` directly. Remove `AgentProfileLLMBinding::LegacyV1`, `AgentProfileModelBinding`, concrete model binding catalogs, and legacy local credential bindings.
- `AgentPackageManifest` becomes a V2-only production value containing portable `LLMSlotV2`; remove public `PackageModelBinding`, `model_file`, and `model`. `AgentPackageReader` may recognize known schema-v1 wire fields only inside its existing read-only translation path and must return a V2 manifest immediately.
- Keep the existing schema-v1 package-to-V2 translation behavior, but make its concrete provider/model/path map private to the reader and discard it after deriving portable requirements plus a redacted hint. Validator, installer, exporter, and public module exports consume only the V2 manifest. Do not add a package migration saga.
- `ResolvedRunSnapshot` stores only `ResolvedHostSlotBinding`; remove provider account/provider/model fields and the legacy tagged snapshot variant.
- Delete `profile_execution_route`, legacy `start_run`, direct `send_message(_streaming)`, provider list/active/set, runtime model option, and Rust local inference C ABI operations. Keep provider-neutral conversation, preparation, host command/event, tool approval/result, cancellation, debug, and host-binding operations.
- `RustRuntimeConfiguration` contains only host epoch, store, and provider-neutral Agent OS configuration. It contains no provider ID/list or App-authored global prompt/sampling options. `AppBootstrapper` contains no simulator provider construction, environment-selected provider, or fallback-to-mock behavior.
- Retain `LegacyAgentProfileTranslator`, `LegacyProfileMigrationRecord`, their narrow FFI operations, `LegacyLLMMigrationCoordinator`, and their tests. They remain necessary for devices that upgrade directly from an old store.
- The retained translator reads known old records as an isolated migration document or bounded JSON value. It does not import or link the deleted production `ModelBinding`, provider, registry, inference, credential, URL, model-path, or engine types.
- Delete V1 route selection and execution endpoints. Retained migration endpoints may only scan, translate, begin, reconcile, complete, or archive a legacy source; they cannot execute it.
- Extend the same Phase 5 runner with the final architecture/deletion checks; do not create or delete a second runner.
- The appended gate includes `agent_package_agent_os`, direct old-store migration after V1 execution deletion, and the Phase 5 architecture lint.

- [ ] **Step 1: Freeze the final architecture test before deleting code**

```rust
#[test]
fn rust_product_has_no_llm_provider_or_engine_ownership() {
    let production = production_rust_sources_excluding([
        "src/migration/legacy_agent_profile_translator.rs",
        "src/agent_package/reader.rs",
    ]);
    for forbidden in [
        "ModelProvider",
        "ProviderRegistry",
        "ProviderProfile",
        "ProviderAccount",
        "ModelBinding",
        "InferenceBackend",
        "InferenceRouter",
        "LocalLLMProvider",
        "OpenAI",
        "base_url",
        "api_key",
        "credential_ref",
        "model_path",
    ] {
        assert_no_occurrence(&production, forbidden);
    }
}

#[test]
fn rust_profile_and_snapshot_are_v2_only() {
    assert!(!read("src/user_customization/agent_profile.rs").contains("LegacyV1"));
    assert!(!read("src/run_snapshot/resolved_bindings.rs").contains("ResolvedModelBinding"));
    assert!(!read("src/ffi_bridge.rs").contains("profile_execution_route_json"));
}

#[test]
fn retained_legacy_translator_is_not_an_execution_or_provider_boundary() {
    let migration = read("src/migration/legacy_agent_profile_translator.rs");
    for forbidden in [
        "ModelBinding",
        "ModelProvider",
        "ProviderRegistry",
        "ProviderAccount",
        "credential_ref",
        "base_url",
        "api_key",
        "model_path",
        "InferenceRouter",
        "start_run",
        "send_message",
    ] {
        assert_no_occurrence(&migration, forbidden);
    }
}

#[test]
fn public_agent_package_contract_has_no_concrete_model_binding() {
    let manifest = read("src/agent_package/manifest.rs");
    let reader = read("src/agent_package/reader.rs");
    let module = read("src/agent_package/mod.rs");
    assert!(!manifest.contains("PackageModelBinding"));
    assert!(!manifest.contains("credential_ref"));
    assert!(!manifest.contains("local_path"));
    assert!(!reader.contains("PackageModelBinding"));
    assert!(!reader.contains("crate::model"));
    assert!(!reader.contains("ModelProvider"));
    assert!(!module.contains("PackageModelBinding"));
}

#[test]
fn schema_v1_package_reader_returns_only_v2_portable_state() {
    let package = fixtures::schema_v1_package_with_provider_credential_and_local_path();
    let manifest = AgentPackageReader::from_fixture(package)
        .read_manifest(&PackagePath::fixture())
        .unwrap();

    assert_eq!(manifest.schema_version, 2);
    assert!(manifest.llm_slot.is_some());
    assert!(!serde_json::to_string(&manifest).unwrap().contains("credential_ref"));
    assert!(!serde_json::to_string(&manifest).unwrap().contains("local_path"));
    assert!(!serde_json::to_string(&manifest).unwrap().contains("provider_id"));
}

```

The two excluded files remain covered by targeted tests: the Profile translator forbids provider/runtime symbols, while the package reader may contain only the fixed schema-v1 wire literals inside its private translation function and may not export a concrete binding type. The general source scan may allow the literal `legacy_v1` only inside these migration boundaries, the provider-neutral migration saga, and their tests. Add Swift/App lint assertions for `RustRuntimeProviderConfiguration`, `providerId`, `simulatorProviders`, `setProvider`, direct Rust model send methods, and any use of the migration coordinator as a run starter.

- [ ] **Step 2: Run RED**

```bash
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml \
  --test lint llm_phase_five_architecture -- --nocapture
```

Expected: fail and enumerate the current allowlisted legacy modules and App bootstrap provider construction.

- [ ] **Step 3: Delete ownership in dependency order**

1. Remove App/Swift runtime provider configuration and C ABI entries.
2. Make `core::runtime` provider-free while preserving conversation/tool state and profile-backed Agent context.
3. Remove the production React model worker and global inference-settings dependencies.
4. Collapse Agent Profile and snapshot binding to V2-only.
5. Collapse the public Agent Package manifest/validator/installer/exporter to V2-only while keeping the reader's private schema-v1-to-V2 translation.
6. Delete Rust provider/model/inference modules and obsolete tests.
7. Delete the temporary allowlist.
8. Update Phase 2-4 lints to assert their surviving ownership/bridge invariants without requiring the deleted legacy route.
9. Narrow the retained Profile migration service/coordinator to translation and host-binding saga operations; delete only the V1 execution route.

Do not move deleted provider code into a `legacy` module. The translator may recognize the historical wire key `"model_binding"` only to skip that subtree; it may not recreate a typed binding. Test fakes implement only:

```rust
pub trait ExecutionModelClient: Send + Sync + 'static {
    fn next_turn(
        &self,
        run_id: &str,
        input: &ModelInputMessages,
    ) -> Result<ExecutionModelTurn, String>;
}
```

- [ ] **Step 4: Run GREEN on the final host-only tree**

```bash
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --lib
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test contract
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test integration
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml \
  --test lint llm_phase_four_architecture -- --nocapture
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml \
  --test lint llm_phase_five_architecture -- --nocapture
swift test --package-path toolkit --filter RustRuntimeClientContractTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:LocalAgentAppTests/LLMHostCompositionTests \
  -only-testing:LocalAgentAppTests/AgentRuntimeServiceTests
git diff --check
```

Expected: all pass; the host product path remains green while no production Rust or App source contains V1 execution or the removed ownership concepts. The provider-neutral Profile translator, private schema-v1 package translator, single migration record, coordinator, and direct-upgrade tests remain available.

- [ ] **Step 5: Commit**

```bash
git add rust-core/src rust-core/tests \
  toolkit/Sources/LocalAgentBridge toolkit/Sources/CLocalAgentRuntime \
  apps/LocalAgentApp/LocalAgentApp/Composition/AppBootstrapper.swift \
  apps/LocalAgentApp/LocalAgentApp/Runtime/LegacyLLMMigrationCoordinator.swift \
  apps/LocalAgentApp/LocalAgentAppTests/Runtime/LegacyLLMMigrationCoordinatorTests.swift \
  apps/LocalAgentApp/LocalAgentAppTests/Integration/RustRuntimeAppIntegrationTests.swift \
  scripts/run-llm-phase-5-contracts.sh
git commit -m "refactor: remove legacy rust llm product path"
```

---

### Task 10: Verify Direct Old-Version Upgrade and Complete Phase 5

**Files:**
- Modify: `docs/superpowers/specs/2026-07-10-swift-llm-system-design.md`
- Modify: `scripts/run-llm-phase-5-contracts.sh`
- Modify: `rust-core/README.md`

**Interfaces:**
- Task 6 owns translation and the single migration record; Task 7 owns final startup scanning/reconciliation; Tasks 8-9 append host-only and deletion gates. Task 10 adds no production behavior.
- The final runner invokes the Phase 4 runner exactly once with explicit Phase5→Phase4 UDID mapping. Phase 4 already supplies the complete Cargo, SwiftPM, C++, App-link, and Phase 1-4 regression gates against the current tree; Phase 5 appends only its architecture lint, product App groups, and source-deletion scan.

- [ ] **Step 1: Complete the single final runner**

`scripts/run-llm-phase-5-contracts.sh` must end as:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IPHONE_UDID="${LOCAL_AGENT_PHASE5_IPHONE_UDID:-}"
IPAD_UDID="${LOCAL_AGENT_PHASE5_IPAD_UDID:-}"
DERIVED_DATA="${LOCAL_AGENT_PHASE5_DERIVED_DATA:-/private/tmp/local-agent-phase5-derived}"
unset OPENAI_API_KEY ANTHROPIC_API_KEY GEMINI_API_KEY XAI_API_KEY
unset DEEPSEEK_API_KEY MINIMAX_API_KEY ZHIPUAI_API_KEY

LOCAL_AGENT_PHASE4_IPHONE_UDID="$IPHONE_UDID" \
LOCAL_AGENT_PHASE4_IPAD_UDID="$IPAD_UDID" \
  "$ROOT/scripts/run-llm-phase-4-contracts.sh"

CARGO_NET_OFFLINE=true cargo test --manifest-path "$ROOT/rust-core/Cargo.toml" \
  --test lint llm_phase_five_architecture -- --nocapture

for UDID in "$IPHONE_UDID" "$IPAD_UDID"; do
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
      -project "$ROOT/apps/LocalAgentApp/LocalAgentApp.xcodeproj" \
      -scheme LocalAgentApp \
      -destination "platform=iOS Simulator,id=$UDID" \
      -derivedDataPath "$DERIVED_DATA-$UDID" \
      -only-testing:LocalAgentAppTests/ModelCenterViewModelTests \
      -only-testing:LocalAgentAppTests/ProviderProfileEditorTests \
      -only-testing:LocalAgentAppTests/AppCloudApprovalBrokerTests \
      -only-testing:LocalAgentAppTests/HostBoundAgentPublishTests \
      -only-testing:LocalAgentAppTests/LegacyLLMMigrationCoordinatorTests \
      -only-testing:LocalAgentAppTests/LLMProductBootstrapTests \
      -only-testing:LocalAgentAppTests/AgentRuntimeServiceTests
done

if rg -n 'ModelRoutingClient|ProviderControllingRuntimeClient|LLMProductRunRouter|LEGACY_COMPATIBILITY_STREAMING_PATH' \
  "$ROOT/apps/LocalAgentApp/LocalAgentApp" "$ROOT/toolkit/Sources"; then
  echo "legacy Swift LLM product route remains" >&2
  exit 1
fi
```

No live provider smoke or real API key is part of this deterministic gate.

- [ ] **Step 2: Run final verification**

```bash
LOCAL_AGENT_PHASE5_IPHONE_UDID="<available iPhone UDID>" \
LOCAL_AGENT_PHASE5_IPAD_UDID="<available iPad UDID>" \
  scripts/run-llm-phase-5-contracts.sh
rg -n 'ModelProvider|ProviderRegistry|ProviderProfile|ProviderAccount|ModelBinding|InferenceRouter|LocalLLMProvider' \
  rust-core/src \
  --glob '!migration/legacy_agent_profile_translator.rs' \
  --glob '!agent_package/reader.rs'
rg -n 'start_run|send_message|InferenceRouter|ProviderRegistry|ModelBinding' \
  rust-core/src/migration/legacy_agent_profile_translator.rs \
  rust-core/src/agent_package/reader.rs
rg -n 'ModelRoutingClient|ProviderControllingRuntimeClient|RustRuntimeProviderConfiguration|simulatorProviders|LLMProductRunRouter' \
  apps/LocalAgentApp/LocalAgentApp toolkit/Sources
rg -n 'TO''DO|T''BD|FI''XME|place''holder|not imple''mented' \
  docs/superpowers/plans/2026-07-27-swift-llm-phase-5-product-adoption-legacy-removal-implementation.md
git diff --check
```

Expected:

- the final runner and direct old-store-to-final-Phase-5 fixture pass;
- the broad ownership scans return no matches outside the two isolated
  translators, and the targeted translator scan returns no execution or typed
  provider/model ownership;
- the unresolved-marker scan returns no matches;
- no legacy execution allowlist or V1 run route remains;
- the only retained legacy boundaries are the read-only Profile/package translators, single migration record, existing host-binding saga, and non-executing App coordinator;
- the translated successor preserves component, tool, memory, voice, and requirements bindings;
- local and cloud Agents run through the same host route;
- pending or failed translation displays recoverable migration UI without executing V1.

- [ ] **Step 3: Record implementation evidence**

Append a concise `Phase 5 implementation evidence` section to the design document stating:

- Model Center and Provider Profile UI are live on iPhone/iPad;
- Agent Builder publishes exact V2 host bindings and capability-checked parameters;
- pre-cutover migration tests preserved V1 on failure;
- the final tree removed all V1 product execution and Rust provider/model/inference ownership;
- the retained Rust translator migrates the complete portable Agent Profile graph directly from an old store;
- the private Agent Package reader translates known schema-v1 wire directly to the V2 public manifest;
- Swift owns local/cloud LLM selection and runtime configuration;
- `scripts/run-llm-phase-5-contracts.sh` is the deterministic Phase 5 evidence.

Do not rewrite the approved architecture or claim cloud multimodal support.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-07-10-swift-llm-system-design.md \
  scripts/run-llm-phase-5-contracts.sh rust-core/README.md
git commit -m "test: gate swift llm phase five"
```

---

## Plan Self-Review Checklist

- [ ] Every Phase 5 bullet in the 2026-07-10 design maps to at least one task and verification command.
- [ ] Phase 1-4 ownership, digest, preparation, bridge, cancellation, recovery, credential, egress, local runtime, and cloud adapter contracts are reused rather than redefined.
- [ ] The cloud initial turn has one authority: Rust's frozen preview.
- [ ] Phase 5 trusted tool display keys are always empty and approval uses generic localized tool copy; no signed-manifest subsystem is invented.
- [ ] One Swift SQLite store owns immutable target revisions and active host-binding projections.
- [ ] Swift `LLMStore` V2→V3 atomically converts the Provider Profile lifecycle envelope; Rust runtime V2→V3 atomically creates Profile/component/migration tables.
- [ ] Both V3 migrations cover populated V2 reopen, every rollback boundary, and future-version rejection.
- [ ] Model Center manages targets and readiness; it has no global provider selection.
- [ ] Agent Builder selects one exact target revision and writes capability-checked semantic overrides into `AgentHostConfiguration`.
- [ ] API key text has no persistence or readback path outside Keychain.
- [ ] Migration creates a hidden V2 successor and leaves V1 unchanged on every pre-completion failure.
- [ ] Every recognized legacy source uses Rust-computed `legacy-profile-source:v1` and has exactly one durable `pending`, `migrated`, or `archived` migration record.
- [ ] Phase 5 is one implementation/cutover; the plan contains no A/B product-release split.
- [ ] The final tree leaves no permanent dual route or V1 execution.
- [ ] The final binary passes a direct old-store upgrade without requiring an intermediate app version.
- [ ] The retained Rust translator is read-only, provider-neutral, non-runnable, and preserves the complete component/tool/memory/voice/requirements graph while rejecting secret/path material.
- [ ] The retained Agent Package reader recognizes only known schema-v1 wire, returns a V2 manifest immediately, and exports no `PackageModelBinding`.
- [ ] Rust production code has no Provider Profile, provider registry, concrete model binding, local provider, model catalog, generation parameter, or inference router ownership.
- [ ] C++ remains linked and used only by `LocalAgentLLMLocal`.
- [ ] Local files stay on disk until explicit deletion and only the active local model enters RAM.
- [ ] Seven cloud presets remain explicit; no generic provider wire bypass is introduced.
- [ ] Unsupported capabilities and parameters fail closed; no model/provider/local-cloud fallback exists.
- [ ] Durable bindings carry no process epoch; new preparations/sessions/commands/events use the current launch epoch.
- [ ] The Phase 5 runner maps both Phase 5 UDIDs into Phase 4 once and appends only Phase 5-specific gates.
- [ ] Task 7's pre-cutover gate and Task 10's final gate both test iPhone and iPad.
- [ ] Every task contains exact files, interfaces, RED/GREEN commands, expected outcomes, and a commit.
- [ ] No step contains an unresolved work marker or vague instruction such as “add tests.”
- [ ] `git diff --check` passes after every task.
