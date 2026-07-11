# LLM Phase 1 Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the provisional Phase 1 preparation and host-binding implementation with Rust-authoritative preview, atomic lifecycle storage, authenticated cleanup, complete public-binding validation, actual Profile/Package saga state, Swift SQLite persistence, and random digest-only bearer tokens.

**Architecture:** Rust remains authoritative for Agent inputs, snapshots, security metadata, leases, and portable capability requirements. Swift owns opaque concrete model bindings and stores them in a separate normalized SQLite database. The bridge carries real start references into Rust and provider-neutral attestations back; Phase 1 remains deliberately non-runnable after successful validation.

**Tech Stack:** Rust 2021, `rusqlite` 0.32, `serde`, canonical SHA-256 digests, `getrandom` 0.4, Swift 6, SwiftPM, Apple `sqlite3`, CryptoKit, Swift Testing.

## Global Constraints

- Work only in `/Users/alexandercou/Projects/Alex-agent/.worktrees/llm-runtime-provider-design/local-ios-agent` on `codex/llm-runtime-provider-design`.
- Execute tasks sequentially with one Agent; do not dispatch subagents.
- Use test-driven development: add one failing behavior test, observe the expected failure, implement the minimum fix, and rerun focused plus regression tests.
- Preserve the legacy production execution route and the single global Agent lease.
- Do not add Provider adapters, credentials, network egress, C++ inference, local model loading, or host-backed generation callbacks.
- Rust DTOs must remain free of Provider names, API keys, base URLs, local paths, model paths, and concrete target identifiers.
- Raw bearer tokens must never enter SQLite, JSON record columns, logs, debug output, or persisted Codable/Serde records.
- `LLMSlotV2` must still end Phase C with `execution.host_slot_v2_not_runnable` after full validation.

---

### Task 1: CSPRNG Bearer Authority Foundation

**Files:**
- Create: `rust-core/src/llm_contracts/bearer_token.rs`
- Modify: `rust-core/src/llm_contracts/mod.rs`
- Modify: `rust-core/src/llm_contracts/host_binding.rs`
- Modify: `rust-core/src/llm_contracts/preparation.rs`
- Modify: `rust-core/src/storage/agent_os_state/in_memory.rs`
- Modify: `rust-core/src/storage/agent_os_state/sqlite.rs`
- Modify: `rust-core/Cargo.toml`
- Test: `rust-core/tests/contract/host_binding_saga.rs`
- Test: `rust-core/tests/contract/run_preparation.rs`
- Test: `rust-core/tests/integration/agent_os_state_sqlite.rs`

**Interfaces:**
- Produces `BearerTokenIssuer::issue(domain) -> IssuedBearerToken`.
- Produces persisted `BearerAuthority { token_generation, token_digest }` and response-only `IssuedBearerToken { raw, authority }`.
- Produces stable host-binding `operation_id` and `operation_request_digest`; staging receipt v2 binds those fields rather than the rotating bearer digest.

- [ ] **Step 1: Add failing randomness and persistence tests**

Add tests that issue 256 tokens, decode unpadded base64url to exactly 32 bytes, assert uniqueness, and serialize every persisted host-binding/preparation record to prove none contains the raw bearer. Add an SQLite inspection test that searches all text columns for the raw bearer and finds none. Add a restart/resume test proving a host-binding bearer rotates while the stable staging receipt remains valid.

- [ ] **Step 2: Run RED**

```bash
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test contract bearer -- --nocapture
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test integration agent_os_state_sqlite -- --nocapture
```

Expected: fail because tokens are deterministic and persisted response records still contain `token`.

- [ ] **Step 3: Implement token issuer and split records/responses**

Add direct dependency `getrandom = "0.4.2"`. `BearerTokenIssuer` calls `getrandom::fill(&mut [u8; 32])`, encodes with an internal unpadded base64url encoder, and hashes the raw encoded token through the registered domain. Persist only:

```rust
pub struct BearerAuthority {
    token_generation: u64,
    token_digest: String,
}

pub struct IssuedBearerToken {
    raw: String,
    authority: BearerAuthority,
}
```

Use constant-time byte comparison for token digests. Add a process-scoped token vault keyed by preparation ID or host-binding operation ID. Change `HostBindingOperation` and `RunPreparationRecord` to persisted digest-only values and construct separate FFI response types containing the raw token. Generate cleanup command IDs with the same CSPRNG but treat them as persisted correlation IDs.

- [ ] **Step 4: Run GREEN and regressions**

```bash
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test contract host_binding_saga -- --nocapture
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test contract run_preparation -- --nocapture
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test integration agent_os_state_sqlite -- --nocapture
```

- [ ] **Step 5: Commit**

```bash
git add rust-core
git commit -m "fix: use random digest-only llm bearer tokens"
```

---

### Task 2: Atomic Preparation Repository and Startup Recovery

**Files:**
- Modify: `rust-core/src/storage/agent_os_state/mod.rs`
- Modify: `rust-core/src/storage/agent_os_state/in_memory.rs`
- Modify: `rust-core/src/storage/agent_os_state/sqlite.rs`
- Modify: `rust-core/src/run_snapshot/snapshot_service.rs`
- Modify: `rust-core/src/ffi_bridge.rs`
- Test: `rust-core/tests/contract/run_preparation.rs`
- Test: `rust-core/tests/integration/agent_os_state_sqlite.rs`
- Test: `rust-core/tests/integration/ffi_bridge.rs`

**Interfaces:**
- Replaces split preparation lease writes with `create_preparation_and_acquire_lease`, `renew_preparation_and_lease`, `abort_preparation_and_begin_release`, `close_preparation_and_release`, and `recover_preparations_for_new_epoch`.
- Startup recovery returns recovered preparation IDs only after one committed transaction.

- [ ] **Step 1: Add failing atomicity/CAS/recovery tests**

Add repository tests for: injected failure after lease insertion rolls back the preparation and lease; renewal updates both expirations; wrong token generation/digest, lease generation, state, or epoch loses CAS; reopen recovery closes pending/registered/aborting old-epoch records and releases the matching lease. Add an FFI initialization test proving runtime construction invokes preparation recovery rather than lease-only recovery.

- [ ] **Step 2: Run RED**

```bash
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test integration agent_os_state_sqlite preparation -- --nocapture
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test integration ffi_bridge old_epoch -- --nocapture
```

Expected: fail because create/renew are split and bridge initialization calls `store.recover_old_epoch`.

- [ ] **Step 3: Implement repository-level transactions**

Remove preparation lifecycle use of public `acquire_preparation`, `create_run_preparation`, and generic `save_run_preparation`. Implement each new operation with `TransactionBehavior::Immediate` and exact SQL predicates over preparation ID, lease generation, epoch, state, token generation, and token digest. Renewal updates `global_run_lease.preparation_expiration` in the same transaction as the preparation record.

Implement `recover_preparations_for_new_epoch` to update all old live preparation rows to closed with internal epoch recovery records, cancel any cleanup rows, and delete the matching old lease before commit. Construct the bridge's `RunPreparationService`, execution service, and callable runtime only after recovery succeeds.

- [ ] **Step 4: Run GREEN and regressions**

```bash
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test contract run_preparation -- --nocapture
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test integration agent_os_state_sqlite -- --nocapture
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test integration ffi_bridge -- --nocapture
```

- [ ] **Step 5: Commit**

```bash
git add rust-core
git commit -m "fix: make llm preparation lifecycle atomic"
```

---

### Task 3: Authenticated Prepared-Session Cleanup Outbox

**Files:**
- Modify: `rust-core/src/llm_contracts/preparation.rs`
- Modify: `rust-core/src/canonical_digest.rs`
- Modify: `rust-core/src/storage/agent_os_state/mod.rs`
- Modify: `rust-core/src/storage/agent_os_state/in_memory.rs`
- Modify: `rust-core/src/storage/agent_os_state/sqlite.rs`
- Modify: `rust-core/src/run_snapshot/snapshot_service.rs`
- Modify: `rust-core/src/ffi_bridge.rs`
- Modify: `toolkit/Sources/LocalAgentLLMContracts/RunPreparationContracts.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCore/LLMStore.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCore/RunPreparationCoordinator.swift`
- Modify: `toolkit/Sources/LocalAgentBridge/AgentOSDTOs.swift`
- Modify: `toolkit/Sources/LocalAgentBridge/RustAgentOSBridgeGateway.swift`
- Modify: `toolkit/Sources/CLocalAgentRuntime/include/CLocalAgentRuntime.h`
- Test: `rust-core/tests/contract/run_preparation.rs`
- Test: `rust-core/tests/integration/agent_os_state_sqlite.rs`
- Test: `rust-core/tests/integration/ffi_bridge.rs`
- Test: `toolkit/Tests/LocalAgentLLMCoreTests/RunPreparationCoordinatorTests.swift`
- Test: `toolkit/Tests/LocalAgentBridgeTests/RustRuntimeClientContractTests.swift`

**Interfaces:**
- Produces `ack_prepared_session_cleanup` C ABI/Swift operation.
- External `CloseDisposition` is exactly `closed | already_closed`.
- Produces canonical `prepared-session-close-receipt:v1` parity across Rust and Swift.

- [ ] **Step 1: Add failing protocol tests**

Test rejection before acknowledgement and for each independent mutation of command ID, sequence, registration digest, command digest, disposition, and receipt digest. Test exact acknowledgement/receipt replay. Test JSON decoding rejects `epoch_ended`. Add Swift/Rust golden digest parity including registration digest, command digest, and disposition.

- [ ] **Step 2: Run RED**

```bash
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test contract run_preparation cleanup -- --nocapture
swift test --package-path toolkit --filter RunPreparationCoordinatorTests
```

- [ ] **Step 3: Implement outbox acknowledgement and receipt recomputation**

Create `preparation_cleanup_outbox` and receipt ledger tables. Persist `pending` in the same abort transaction, then CAS `pending -> acknowledged` using command ID/sequence/digest. Recompute the close receipt from the persisted registration and command using the registered digest domain and constant-time compare before the atomic close/release transaction. Remove external construction/decoding of `epoch_ended`; use only the internal recovery record from Task 2.

Swift must first persist the cleanup command and return an acknowledgement. It computes close receipt digest only after the stored command matches the prepared session. Add the C ABI declaration and provider-neutral Swift gateway operation.

- [ ] **Step 4: Run GREEN and regressions**

```bash
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test contract run_preparation -- --nocapture
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test integration agent_os_state_sqlite -- --nocapture
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test integration ffi_bridge -- --nocapture
swift test --package-path toolkit --filter RunPreparationCoordinatorTests
swift test --package-path toolkit --filter RustRuntimeClientContractTests
```

- [ ] **Step 5: Commit**

```bash
git add rust-core toolkit
git commit -m "fix: authenticate prepared session cleanup"
```

---

### Task 4: Rust-Authoritative Phase A Preview

**Files:**
- Create: `rust-core/src/run_snapshot/preparation_preview.rs`
- Modify: `rust-core/src/run_snapshot/mod.rs`
- Modify: `rust-core/src/run_snapshot/resolver.rs`
- Modify: `rust-core/src/run_snapshot/snapshot_service.rs`
- Modify: `rust-core/src/llm_contracts/preparation.rs`
- Modify: `rust-core/src/execution/context_input.rs`
- Modify: `rust-core/src/ffi_bridge.rs`
- Modify: `toolkit/Sources/LocalAgentBridge/AgentOSDTOs.swift`
- Modify: `toolkit/Sources/LocalAgentBridge/RustAgentOSBridgeGateway.swift`
- Test: `rust-core/tests/contract/run_preparation.rs`
- Test: `rust-core/tests/integration/ffi_bridge.rs`
- Test: `rust-core/tests/lint/llm_phase_one_architecture.rs`
- Test: `toolkit/Tests/LocalAgentBridgeTests/RustRuntimeClientContractTests.swift`

**Interfaces:**
- FFI consumes only `AuthoritativeRunPreparationRequest { idempotency_key, preparation_id, proposed_run_id, start_request }`.
- Produces `AuthoritativePreparationPreviewService::preview(StartRunRequest) -> FrozenPreparationInput`.
- Produces process-scoped `PreparedModelInputVault` keyed by frozen input ID.

- [ ] **Step 1: Add failing authority tests**

Test that old digest fields are rejected as unknown FFI fields. Build real Profile/frame/tool/context fixtures and prove Rust-derived digests change when each source changes. Prove the vault bytes recompute to `model_input_digest`. Add an instrumentation test proving V2 preparation never calls legacy `resolve_model_binding`.

- [ ] **Step 2: Run RED**

```bash
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test contract run_preparation authoritative -- --nocapture
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test integration ffi_bridge preparation_preview -- --nocapture
```

- [ ] **Step 3: Implement the shared trusted-source preview**

Extract trusted source capture/component/tool resolution shared with `RunSnapshotService.preview`. Add a V2-specific preparation preview that loads the exact Profile revision and `LLMSlotV2`, resolves the conversation frame and plan, assembles the actual first-turn model input, computes disclosure and registered digests, and stores canonical input bytes in the vault. It must not resolve a concrete model binding or persist a run snapshot.

Change the Rust C ABI and Swift DTO so the caller sends the real start request and no derived digest. On transaction failure remove the vault entry; on old-epoch recovery clear recovered vault entries.

- [ ] **Step 4: Run GREEN and regressions**

```bash
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test contract run_preparation -- --nocapture
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test integration ffi_bridge -- --nocapture
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test lint llm_phase_one_architecture -- --nocapture
swift test --package-path toolkit --filter RustRuntimeClientContractTests
```

- [ ] **Step 5: Commit**

```bash
git add rust-core toolkit
git commit -m "fix: derive llm preparation input in rust"
```

---

### Task 5: Reusable Phase C Public-Binding Validator

**Files:**
- Create: `rust-core/src/llm_contracts/prepared_start_validator.rs`
- Modify: `rust-core/src/llm_contracts/mod.rs`
- Modify: `rust-core/src/llm_contracts/preparation.rs`
- Modify: `rust-core/src/canonical_digest.rs`
- Modify: `rust-core/src/run_snapshot/snapshot_service.rs`
- Modify: `rust-core/src/storage/agent_os_state/mod.rs`
- Modify: `rust-core/src/storage/agent_os_state/in_memory.rs`
- Modify: `rust-core/src/storage/agent_os_state/sqlite.rs`
- Modify: `toolkit/Sources/LocalAgentLLMContracts/RunPreparationContracts.swift`
- Modify: `toolkit/Sources/LocalAgentBridge/AgentOSDTOs.swift`
- Test: `rust-core/tests/contract/run_preparation.rs`
- Test: `rust-core/tests/integration/ffi_bridge.rs`
- Test: `toolkit/Tests/LocalAgentLLMContractsTests/CanonicalDigestV1Tests.swift`

**Interfaces:**
- Produces `PreparedStartValidator::validate(...) -> ValidatedPreparedStart`.
- Extends registration with opaque binding ID/revision/hash.
- Extends host attestation with provider-neutral capability and egress public fields.

- [ ] **Step 1: Add failing mutation tests**

Start from one valid registration/attestation, mutate registration digest, binding tuple, cross-link, capability digest/claims, context length, modality, expiry, disclosure grant/data classes/sensitivity, opaque subject digest, egress digest, vault bytes, and source revisions one at a time. Assert every mutation is rejected before run state and enters exact commit-rejected cleanup. Assert the unmodified input reaches only the Phase 1 non-runnable error.

- [ ] **Step 2: Run RED**

```bash
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test contract run_preparation commit_validation -- --nocapture
```

- [ ] **Step 3: Implement complete pure validation**

Register and use `prepared-session-registration:v1`, `capability-attestation:v1`, and `egress-attestation:v1`. Recompute each digest from a copy without its digest field. Query the cross-link by the exact Profile/revision/slot/binding tuple. Compare generic capability claims with frozen requirements, validate expirations and disclosure public fields, and rehash vault bytes. Return `ValidatedPreparedStart`; do not start a worker or persist a run.

- [ ] **Step 4: Run GREEN and regressions**

```bash
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test contract run_preparation -- --nocapture
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test integration ffi_bridge -- --nocapture
swift test --package-path toolkit --filter CanonicalDigestV1Tests
```

- [ ] **Step 5: Commit**

```bash
git add rust-core toolkit
git commit -m "fix: validate llm prepared start bindings"
```

---

### Task 6: Bind Host Saga to Actual Profile and Package State

**Files:**
- Create: `rust-core/src/llm_contracts/host_binding_service.rs`
- Modify: `rust-core/src/llm_contracts/mod.rs`
- Modify: `rust-core/src/llm_contracts/host_binding.rs`
- Modify: `rust-core/src/user_customization/agent_profile.rs`
- Modify: `rust-core/src/agent_package/installer.rs`
- Modify: `rust-core/src/app_service.rs`
- Modify: `rust-core/src/ffi_bridge.rs`
- Modify: `toolkit/Sources/LocalAgentBridge/AgentOSDTOs.swift`
- Modify: `toolkit/Sources/LocalAgentBridge/RustAgentOSBridgeGateway.swift`
- Modify: `toolkit/Sources/CLocalAgentRuntime/include/CLocalAgentRuntime.h`
- Test: `rust-core/tests/contract/host_binding_saga.rs`
- Test: `rust-core/tests/integration/agent_os_state_sqlite.rs`
- Test: `rust-core/tests/integration/agent_package_agent_os.rs`
- Test: `rust-core/tests/integration/ffi_bridge.rs`

**Interfaces:**
- Produces `HostBindingSubjectCatalog` and `AgentHostBindingService`.
- Produces Profile states `pending_host_binding | host_unbound | active` for V2 revisions.
- Produces package installation states `needs_llm_binding | host_unbound | ready`.
- Produces `confirm_host_binding_activation` C ABI/Swift operation.

- [ ] **Step 1: Add failing subject-state tests**

Test prepare/begin reject nonexistent or mismatched subjects. Test V2 Profile is hidden before commit, visible but not runnable at `host_unbound`, and active only after exact Swift activation confirmation. Test package state advances through all three states. Test legacy publication/install behavior is unchanged. Test reconciliation repairs partial side-table/subject-state transitions without moving backward.

- [ ] **Step 2: Run RED**

```bash
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test contract host_binding_saga -- --nocapture
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test integration agent_package_agent_os host_binding -- --nocapture
```

- [ ] **Step 3: Implement semantic saga service**

Add actual V2 readiness state to Profile revision and Package installation records. Keep legacy APIs unchanged. Move FFI semantics from raw `AgentOSStateRepository` calls into `AgentHostBindingService`, which validates actual subjects, invokes persistence primitives, advances subject state, and reconciles. Add stable operation ID/request digest plus staging receipt v2. Add activation confirmation using exact binding tuple and receipt.

- [ ] **Step 4: Run GREEN and regressions**

```bash
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test contract host_binding_saga -- --nocapture
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test integration agent_os_state_sqlite -- --nocapture
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test integration agent_package_agent_os -- --nocapture
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test integration ffi_bridge -- --nocapture
```

- [ ] **Step 5: Commit**

```bash
git add rust-core toolkit
git commit -m "fix: bind llm sagas to agent domain state"
```

---

### Task 7: Replace Swift JSON Store with Transactional SQLite

**Files:**
- Create: `toolkit/Sources/CSQLite/module.modulemap`
- Create: `toolkit/Sources/CSQLite/shim.h`
- Create: `toolkit/Sources/LocalAgentLLMCore/SQLiteConnection.swift`
- Modify: `toolkit/Package.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCore/LLMStore.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCore/AgentHostBindingSaga.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCore/RunPreparationCoordinator.swift`
- Test: `toolkit/Tests/LocalAgentLLMCoreTests/LLMStoreTests.swift`
- Test: `toolkit/Tests/LocalAgentLLMCoreTests/AgentHostBindingSagaTests.swift`
- Test: `toolkit/Tests/LocalAgentLLMCoreTests/RunPreparationCoordinatorTests.swift`

**Interfaces:**
- `LLMStore.inMemory()` opens SQLite `:memory:`.
- `LLMStore(fileURL:)` opens a normalized SQLite database and performs migration/import before returning.
- All state changes use `BEGIN IMMEDIATE` and SQL CAS.

- [ ] **Step 1: Add failing SQLite behavior tests**

Test file header is SQLite rather than JSON; inspect normalized tables/indexes; test reopen, rollback injection, CAS conflict, multi-row cleanup atomicity, `PRAGMA user_version`, successful legacy JSON import and `.migrated` backup, corrupt import failure without source mutation, and absence of bearer/Provider/credential/path fields in every SQLite text value.

- [ ] **Step 2: Run RED**

```bash
swift test --package-path toolkit --filter LLMStoreTests
```

Expected: fail because `LLMStore` currently atomically overwrites one JSON document.

- [ ] **Step 3: Implement SQLite repository**

Add a `CSQLite` system library target linking `sqlite3`. Implement checked statement binding/column reads, error codes, `BEGIN IMMEDIATE` transaction rollback, schema version 1 tables/indexes from the design, and deterministic JSON only inside per-record `record_json` columns. Keep response bearer types out of stored record types. Implement one-time legacy JSON import in one transaction and rename only after commit.

- [ ] **Step 4: Run GREEN and Swift regressions**

```bash
swift test --package-path toolkit --filter LLMStoreTests
swift test --package-path toolkit --filter AgentHostBindingSagaTests
swift test --package-path toolkit --filter RunPreparationCoordinatorTests
swift test --package-path toolkit
```

- [ ] **Step 5: Commit**

```bash
git add toolkit
git commit -m "fix: persist swift llm state in sqlite"
```

---

### Task 8: Bridge Migration, Architecture Gates, and Final Verification

**Files:**
- Modify: `rust-core/src/ffi_bridge.rs`
- Modify: `toolkit/Sources/CLocalAgentRuntime/include/CLocalAgentRuntime.h`
- Modify: `toolkit/Sources/LocalAgentBridge/AgentOSDTOs.swift`
- Modify: `toolkit/Sources/LocalAgentBridge/RustAgentOSBridgeGateway.swift`
- Modify: `toolkit/Sources/LocalAgentBridge/RustRuntimeClient.swift`
- Modify: `rust-core/tests/integration/ffi_bridge.rs`
- Modify: `toolkit/Tests/LocalAgentBridgeTests/RustRuntimeClientContractTests.swift`
- Modify: `rust-core/tests/lint/llm_phase_one_architecture.rs`
- Modify: `rust-core/tests/fixtures/architecture/legacy_llm_allowlist.txt`
- Modify: `scripts/run-llm-phase-1-contracts.sh`
- Modify: `docs/superpowers/specs/2026-07-10-swift-llm-system-design.md`
- Modify: `docs/superpowers/specs/2026-07-11-llm-phase-1-remediation-design.md`

**Interfaces:**
- Final C ABI exposes authoritative preview, cleanup acknowledgement, and host-binding activation confirmation with provider-neutral DTOs.
- Architecture lint rejects every provisional unsafe path.

- [ ] **Step 1: Add failing bridge/lint tests**

Test all new C functions round-trip provider-neutral JSON, old digest-bearing preview payloads fail unknown-field decoding, external `epoch_ended` fails, and forbidden Provider/credential/path keys remain absent. Add lints for split lifecycle writes, raw token fields/columns, JSON-document production store, raw host-binding FFI repository calls, and caller-supplied Phase A digests.

- [ ] **Step 2: Run RED**

```bash
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test integration ffi_bridge llm -- --nocapture
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test lint llm_phase_one_architecture -- --nocapture
swift test --package-path toolkit --filter RustRuntimeClientContractTests
```

- [ ] **Step 3: Complete bridge migration and docs**

Remove provisional bridge DTOs and functions that accept derived digests or unacknowledged close receipts. Route host-binding FFI through `AgentHostBindingService`. Extend the unified runner only with deterministic local checks. Update the main design's Phase 1 evidence and remediation status without claiming Provider/local inference execution.

- [ ] **Step 4: Run focused GREEN**

```bash
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test integration ffi_bridge -- --nocapture
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test lint llm_phase_one_architecture -- --nocapture
swift test --package-path toolkit --filter RustRuntimeClientContractTests
scripts/test-check-rust-ffi-panic-strategy.sh
```

- [ ] **Step 5: Run final clean-worktree gate**

```bash
scripts/run-llm-phase-1-contracts.sh
git diff --check
git status --short
```

Expected: all Rust tests, Rust build, all Swift tests, FFI panic checks, and architecture lints pass; only the intended Task 8 changes are present before commit.

- [ ] **Step 6: Commit**

```bash
git add rust-core toolkit scripts docs
git commit -m "test: enforce remediated llm phase one contracts"
```

- [ ] **Step 7: Re-run final gate after commit**

```bash
scripts/run-llm-phase-1-contracts.sh
git status --short
```

Expected: exit code 0 and empty worktree status.

