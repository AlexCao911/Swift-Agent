# Swift LLM Phase 4 Host Session Bridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `host_slot_v2` runnable by connecting the provider-neutral Rust Agent worker to opaque Swift-owned local or cloud LLM sessions through a durable, sequenced, restart-safe command/event bridge while preserving the legacy route until Phase 5.

**Architecture:** Add a `LocalAgentLLMHost` Swift target as the sole composition layer above `LocalAgentBridge`, `LocalAgentLLMLocal`, and `LocalAgentLLMCloud`. Rust establishes one `agent.sqlite` runtime aggregate as the only persisted authority for the complete V2 run snapshot, Agent execution events/output, worker, tool progress, outbox, event receipts, preparation/cross-link state, and global lease; every transition that spans those records commits through one repository transaction. Swift copies and deduplicates commands, installs a cleanup owner before registration can succeed, owns opaque sessions and provider-private continuation, and submits only normalized events through an independent FFI entry. `legacy_v1` continues through the current synchronous route, while `host_slot_v2` can start only through authoritative Rust preview → Swift reserve/cleanup-owner registration → Rust registration → Swift open → Rust commit.

**Tech Stack:** Rust 2021, `serde`, `rusqlite`, C ABI vtable callbacks, Swift 6, SwiftPM, Foundation actors and `AsyncSequence`, Apple SQLite3, Security random bytes, existing C++ v2 inference boundary, Swift Testing, Cargo tests, Xcode iOS Simulator tests, and shell contract runners.

**Design authority:** `docs/superpowers/specs/2026-07-10-swift-llm-system-design.md`, especially Two-Phase Run Preparation, Rust-Swift LLM Client Port, Durable Host Command Outbox, Independent Event Submission, Backpressure, Cancellation Race, Retry and Recovery, Testing Strategy, and Phase 4 migration sections. Phase 3.1 evidence in the same document remains authoritative for cloud continuation and loss-detecting direct streams.

## Global Constraints

- Work only in `/Users/alexandercou/Projects/Alex-agent/.worktrees/llm-runtime-provider-design/local-ios-agent` on `codex/llm-runtime-provider-design`.
- Execute sequentially with one Agent; do not dispatch subagents or implement tasks concurrently.
- Use strict RED/GREEN/REFACTOR for every behavior change. No production edit is allowed before the focused test fails for the intended reason.
- Target iOS/iPadOS 17+ and macOS 14+ test hosts.
- Rust remains the provider-neutral Agent kernel. No Rust DTO, worker, store, FFI entry, diagnostic, or test fixture may contain Provider Profile, origin, Base URL, credential, API key, provider model ID, provider request field, adapter kind, local installation path, or C++ engine detail.
- C++ remains local-inference-only. Phase 4 changes no C++ ABI or model format behavior.
- Swift owns every local/cloud target, capability observation, resolved parameter mapping, credential, egress decision, provider-private continuation, backend session, and opaque session handle.
- A persisted V2 `ResolvedRunSnapshot` uses a tagged `host_slot_v2` binding containing only Rust-frozen `AgentLLMRequirements` and an opaque host-binding cross-link. Legacy provider account/provider/model fields and legacy credential-readiness state are structurally impossible in the V2 variant.
- `egress-attestation:v1` has exactly one canonical `HostAttestationV1Document`, matching the existing cloud fixture. Cloud, local `not_applicable`, Swift FFI, and Rust validation use the same production builders; the earlier Rust-only document shape is deleted rather than versioned under the same domain.
- Exactly one App-created 256-bit `HostProcessEpoch` is injected into Rust, `LocalAgentLLMHost`, local Swift, and cloud Swift. No subsystem may generate a second epoch.
- At most one legacy or V2 Agent run/preparation owns the durable global run lease. At most one Swift LLM session and one generation are active.
- `agent.sqlite` is the sole Rust transaction authority for V2 snapshot, Agent execution events/output, worker/accumulator/tool progress, outbox, receipts, preparation/cross-link rows, and the global lease. The current `.agent-os` sidecar is migrated transactionally and is never an active second authority after Phase 4 bootstrap.
- Phase C, normalized event application, logical completion, lifecycle close, and old-epoch recovery each use one aggregate repository operation. A receipt cannot commit before the worker/accumulator/output/event/next-outbox transition it represents.
- Logical Agent outcome and physical LLM resource lifecycle are orthogonal. Output may be readable while cleanup is pending, but only an accepted exact `session_closed` receipt or the Rust old-epoch recovery transaction reaches fully closed and releases the lease.
- Swift installs a `PreparedSessionCleanupOwner` in the session registry before invoking Rust registration. Registration success can therefore always be compensated during opening, before commit, or while the commit FFI call is still returning.
- Session handles and event IDs contain at least 128 bits of CSPRNG output, are epoch-bound, and are never reused. Closed handles remain tombstoned for the epoch.
- Command IDs contain at least 128 bits of CSPRNG output and are globally unique. Preparation leases renew in five-minute increments for at most thirty minutes; a ready host attestation is valid for two minutes.
- Rust command state transition and outbox insertion commit in one SQLite transaction. An in-memory callback without a committed outbox row is forbidden.
- Command delivery uses a synchronous `copied | backpressure | host_unavailable` receipt followed by an asynchronous `accepted | rejected` acknowledgement. Acknowledgement never proves backend start, backend stop, or session close.
- Command sequence is monotonic per session. Duplicate identity requires the same command ID, sequence, and full envelope digest.
- Event sequence is monotonic per session. Rust retains accepted and terminally ignored receipts until close; only `backpressure` asks Swift to retry the exact envelope.
- Rust inbound limits are exactly 256 events and 2 MiB per session, with low-water notification below both 128 events and 1 MiB. A single event above 2 MiB fails with `llm.event.payload_too_large`.
- Start/resume/cancel/close command acknowledgement timeout is ten seconds. Backend cancel confirmation and session close confirmation each have a separate ten-second watchdog. User egress approval time is excluded from the operation-start watchdog.
- A generation terminal distinguishes `final_response` from `tool_calls_ready`. V1 executes a complete multi-call batch sequentially in first-appearance order and sends one ordered result batch in one resume command.
- Every start/resume command carries the complete semantic payload and a `GenerationDisclosure`. Cloud encoding accepts only a recomputed sealed turn; expanded tool-result sensitivity pauses before the affected request.
- Provider-private response IDs, reasoning/signature items, raw thinking, request bodies, credentials, native pointers, and absolute paths never cross Rust FFI and are never persisted by Rust.
- No automatic model/provider/local-cloud fallback is allowed. A route switch affects only the next run.
- Process restart never reconstructs an LLM continuation. It interrupts old-epoch legacy/V2 runs before exposing pending tools or approvals, cancels old outboxes, releases the old lease, and rejects late work with `execution.continuation_expired`.
- The production dispatcher is a runtime-owned scheduler: install/reopen/commit/ack/event wake it, persisted deadlines wake without another FFI call, App suspend/resume is explicit, and runtime free stops intake, quiesces callbacks, joins the dispatcher, then releases the retained Swift context.
- App routing uses a versioned Rust `ProfileExecutionRoute` for the exact profile revision. Neither Swift nor Rust guesses a route or falls back when a route tag/revision is stale.
- `legacy_v1` remains runnable and tagged during Phase 4. Phase 5 alone removes the legacy resolver, provider path, writer, and architecture allowlist.
- Each task ends with focused tests, its required regression gate, `git diff --check`, and one reviewable commit.

## Scope and Non-Goals

Phase 4 is one vertical migration: preparation, command delivery, normalized event ingestion, tool continuation, cancellation/close, recovery, and route selection must compose before `host_slot_v2` is enabled. It does not add Model Center UI, Provider Profile UI, cloud attachment byte upload, persisted provider continuation, multi-Agent concurrency, speculative parallel tool execution, or Phase 5 legacy removal.

## File Structure

The implementation adds one Swift composition target and keeps protocol, storage, and backend responsibilities separate:

```text
contracts/canonical-digest-v1/fixtures/
  egress-subject-local-v1.json
  egress-attestation-local-v1.json
  host-command-payload-v1.json
  host-command-envelope-v1.json
  llm-event-envelope-v1.json
  llm-event-receipt-v1.json
  host-tool-effect-result-v1.json

rust-core/src/llm_contracts/
  host_command.rs                 provider-neutral command payload/envelope/ack
  llm_event.rs                    normalized event envelope/result/receipt
  host_worker.rs                  durable worker/session/watchdog state
rust-core/src/execution/
  host_llm_worker.rs              resumable V2 Agent worker transitions
  host_llm_dispatcher.rs          runtime-owned scheduler and serial dispatch
rust-core/src/storage/
  runtime_state.rs                unified runtime aggregate repository contract
  sqlite_runtime_state.rs         sole agent.sqlite transaction authority
rust-core/src/storage/agent_os_state/
  mod.rs                          compatibility views over runtime aggregate
  in_memory.rs                    transaction-equivalent test repository
  sqlite.rs                       sidecar migration/compatibility adapter only
rust-core/src/run_snapshot/
  snapshot.rs                     tagged legacy_v1/host_slot_v2 snapshot
  resolved_bindings.rs            provider-neutral V2 host slot binding
  preparation_preview.rs          exact semantic payload/disclosure documents
  snapshot_service.rs             Phase C atomic commit into V2 worker
rust-core/src/ffi_bridge.rs        vtable registration, command ack, event entry
rust-core/tests/contract/
  host_llm_contracts.rs
  host_llm_outbox.rs
  host_llm_worker.rs
  host_llm_event_ingress.rs
  host_llm_recovery.rs
  runtime_state_migration.rs
rust-core/tests/integration/
  host_llm_ffi.rs
  host_llm_product_path.rs
rust-core/tests/lint/
  llm_phase_four_architecture.rs

toolkit/Sources/CLocalAgentRuntime/include/CLocalAgentRuntime.h
toolkit/Sources/CLocalAgentRuntime/CLocalAgentRuntime.c
toolkit/Sources/LocalAgentLLMContracts/
  HostAttestationV1.swift         sole egress-attestation:v1 document/builder
  LLMHostCommand.swift            cross-language command wire contract
  LLMEventEnvelope.swift          cross-language event wire/result contract
toolkit/Sources/LocalAgentBridge/
  RustLLMHostPort.swift           safe Swift wrapper for the C vtable/FFI entries
  AgentOSDTOs.swift               complete preparation/attestation DTOs
toolkit/Sources/LocalAgentLLMHost/
  LLMHostRuntime.swift            bounded command actor and public host lifecycle
  LLMHostCommandInbox.swift       synchronous bounded copy queue for the C callback
  LLMHostSessionRegistry.swift    epoch-bound handles, ledger, tombstones
  PreparedSessionCleanupOwner.swift partial-resource cleanup before/open/commit
  LLMHostSessionDriver.swift      local/cloud type-erased backend seam
  LLMEventSequencer.swift         event ID/sequence/retry ownership
  LLMRunPreparationBridge.swift   preview/reserve/register/open/commit/abort saga
  LocalHostSessionDriver.swift    local runtime adapter
  CloudHostSessionDriver.swift    cloud runtime adapter
  HostToolEffectLedger.swift      effect replay/outcome-unknown guard
toolkit/Tests/LocalAgentLLMHostTests/
  LLMHostContractTests.swift
  LLMHostRuntimeTests.swift
  LLMHostPreparationTests.swift
  LLMHostEventSequencerTests.swift
  LLMHostToolLoopTests.swift
  LLMHostCancellationTests.swift
  LLMHostRecoveryTests.swift
  LLMHostProductPathTests.swift

apps/LocalAgentApp/LocalAgentApp/Composition/AppBootstrapper.swift
apps/LocalAgentApp/LocalAgentApp/App/LocalAgentApp.swift
apps/LocalAgentApp/LocalAgentApp/Runtime/AgentRuntimeService.swift
apps/LocalAgentApp/LocalAgentApp/Tools/NativeHostToolDriver.swift
apps/LocalAgentApp/LocalAgentAppTests/LLMHostCompositionTests.swift
scripts/run-llm-phase-4-contracts.sh
```

`LocalAgentLLMHost` depends on `LocalAgentBridge`, `LocalAgentLLMContracts`, `LocalAgentLLMCore`, `LocalAgentLLMLocal`, and `LocalAgentLLMCloud`. Neither local nor cloud imports the host target or each other. `LocalAgentBridge` remains the low-level Rust owner and does not acquire backend semantics.

---

### Task 1: Freeze Host Commands, Events, and the Sole Host Attestation Document

**Files:**
- Create: `toolkit/Sources/LocalAgentLLMContracts/LLMHostCommand.swift`
- Create: `toolkit/Sources/LocalAgentLLMContracts/LLMEventEnvelope.swift`
- Create: `toolkit/Sources/LocalAgentLLMContracts/HostAttestationV1.swift`
- Modify: `toolkit/Sources/LocalAgentLLMContracts/LLMBackendEvent.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCloud/CloudLLMRuntime.swift`
- Modify: `toolkit/Tests/LocalAgentLLMCloudTests/CloudLLMRuntimeTests.swift`
- Modify: `toolkit/Sources/LocalAgentBridge/AgentOSDTOs.swift`
- Modify: `toolkit/Tests/LocalAgentBridgeTests/RustRuntimeClientContractTests.swift`
- Create: `rust-core/src/llm_contracts/host_command.rs`
- Create: `rust-core/src/llm_contracts/llm_event.rs`
- Modify: `rust-core/src/llm_contracts/preparation.rs`
- Modify: `rust-core/src/llm_contracts/prepared_start_validator.rs`
- Modify: `rust-core/src/llm_contracts/mod.rs`
- Create: `contracts/canonical-digest-v1/fixtures/egress-subject-local-v1.json`
- Create: `contracts/canonical-digest-v1/fixtures/egress-attestation-local-v1.json`
- Create: `contracts/canonical-digest-v1/fixtures/host-command-payload-v1.json`
- Create: `contracts/canonical-digest-v1/fixtures/host-command-envelope-v1.json`
- Create: `contracts/canonical-digest-v1/fixtures/llm-event-envelope-v1.json`
- Create: `contracts/canonical-digest-v1/fixtures/llm-event-receipt-v1.json`
- Create: `contracts/canonical-digest-v1/fixtures/host-tool-effect-result-v1.json`
- Modify: `toolkit/Tests/LocalAgentLLMContractsTests/CanonicalDigestTests.swift`
- Create: `toolkit/Tests/LocalAgentLLMContractsTests/LLMHostContractTests.swift`
- Modify: `rust-core/tests/contract.rs`
- Create: `rust-core/tests/contract/host_llm_contracts.rs`
- Modify: `rust-core/tests/contract/canonical_digest_v1.rs`
- Modify: `rust-core/tests/integration/ffi_bridge.rs`

**Interfaces:**
- Produces `HostCommandEnvelope`, `HostCommandPayload`, `HostCommandKind`, `HostCommandCopyReceipt`, and `HostCommandAcknowledgement` with identical snake-case JSON in Swift and Rust.
- Produces a tagged `HostDispatchEnvelope` carrying either a regular run command or the existing `PreparedSessionCleanupEnvelope`; preparation cleanup never pretends that its proposed run was committed.
- Produces `LLMEventEnvelope`, `LLMEventPayload`, `LLMEventSubmissionResult`, and `LLMEventReceiptDisposition` with the exact result matrix from the design.
- `HostCommandPayload` contains canonical input, complete tool schema/source revisions, attachment identity/revision references, normalized semantic history, and the complete ordered tool-result batch; it contains no provider wire/private state.
- Extends normalized backend events with explicit start/failure/session-close lifecycle data without making local/cloud adapters Codable wire owners.
- Produces one field-for-field `HostAttestationV1Document` in Swift and Rust for the already registered `egress-attestation:v1` domain. Its only fields are `schema_version`, preparation/run/session/snapshot identity, prepared registration digest, binding tuple, requirements/disclosure/capability/parameter digests, host epoch, canonical UTC-millisecond expiry, and opaque egress-subject digest.
- Replaces the private cloud `cloudEgressAttestationDigest` function and Rust `HostAttestation::expected_egress_digest` local `Document` with the shared production builders. The obsolete shape containing `preparation_binding_digest`, grant ID, data classes, highest sensitivity, and `opaque_subject_digest` is deleted from this digest domain; those public disclosure claims remain separately validated against the frozen preparation.
- `HostAttestationDTO` carries one `document: HostAttestationV1Document`, its `egressAttestationDigest`, the full provider-neutral capability attestation, and separately validated frozen disclosure/grant claims. It removes `expirationMillis` and the old flattened partial-attestation fields. Document coding keys match the fixture, including `session_id` mapped from `PreparedSessionRegistration.session_handle`.
- Freezes field-based `HostRunHandleDTO`, `PreparedSessionCleanupIdentityDTO`, and `PreparationReconciliationDTO { status, handle?, cleanup_identity? }` in Swift plus matching Rust wire records. Task 3 supplies the repository behavior; Tasks 5 and 7 consume these already-frozen types.

- [x] **Step 1: Write failing golden-contract tests**

Add Swift and Rust tests that decode the same fixtures, invoke the real production builders, and reject an envelope/attestation when any command/event/attestation identity, sequence, turn, payload digest, disclosure digest, expiry, or epoch changes. Lock the result cases, their sequence behavior, and both egress subjects:

```swift
@Test func eventResultMatrixIsExhaustive() {
    #expect(LLMEventSubmissionResult.accepted.sequenceEffect == .consumeNew)
    #expect(LLMEventSubmissionResult.duplicate.sequenceEffect == .alreadyConsumed)
    #expect(LLMEventSubmissionResult.backpressure.sequenceEffect == .doNotConsume)
    #expect(LLMEventSubmissionResult.turnTerminal.sequenceEffect == .consumeNew)
    #expect(LLMEventSubmissionResult.generationTerminal.sequenceEffect == .consumeNew)
    #expect(LLMEventSubmissionResult.staleSession.retrySameEnvelope == false)
}

@Test func commandFixtureContainsOnlySemanticPayload() throws {
    let envelope = try fixture(HostCommandEnvelope.self, "host-command-envelope-v1.json")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let bytes = try encoder.encode(envelope)
    for forbidden in ["api_key", "base_url", "provider_profile", "model_path", "response_id"] {
        #expect(!String(decoding: bytes, as: UTF8.self).contains(forbidden))
    }
    #expect(try envelope.recomputedDigest() == envelope.commandEnvelopeDigest)
}

@Test func productionHostAttestationBuilderMatchesCloudAndLocalFixtures() throws {
    let cloud = try fixtureDocument("egress-attestation-cloud-v1.json")
    let local = try fixtureDocument("egress-attestation-local-v1.json")
    #expect(try HostAttestationV1Document(fixture: cloud).computedDigest().hex
            == "9de220bd518ebd4ee705a14b26737fc5b7cea4f1a1b378a112e013c12d404822")
    #expect(try HostAttestationV1Document(fixture: local).computedDigest().hex
            == "58ef0e04243b5a3b4f324869b60de728ba04928eec536f8d72eff217132c4034")
}
```

The local subject fixture is exactly `{"kind":"not_applicable","reason":"local_inference","schema_version":"1"}` with digest `36eb3f18dc9339783b8bd44cf672a39d02fabad80b46d63c8bd29ba3a884317e`. The local attestation uses `prep-local-1`, `run-local-1`, `session-local-1`, `snapshot-local-1`, `binding-local-1`, revision `5`, the same `a`/`b`/`c`/`d`/`e` fixture digests and expiry/epoch as the cloud fixture, and that local subject digest; its expected digest is `58ef0e04243b5a3b4f324869b60de728ba04928eec536f8d72eff217132c4034`. Rust must construct both through the real `HostAttestation { document, ... }.expected_egress_digest()` path, not generic `serde_json::Value`, and match the same digests. Also assert `final_response` requires no call IDs and `tool_calls_ready` requires a non-empty unique ordered list plus `finish_reason: tool_calls`.

- [x] **Step 2: Run RED**

```bash
swift test --package-path toolkit --filter LLMHostContractTests
swift test --package-path toolkit --filter CanonicalDigestTests
swift test --package-path toolkit --filter CloudLLMRuntimeTests
swift test --package-path toolkit --filter RustRuntimeClientContractTests
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test contract host_llm_contracts -- --nocapture
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test integration ffi_bridge -- --nocapture
```

Expected: fail because the host command/event types are absent, Rust and Swift production attestation builders disagree on `egress-attestation:v1`, and the local `not_applicable` fixtures do not exist.

- [x] **Step 3: Add explicit tagged wire types and digest builders**

Use a field-based wire payload rather than relying on Swift associated-enum synthesis:

```swift
public enum HostCommandKind: String, Codable, Sendable {
    case startGeneration = "start_generation"
    case resumeGeneration = "resume_generation"
    case cancelGeneration = "cancel_generation"
    case closeSession = "close_session"
    case capacityAvailable = "capacity_available"
}

public struct HostCommandEnvelope: Codable, Equatable, Sendable {
    public let schemaVersion: UInt32
    public let commandID: String
    public let runID: String
    public let sessionHandle: String
    public let hostProcessEpoch: String
    public let commandSequence: UInt64
    public let generationTurnID: String?
    public let kind: HostCommandKind
    public let payloadDigest: String
    public let disclosureDigest: String?
    public let commandEnvelopeDigest: String
    public let disclosure: GenerationDisclosure?
    public let payload: HostCommandPayload
}

public enum LLMEventSubmissionResult: String, Codable, Sendable {
    case accepted, duplicate, backpressure
    case staleSession = "stale_session"
    case turnTerminal = "turn_terminal"
    case generationTerminal = "generation_terminal"
    case closedSession = "closed_session"
    case sequenceGap = "sequence_gap"
    case sequenceConflict = "sequence_conflict"
    case identityConflict = "identity_conflict"
    case invalidEnvelope = "invalid_envelope"
    case payloadTooLarge = "payload_too_large"
}

public struct HostAttestationV1Document: Codable, Equatable, Sendable {
    public let schemaVersion: String                 // exactly "1"
    public let preparationID: String
    public let proposedRunID: String
    public let sessionID: String
    public let swiftSnapshotID: String
    public let preparedSessionRegistrationDigest: String
    public let bindingID: String
    public let bindingRevision: String
    public let bindingHash: String
    public let requirementsHash: String
    public let disclosureDigest: String
    public let capabilitySnapshotDigest: String
    public let resolvedParametersDigest: String
    public let hostProcessEpoch: String
    public let expiresAt: String                     // YYYY-MM-DDTHH:mm:ss.SSSZ
    public let opaqueEgressSubjectDigest: String

    public func computedDigest() throws -> CanonicalDigest

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case preparationID = "preparation_id"
        case proposedRunID = "proposed_run_id"
        case sessionID = "session_id"
        case swiftSnapshotID = "swift_snapshot_id"
        case preparedSessionRegistrationDigest = "prepared_session_registration_digest"
        case bindingID = "binding_id"
        case bindingRevision = "binding_revision"
        case bindingHash = "binding_hash"
        case requirementsHash = "requirements_hash"
        case disclosureDigest = "disclosure_digest"
        case capabilitySnapshotDigest = "capability_snapshot_digest"
        case resolvedParametersDigest = "resolved_parameters_digest"
        case hostProcessEpoch = "host_process_epoch"
        case expiresAt = "expires_at"
        case opaqueEgressSubjectDigest = "opaque_egress_subject_digest"
    }
}

public struct HostAttestationDTO: Codable, Equatable, Sendable {
    public let document: HostAttestationV1Document
    public let egressAttestationDigest: String
    public let preparationBindingDigest: String
    public let disclosureGrantID: String
    public let dataClasses: [String: Bool]
    public let highestSensitivity: String
    public let capabilityAttestation: PreparedCapabilityAttestationDTO
    private enum CodingKeys: String, CodingKey {
        case document
        case egressAttestationDigest = "egress_attestation_digest"
        case preparationBindingDigest = "preparation_binding_digest"
        case disclosureGrantID = "disclosure_grant_id"
        case dataClasses = "data_classes"
        case highestSensitivity = "highest_sensitivity"
        case capabilityAttestation = "capability_attestation"
    }
}

public struct HostRunHandleDTO: Codable, Equatable, Sendable {
    public let runID: String
    public let sessionHandle: String
    public let firstCommandID: String
    private enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case sessionHandle = "session_handle"
        case firstCommandID = "first_command_id"
    }
}

public struct PreparedSessionCleanupIdentityDTO: Codable, Equatable, Sendable {
    public let cleanupCommandID: String
    public let cleanupCommandSequence: UInt64
    public let preparationID: String
    public let proposedRunID: String
    public let sessionHandle: String
    public let registrationDigest: String
    public let hostProcessEpoch: String
    private enum CodingKeys: String, CodingKey {
        case cleanupCommandID = "cleanup_command_id"
        case cleanupCommandSequence = "cleanup_command_sequence"
        case preparationID = "preparation_id"
        case proposedRunID = "proposed_run_id"
        case sessionHandle = "session_handle"
        case registrationDigest = "registration_digest"
        case hostProcessEpoch = "host_process_epoch"
    }
}

public enum PreparationReconciliationStatusDTO: String, Codable, Sendable {
    case committed, pending, aborting
}

public struct PreparationReconciliationDTO: Codable, Equatable, Sendable {
    public let status: PreparationReconciliationStatusDTO
    public let handle: HostRunHandleDTO?
    public let cleanupIdentity: PreparedSessionCleanupIdentityDTO?
    private enum CodingKeys: String, CodingKey {
        case status, handle
        case cleanupIdentity = "cleanup_identity"
    }
}
```

`HostAttestationV1Document` lives in `LocalAgentLLMContracts`. `HostAttestationDTO`, `HostRunHandleDTO`, `PreparedSessionCleanupIdentityDTO`, and `PreparationReconciliationDTO` live in `LocalAgentBridge/AgentOSDTOs.swift`; they import the shared document and never duplicate its fields.

Register no new domains: the five bridge domains and `egress-subject:v1`/`egress-attestation:v1` already exist in `contracts/canonical-digest-v1/registry.json`. Keep the existing cloud fixture unchanged, add the exact local fixtures above, and make Swift/Rust production builders recompute them with `CanonicalDigestV1`; do not hash ordinary encoder byte order.

All Swift DTOs above use explicit snake-case `CodingKeys`; the reconciliation decoder enforces `committed => handle only`, `pending => neither payload`, and `aborting => cleanup_identity only`. Rust defines matching `#[serde(deny_unknown_fields)]` records and a `#[serde(tag = "status", rename_all = "snake_case")]` reconciliation enum with struct variants.

Rust defines the same `HostAttestationV1Document` with `#[serde(deny_unknown_fields)]`. `HostAttestation` contains that document, `egress_attestation_digest`, `preparation_binding_digest`, the full `PreparedCapabilityAttestation`, and the separately validated disclosure grant/data-class/highest-sensitivity claims; it no longer synthesizes a second document from those outer claims. `HostAttestation::expected_egress_digest()` delegates exclusively to `document.expected_digest()`. Add one strict canonical UTC-millisecond parser for `expires_at`; reject offsets, missing milliseconds, or non-canonical strings and compare the parsed value with `now_millis`. Remove the legacy Swift golden test and Rust/FFI helper that build the incompatible seven-field document. `PreparedStartValidator` separately checks frozen data classes/highest sensitivity/grant presence, then binds the unique attestation document to the registration, requirements hash, capability snapshot digest, resolved parameter digest, epoch, and expiry.

- [x] **Step 4: Run GREEN and canonical regressions**

```bash
swift test --package-path toolkit --filter LLMHostContractTests
swift test --package-path toolkit --filter CanonicalDigestTests
swift test --package-path toolkit --filter CloudLLMRuntimeTests
swift test --package-path toolkit --filter RustRuntimeClientContractTests
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test contract host_llm_contracts -- --nocapture
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test contract canonical_digest_v1 -- --nocapture
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test integration ffi_bridge -- --nocapture
git diff --check
```

Expected: both languages and the real cloud builder accept the same command/event/attestation bytes and digests; the local `not_applicable` builder matches its fixture; the obsolete same-domain shape and every field mutation are rejected.

- [x] **Step 5: Commit**

```bash
git add contracts/canonical-digest-v1 toolkit/Sources/LocalAgentLLMContracts \
  toolkit/Sources/LocalAgentLLMCloud toolkit/Sources/LocalAgentBridge/AgentOSDTOs.swift \
  toolkit/Tests/LocalAgentLLMContractsTests toolkit/Tests/LocalAgentLLMCloudTests \
  toolkit/Tests/LocalAgentBridgeTests/RustRuntimeClientContractTests.swift \
  rust-core/src/llm_contracts rust-core/tests/contract.rs \
  rust-core/tests/contract/host_llm_contracts.rs \
  rust-core/tests/contract/canonical_digest_v1.rs rust-core/tests/integration/ffi_bridge.rs
git commit -m "feat: freeze host llm bridge attestation contracts"
```

---

### Task 2: Establish the Unified Rust Runtime Aggregate and Durable Outbox

**Files:**
- Create: `rust-core/src/llm_contracts/host_worker.rs`
- Modify: `rust-core/src/llm_contracts/mod.rs`
- Create: `rust-core/src/storage/runtime_state.rs`
- Create: `rust-core/src/storage/sqlite_runtime_state.rs`
- Modify: `rust-core/src/storage/mod.rs`
- Modify: `rust-core/src/storage/event_store.rs`
- Modify: `rust-core/src/storage/agent_os_state/mod.rs`
- Modify: `rust-core/src/storage/agent_os_state/in_memory.rs`
- Modify: `rust-core/src/ffi_bridge.rs`
- Modify: `rust-core/src/storage/agent_os_state/sqlite.rs`
- Modify: `rust-core/src/execution/event_log.rs`
- Modify: `rust-core/src/run_snapshot/resolver.rs`
- Create: `rust-core/tests/contract/host_llm_outbox.rs`
- Create: `rust-core/tests/contract/runtime_state_migration.rs`
- Modify: `rust-core/tests/contract.rs`

**Interfaces:**
- Produces `HostExecutionPhase`, `LogicalRunOutcome`, `ResourceLifecycle`, `HostWorkerRecord`, `HostSessionRecord`, `HostCommandOutboxRow`, `LLMEventReceipt`, and `HostWatchdogKind`.
- Adds `UnifiedRuntimeStateRepository` as the only write authority for V2. Its aggregate methods include `commit_prepared_host_run`, `transition_and_enqueue`, `record_copy_receipt`, `acknowledge_command`, `apply_event_transactionally`, `begin_terminal_close`, and `recover_run_for_epoch`.
- The repository owns one `rusqlite::Connection` to `agent.sqlite`. Existing event-store, snapshot, and Agent OS APIs become read/write views over this same owner; no Phase 4 call composes transactions across separate repository objects or connections.
- `commit_prepared_host_run` consumes the preparation token, promotes the same global lease, stores the complete canonical V2 run snapshot plus initial Agent execution event and worker, and inserts sequence 1 `start_generation` in one transaction.
- `apply_event_transactionally` is the only event mutation path and atomically persists receipt/expected sequence, event/turn accumulator, worker transition, formal Agent run/output event, optional tool progress, optional next outbox row, and any lease/lifecycle transition.
- `recover_run_for_epoch` is the only restart mutation path and atomically appends the interruption event, invalidates pending continuations/tool approvals/outbox/cross-link, records the epoch-ended close disposition, and releases the lease.
- Outbox payload is retained only until asynchronous command acceptance; after acceptance it is redacted while ID/sequence/digests/status remain.
- A later start/resume waits for asynchronous acceptance of the earlier lifecycle command. Cancel/close may follow an earlier `copied` receipt, and an atomically cancelled never-copied sequence is released only for its replacement cleanup command.
- Phase 4 bootstrap transactionally imports the current `agent.sqlite.agent-os` tables into `agent.sqlite`, records a migration marker and source digest, and activates the unified store only after all rows validate. A failed or interrupted migration leaves the old sidecar readable and does not expose a half-migrated runtime; after successful activation, the sidecar is never opened as an authority.

- [x] **Step 1: Write failing aggregate, migration, CAS, and crash-injection tests**

Create repository tests for in-memory and SQLite implementations. Start migration tests from realistic `agent.sqlite` plus `agent.sqlite.agent-os` fixtures. Require zero partial rows after every injected failure, exact replay after reopen, monotonic sequences, one winner under concurrent commit, and no active sidecar authority after successful migration:

```rust
#[test]
fn worker_transition_and_outbox_are_one_transaction() {
    let mut store = sqlite_fixture();
    store.inject_failure_after_worker_write();
    let error = store.transition_and_enqueue(transition_fixture()).unwrap_err();
    assert_eq!(error.code(), "llm.command.transaction_failed");
    assert!(store.host_worker("run-v2").unwrap().is_none());
    assert!(store.pending_host_commands().unwrap().is_empty());
}

#[test]
fn phase_c_failure_cannot_leave_snapshot_without_worker_event_or_outbox() {
    for failure_point in RuntimeAggregateFailurePoint::phase_c_points() {
        let mut store = sqlite_fixture();
        store.inject_failure(failure_point);
        assert!(store.commit_prepared_host_run(commit_fixture()).is_err());
        assert_eq!(store.inspect_v2_aggregate("run-v2"), EmptyAggregate::ALL);
        assert_eq!(store.global_lease().state(), LeaseState::Preparing);
    }
}

#[test]
fn sidecar_migration_is_atomic_and_not_a_second_authority() {
    let fixture = legacy_split_database_fixture();
    let store = SqliteRuntimeStateStore::open(fixture.agent_sqlite()).unwrap();
    assert_eq!(store.migration_state(), MigrationState::UnifiedV2Active);
    assert_eq!(store.preparation("prep-1").unwrap().unwrap().generation(), 3);
    fixture.mutate_sidecar_after_activation();
    assert_eq!(store.preparation("prep-1").unwrap().unwrap().generation(), 3);
}

#[test]
fn acknowledgement_redacts_payload_but_keeps_identity() {
    let mut store = sqlite_fixture_with_start();
    store.acknowledge_command(accepted_ack()).unwrap();
    let row = store.host_command("command-1").unwrap().unwrap();
    assert!(row.payload().is_none());
    assert_eq!(row.command_envelope_digest(), fixture_envelope_digest());
}
```

Add reopen tests proving accepted/terminally ignored event receipts persist, while `backpressure` creates no receipt and consumes no sequence. Add schema-version/future-version rejection, rollback-and-retry migration, and in-memory transaction-equivalence tests.

- [x] **Step 2: Run RED**

```bash
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test contract host_llm_outbox -- --nocapture
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test contract runtime_state_migration -- --nocapture
```

Expected: fail because the unified repository, aggregate transaction methods, migration, and orthogonal lifecycle types do not exist.

- [x] **Step 3: Add the unified repository, orthogonal state machine, and SQLite schema**

Define exact state axes:

```rust
pub enum HostExecutionPhase {
    AwaitingStartCommandAck,
    AwaitingGenerationStarted,
    ConsumingLlmTurn,
    ExecutingToolBatch,
    SuspendedForToolApproval,
    AwaitingIncrementalEgressApproval,
    AwaitingResumeCommandAck,
}

pub enum LogicalRunOutcome {
    Pending,
    Succeeded { finish_reason: HostFinishReason },
    Failed { code: String },
    Cancelled,
    Interrupted { code: String },
}

pub enum ResourceLifecycle {
    Registered,
    Generating,
    AwaitingCancelCommandAck,
    AwaitingCancelledTerminal,
    AwaitingCloseCommandAck,
    AwaitingSessionClosed,
    Quarantined { code: String },
    Closed { disposition: HostSessionCloseDisposition },
}

pub struct HostWorkerRecord {
    pub execution_phase: Option<HostExecutionPhase>,
    pub logical_outcome: LogicalRunOutcome,
    pub resource_lifecycle: ResourceLifecycle,
    // exact run/session/epoch/revision/watchdog fields
}
```

`HostWorkerRecord::is_fully_terminal()` is true only when `logical_outcome != pending` and `resource_lifecycle == closed`. `succeeded + awaiting_session_closed` remains recoverable and owns a releasing lease. Close or prepared-cleanup acknowledgement rejection moves the resource axis to `quarantined`, never to a generic terminal outcome.

Create normalized SQLite tables for complete V2 snapshots, Agent execution events/formal assistant outputs, workers, sessions, accumulators/tool batches, outbox, receipts, preparations/cross-links, and the global lease. Add unique constraints on `(session_handle, command_sequence)`, `(session_handle, event_sequence)`, `(session_handle, event_id)`, and stable output identity. Store full command JSON only in a nullable outbox payload column; retain indexed state/epoch/revision columns beside versioned canonical records. Every aggregate mutation uses `TransactionBehavior::Immediate` and verifies expected worker revision/state axes, lease generation, session handle, epoch, and schema version.

Move initialization in `ffi_bridge.rs` from two separately opened SQLite files plus default in-memory `ExecutionEventLog`/`RunSnapshotRepository` to one shared `SqliteRuntimeStateStore`. Adapt `storage/event_store.rs`, `execution/event_log.rs`, and `run_snapshot/resolver.rs` so existing observe/commit APIs can use typed views backed by that store. Compatibility traits clone a store handle, not a connection or transaction boundary. The in-memory implementation must expose the same aggregate methods and injected failure points; tests may not fake atomicity by calling lower-level writes directly.

- [x] **Step 4: Run GREEN and Phase 1 storage regressions**

```bash
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test contract host_llm_outbox -- --nocapture
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test contract runtime_state_migration -- --nocapture
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test contract -- --nocapture
git diff --check
```

Expected: migration, aggregate transaction, reopen, idempotency, orthogonal lifecycle, and existing preparation/lease tests pass from one authority.

- [x] **Step 5: Commit**

```bash
git add rust-core/src/llm_contracts rust-core/src/storage rust-core/src/ffi_bridge.rs \
  rust-core/src/execution/event_log.rs rust-core/src/run_snapshot/resolver.rs \
  rust-core/tests/contract.rs rust-core/tests/contract/host_llm_outbox.rs \
  rust-core/tests/contract/runtime_state_migration.rs
git commit -m "feat: unify host llm runtime state"
```

---

### Task 3: Align Authoritative Preview and Atomically Commit the First Host Command

**Files:**
- Modify: `rust-core/src/run_snapshot/snapshot.rs`
- Modify: `rust-core/src/run_snapshot/resolved_bindings.rs`
- Modify: `rust-core/src/run_snapshot/resolver.rs`
- Modify: `rust-core/src/run_snapshot/mod.rs`
- Modify: `rust-core/src/run_snapshot/preparation_preview.rs`
- Modify: `rust-core/src/run_snapshot/snapshot_service.rs`
- Modify: `rust-core/src/llm_contracts/preparation.rs`
- Modify: `rust-core/src/llm_contracts/prepared_start_validator.rs`
- Modify: `rust-core/src/storage/runtime_state.rs`
- Modify: `rust-core/src/storage/sqlite_runtime_state.rs`
- Modify: `rust-core/src/storage/agent_os_state/mod.rs`
- Modify: `rust-core/src/storage/agent_os_state/in_memory.rs`
- Modify: `rust-core/src/ffi_bridge.rs`
- Modify: `rust-core/tests/contract/run_preparation.rs`
- Modify: `rust-core/tests/contract/run_snapshot_resolution_agent_os.rs`
- Create: `rust-core/tests/contract/host_llm_worker.rs`
- Modify: `rust-core/tests/contract.rs`
- Modify: `rust-core/tests/integration/ffi_bridge.rs`
- Create: `rust-core/tests/lint/llm_phase_four_architecture.rs`
- Modify: `rust-core/tests/lint.rs`

**Interfaces:**
- Replaces the private digest-only preparation derivation with one `FrozenGenerationTurn` containing canonical `AgentLLMInput`, complete tool schema, source revision document, attachment references, empty start tool-result batch, semantic history, and full `GenerationDisclosure`.
- Replaces the mandatory legacy `ResolvedModelBinding` field with `ResolvedLLMBinding::LegacyV1` or `ResolvedLLMBinding::HostSlotV2`. The host variant stores complete provider-neutral `AgentLLMRequirements`, their canonical hash, and only `bindingID`/`bindingRevision`/`bindingHash` as an opaque host cross-link; provider account, provider ID, model ID, credential, origin, installation path, and adapter fields cannot be constructed in this variant.
- Moves `TrustedHostRunState` under `ResolvedLLMBinding::LegacyV1`; `HostSlotV2` has no trusted-host/credential-readiness member at all, so empty legacy credential keys cannot leak into the persisted V2 snapshot. Common profile/component/tool/memory/voice/frame/readiness fields remain at the snapshot level.
- `RunPreparationPreview` exposes the full public disclosure but never prompt content.
- `RunPreparationService::commit_start` returns `HostRunHandle` and calls the atomic repository commit instead of aborting with `execution.host_slot_v2_not_runnable`.
- Recomputes registration, provider-neutral capability, preparation, and outer egress attestation digests from exact public fields; it binds but does not interpret the exact resolved-parameter and opaque egress-subject digests supplied by Swift.
- Phase C writes the complete canonical V2 `ResolvedRunSnapshot`, its exact host cross-link, `run.started` Agent execution event, worker/session record, consumed token, promoted lease, and first outbox row through one `commit_prepared_host_run` transaction. There is no detached snapshot projection or in-memory snapshot authority for V2.
- Existing run observation/status/output APIs read V2 data from the unified aggregate. They do not reconstruct V2 state from the outbox or side tables.
- Adds `RunPreparationService::reconcile_preparation(preparationID, proposedRunID, tokenDigest) -> PreparationReconciliation` backed by the same aggregate authority. Phase C persists the consumed token digest with the committed run so a lost FFI result can recover the exact `HostRunHandle` without reopening or aborting the session.
- Exposes the same operation through `RuntimeJsonBridge::reconcile_preparation_json`; the C/Swift wrappers are added in Task 7 without changing its outcome semantics.

- [x] **Step 1: Write failing authoritative binding and Phase C tests**

Add tests that mutate the real frame, tool schema, component/source revision, attachment reference, model input, registration tuple, capability, parameter digest, opaque subject, host cross-link, lease revision, profile route revision, or epoch after preview and require commit rejection plus prepared-session cleanup. Inject a crash after every aggregate row write and prove reopen sees either the entire Phase C aggregate or the unchanged preparation—never a partial run. Add successful tagged-snapshot and reconciliation assertions:

```rust
#[test]
fn commit_start_promotes_exact_preparation_and_enqueues_frozen_input() {
    let harness = HostPreparationHarness::ready();
    let handle = harness.commit().unwrap();
    assert_eq!(handle.run_id(), harness.preview().proposed_run_id());
    let command = harness.only_pending_command();
    assert_eq!(command.kind(), HostCommandKind::StartGeneration);
    assert_eq!(command.payload().unwrap().model_input_digest(),
               harness.preview().binding().model_input_digest());
    assert_eq!(harness.global_lease().owner_id(), handle.run_id());
    assert_eq!(harness.observed_snapshot().unwrap(), harness.expected_v2_snapshot());
    assert_eq!(harness.agent_events(), [AgentExecutionEvent::run_started(handle.run_id())]);
    assert!(matches!(
        harness.observed_snapshot().unwrap().llm_binding(),
        ResolvedLLMBinding::HostSlotV2(binding)
            if binding.requirements_hash() == harness.preview().binding().requirements_hash()
                && binding.host_cross_link().binding_hash() == harness.registration().binding_hash()
    ));
}

#[test]
fn lost_commit_response_reconciles_to_the_exact_committed_handle() {
    let harness = HostPreparationHarness::ready();
    let expected = harness.commit_and_drop_response();
    let outcome = harness.reconcile();
    assert_eq!(outcome, PreparationReconciliation::Committed { handle: expected });
    assert_eq!(harness.pending_start_commands(), 1);
    assert_eq!(harness.prepared_cleanup_commands(), 0);
}
```

Assert the persisted outbox payload canonicalizes to `host-command-payload:v1` and its disclosure exactly equals the preview disclosure. Serialize the persisted V2 snapshot and recursively reject keys named `provider_account_id`, `provider_id`, `model_id`, `credential`, `origin`, `base_url`, `installation_path`, or `adapter`; additionally inspect the `llm_binding` subtree for sentinel legacy provider/model/credential values. Do not scan free-form user intent/message strings. Verify legacy snapshots still round-trip as `legacy_v1` and existing legacy getters return their model/trust state.

Add reconciliation tests for exact committed replay, still-pending proof, already-aborting cleanup identity, wrong preparation/run/token digest, concurrent commit/reconcile serialization, concurrent late-commit versus pending-abort CAS, and reopen. Reconciliation is read-only and must not enqueue start/cleanup commands or change lease state. `begin_abort_preparation` must CAS only an uncommitted preparation to aborting; if Phase C wins first it returns `preparation.already_committed` without creating cleanup.

- [x] **Step 2: Run RED**

```bash
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test contract host_llm_worker -- --nocapture
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test contract run_preparation -- --nocapture
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test contract run_snapshot_resolution_agent_os -- --nocapture
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test lint llm_phase_four_architecture -- --nocapture
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test integration ffi_bridge -- --nocapture
```

Expected: successful commit still returns `execution.host_slot_v2_not_runnable`; `ResolvedRunSnapshot` cannot construct a host binding; reconciliation is absent; preview does not expose a complete disclosure/payload.

- [x] **Step 3: Build one canonical frozen turn and use it at commit**

Introduce:

```rust
pub(crate) struct FrozenGenerationTurn {
    pub model_input_id: String,
    pub semantic_payload: HostCommandPayload,
    pub semantic_payload_digest: String,
    pub disclosure: GenerationDisclosureDocument,
    pub disclosure_digest: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ResolvedLLMBinding {
    LegacyV1 {
        model: ResolvedModelBinding,
        trusted_host_state: TrustedHostRunState,
    },
    HostSlotV2(ResolvedHostSlotBinding),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ResolvedHostSlotBinding {
    requirements: AgentLLMRequirements,
    requirements_hash: String,
    host_cross_link: OpaqueHostBindingCrossLink,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OpaqueHostBindingCrossLink {
    binding_id: String,
    binding_revision: u64,
    binding_hash: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PersistedResolvedRunSnapshotV2 {
    schema_version: u32,
    snapshot_id: u64,
    agent_profile_id: String,
    user_intent: String,
    profile_version: u64,
    component_versions: Vec<PersistedComponentBinding>,
    llm_binding: PersistedResolvedLLMBinding,
    tool_bindings: Vec<PersistedToolBinding>,
    memory_binding: Option<PersistedSlotComponentBinding>,
    voice_binding: Option<PersistedSlotComponentBinding>,
    readiness_issues: Vec<PersistedReadinessIssue>,
    conversation_frame: PersistedConversationFrameRef,
    created_at_millis: u64,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "binding_schema", content = "binding", rename_all = "snake_case")]
pub enum PersistedResolvedLLMBinding {
    LegacyV1 {
        model_binding: PersistedLegacyModelBinding,
        permission_state: String,
        local_credential_refs: BTreeMap<String, String>,
        credential_availability: BTreeMap<String, String>,
    },
    HostSlotV2 {
        requirements: AgentLLMRequirements,
        requirements_hash: String,
        binding_id: String,
        binding_revision: u64,
        binding_hash: String,
    },
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PersistedLegacyModelBinding {
    binding_id: String,
    provider_account_id: String,
    provider_id: String,
    model_id: String,
    catalog_version: u64,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PersistedComponentBinding {
    slot_id: String,
    slot_kind: String,
    version_id: String,
    entity_version: u64,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PersistedToolBinding {
    slot_id: String,
    component: PersistedComponentBinding,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PersistedSlotComponentBinding {
    slot_id: String,
    component: PersistedComponentBinding,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PersistedReadinessIssue { code: String, message: String }

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PersistedConversationFrameRef {
    frame_id: String,
    session_id: String,
    branch_head_id: String,
    user_turn_id: String,
}
```

Use the `HostRunHandle`, `PreparedSessionCleanupIdentity`, and `PreparationReconciliation` wire records frozen in Task 1. Expand `HostSlotPreparationSources` so the Rust preview vault retains every provider-neutral field needed to build the final snapshot: requirements, component/tool/memory/voice bindings, frame reference, readiness report, and the frozen turn. The legacy resolver constructs `ResolvedLLMBinding::LegacyV1`; the host resolver never calls `resolve_model_binding`. Replace `model_binding() -> &ResolvedModelBinding` with explicit `legacy_model_binding() -> Option<&ResolvedModelBinding>`, `legacy_trusted_host_state()`, and `host_slot_binding()` accessors and update every current call site. Implement exhaustive `TryFrom<&ResolvedRunSnapshot> for PersistedResolvedRunSnapshotV2` and reverse conversion with `schema_version == 2`; do not add `Serialize` transitively to unrelated domain IDs merely to persist the snapshot.

Keep the frozen turn/snapshot sources in the preparation vault only until commit. Before the repository call, recompute public digests without provider semantics; inside `commit_prepared_host_run`, re-read and CAS the preparation/token generation, registration, profile route/cross-link, capability/parameter attestation, and lease. Construct `ResolvedHostSlotBinding` only from the Rust-frozen requirements plus the validated opaque cross-link. The transaction stores the complete tagged V2 snapshot and `run.started` event, worker/session, consumed token digest, and first command bytes while consuming the bearer token and promoting the lease.

Define the commit return boundary so a decoded Rust error is authoritative: every validation/error branch occurs before commit or after transaction rollback, and after a successful aggregate commit Rust performs only total field projection into the already-frozen `HostRunHandle`. Swift allocation/copy/UTF-8/JSON decoding and caller cancellation remain outside that boundary and therefore require reconciliation.

`reconcile_preparation` performs one consistent aggregate read keyed by all three supplied identities. A matching committed aggregate returns its persisted handle even if the preparation token was consumed; a live unconsumed matching record returns `pending`; an aborting/closed preparation returns its stable cleanup identity as `aborting`. Any mismatch returns `preparation.reconciliation_identity_mismatch`. Failed validation invokes the existing idempotent cleanup path. Successful commit removes the frozen preparation-vault entry only after the aggregate transaction returns; a callback may dispatch the committed start before the outer FFI call returns, so Swift must already be in `commitInFlight`.

Create the Phase 4 architecture lint now, rather than at the production switch. It serializes a real `host_slot_v2` snapshot from the SQLite aggregate, recursively scans structured key names, and scans only the `llm_binding` subtree for seeded legacy secret/model values; free-form user text is excluded. It separately permits the unchanged legacy variant and rejects a synthetic V2 fixture if any forbidden field is injected.

- [x] **Step 4: Run GREEN and preparation regressions**

```bash
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test contract host_llm_worker -- --nocapture
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test contract run_preparation -- --nocapture
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test contract run_snapshot_resolution_agent_os -- --nocapture
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test lint llm_phase_four_architecture -- --nocapture
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test integration ffi_bridge -- --nocapture
scripts/run-llm-phase-1-contracts.sh
git diff --check
```

Expected: exact attestation commits one provider-neutral tagged V2 snapshot/worker/command; lost replies reconcile without cleanup; every mismatch cleans up without a runnable partial run; legacy snapshots and Phase 1 contracts remain green.

- [x] **Step 5: Commit**

```bash
git add rust-core/src/run_snapshot rust-core/src/llm_contracts rust-core/src/ffi_bridge.rs \
  rust-core/src/storage rust-core/tests/contract.rs rust-core/tests/lint.rs \
  rust-core/tests/contract/run_preparation.rs \
  rust-core/tests/contract/run_snapshot_resolution_agent_os.rs \
  rust-core/tests/contract/host_llm_worker.rs \
  rust-core/tests/lint/llm_phase_four_architecture.rs \
  rust-core/tests/integration/ffi_bridge.rs
git commit -m "feat: commit authoritative host llm runs"
```

---

### Task 4: Add the C Vtable and a Production-Lifecycle Rust Dispatcher

**Files:**
- Create: `rust-core/src/execution/host_llm_dispatcher.rs`
- Modify: `rust-core/src/execution/mod.rs`
- Modify: `rust-core/src/ffi_bridge.rs`
- Modify: `toolkit/Sources/CLocalAgentRuntime/include/CLocalAgentRuntime.h`
- Modify: `toolkit/Sources/CLocalAgentRuntime/CLocalAgentRuntime.c`
- Create: `toolkit/Sources/LocalAgentBridge/RustLLMHostPort.swift`
- Modify: `toolkit/Sources/LocalAgentBridge/RustRuntimeClient.swift`
- Create: `rust-core/tests/integration/host_llm_ffi.rs`
- Modify: `rust-core/tests/integration.rs`
- Modify: `toolkit/Tests/LocalAgentBridgeTests/RustRuntimeClientContractTests.swift`

**Interfaces:**
- Produces `local_agent_runtime_bridge_install_llm_host`, `local_agent_runtime_bridge_uninstall_llm_host`, dispatcher suspend/resume entries, `local_agent_runtime_bridge_submit_llm_command_ack`, `local_agent_runtime_bridge_submit_llm_event`, and explicit free/drive hooks used by tests.
- Swift installs one `LocalAgentLLMHostVTable` whose callback receives immutable bytes and returns `copied | backpressure | host_unavailable`.
- Rust dispatcher reads only committed outbox rows and invokes callbacks after releasing runtime/repository mutexes.
- `HostLLMDispatcherRuntime` owns a scheduler thread, wake condition, current Swift context, and lifecycle `uninstalled | installed | quiescing | stopped`. Install starts or wakes it; commit, command acknowledgement, event application, and store reopen wake it; it rebuilds the earliest persisted command/watchdog deadline and fires without requiring a later FFI call.
- Explicit App suspend/resume hooks stop new backend-start dispatch during suspension but keep durable deadlines and allow lifecycle cleanup. Uninstall quiesces callbacks and permits a later install. Runtime free stops intake, wakes the scheduler, waits for all in-flight callbacks, joins it, and only then invokes the vtable `release_context` callback.
- Start/resume acknowledgement timeout uses the same ID/sequence/digest on redispatch and terminates as `llm.command.ack_timeout` without inventing a new identity.
- The same callback transports regular `HostCommandEnvelope` and preparation-scoped cleanup envelopes under `HostDispatchEnvelope`; their asynchronous acknowledgements remain separate FFI operations and cannot be confused.
- Rejected acknowledgement handling is explicit: rejected start/resume records a logical failure and schedules close; rejected cancel schedules close or quarantine according to backend confirmation; rejected close or prepared cleanup moves the resource to `quarantined` and keeps the lease `releasing`.

- [x] **Step 1: Write failing ownership, reentrancy, redispatch, and FFI tests**

Add a callback probe that records buffer bytes, tries to lock the runtime during the callback, blocks on demand, and returns scripted receipts. Require byte-for-byte stable redispatch, no held mutex, scheduler-owned timeouts, and safe teardown:

```rust
#[test]
fn dispatcher_never_calls_swift_while_runtime_or_repository_is_locked() {
    let probe = ReentrantHostProbe::new();
    let bridge = bridge_with_probe(probe.clone());
    bridge.commit_v2_fixture().unwrap();
    bridge.drive_host_dispatcher().unwrap();
    assert!(probe.runtime_try_lock_succeeded());
    assert!(probe.repository_try_lock_succeeded());
}

#[test]
fn crash_after_copy_before_ack_redispatches_identical_envelope() {
    let first = dispatch_then_drop_bridge_before_ack();
    let second = reopen_and_dispatch();
    assert_eq!(first.command_id, second.command_id);
    assert_eq!(first.command_sequence, second.command_sequence);
    assert_eq!(first.bytes, second.bytes);
}

#[test]
fn timeout_fires_without_any_followup_ffi_call() {
    let bridge = bridge_with_virtual_clock();
    bridge.commit_v2_fixture().unwrap();
    bridge.install_host(backpressured_probe()).unwrap();
    bridge.advance_clock(Duration::from_secs(11));
    assert_eq!(bridge.run_failure(), Some("llm.command.ack_timeout"));
}

#[test]
fn runtime_free_waits_for_blocked_callback_before_releasing_context() {
    let probe = BlockingHostProbe::new();
    let bridge = bridge_with_probe(probe.clone());
    bridge.commit_v2_fixture().unwrap();
    probe.wait_until_callback_entered();
    let free = bridge.free_on_thread();
    assert!(!probe.context_released());
    probe.release_callback();
    free.join().unwrap();
    assert!(probe.context_released());
}
```

Swift tests must prove the callback copies into owned `Data` before returning, never synchronously re-enters Rust, survives uninstall/reinstall without reusing a released context, and cannot accept work after quiescing begins. Add reopen-deadline and App suspend/resume tests.

- [x] **Step 2: Run RED**

```bash
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test integration host_llm_ffi -- --nocapture
swift test --package-path toolkit --filter RustRuntimeClientContractTests.llmHost
```

Expected: fail because the C ABI, runtime-owned scheduler/lifecycle, deadline wakeup, safe context release, and Swift wrapper are absent.

- [x] **Step 3: Implement the narrow ABI and post-lock dispatcher**

Add the C contract:

```c
typedef enum {
  LOCAL_AGENT_LLM_HOST_COPIED = 0,
  LOCAL_AGENT_LLM_HOST_BACKPRESSURE = 1,
  LOCAL_AGENT_LLM_HOST_UNAVAILABLE = 2
} local_agent_llm_host_copy_receipt_t;

typedef local_agent_llm_host_copy_receipt_t (*local_agent_llm_host_command_fn)(
  const uint8_t *bytes, size_t length, void *context);

typedef struct {
  uint32_t abi_version;
  local_agent_llm_host_command_fn submit_command;
  void (*release_context)(void *context);
  void *context;
} local_agent_llm_host_vtable_t;
```

The Rust dispatcher snapshots pending rows under the repository lock, releases it, calls the vtable serially, then records only the synchronous copy receipt in a new transaction. Its scheduler waits on a condition variable until a wake signal or the earliest persisted deadline, then re-queries SQLite; no in-memory timer is authoritative. `backpressure`, `host_unavailable`, and a missing acknowledgement redispatch the identical bytes within the bounded deadline. A rejected asynchronous acknowledgement executes the command-kind matrix above without retrying under a new identity. The Swift trampoline copies to `Data(bytes:count:)`, attempts one bounded enqueue, and returns immediately. It schedules regular or prepared-cleanup acknowledgement/event submission on a task after the callback returns.

Store the retained Swift context behind an in-flight callback guard. Install rejects a second live host, uninstall transitions to quiescing and waits for callbacks, reinstall creates a fresh context generation, and runtime destruction follows `stop intake → wake → quiesce callbacks → join dispatcher → release_context → free Rust state`. Test-only drive hooks call the same single-iteration routine used by the scheduler and are not needed in production.

- [x] **Step 4: Run GREEN and bridge regressions**

```bash
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test integration -- --nocapture
swift test --package-path toolkit --filter RustRuntimeClientContractTests
git diff --check
```

Expected: ownership/reentrancy/redispatch, autonomous timeout, suspend/resume, uninstall/reinstall, callback-blocked free, and existing bridge tests pass.

- [x] **Step 5: Commit**

```bash
git add rust-core/src/execution rust-core/src/ffi_bridge.rs rust-core/tests/integration* \
  toolkit/Sources/CLocalAgentRuntime toolkit/Sources/LocalAgentBridge \
  toolkit/Tests/LocalAgentBridgeTests/RustRuntimeClientContractTests.swift
git commit -m "feat: add durable host llm ffi port"
```

---

### Task 5: Create the Swift Host Actor, Session Registry, and Command Ledger

**Files:**
- Modify: `toolkit/Package.swift`
- Create: `toolkit/Sources/LocalAgentLLMHost/LLMHostRuntime.swift`
- Create: `toolkit/Sources/LocalAgentLLMHost/LLMHostCommandInbox.swift`
- Create: `toolkit/Sources/LocalAgentLLMHost/LLMHostSessionRegistry.swift`
- Create: `toolkit/Sources/LocalAgentLLMHost/LLMHostSessionDriver.swift`
- Create: `toolkit/Sources/LocalAgentLLMHost/PreparedSessionCleanupOwner.swift`
- Create: `toolkit/Tests/LocalAgentLLMHostTests/LLMHostRuntimeTests.swift`

**Interfaces:**
- Produces public `LLMHostRuntime`, a lock-protected bounded 64-command copy inbox callable synchronously from C, and package `LLMBridgeActor` that drains it asynchronously.
- Produces `LLMHostSessionDriver`, implemented later by local/cloud wrappers, without exposing their concrete types to Rust.
- Produces `PreparedSessionCleanupOwner`, installed before Rust registration, which can cancel/close every partially allocated local/cloud resource while `open()` is in flight and return one exact `closed | already_closed` disposition.
- Registry binds handle to preparation, run, snapshot, binding hash, epoch, cleanup owner, optional opened driver, command ledger, and event sequencer. Its exact lifecycle is `allocated → registrationInFlight → registeredNotOpen → opening → openedAwaitingCommit → commitInFlight → commitOutcomeUnknown | committed → closing | quarantined → closed`.
- Command ledger accepts only the next sequence, replays exact duplicates, rejects identity conflicts/gaps, and retains entries until `session_closed`.
- Prepared cleanup is admissible from `registrationInFlight` onward. A valid Rust cleanup envelope received while registration FFI is returning proves Rust accepted registration and atomically advances the entry into `closing`; this removes the last post-registration cleanup gap. Start is admissible in `commitInFlight`, `commitOutcomeUnknown`, or `committed`, because a committed outbox may dispatch before—or after loss of—the `commit_start` FFI response; a valid start atomically proves and records `committed`. No other pre-commit state may start a backend.

- [x] **Step 1: Write failing actor/ledger/tombstone tests**

Cover 256-bit random handles, exact duplicate replay, sequence gap/conflict, wrong epoch/run, queue overflow, close tombstones, ABA attempts, cleanup during opening, start while commit FFI is returning, and quarantine on rejected cleanup acknowledgement:

```swift
@Test func duplicateCommandReturnsExistingAckWithoutStartingTwice() async throws {
    let harness = try HostRuntimeHarness.make()
    let command = harness.startCommand(sequence: 1)
    #expect(await harness.host.copy(command) == .copied)
    #expect(await harness.host.copy(command) == .copied)
    await harness.drain()
    #expect(await harness.driver.startCount == 1)
    #expect(await harness.rust.acceptedAcknowledgements == [command.commandID, command.commandID])
}

@Test func reusedSequenceWithDifferentIDInterruptsWithoutBackendCall() async throws {
    let harness = try HostRuntimeHarness.make()
    await harness.submit(harness.startCommand(id: "a", sequence: 1))
    await harness.submit(harness.cancelCommand(id: "b", sequence: 1))
    #expect(await harness.driver.cancelCount == 0)
    #expect(await harness.rust.lastRejectedCode == "llm.command.sequence_conflict")
}

@Test func registeredSessionCanBeCleanedWhileOpenIsBlocked() async throws {
    let harness = try HostRuntimeHarness.openBlockedAfterFirstResource()
    await harness.registerAndBeginOpen()
    await harness.deliverPreparedCleanup()
    #expect(await harness.cleanupOwner.closeCount == 1)
    #expect(await harness.driverWasInstalled == false)
    #expect(await harness.rust.closedDisposition == .closed)
}

@Test func committedStartMayArriveBeforeCommitFFIReturns() async throws {
    let harness = try HostRuntimeHarness.commitCallbackBlocked()
    await harness.beginCommit()
    await harness.drainCommittedStartCommand()
    #expect(await harness.registryState == .committed)
    #expect(await harness.driver.startCount == 1)
}
```

- [x] **Step 2: Run RED**

```bash
swift test --package-path toolkit --filter LLMHostRuntimeTests
```

Expected: fail because the target, actor, registry, and ledger do not exist.

- [x] **Step 3: Add the host target and actor-isolated registries**

Define the backend-neutral seam:

```swift
package protocol LLMHostSessionDriver: Sendable {
    func makeAuthorizedLaunch(
        for turn: HostGenerationTurn,
        mode: HostGenerationMode
    ) async throws -> AuthorizedHostGenerationLaunch
    func cancel() async throws
    func close() async throws
}

package enum HostGenerationMode: Sendable { case start, resume }

package struct HostGenerationTurn: Sendable {
    let commandID: String
    let generationTurnID: String
    let payload: HostCommandPayload
    let disclosure: GenerationDisclosure
}

package struct AuthorizedHostGenerationLaunch: Sendable {
    let run: @Sendable () async throws -> HostGenerationOperation
}

package struct HostGenerationOperation: Sendable {
    let opaqueOperationID: String
    let events: LLMBackendEventStream
}

package final class BoundedHostCommandInbox: @unchecked Sendable {
    package func copyAndEnqueue(_ ownedBytes: Data) -> HostCommandCopyReceipt
    package func pop() -> Data?
}

package actor LLMBridgeActor {
    package func allocate(_ session: AllocatedHostSession) throws
    package func beginRegistration(_ handle: String) throws
    package func markRegistered(_ handle: String) throws
    package func beginOpen(_ handle: String) throws
    package func installOpenedDriver(_ driver: any LLMHostSessionDriver,
                                     for handle: String) throws
    package func beginCommit(_ handle: String) throws
    package func markCommitOutcomeUnknown(_ handle: String) throws
    package func applyReconciliation(_ outcome: PreparationReconciliationDTO,
                                     to handle: String) throws
    package func drainNext() async
}
```

Use `SecRandomCopyBytes` for handles. Allocation installs the cleanup owner first; the coordinator then marks `registrationInFlight` before calling Rust registration. Before each open substep allocates a model lease, C++ session, credential-use lease, provider task/session, or continuation object, it registers its idempotent compensator with that owner. `close()` may race registration/open; all paths converge on the same close task and exact disposition. Open success atomically upgrades the registry entry with the driver. Before calling Rust commit the coordinator moves to `commitInFlight`; receipt of its valid first start command upgrades `commitInFlight` or `commitOutcomeUnknown` to `committed`. An ambiguous FFI result never closes the cleanup owner until Rust reconciliation proves `pending` or supplies an existing `aborting` cleanup identity.

The C trampoline owns the first `Data(bytes:count:)` copy and calls only `BoundedHostCommandInbox.copyAndEnqueue`; it never awaits an actor. The inbox uses `NSLock` only around its fixed-capacity FIFO, signals the actor after insertion, and performs no Rust call or main-actor hop. A command is acknowledged only after the actor's schema/digest/session/epoch/sequence/lifecycle checks and ledger claim. A duplicate returns the stored acknowledgement and never invokes the driver. Do not persist command payload, provider state, or the in-process ledger.

- [x] **Step 4: Run GREEN and target-boundary regressions**

```bash
swift test --package-path toolkit --filter LLMHostRuntimeTests
swift test --package-path toolkit --filter CloudProviderBoundaryTests
swift test --package-path toolkit --filter CppInferenceOwnershipTests
git diff --check
```

Expected: host actor tests pass; Local/Cloud boundary tests prove no reverse import or ownership drift.

- [x] **Step 5: Commit**

```bash
git add toolkit/Package.swift toolkit/Sources/LocalAgentLLMHost \
  toolkit/Tests/LocalAgentLLMHostTests/LLMHostRuntimeTests.swift
git commit -m "feat: add swift llm host actor"
```

---

### Task 6: Implement Durable Event Ingress, Receipts, and Capacity Backpressure

**Files:**
- Create: `rust-core/src/execution/host_llm_worker.rs`
- Modify: `rust-core/src/execution/mod.rs`
- Modify: `rust-core/src/ffi_bridge.rs`
- Modify: `rust-core/src/storage/runtime_state.rs`
- Modify: `rust-core/src/storage/sqlite_runtime_state.rs`
- Modify: `rust-core/src/storage/agent_os_state/mod.rs`
- Modify: `rust-core/src/storage/agent_os_state/in_memory.rs`
- Create: `rust-core/tests/contract/host_llm_event_ingress.rs`
- Modify: `rust-core/tests/contract.rs`
- Create: `toolkit/Sources/LocalAgentLLMHost/LLMEventSequencer.swift`
- Create: `toolkit/Tests/LocalAgentLLMHostTests/LLMHostEventSequencerTests.swift`

**Interfaces:**
- Produces `HostLLMWorkerService::submit_event` with the exact deterministic validation order and result matrix.
- Produces one `UnifiedRuntimeStateRepository::apply_event_transactionally` boundary. After read-only envelope validation, this transaction owns receipt/expected-sequence consumption, persisted inbound event/turn accumulator, worker/lifecycle transition, formal Agent event/output, optional tool progress/next command, and lease transition. No caller may first persist a receipt and later apply the event.
- Rust queue owns at most 256 events/2 MiB; `capacity_available` is a normal deduplicated host command emitted below both low-water marks.
- Swift `LLMEventSequencer` assigns ID/sequence only when an immutable envelope is ready for FFI, retries only `backpressure`, and never advances on stale/closed/invalid results.
- Exact close receipt replay remains `duplicate`; other closed/stale events never consume sequence.

- [x] **Step 1: Write the complete failing result-matrix tests**

Parameterize every result with `sequenceConsumed`, `receiptPersisted`, and `retrySameSequence`. Add conflict-before-terminal-order tests and the N/N+1 late-event case:

```rust
#[test]
fn terminally_ignored_event_consumes_n_so_close_at_n_plus_one_is_valid() {
    let harness = consuming_turn_with_terminal_at(4);
    assert_eq!(harness.submit(late_delta(sequence(5))), EventResult::TurnTerminal);
    assert_eq!(harness.submit(session_closed(sequence(6))), EventResult::Accepted);
    assert_eq!(harness.receipt(5).unwrap().disposition(),
               ReceiptDisposition::TerminallyIgnored);
}

#[test]
fn backpressure_does_not_consume_or_persist() {
    let harness = full_queue();
    let event = text_delta(sequence(257));
    assert_eq!(harness.submit(event.clone()), EventResult::Backpressure);
    assert!(harness.receipt(257).is_none());
    harness.drain_below_low_water();
    assert_eq!(harness.submit(event), EventResult::Accepted);
}
```

Add a crash-injection matrix after receipt write, expected-sequence write, inbound event write, accumulator write, logical/physical state write, Agent event/output write, and next-outbox write. Reopen must show either no consumed sequence/no effects or the complete applied transition. Exact duplicate replay must return the stored disposition without duplicating accumulator content, output, run events, tools, or outbox rows.

Swift tests must prove only the exact backpressured bytes are retried and that raw backend late events are filtered before sequence allocation.

- [x] **Step 2: Run RED**

```bash
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test contract host_llm_event_ingress -- --nocapture
swift test --package-path toolkit --filter LLMHostEventSequencerTests
```

Expected: fail because the aggregate event transaction, crash-safe receipt coupling, and Swift sequencer are absent.

- [x] **Step 3: Implement validation order and lossless handoff**

Apply this order exactly: structural/canonical validation → session/epoch lookup including retained close duplicate → identity/sequence receipt comparison → expected sequence → turn/generation lifecycle → capacity → one `apply_event_transactionally` call. The repository rechecks session/epoch/expected sequence and worker revision inside its immediate transaction before writing anything. Return a typed FFI response only after commit:

```swift
package func submit(_ payload: LLMEventPayload) async throws {
    let envelope = try makeEnvelope(payload, sequence: nextSequence)
    while true {
        switch try rust.submitEvent(envelope) {
        case .accepted, .turnTerminal, .generationTerminal, .payloadTooLarge:
            nextSequence += 1
            return
        case .duplicate:
            nextSequence = max(nextSequence, envelope.eventSequence + 1)
            return
        case .backpressure:
            try await capacityGate.wait()
        case .staleSession, .closedSession:
            return
        default:
            throw LLMHostFailure.protocolViolation
        }
    }
}
```

Coalesce only text/reasoning deltas up to 32 KiB or 50 ms. Never coalesce/drop tool, usage, start, terminal, failure, cancel, or close events. Low-water `capacity_available` insertion is part of the same aggregate transaction that drains below both limits, so a crash cannot lose the only wakeup.

- [x] **Step 4: Run GREEN and reopen regressions**

```bash
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test contract host_llm_event_ingress -- --nocapture
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test contract host_llm_outbox -- --nocapture
swift test --package-path toolkit --filter LLMHostEventSequencerTests
git diff --check
```

Expected: every matrix row, conflict precedence, low-water notification, exact retry, and reopen receipt case passes.

- [x] **Step 5: Commit**

```bash
git add rust-core/src/execution rust-core/src/ffi_bridge.rs \
  rust-core/src/storage rust-core/tests/contract.rs \
  rust-core/tests/contract/host_llm_event_ingress.rs \
  toolkit/Sources/LocalAgentLLMHost/LLMEventSequencer.swift \
  toolkit/Tests/LocalAgentLLMHostTests/LLMHostEventSequencerTests.swift
git commit -m "feat: add sequenced host llm event ingress"
```

---

### Task 7: Make Two-Phase Swift Preparation Register Before Opening Resources

**Files:**
- Create: `toolkit/Sources/LocalAgentLLMHost/LLMRunPreparationBridge.swift`
- Create: `toolkit/Sources/LocalAgentLLMHost/PreparedLLMSession.swift`
- Modify: `toolkit/Sources/LocalAgentLLMHost/PreparedSessionCleanupOwner.swift`
- Create: `toolkit/Sources/LocalAgentLLMHost/LocalHostSessionDriver.swift`
- Create: `toolkit/Sources/LocalAgentLLMHost/CloudHostSessionDriver.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCore/RunPreparationCoordinator.swift`
- Modify: `toolkit/Sources/LocalAgentLLMLocal/PreparedLocalSession.swift`
- Modify: `toolkit/Sources/LocalAgentLLMLocal/LocalModelRuntime.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCloud/PreparedCloudSession.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCloud/CloudLLMRuntime.swift`
- Modify: `toolkit/Sources/LocalAgentBridge/AgentOSDTOs.swift`
- Modify: `toolkit/Sources/LocalAgentBridge/RustAgentOSBridgeGateway.swift`
- Modify: `toolkit/Sources/LocalAgentBridge/RustRuntimeClient.swift`
- Modify: `toolkit/Sources/CLocalAgentRuntime/include/CLocalAgentRuntime.h`
- Modify: `toolkit/Sources/CLocalAgentRuntime/CLocalAgentRuntime.c`
- Create: `toolkit/Tests/LocalAgentLLMHostTests/LLMHostPreparationTests.swift`
- Modify: `toolkit/Tests/LocalAgentLLMLocalTests/PreparedLocalSessionTests.swift`
- Modify: `toolkit/Tests/LocalAgentLLMCloudTests/PreparedCloudSessionTests.swift`

**Interfaces:**
- Produces `LLMRunPreparationBridge.prepareAndCommit(startRequest:) -> HostRunHandleDTO`.
- Splits local/cloud preparation into `reserveSession`, registry allocation with cleanup owner, Rust `registerPreparedSession`, and `openRegisteredSession`; no local load/provider session exists before registration receipt.
- Produces one sanitized `PreparedLLMSession` projection with exact target/binding/requirements/capability/parameters/registration/epoch and opaque egress attestation.
- Initial denial, token expiry, open failure, commit rejection/conflict, and host shutdown use `begin_abort_preparation`; a registered session releases only after matching cleanup ack and close receipt.
- Immediately after Rust registration succeeds, cleanup is possible even if opening has not started, is blocked between substeps, has just installed the driver, or Rust commit has succeeded while its FFI return is blocked.
- Produces `reconcilePreparation(_:) -> PreparationReconciliationDTO` over `local_agent_runtime_bridge_reconcile_preparation`. Only an explicit Rust commit rejection or a reconciled `pending` result proves that abort is safe; transport/copy/decode/cancellation errors after entering `commit_start` are outcome-unknown and never directly call `begin_abort_preparation`.

- [x] **Step 1: Write failing ordering and compensation tests**

Use spies to assert exact call order and crash points:

```swift
@Test func localRegistrationPrecedesModelLoad() async throws {
    let harness = try await PreparationHarness.local()
    _ = try await harness.bridge.prepareAndCommit(startRequest: harness.start)
    #expect(await harness.trace == [
        "rust.preview", "swift.reserve", "rust.register",
        "local.load", "swift.attest", "rust.commit"
    ])
}

@Test func commitConflictAfterOpenUsesPreparedCleanupReceipt() async throws {
    let harness = try await PreparationHarness.cloud(commitFailure: .conflict)
    await #expect(throws: LLMHostFailure.self) {
        try await harness.bridge.prepareAndCommit(startRequest: harness.start)
    }
    #expect(await harness.provider.closeCount == 1)
    #expect(await harness.rust.cleanupAckCount == 1)
    #expect(await harness.rust.closedReceiptCount == 1)
    #expect(await harness.rust.globalLeaseState == .idle)
}
```

Cover pre-registration failure (no Rust cleanup command), duplicate abort/cleanup, lost/rejected cleanup acknowledgement, local load failure, cloud credential lease release, and token renewal during a delayed approval/load. Add deterministic crash/race cases at all four boundaries: after Rust accepts registration while its FFI return is blocked, during open, after open before commit, and after Rust commit before FFI return. For both local and cloud, inject failure after every open substep and assert the cleanup owner releases exactly the resources already acquired and Rust keeps the lease `releasing` until the exact close receipt.

Add three mandatory ambiguous-commit tests: the start callback already arrived before the lost FFI reply, the callback is delayed until after reconciliation, and the command inbox returns backpressure before accepting the start. In all three cases reconciliation returns the exact committed handle, `begin_abort_preparation` is never called, the driver/cleanup owner stays registered, and the single persisted start command is eventually accepted. Add a fourth test where reconciliation returns `pending`; only that path may attempt the pending→aborting CAS. Race that CAS against a delayed Phase C commit and prove exactly one wins: abort winner closes the prepared session and commit fails, while commit winner returns `preparation.already_committed`, reconciles the handle, and never calls cleanup. If reconciliation itself is unavailable, assert state remains `commitOutcomeUnknown`, no backend close occurs, and the stable `execution.commit_outcome_unknown` diagnostic is exposed for retry/restart recovery.

- [x] **Step 2: Run RED**

```bash
swift test --package-path toolkit --filter LLMHostPreparationTests
swift test --package-path toolkit --filter PreparedLocalSessionTests
swift test --package-path toolkit --filter PreparedCloudSessionTests
swift test --package-path toolkit --filter RustRuntimeClientContractTests
```

Expected: current local/cloud `prepareSession` opens resources without a Rust registration boundary, the bridge has no reconciliation entry, and an ambiguous commit result cannot be distinguished from a safe-to-abort failure.

- [x] **Step 3: Split reserve/open and implement the coordinator**

Use separate reservation and opened-session types so resource readiness cannot be forged:

```swift
package struct ReservedHostSession: Sendable {
    let reservation: HostSessionReservation
    let registration: PreparedSessionRegistrationDTO
    let cleanupOwner: PreparedSessionCleanupOwner
}

package protocol PreparedSessionCleanupOwner: Sendable {
    func open() async throws -> OpenedHostSession
    func close() async -> PreparedSessionCloseDisposition
}

package struct OpenedHostSession: Sendable {
    let prepared: PreparedLLMSession
    let driver: any LLMHostSessionDriver
}

public struct PreparedLLMSession: Sendable {
    public let handle: String
    public let capabilitySnapshot: CapabilitySnapshot
    public let publicCapabilityAttestation: PreparedCapabilityAttestationDTO
    public let hostBindingID: String
    public let hostBindingRevision: UInt64
    public let hostBindingHash: String
    public let preparedSessionRegistrationDigest: String
    public let hostAttestation: HostAttestationV1Document
    public let credentialUseLeaseID: String?
    public let egressAttestationDigest: String
    public let sanitizedSnapshotID: String
    public let hostProcessEpoch: HostProcessEpoch
}
```

Consume the field-based reconciliation DTO frozen in Task 1: `committed` requires only `handle`, `pending` requires neither optional payload, and `aborting` requires only `cleanup_identity`. Reject missing, extra, or conflicting payloads before mutating the registry.

For local targets, reserve validates exact installation/catalog/capability/parameters and persists an allocated-not-open snapshot; `cleanupOwner.open()` alone acquires the active/loaded leases and loads C++. For cloud targets, reserve creates the cleanup owner first, atomically acquires the credential generation-use lease through it, validates target/profile/egress, and persists the sanitized snapshot; opening alone creates the provider session and adds each new resource to the same cleanup stack. The coordinator installs this already-live owner in the registry before Rust registration. Local computes the `egress-subject-local-v1` `not_applicable` digest frozen in Task 1. Both derive a provider-neutral `PreparedCapabilityAttestationDTO`, construct and retain the exact shared `HostAttestationV1Document`, and pass those same objects to `HostAttestationDTO`; neither reconstructs the attestation later from partial `PreparedLLMSession` fields.

`HostSessionReservation`, `ReservedLocalSession`, and `ReservedCloudSession` are distinct non-runnable types. `PreparedLLMSession` is constructed only after `openRegisteredSession` succeeds, so the existing local loaded/active lease IDs and cloud bound credential-use lease revision cannot appear on an allocated-not-open reservation.

The coordinator renews only an unchanged preview and never transmits prompt content. It first allocates the registry entry with `cleanupOwner`, marks `registrationInFlight`, then invokes Rust registration, marks `registeredNotOpen` after the receipt, begins opening, and atomically upgrades the entry with the driver. A cleanup command arriving before the registration call returns is still accepted and wins the lifecycle race. The coordinator sets `commitInFlight` before calling Rust commit. A valid committed start command may therefore be accepted before the FFI result returns.

Classify commit completion exactly. `isAuthoritativeRustRejection` means a fully decoded Rust error envelope produced by a pre-commit/rolled-back branch; C allocation/copy failures, invalid UTF-8/JSON, missing response, and task cancellation never satisfy it:

```swift
do {
    let handle = try await rust.commitStart(request)
    try await registry.markCommitted(handle)
    return handle
} catch let error where error.isAuthoritativeRustRejection {
    try await abortRegisteredPreparation(error)
    throw error
} catch {
    try await registry.markCommitOutcomeUnknown(sessionHandle)
    let outcome: PreparationReconciliationDTO
    do {
        outcome = try await rust.reconcilePreparation(.init(
            preparationID: preview.preparationID,
            proposedRunID: preview.proposedRunID,
            tokenDigest: preview.tokenDigest
        ))
    } catch {
        throw LLMHostFailure.commitOutcomeUnknown
    }
    switch outcome.status {
    case .committed:
        let handle = try outcome.requireCommittedHandle()
        try await registry.applyReconciliation(outcome, to: sessionHandle)
        return handle
    case .pending:
        do {
            try await abortRegisteredPreparationOnlyIfStillPending(error)
            throw error
        } catch LLMHostFailure.preparationAlreadyCommitted {
            return try await reconcileCommittedHandle(preview, sessionHandle)
        }
    case .aborting:
        let cleanupIdentity = try outcome.requireCleanupIdentity()
        try await registry.adoptCleanup(cleanupIdentity, for: sessionHandle)
        throw error
    }
}
```

`markCommitOutcomeUnknown` is a CAS from `commitInFlight`; it is a no-op if a start callback already advanced the entry to `committed`, so the lost FFI response cannot regress known committed state. `abortRegisteredPreparationOnlyIfStillPending` waits for Rust's pending→aborting CAS before invoking any cleanup owner. If a delayed commit wins, `preparation.already_committed` forces another reconciliation and no cleanup. An error calling reconciliation leaves `commitOutcomeUnknown`/`committed` intact and returns `execution.commit_outcome_unknown`; it never performs local cleanup speculatively. Retry uses the same three identities. A valid start callback may independently upgrade the registry to committed, but reconciliation is still used to recover the exact `HostRunHandle`. The registry remains until an exact close receipt is accepted, or remains quarantined with the lease releasing after timeout/rejected acknowledgement.

- [x] **Step 4: Run GREEN and Phase 2/3 preparation regressions**

```bash
swift test --package-path toolkit --filter LLMHostPreparationTests
swift test --package-path toolkit --filter PreparedLocalSessionTests
swift test --package-path toolkit --filter PreparedCloudSessionTests
swift test --package-path toolkit --filter RunPreparationCoordinatorTests
swift test --package-path toolkit --filter RustRuntimeClientContractTests
git diff --check
```

Expected: ordering, every open-substep failure, all registration/open/commit race windows, callback-arrived/delayed/backpressured reconciliation, and all proven compensation paths pass; no ambiguous commit is aborted; local/cloud snapshots remain sanitized and exact-revision-bound.

- [x] **Step 5: Commit**

```bash
git add toolkit/Sources/LocalAgentLLMHost toolkit/Sources/LocalAgentLLMCore \
  toolkit/Sources/LocalAgentLLMLocal toolkit/Sources/LocalAgentLLMCloud \
  toolkit/Sources/LocalAgentBridge toolkit/Sources/CLocalAgentRuntime \
  toolkit/Tests/LocalAgentLLMHostTests/LLMHostPreparationTests.swift \
  toolkit/Tests/LocalAgentLLMLocalTests/PreparedLocalSessionTests.swift \
  toolkit/Tests/LocalAgentLLMCloudTests/PreparedCloudSessionTests.swift
git commit -m "feat: register llm sessions before opening resources"
```

---

### Task 8: Dispatch Start/Resume to Local or Cloud and Normalize Lifecycle Events

**Files:**
- Modify: `toolkit/Sources/LocalAgentLLMHost/LLMHostRuntime.swift`
- Modify: `toolkit/Sources/LocalAgentLLMHost/LLMHostSessionDriver.swift`
- Modify: `toolkit/Sources/LocalAgentLLMHost/LocalHostSessionDriver.swift`
- Modify: `toolkit/Sources/LocalAgentLLMHost/CloudHostSessionDriver.swift`
- Modify: `toolkit/Sources/LocalAgentLLMLocal/LocalModelRuntime.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCloud/CloudLLMRuntime.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCloud/CloudHTTPTransport.swift`
- Create: `toolkit/Tests/LocalAgentLLMHostTests/LLMHostGenerationTests.swift`
- Modify: `toolkit/Tests/LocalAgentLLMLocalTests/LocalModelRuntimeTests.swift`
- Modify: `toolkit/Tests/LocalAgentLLMCloudTests/CloudLLMRuntimeTests.swift`
- Modify: `toolkit/Tests/LocalAgentLLMCloudTests/CloudHTTPTransportTests.swift`

**Interfaces:**
- Acknowledges a valid start/resume command before awaiting incremental user approval, but starts the backend at most once for that command identity.
- `makeAuthorizedLaunch` recomputes the complete semantic request; cloud may wait for egress approval, local is non-egress. Invoking the returned one-shot launch is the only operation covered by the ten-second operation-start watchdog.
- Emits `generation_started(commandID, opaqueBackendOperationID)` only after URLSession/C++ returns a live operation, then forwards normalized events through `LLMEventSequencer`.
- The same semantic command drives local or cloud solely according to the pre-registered opaque Swift session; Rust cannot select a backend.
- Converts a thrown Swift `AgentLLMFailure` into a normalized `failed` event containing only `not_ready | unsupported_capability | context_exceeded | egress_denied | rate_limited | generation_failed | stream_interrupted | cancelled`; Rust bridge protocol errors keep their `llm.*`/`execution.*` codes and are never disguised as provider failures.

- [ ] **Step 1: Write failing local/cloud parity and lifecycle tests**

Run the same test vector through fake local and cloud drivers. Assert `ack` precedes approval, no `generation_started` appears before a live operation, start/resume use the exact turn ID, and approval wait does not trip the operation timer:

```swift
@Test(arguments: [HostRouteFixture.local, .cloud])
func startEmitsTheSameNormalizedLifecycle(route: HostRouteFixture) async throws {
    let harness = try await HostGenerationHarness.make(route: route)
    await harness.submit(harness.startCommand)
    #expect(await harness.rust.acknowledgements.count == 1)
    #expect(await harness.rust.events.map(\.kind) == [
        .generationStarted, .textDelta, .generationCompleted
    ])
    #expect(await harness.rust.events.last?.completion?.outcome == .finalResponse)
}

@Test func changedDisclosureFailsBeforeCloudTransport() async throws {
    let harness = try await HostGenerationHarness.make(route: .cloud)
    await harness.submit(harness.startCommand.mutatingModelInput())
    #expect(await harness.transport.requestCount == 0)
    #expect(await harness.rust.lastFailureCode == "generation.disclosure_mismatch")
}
```

Add a backend-start hang after authorization and require one terminal failure without falsely emitting `generation_started`.

- [ ] **Step 2: Run RED**

```bash
swift test --package-path toolkit --filter LLMHostGenerationTests
```

Expected: the host actor cannot dispatch semantic commands or emit explicit start lifecycle events.

- [ ] **Step 3: Add route adapters and an approval-excluding launch boundary**

Split driver work:

```swift
package protocol LLMHostSessionDriver: Sendable {
    func makeAuthorizedLaunch(
        for turn: HostGenerationTurn,
        mode: HostGenerationMode
    ) async throws -> AuthorizedHostGenerationLaunch
    func cancel() async throws
    func close() async throws
}

package struct HostGenerationOperation: Sendable {
    let opaqueOperationID: String
    let events: LLMBackendEventStream
}
```

Cloud `makeAuthorizedLaunch` reuses `CloudSemanticTurnValidator` and `ProviderEgressPolicy`; only the returned one-shot closure reaches adapter encoding/transport. Split cloud transport creation so invoking that closure returns only after the `URLSessionTask` has been created/resumed and owns a live stream. Local validates the same semantic input/source/tool-result identities, resolves attachments locally, then returns a closure that starts C++. The actor awaits approval without a timeout, applies the ten-second timeout only around `launch.run()`, submits `generation_started`, converts thrown backend failures to the limited public taxonomy, and pumps events without an intermediate dropping buffer.

- [ ] **Step 4: Run GREEN and backend regressions**

```bash
swift test --package-path toolkit --filter LLMHostGenerationTests
swift test --package-path toolkit --filter LocalModelRuntimeTests
swift test --package-path toolkit --filter CloudLLMRuntimeTests
swift test --package-path toolkit --filter CloudHTTPTransportTests
git diff --check
```

Expected: local/cloud parity, exact disclosure failure, approval timing, live-operation start, and no-drop pump tests pass.

- [ ] **Step 5: Commit**

```bash
git add toolkit/Sources/LocalAgentLLMHost toolkit/Sources/LocalAgentLLMLocal/LocalModelRuntime.swift \
  toolkit/Sources/LocalAgentLLMCloud/CloudLLMRuntime.swift \
  toolkit/Sources/LocalAgentLLMCloud/CloudHTTPTransport.swift \
  toolkit/Tests/LocalAgentLLMHostTests/LLMHostGenerationTests.swift \
  toolkit/Tests/LocalAgentLLMLocalTests/LocalModelRuntimeTests.swift \
  toolkit/Tests/LocalAgentLLMCloudTests/CloudLLMRuntimeTests.swift \
  toolkit/Tests/LocalAgentLLMCloudTests/CloudHTTPTransportTests.swift
git commit -m "feat: drive local and cloud sessions through host commands"
```

---

### Task 9: Commit Final Assistant Output and Resume Complete Ordered Tool Batches

**Files:**
- Modify: `rust-core/src/execution/host_llm_worker.rs`
- Modify: `rust-core/src/execution/react_worker.rs`
- Modify: `rust-core/src/execution/execution_service.rs`
- Modify: `rust-core/src/ffi_bridge.rs`
- Modify: `rust-core/src/storage/runtime_state.rs`
- Modify: `rust-core/src/storage/sqlite_runtime_state.rs`
- Modify: `rust-core/src/storage/agent_os_state/mod.rs`
- Modify: `rust-core/src/storage/agent_os_state/in_memory.rs`
- Create: `toolkit/Tests/LocalAgentLLMHostTests/LLMHostToolLoopTests.swift`
- Create: `rust-core/tests/integration/host_llm_product_path.rs`
- Modify: `rust-core/tests/integration.rs`

**Interfaces:**
- Rust accumulates text/tool fragments per turn but executes no tool until a valid `generation_completed` terminal arrives.
- `tool_calls_ready` must exactly match all completed calls in first-appearance order; malformed batches fail with `llm.turn.invalid_tool_batch`.
- V1 executes calls sequentially, persists every normalized success/failure result, and enqueues exactly one resume command containing the entire ordered result batch.
- Host/user-mediated tool results continue through existing Rust tool/approval APIs, but are bound to run/turn/call IDs and cannot resume another or expired continuation.
- Expanded disclosure denial maps to Rust `execution.egress_denied` and closes before the affected network request.
- A valid `final_response` atomically writes one formal assistant output with stable identity `assistant:<runID>:<generationTurnID>`, records `finishReason`, changes `logicalOutcome` to `succeeded`, moves the global lease to `releasing`, and inserts one `close_session` command. The output is immediately observable while `resourceLifecycle` remains `awaitingCloseCommandAck`/`awaitingSessionClosed`/`quarantined`.
- `final_response` is valid only when no tool call was started or accumulated. Empty text is a valid formal output. `length`, `content_filtered`, and provider-neutral `other` finish reasons are preserved in the logical outcome/output metadata; duplicate terminal replay cannot duplicate output or run events.

- [ ] **Step 1: Write failing terminal, batch, and incremental-egress tests**

Cover incomplete/duplicate/reordered/unknown call IDs, text plus tools, two sequential tools with one host-pending result, one resume batch, denial, and restart-expired results. Also cover final text, empty final text, every finish reason, duplicate final terminal, conflict between final and any started tool call, and a close timeout after a readable answer:

```rust
#[test]
fn two_calls_execute_sequentially_and_enqueue_one_batched_resume() {
    let harness = HostWorkerHarness::started();
    harness.submit(tool_call("call-a", "contacts.search"));
    harness.submit(tool_call("call-b", "calendar.list"));
    harness.submit(tool_terminal(["call-a", "call-b"]));
    assert_eq!(harness.tool_execution_order(), ["call-a", "call-b"]);
    let resume = harness.only_resume_command();
    assert_eq!(resume.payload().tool_results().iter().map(|v| v.call_id()).collect::<Vec<_>>(),
               ["call-a", "call-b"]);
}

#[test]
fn final_response_persists_output_before_close_finishes() {
    let harness = HostWorkerHarness::started();
    harness.submit(text_delta("answer"));
    harness.submit(final_terminal(HostFinishReason::Stop));
    assert_eq!(harness.observed_assistant_output(), Some("answer"));
    assert!(matches!(harness.logical_outcome(), LogicalRunOutcome::Succeeded { .. }));
    assert_eq!(harness.resource_lifecycle(), ResourceLifecycle::AwaitingCloseCommandAck);
    assert_eq!(harness.only_close_command().session_handle(), harness.session_handle());
}

#[test]
fn duplicate_final_and_close_timeout_do_not_hide_or_duplicate_output() {
    let harness = HostWorkerHarness::started();
    let terminal = final_terminal(HostFinishReason::Length);
    harness.submit(text_delta("partial but valid"));
    harness.submit(terminal.clone());
    harness.submit(terminal);
    harness.fire_close_timeout();
    assert_eq!(harness.assistant_outputs().len(), 1);
    assert_eq!(harness.observed_assistant_output(), Some("partial but valid"));
    assert!(matches!(harness.resource_lifecycle(), ResourceLifecycle::Quarantined { .. }));
}
```

Swift integration must prove a sensitive result waits for incremental approval, denial yields `egress_denied`, and transport request count remains unchanged.

- [ ] **Step 2: Run RED**

```bash
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test integration host_llm_product_path -- --nocapture
swift test --package-path toolkit --filter LLMHostToolLoopTests
```

Expected: the current synchronous worker supports one tool call at a time and cannot persist/emit a complete V2 batch.

- [ ] **Step 3: Advance only on the structured generation terminal**

Add a durable accumulator and stable formal-output identity:

```rust
pub struct HostTurnAccumulator {
    generation_turn_id: String,
    assistant_preamble: String,
    open_calls: BTreeMap<String, PartialToolCall>,
    completed_calls: Vec<ExecutionToolCall>,
}
```

On a valid `tool_calls_ready` terminal, persist the assistant preamble once as turn context/UI preamble—not as the final assistant answer—then execute the ordered batch sequentially through `ExecutionToolExecutor`, persisting partial progress after each call in the same aggregate authority. If a result is pending/approval-required, suspend with the remaining batch intact. When all results exist, recompute `agent-input:v1`, `source-revisions:v1`, and `generation-disclosure:v1`, then atomically transition to `awaiting_resume_command_ack` and insert one resume outbox row. Unknown data labels become `unknown_data`/`unknown`.

On a valid `final_response`, call `apply_event_transactionally` once to persist the exact accumulated assistant text under its stable output ID, append the formal output and `run.completed` Agent execution events, record finish reason and `logicalOutcome = succeeded`, clear the execution phase, transition the lease/resource lifecycle into release, and enqueue exactly one close command. This transaction is the public answer commit point; session cleanup is a later physical lifecycle. Observation APIs return the answer even if close acknowledgement/receipt times out. Failure/cancellation use the same separation without creating a success output.

- [ ] **Step 4: Run GREEN and tool regressions**

```bash
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test integration -- --nocapture
swift test --package-path toolkit --filter LLMHostToolLoopTests
git diff --check
```

Expected: valid batches resume once; invalid batches never execute; final output commits exactly once and remains readable through cleanup timeout; sensitive denial sends no request; existing legacy tool tests remain green.

- [ ] **Step 5: Commit**

```bash
git add rust-core/src/execution rust-core/src/ffi_bridge.rs rust-core/src/storage \
  rust-core/tests/integration.rs rust-core/tests/integration/host_llm_product_path.rs \
  toolkit/Tests/LocalAgentLLMHostTests/LLMHostToolLoopTests.swift
git commit -m "feat: resume host llm runs with ordered tool batches"
```

---

### Task 10: Separate Cancel, Backend Stop, Close, and Lease-Release Completion

**Files:**
- Modify: `rust-core/src/execution/host_llm_worker.rs`
- Modify: `rust-core/src/execution/host_llm_dispatcher.rs`
- Modify: `rust-core/src/storage/runtime_state.rs`
- Modify: `rust-core/src/storage/sqlite_runtime_state.rs`
- Modify: `rust-core/src/storage/agent_os_state/mod.rs`
- Modify: `rust-core/src/storage/agent_os_state/in_memory.rs`
- Modify: `toolkit/Sources/LocalAgentLLMHost/LLMHostRuntime.swift`
- Modify: `toolkit/Sources/LocalAgentLLMHost/LLMHostSessionRegistry.swift`
- Modify: `toolkit/Sources/LocalAgentLLMLocal/LocalModelRuntime.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCloud/CloudLLMRuntime.swift`
- Create: `toolkit/Tests/LocalAgentLLMHostTests/LLMHostCancellationTests.swift`
- Modify: `rust-core/tests/contract/host_llm_worker.rs`

**Interfaces:**
- Cancel, final/failure, and close transitions are idempotent and produce at most one cancel plus one close command identity.
- Accepted cancel waits for backend `cancelled`; accepted close waits for `session_closed`. Neither acknowledgement satisfies the terminal watchdog.
- `LogicalRunOutcome` and `ResourceLifecycle` change independently. Logical success/failure/cancellation may be persisted before close, but the run is fully terminal and the global lease is released only after an accepted exact `session_closed` or the old-epoch recovery transaction records `epoch_ended`.
- Rejected close/prepared-cleanup acknowledgement, missing close receipt, or close backend failure moves resources to `quarantined` and keeps the lease `releasing`; it never overwrites an already committed success output with a generic run failure. The lifecycle diagnostic remains separately observable.
- Local close releases generation/session only; loaded model may remain in RAM. Cloud close releases provider session and exact credential-use lease.

- [ ] **Step 1: Write failing race and watchdog tests**

Cover terminal-first, cancel-first, simultaneous cancel/terminal, callback-blocked local cancel, backend-blocked local cancel, provider cancel-once, missing cancelled, rejected close/prepared-cleanup acknowledgement, missing close, late exact close, duplicate close, and logical success while physical cleanup is quarantined:

```swift
@Test func explicitAndTerminalRaceCallsBackendCancelAtMostOnce() async throws {
    let harness = try await CancellationHarness.cloud()
    async let cancel: Void = harness.cancelRun()
    async let terminal: Void = harness.emitFinal()
    _ = try await (cancel, terminal)
    #expect(await harness.provider.cancelCount <= 1)
    #expect(await harness.provider.closeCount == 1)
    #expect(await harness.rust.terminalRunCount == 1)
}

@Test func closeAckWithoutSessionClosedKeepsLeaseReleasing() async throws {
    let harness = try await CancellationHarness.closeNeverCompletes()
    await harness.advance(by: .seconds(11))
    #expect(await harness.rust.failureCode == "llm.session.close_timeout")
    #expect(await harness.rust.globalLeaseState == .releasing)
    #expect(await harness.host.sessionState == .quarantined)
}

@Test func rejectedPreparedCleanupQuarantinesWithoutReleasingLease() async throws {
    let harness = try await CancellationHarness.registeredButNotOpened()
    await harness.rustDispatchPreparedCleanup()
    await harness.hostRejectCleanupAck()
    #expect(await harness.rust.resourceLifecycle == .quarantined)
    #expect(await harness.rust.globalLeaseState == .releasing)
    #expect(await harness.rust.isFullyTerminal == false)
}
```

- [ ] **Step 2: Run RED**

```bash
swift test --package-path toolkit --filter LLMHostCancellationTests
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test contract host_llm_worker -- --nocapture
```

Expected: lifecycle acknowledgements are not yet separated from backend terminal/close confirmation.

- [ ] **Step 3: Add independent persisted watchdogs and cancel-once arbitration**

Persist deadlines as `(kind, command_id, deadline_millis, state_revision)`. A deadline handler performs a CAS against the same state/command before transitioning the resource axis. Use these stable lifecycle diagnostics:

```text
llm.command.ack_timeout
llm.cancel.stop_timeout
llm.session.close_timeout
```

The Swift actor claims a cancel/close command ID before calling the backend. Duplicate claimants await the same task. It submits `cancelled(cancelCommandID)` only after backend confirmation and `session_closed(closeCommandID)` only after all session resources are released. Rust applies each through the unified event transaction; accepted `session_closed` changes only the resource axis to `closed`, completes lease release, and derives fully-terminal status from both axes. Swift tombstones the handle only after Rust accepts the close event. A rejected acknowledgement/timeout keeps the registry entry quarantined for epoch recovery.

- [ ] **Step 4: Run GREEN and native/cloud cancel regressions**

```bash
swift test --package-path toolkit --filter LLMHostCancellationTests
swift test --package-path toolkit --filter LocalModelRuntimeTests
swift test --package-path toolkit --filter CloudLLMRuntimeTests
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test contract host_llm_worker -- --nocapture
git diff --check
```

Expected: races have one deterministic logical outcome, backend cancel/close are once-only, quarantined cleanup cannot release a lease or hide output, and the exact close gate is enforced.

- [ ] **Step 5: Commit**

```bash
git add rust-core/src/execution rust-core/src/storage \
  rust-core/tests/contract/host_llm_worker.rs toolkit/Sources/LocalAgentLLMHost \
  toolkit/Sources/LocalAgentLLMLocal/LocalModelRuntime.swift \
  toolkit/Sources/LocalAgentLLMCloud/CloudLLMRuntime.swift \
  toolkit/Tests/LocalAgentLLMHostTests/LLMHostCancellationTests.swift
git commit -m "feat: separate host llm lifecycle watchdogs"
```

---

### Task 11: Reconcile Host Epochs and Prevent Duplicate Host Tool Effects

**Files:**
- Modify: `rust-core/src/core/runtime.rs`
- Modify: `rust-core/src/ffi_bridge.rs`
- Modify: `rust-core/src/execution/host_llm_worker.rs`
- Modify: `rust-core/src/storage/runtime_state.rs`
- Modify: `rust-core/src/storage/sqlite_runtime_state.rs`
- Modify: `rust-core/src/storage/agent_os_state/mod.rs`
- Modify: `rust-core/src/storage/agent_os_state/in_memory.rs`
- Create: `rust-core/tests/contract/host_llm_recovery.rs`
- Modify: `rust-core/tests/contract.rs`
- Create: `toolkit/Sources/LocalAgentLLMHost/HostToolEffectLedger.swift`
- Create: `toolkit/Tests/LocalAgentLLMHostTests/LLMHostRecoveryTests.swift`
- Modify: `apps/LocalAgentApp/LocalAgentApp/Tools/NativeHostToolDriver.swift`
- Create: `apps/LocalAgentApp/LocalAgentAppTests/HostToolEffectLedgerTests.swift`

**Interfaces:**
- Splits Rust construction into storage open → old-epoch invalidation → provider-independent replay; LLM-dependent waiting state is never exposed first.
- One unified aggregate recovery transaction per old run appends `run.interrupted(execution.llm_continuation_lost)`, sets `logicalOutcome = interrupted`, invalidates pending tools/approvals/outbox/session cross-link, records `resourceLifecycle = closed(epoch_ended)`, and releases the old lease. This remains atomic even when the run previously committed a readable assistant output; recovery preserves that output and adds the interruption lifecycle/status.
- Old uncommitted preparation recovery persists `epoch_ended`, cancels cleanup outbox, and releases without creating a run event.
- `legacy_starting_or_running` is included, not just legacy waiting-tool/approval: startup atomically abandons the legacy continuation, appends the interruption event, clears the active execution marker, and releases its old lease before pending actions are visible.
- Swift recovery deletes an old-epoch cloud credential-use lease only after proving that no current-epoch provider task/session owns it; local old-epoch active-session leases reconcile without unloading a current-epoch model.
- Produces a Swift SQLite effect ledger with `prepared | committed | outcome_unknown`, stable effect ID `runID + callID + toolName`, and `host-tool-effect-result:v1` result digest.

- [ ] **Step 1: Write failing restart and effect-idempotency tests**

Crash/reopen every V2 record whose `resourceLifecycle != closed`, including `logicalOutcome = succeeded/failed/cancelled` while awaiting close, plus legacy starting/running/waiting-tool/approval states. Add the exact crash window after a legacy model request starts but before any terminal response. Assert recovery occurs before pending action enumeration, late ack/event/tool/approval returns `execution.continuation_expired`, no outbox dispatch happens for the old epoch, active legacy state is cleared, and the old lease is released in the same transaction as the interruption event.

Inject failure after interruption-event write, logical/resource state write, tool/approval invalidation, outbox cancellation, cross-link close, active-marker clear, and lease release. Reopen must expose either the entire pre-recovery state (and retry recovery before replay) or the complete recovered state—never an interrupted run that still owns an active continuation/lease.

For tools:

```swift
@Test func committedEffectReplaysStoredSafeResultWithoutExecution() async throws {
    let harness = try EffectHarness.committedFixture()
    let result = try await harness.driver.execute(harness.request)
    #expect(result == harness.safeReplayResult)
    #expect(await harness.tool.executionCount == 0)
}

@Test func crashAfterPreparedBecomesOutcomeUnknownAndNeverAutoRepeats() async throws {
    let harness = try EffectHarness.crashedAfterPrepared()
    await #expect(throws: HostToolEffectError.outcomeUnknown) {
        try await harness.driver.execute(harness.request)
    }
    #expect(await harness.tool.executionCount == 0)
}
```

- [ ] **Step 2: Run RED**

```bash
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test contract host_llm_recovery -- --nocapture
swift test --package-path toolkit --filter LLMHostRecoveryTests
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project apps/LocalAgentApp/LocalAgentApp.xcodeproj -scheme LocalAgentApp \
  -destination "platform=iOS Simulator,id=$LOCAL_AGENT_PHASE4_IPHONE_UDID" \
  -only-testing:LocalAgentAppTests/HostToolEffectLedgerTests
```

Expected: current runtime replays waiting runs during construction and the host tool path has no durable effect identity.

- [ ] **Step 3: Gate bootstrap on epoch reconciliation and wrap side effects**

Refactor construction so the unified repository—not separate event and Agent OS stores—owns invalidation:

```rust
let runtime_state = SqliteRuntimeStateStore::open_and_migrate(config.database_path())?;
runtime_state.reconcile_for_host_epoch(&config.host_process_epoch)?;
let mut runtime = AgentRuntime::open_without_replay(config, runtime_state.clone(), registry)?;
runtime.replay_provider_independent_state()?;
```

`reconcile_for_host_epoch` enumerates and recovers old V2/legacy aggregates using `recover_run_for_epoch` before constructing any public pending-action view or starting the dispatcher. Compatibility observation APIs read the post-reconciliation aggregate. No call to an in-memory `ExecutionEventLog`, `RunSnapshotRepository`, or separate `.agent-os` connection participates in recovery.

Persist effect `prepared` before invoking a side-effecting tool. On successful normalized result, atomically store the canonical result digest and safe replay envelope. During startup, any `prepared` row without a committed result becomes `outcome_unknown`. Read-only tools may retry only when their manifest declares idempotency; other effects require reconciliation/user action.

- [ ] **Step 4: Run GREEN and runtime replay regressions**

```bash
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test contract host_llm_recovery -- --nocapture
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test integration runtime_replay -- --nocapture
swift test --package-path toolkit --filter LLMHostRecoveryTests
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project apps/LocalAgentApp/LocalAgentApp.xcodeproj -scheme LocalAgentApp \
  -destination "platform=iOS Simulator,id=$LOCAL_AGENT_PHASE4_IPHONE_UDID" \
  -only-testing:LocalAgentAppTests/HostToolEffectLedgerTests
git diff --check
```

Expected: legacy starting/running and every unclosed V2 resource lifecycle are atomically interrupted before replay; committed assistant output remains readable with interruption status; committed/outcome-unknown effects never execute twice.

- [ ] **Step 5: Commit**

```bash
git add rust-core/src/core/runtime.rs rust-core/src/ffi_bridge.rs rust-core/src/execution \
  rust-core/src/storage rust-core/tests/contract.rs \
  rust-core/tests/contract/host_llm_recovery.rs toolkit/Sources/LocalAgentLLMHost \
  toolkit/Tests/LocalAgentLLMHostTests/LLMHostRecoveryTests.swift \
  apps/LocalAgentApp/LocalAgentApp/Tools/NativeHostToolDriver.swift \
  apps/LocalAgentApp/LocalAgentAppTests/HostToolEffectLedgerTests.swift
git commit -m "feat: recover host llm epochs and tool effects"
```

---

### Task 12: Enable `host_slot_v2`, Preserve Legacy Coexistence, and Complete the Phase 4 Gate

**Files:**
- Modify: `rust-core/src/run_snapshot/resolver.rs`
- Modify: `rust-core/src/execution/execution_service.rs`
- Modify: `rust-core/src/ffi_bridge.rs`
- Verify: `rust-core/tests/fixtures/architecture/legacy_llm_allowlist.txt`
- Modify: `rust-core/tests/lint/llm_phase_four_architecture.rs`
- Modify: `rust-core/tests/lint.rs`
- Modify: `toolkit/Package.swift`
- Modify: `toolkit/Sources/LocalAgentBridge/AgentOSDTOs.swift`
- Modify: `toolkit/Sources/LocalAgentBridge/RustAgentOSBridgeGateway.swift`
- Modify: `toolkit/Sources/LocalAgentBridge/RustRuntimeClient.swift`
- Modify: `apps/LocalAgentApp/LocalAgentApp/App/LocalAgentApp.swift`
- Modify: `apps/LocalAgentApp/LocalAgentApp/Composition/AppBootstrapper.swift`
- Modify: `apps/LocalAgentApp/LocalAgentApp/Runtime/AgentRuntimeService.swift`
- Create: `apps/LocalAgentApp/LocalAgentAppTests/LLMHostCompositionTests.swift`
- Create: `toolkit/Tests/LocalAgentLLMHostTests/LLMHostProductPathTests.swift`
- Create: `scripts/run-llm-phase-4-contracts.sh`
- Modify: `docs/superpowers/specs/2026-07-10-swift-llm-system-design.md`
- Modify: `docs/model-providers/cloud-provider-adapter-architecture.md`

**Interfaces:**
- Produces a versioned Rust-owned `ProfileExecutionRoute { profileID, profileRevision, llmBindingSchema: legacy_v1 | host_slot_v2 }` for an exact requested profile revision. The FFI DTO contains no provider/model semantics.
- Production App asks Rust for that exact route descriptor: `legacy_v1` calls the existing start path; `host_slot_v2` calls `LLMRunPreparationBridge` and never enters `BridgeExecutionModelClient::next_turn`. Missing/stale/mismatched route data fails closed; target availability is never used to infer or fall back to a route.
- The existing `RunSnapshotResolver::resolve` remains the legacy-only resolver. If a V2 profile is incorrectly sent to legacy `start_run`, Rust returns `execution.host_slot_v2_requires_preparation`; only preview/register/commit can create a V2 run.
- Both endpoints re-read the current exact route in their own authoritative transaction: legacy `start_run` accepts only `legacy_v1`, and V2 preview/commit accepts only `host_slot_v2` with the same profile revision. A Swift route DTO cannot override this check.
- Both routes use the same App epoch and durable global run lease. A concurrent legacy start/V2 commit yields one winner and `execution.global_run_busy` for the loser without a partial snapshot/worker.
- App composition installs the host dispatcher only after Rust/Swift recovery. Scene suspension/resumption calls the explicit dispatcher lifecycle hooks. Runtime shutdown unregisters/quiesces the host and awaits dispatcher join before deinitializing the Swift host/subsystems; a later bootstrap installs a fresh context generation.
- Architecture lint forbids provider/credential/model-path/adapter/C++ concepts in new Rust V2 code and forbids growth of the exact legacy allowlist.
- `scripts/run-llm-phase-4-contracts.sh` is the deterministic release gate and invokes Phase 3 first.

- [ ] **Step 1: Write failing local/cloud/legacy production-path tests and lint**

Add product tests for:

```text
Rust preview -> Swift local reserve/register/open -> Rust commit -> tool batch -> resume -> final -> close
Rust preview -> Swift cloud fixture reserve/register/open -> Rust commit -> tool batch -> resume -> final -> close
local/cloud switch affects only the next run
missing model/key/capability/egress fails before Rust commit
legacy_v1 remains runnable
host_slot_v2 never invokes the legacy model client
concurrent legacy/V2 admission has exactly one winner
exact profile revision returns one authoritative route descriptor
stale revision/tag tamper/wrong endpoint fail without fallback
App suspend/resume preserves pending deadlines and cleanup
App runtime teardown waits for a callback-blocked dispatcher, then reinstall succeeds
persisted host_slot_v2 snapshot has no legacy provider/model/credential/path keys or binding values
```

Extend the Task 3 lint across all new Rust V2 files, keep its real persisted-snapshot scan, and assert `execution.host_slot_v2_not_runnable` is absent from production code after the switch while the legacy allowlist count never increases. The lint permits provider fields only inside the tagged `LegacyV1` payload and never in `HostSlotV2`.

- [ ] **Step 2: Run RED**

```bash
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test lint llm_phase_four_architecture -- --nocapture
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test integration host_llm_product_path -- --nocapture
swift test --package-path toolkit --filter LLMHostProductPathTests
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project apps/LocalAgentApp/LocalAgentApp.xcodeproj -scheme LocalAgentApp \
  -destination "platform=iOS Simulator,id=$LOCAL_AGENT_PHASE4_IPHONE_UDID" \
  -only-testing:LocalAgentAppTests/LLMHostCompositionTests
```

Expected: V2 remains blocked/non-composed; the existing Phase 4 lint fails its production-switch assertions; exact route DTO/revalidation, App dispatcher composition, and the release runner do not exist.

- [ ] **Step 3: Compose one App-owned host and switch only the V2 route**

Build in this order:

```swift
let epoch = hostProcessEpoch                         // generated once by App
let rust = try RustRuntimeClient(configuration: .init(hostProcessEpoch: epoch, ...))
let local = try await LocalLLMSubsystem.bootstrap(hostProcessEpoch: epoch, ...)
let cloud = try await CloudLLMSubsystem.bootstrap(hostProcessEpoch: epoch, ...)
let host = try await LLMHostRuntime.bootstrap(
    rust: rust,
    local: local,
    cloud: cloud,
    hostProcessEpoch: epoch
)
try rust.installLLMHost(host.port)
```

App startup must await Rust old-epoch reconciliation and Swift local/cloud lease/session reconciliation before exposing pending actions. Route selection reads the explicit schema tag; it never guesses from target availability. Preserve `BridgeExecutionModelClient` and legacy resolver unchanged except for sharing epoch/lease admission.

Expose and consume the exact route contract:

```rust
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ProfileExecutionRoute {
    pub schema_version: u32,
    pub profile_id: String,
    pub profile_revision: u64,
    pub llm_binding_schema: LLMBindingSchema,
}
```

Swift requests it with `(profileID, profileRevision)` immediately before routing and passes that exact identity into the selected start API. Rust revalidates inside legacy admission or V2 preview/Phase C. Remove any Swift branching based on target kind, presence of a host binding, model availability, or error fallback.

Wire App scene/lifecycle events to `rust.suspendLLMHostDispatcher()` and `rust.resumeLLMHostDispatcher()`. `AgentRuntimeService.shutdown()` first prevents new starts, calls unregister/quiesce, waits for Rust dispatcher shutdown/runtime free, and only then releases `LLMHostRuntime`; tests use a blocked callback to verify no use-after-free and a second bootstrap to verify clean reinstall.

- [ ] **Step 4: Add and run the complete deterministic Phase 4 gate**

Create `scripts/run-llm-phase-4-contracts.sh`, run `chmod +x scripts/run-llm-phase-4-contracts.sh`, and make the script execute:

```bash
scripts/run-llm-phase-3-contracts.sh
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test contract
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test integration
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test lint llm_phase_four_architecture -- --nocapture
swift test --package-path toolkit
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project apps/LocalAgentApp/LocalAgentApp.xcodeproj -scheme LocalAgentApp \
  -destination "platform=iOS Simulator,id=$LOCAL_AGENT_PHASE4_IPHONE_UDID" \
  -only-testing:LocalAgentAppTests/LLMHostCompositionTests
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project apps/LocalAgentApp/LocalAgentApp.xcodeproj -scheme LocalAgentApp \
  -destination "platform=iOS Simulator,id=$LOCAL_AGENT_PHASE4_IPAD_UDID" \
  -only-testing:LocalAgentAppTests/LLMHostCompositionTests
```

The runner must clear the seven known provider key environment variables, use secret-free provider fixtures, require explicitly resolved available iPhone and iPad Simulator UDIDs, and never invoke the live smoke script. Run:

```bash
scripts/run-llm-phase-4-contracts.sh
git diff --check
git status --short
```

Expected: all Phase 1–4 Rust/Swift/C++/Simulator gates pass, route tamper/staleness and dispatcher lifecycle tests pass, and only intended documentation/status changes remain.

- [ ] **Step 5: Record evidence and commit**

Add a dated Phase 4 implementation-evidence section to the parent design covering the host target, durable outbox/receipts, lifecycle watchdogs, restart behavior, route coexistence, test counts, and remaining Phase 5 removal/UI work. Then commit:

```bash
git add rust-core toolkit apps/LocalAgentApp scripts/run-llm-phase-4-contracts.sh \
  docs/superpowers/specs/2026-07-10-swift-llm-system-design.md \
  docs/model-providers/cloud-provider-adapter-architecture.md
git commit -m "feat: enable host backed llm execution"
```

---

## Checkpoint Order

Execute Tasks 1–12 strictly in order. Stop for review after Task 4 (wire/FFI boundary), Task 7 (two-phase preparation), Task 10 (full lifecycle), and Task 12 (production switch). Do not enable the App V2 route early: Tasks 1–11 may expose package-internal fixtures, but production `host_slot_v2` remains blocked until the full Phase 4 gate passes.

## Design Coverage Matrix

| 7-10 design requirement | Implemented by |
| --- | --- |
| Opaque epoch-bound handles and provider-neutral DTOs | Tasks 1, 5, 7 |
| Sole cloud/local/Rust `HostAttestationV1Document` for `egress-attestation:v1` | Tasks 1, 7 |
| Authoritative frozen input/disclosure and public attestation recomputation | Tasks 3, 7 |
| Tagged provider-neutral V2 snapshot binding with no legacy provider state | Tasks 3, 12 |
| One persisted V2 aggregate for snapshot/events/output/worker/outbox/receipt/lease | Tasks 2, 3, 6, 9, 11 |
| Transactional worker/outbox and two-level acknowledgement | Tasks 2, 4 |
| Production dispatcher wake/deadline/suspend/quiesce/free lifecycle | Tasks 4, 12 |
| No callback under Rust mutex and no Swift context release while in flight | Task 4 |
| Event identity/sequence/receipt matrix, atomic application, and bounded backpressure | Tasks 1, 6 |
| Local/cloud normalized start/resume parity and operation-start signal | Task 8 |
| Structured final/tool terminal, formal assistant output, and complete ordered batch | Task 9 |
| Incremental sensitive-tool-result approval before affected request | Tasks 8, 9 |
| Independent ack/start/cancel/close watchdogs and races | Tasks 4, 8, 10 |
| Cleanup owner before registration and opening/commit race compensation | Tasks 5, 7 |
| Lost Phase C reply reconciliation before any abort | Tasks 3, 5, 7 |
| Orthogonal logical outcome/resource lifecycle and quarantine | Tasks 2, 9, 10 |
| Host epoch invalidation, legacy-running interruption, and continuation loss | Task 11 |
| Host tool effect idempotency | Task 11 |
| Exact revision route descriptor and legacy/V2 coexistence under one lease/epoch | Task 12 |
| Provider-neutral Rust, cloud-free C++, no fallback | Global constraints and Task 12 lint |

## Completion Criteria

Phase 4 is complete only when all of the following are true:

- `host_slot_v2` completes both local fake-engine and cloud fixture tool loops through the real Rust/Swift bridge.
- Persisted V2 snapshots use `ResolvedLLMBinding::HostSlotV2`, contain no provider/model/credential/path keys, and contain no seeded legacy values in their host-binding subtree; legacy snapshots continue through the tagged `LegacyV1` variant.
- Cloud and local preparations plus Rust validation reproduce the sole shared `egress-attestation:v1` fixtures through production builders; the obsolete Rust seven-field document no longer exists.
- `agent.sqlite` is the sole active Rust runtime authority after idempotent sidecar migration; V2 Phase C, event application, formal output, lifecycle close, and recovery cannot commit partial cross-store state.
- Every Rust outbound command is backed by a durable outbox row, stable identity, copy receipt, asynchronous acknowledgement, and bounded deadline.
- Every submitted Swift event follows the receipt matrix and one aggregate transaction, and no terminal/tool event can be silently dropped or acknowledged without its worker/output/outbox effects.
- A registered Swift session has a cleanup owner before Rust can accept registration; cleanup succeeds or remains quarantined at every registration/open/commit race point.
- An ambiguous `commit_start` FFI result is reconciled by preparation/run/token digest identity; callback-arrived, callback-delayed, and inbox-backpressured committed runs are never aborted.
- A final assistant answer is persisted exactly once and remains observable while cleanup is pending or quarantined; only exact close/recovery ends the physical resource lifecycle and releases the lease.
- Initial and resumed cloud requests are bound to the exact Rust semantic payload/disclosure and stop before transmission when approval is denied.
- Cancel and close acknowledgements cannot release resources or the global lease without their distinct backend terminal receipts.
- Restart interrupts old-epoch legacy starting/running and every unclosed V2 lifecycle before pending actions appear, and side-effecting host tools are not blindly replayed.
- Production dispatcher deadlines fire without a follow-up FFI call, and suspend/resume/uninstall/runtime-free cannot outlive or reuse the retained Swift context.
- App route choice comes only from Rust's exact-revision `ProfileExecutionRoute`; stale/tampered/wrong-endpoint requests fail without fallback.
- `legacy_v1` still passes its production tests and the temporary allowlist does not grow.
- `scripts/run-llm-phase-4-contracts.sh` passes from a clean worktree on both iPhone and iPad Simulator with no live keys/network requirement.
