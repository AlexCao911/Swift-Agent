# Swift-Owned LLM Phase 1 Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Phase 1 contracts, portable LLM slots, Swift-owned host configuration foundation, durable single-run gate, and non-runnable two-phase preparation/saga records while leaving the current legacy production inference route intact.

**Architecture:** Rust adds only provider-neutral digests, portable LLM requirements, migration tags, leases, and opaque host cross-links. Swift adds the product-owned LLM contract/core targets and stores concrete local/cloud target configuration. Phase 1 introduces and validates `host_slot_v2`, but production execution continues to accept only `legacy_v1` until Phase 4.

**Tech Stack:** Rust 2021, `serde`, `serde_json`, `serde_json_canonicalizer` 0.3.2, `sha2` 0.10.9, `rusqlite` 0.32, Swift 6, SwiftPM, Foundation, CryptoKit, Swift Testing, SQLite.

## Global Constraints

- Target iOS and iPadOS 17 or newer; keep the existing macOS 14 SwiftPM test host.
- Only one Agent run or preparation may own the Rust global run lease.
- Rust must not parse Provider Profiles, Base URLs, CredentialRefs/generations, model paths, adapter kinds, or engine IDs.
- Swift owns every concrete local/cloud target, capability observation, resolved parameter set, host binding, and sanitized LLM snapshot.
- C++ is unchanged in Phase 1.
- `legacy_v1` production resolution and execution remain behaviorally unchanged except for the new global lease gate.
- `host_slot_v2` records may be created, translated, staged, and reconciled, but must return `execution.host_slot_v2_not_runnable` if execution is attempted before Phase 4.
- Every authoritative structured digest uses a registered `CanonicalDigestV1` domain; raw artifact hashes remain explicitly named byte hashes.
- Every production behavior is implemented test-first and committed at the end of its task.
- No Provider adapter, Keychain access, model download, local engine loading, session streaming, or outbound network request is implemented in this plan.

---

## Source Specification

- `local-ios-agent/docs/superpowers/specs/2026-07-10-swift-llm-system-design.md`

This plan implements only “Phase 1: Contracts, Slots, and Consistency Foundation.” Phase 2 local inference product work, Phase 3 cloud providers/credentials/egress, Phase 4 async session execution, and Phase 5 UI adoption/removal remain separate plans.

## File Structure

### Shared contracts

- Create `local-ios-agent/contracts/canonical-digest-v1/registry.json`
  - Machine-readable list of every registered V1 domain, computing authority, and required/excluded fields.
- Create `local-ios-agent/contracts/canonical-digest-v1/fixtures/jcs-number-samples.json`
  - RFC 8785 number-format conformance vector.
- Create `local-ios-agent/contracts/canonical-digest-v1/fixtures/agent-requirements-v1.json`
  - First complete domain-separated digest vector.
- Create `local-ios-agent/scripts/run-llm-phase-1-contracts.sh`
  - Runs the Rust and Swift Phase 1 contract suites.

### Rust

- Modify `local-ios-agent/rust-core/Cargo.toml`
  - Add RFC 8785 canonicalization and SHA-256 dependencies.
- Modify `local-ios-agent/rust-core/src/lib.rs`
  - Export `canonical_digest` and `llm_contracts` modules.
- Create `local-ios-agent/rust-core/src/canonical_digest.rs`
  - `CanonicalDigestV1`, registered-domain validation, canonical bytes, digest hex, and stable errors.
- Create `local-ios-agent/rust-core/src/llm_contracts/mod.rs`
  - Public exports for Phase 1 provider-neutral contracts.
- Create `local-ios-agent/rust-core/src/llm_contracts/requirements.rs`
  - `AgentLLMRequirements`, capabilities, modalities, context budget, and canonical document.
- Create `local-ios-agent/rust-core/src/llm_contracts/slot.rs`
  - `LLMSlotV2`, optional hints, and `LLMBindingSchema` transition tag.
- Create `local-ios-agent/rust-core/src/llm_contracts/host_binding.rs`
  - Opaque binding tuple, staging receipt, publish/package saga records, and state transitions.
- Create `local-ios-agent/rust-core/src/llm_contracts/preparation.rs`
  - Provider-neutral preview/token/registration/commit/abort/cleanup records without worker execution.
- Create `local-ios-agent/rust-core/src/llm_contracts/global_run_lease.rs`
  - Lease model, CAS transition rules, and stable errors.
- Create `local-ios-agent/rust-core/src/storage/agent_os_state/mod.rs`
  - Repository trait and transaction operations for leases, V2 bindings, and preparations.
- Create `local-ios-agent/rust-core/src/storage/agent_os_state/in_memory.rs`
  - Test/default in-memory implementation.
- Create `local-ios-agent/rust-core/src/storage/agent_os_state/sqlite.rs`
  - Durable SQLite implementation and schema creation.
- Modify `local-ios-agent/rust-core/src/storage/mod.rs`
  - Export `agent_os_state`.
- Modify `local-ios-agent/rust-core/src/user_customization/agent_profile.rs`
  - Store exactly one tagged `legacy_v1` or `host_slot_v2` LLM binding.
- Modify `local-ios-agent/rust-core/src/user_customization/mod.rs`
  - Export new profile binding APIs.
- Modify `local-ios-agent/rust-core/src/agent_package/manifest.rs`
  - Add portable package LLM slot/requirements and schema-tagged decoding.
- Modify `local-ios-agent/rust-core/src/agent_package/validator.rs`
  - Enforce V1 translation and native V2 portability rules.
- Modify `local-ios-agent/rust-core/src/agent_package/installer.rs`
  - Store translated packages as `host_slot_v2` with `needs_llm_binding` readiness.
- Modify `local-ios-agent/rust-core/src/agent_package/lockfile.rs`
  - Persist only portable V2 requirements/hints.
- Modify `local-ios-agent/rust-core/src/run_snapshot/snapshot.rs`
  - Add provider-neutral preparation preview types while retaining the legacy snapshot type.
- Modify `local-ios-agent/rust-core/src/run_snapshot/snapshot_service.rs`
  - Add preview-only resolution and preparation orchestration.
- Modify `local-ios-agent/rust-core/src/execution/execution_service.rs`
  - Acquire the durable lease before the legacy resolver and reject V2 execution.
- Modify `local-ios-agent/rust-core/src/execution/run_lifecycle.rs`
  - Release/retain the legacy lease according to terminal/waiting state.
- Modify `local-ios-agent/rust-core/src/ffi_bridge.rs`
  - Expose Phase 1 JSON/C ABI contracts without routing V2 into the worker.
- Modify `local-ios-agent/toolkit/Sources/CLocalAgentRuntime/include/CLocalAgentRuntime.h`
  - Declare preparation and host-binding C functions.
- Create/extend Rust tests listed in the tasks below.

### Swift

- Modify `local-ios-agent/toolkit/Package.swift`
  - Add `LocalAgentLLMContracts`, `LocalAgentLLMCore`, and their test targets.
- Create `local-ios-agent/toolkit/Sources/LocalAgentLLMContracts/CanonicalJSONValue.swift`
- Create `local-ios-agent/toolkit/Sources/LocalAgentLLMContracts/CanonicalDigest.swift`
- Create `local-ios-agent/toolkit/Sources/LocalAgentLLMContracts/LLMCapabilities.swift`
- Create `local-ios-agent/toolkit/Sources/LocalAgentLLMContracts/LLMParameters.swift`
- Create `local-ios-agent/toolkit/Sources/LocalAgentLLMContracts/LLMInput.swift`
- Create `local-ios-agent/toolkit/Sources/LocalAgentLLMContracts/LLMFailure.swift`
- Create `local-ios-agent/toolkit/Sources/LocalAgentLLMCore/LLMTarget.swift`
- Create `local-ios-agent/toolkit/Sources/LocalAgentLLMCore/AgentHostConfiguration.swift`
- Create `local-ios-agent/toolkit/Sources/LocalAgentLLMCore/CapabilityMatrix.swift`
- Create `local-ios-agent/toolkit/Sources/LocalAgentLLMCore/LLMParameterSystem.swift`
- Create `local-ios-agent/toolkit/Sources/LocalAgentLLMCore/LLMStore.swift`
- Create `local-ios-agent/toolkit/Sources/LocalAgentLLMCore/AgentHostBindingSaga.swift`
- Create `local-ios-agent/toolkit/Sources/LocalAgentLLMCore/RunPreparationCoordinator.swift`
- Modify `local-ios-agent/toolkit/Sources/LocalAgentBridge/RustAgentOSBridgeGateway.swift`
- Modify `local-ios-agent/toolkit/Sources/LocalAgentBridge/RustRuntimeClient.swift`
- Modify `local-ios-agent/toolkit/Sources/LocalAgentBridge/AgentOSDTOs.swift`
- Create/extend Swift tests listed in the tasks below.

---

### Task 1: Shared Registry and Rust CanonicalDigestV1

**Files:**
- Create: `local-ios-agent/contracts/canonical-digest-v1/registry.json`
- Create: `local-ios-agent/contracts/canonical-digest-v1/fixtures/jcs-number-samples.json`
- Create: `local-ios-agent/contracts/canonical-digest-v1/fixtures/agent-requirements-v1.json`
- Modify: `local-ios-agent/rust-core/Cargo.toml`
- Modify: `local-ios-agent/rust-core/src/lib.rs`
- Create: `local-ios-agent/rust-core/src/canonical_digest.rs`
- Create: `local-ios-agent/rust-core/tests/contract/canonical_digest_v1.rs`
- Modify: `local-ios-agent/rust-core/tests/contract.rs`

**Interfaces:**
- Consumes: RFC 8785 typed JSON documents and the registry defined by the design.
- Produces: `CanonicalDigestV1::canonicalize`, `CanonicalDigestV1::digest`, `CanonicalDigest`, `CanonicalDigestError`.

- [ ] **Step 1: Add the failing Rust fixture tests**

Create tests that load both shared fixtures and assert:

```rust
#[test]
fn canonicalizes_rfc8785_number_sample() {
    let fixture = fixture("jcs-number-samples.json");
    let canonical = CanonicalDigestV1::canonicalize(&fixture.document).unwrap();
    assert_eq!(String::from_utf8(canonical).unwrap(), fixture.expected_canonical_utf8);
}

#[test]
fn computes_domain_separated_agent_requirements_digest() {
    let fixture = fixture("agent-requirements-v1.json");
    let digest = CanonicalDigestV1::digest(fixture.domain.as_deref().unwrap(), &fixture.document).unwrap();
    assert_eq!(digest.as_str(), "df309a1f80fb005d51e9aa7f249939f9480d106d5d5ea43d102935bdd1baee30");
}

#[test]
fn rejects_unregistered_domain_and_nul() {
    assert_eq!(
        CanonicalDigestV1::digest("not-registered:v1", &serde_json::json!({"schema_version":"1"}))
            .unwrap_err()
            .code(),
        "canonical_digest.domain_unregistered"
    );
    assert_eq!(
        CanonicalDigestV1::digest("agent-requirements:v1\0x", &serde_json::json!({"schema_version":"1"}))
            .unwrap_err()
            .code(),
        "canonical_digest.domain_invalid"
    );
}
```

- [ ] **Step 2: Run RED**

Run:

```bash
cargo test --test contract canonical_digest_v1 -- --nocapture
```

Expected: FAIL because `canonical_digest`, fixtures, and dependencies do not exist.

- [ ] **Step 3: Add the registry and fixtures**

The requirements fixture must contain this exact canonical document and digest:

```json
{
  "name": "agent-requirements-v1",
  "domain": "agent-requirements:v1",
  "document": {
    "schema_version": "1",
    "slot_id": "llm.primary",
    "capabilities": ["streaming", "tool_calling"],
    "input_modalities": ["text"],
    "context_budget": "8192",
    "streaming_required": true,
    "tool_calling_required": true
  },
  "expected_canonical_utf8": "{\"capabilities\":[\"streaming\",\"tool_calling\"],\"context_budget\":\"8192\",\"input_modalities\":[\"text\"],\"schema_version\":\"1\",\"slot_id\":\"llm.primary\",\"streaming_required\":true,\"tool_calling_required\":true}",
  "expected_sha256": "df309a1f80fb005d51e9aa7f249939f9480d106d5d5ea43d102935bdd1baee30"
}
```

The number fixture uses RFC 8785 canonical output:

```json
{
  "name": "jcs-number-samples",
  "document": {"numbers":[333333333.33333329,1e30,4.50,0.002,1e-27]},
  "expected_canonical_utf8": "{\"numbers\":[333333333.3333333,1e+30,4.5,0.002,1e-27]}"
}
```

- [ ] **Step 4: Implement the minimal Rust canonicalizer wrapper**

Add `serde_json_canonicalizer = "0.3.2"` and `sha2 = "0.10.9"`. Implement:

```rust
pub struct CanonicalDigestV1;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CanonicalDigest(String);

impl CanonicalDigestV1 {
    pub fn canonicalize<T: serde::Serialize>(value: &T) -> Result<Vec<u8>, CanonicalDigestError>;
    pub fn digest<T: serde::Serialize>(
        domain: &str,
        value: &T,
    ) -> Result<CanonicalDigest, CanonicalDigestError>;
}

impl CanonicalDigest {
    pub fn as_str(&self) -> &str;
}
```

`digest` must require a registered lowercase ASCII `*:v1` domain, reject NUL,
build `UTF8(domain) || 0x00 || canonicalBytes`, and return lowercase SHA-256.

- [ ] **Step 5: Run GREEN and the Rust suite**

```bash
cargo test --test contract canonical_digest_v1 -- --nocapture
cargo test
```

Expected: canonical digest tests pass; complete Rust suite has zero failures.

- [ ] **Step 6: Commit**

```bash
git add local-ios-agent/contracts/canonical-digest-v1 local-ios-agent/rust-core
git commit -m "feat: add rust canonical digest foundation"
```

---

### Task 2: Swift CanonicalDigestV1 Parity

**Files:**
- Modify: `local-ios-agent/toolkit/Package.swift`
- Create: `local-ios-agent/toolkit/Sources/LocalAgentLLMContracts/CanonicalJSONValue.swift`
- Create: `local-ios-agent/toolkit/Sources/LocalAgentLLMContracts/CanonicalDigest.swift`
- Create: `local-ios-agent/toolkit/Tests/LocalAgentLLMContractsTests/CanonicalDigestTests.swift`

**Interfaces:**
- Consumes: the same shared fixture files as Task 1.
- Produces: `CanonicalJSONValue`, `CanonicalDigestV1.canonicalize(_:)`, and `CanonicalDigestV1.digest(domain:document:)`.

- [ ] **Step 1: Add the Swift target and failing parity tests**

Add `LocalAgentLLMContracts` and `LocalAgentLLMContractsTests` to `Package.swift`.
The tests must load fixtures relative to `#filePath`, assert byte-for-byte
canonical output, and assert the same requirements digest.

```swift
@Test
func requirementsDigestMatchesRustGolden() throws {
    let fixture = try DigestFixture.load("agent-requirements-v1.json")
    let digest = try CanonicalDigestV1.digest(
        domain: fixture.domain,
        document: fixture.document
    )
    #expect(digest.hex == fixture.expectedSHA256)
}
```

- [ ] **Step 2: Run RED**

```bash
swift test --package-path local-ios-agent/toolkit --filter CanonicalDigestTests
```

Expected: FAIL because the target and canonical APIs do not exist.

- [ ] **Step 3: Implement canonical values and UTF-16 key ordering**

Use an enum that cannot contain invalid JSON values:

```swift
public struct CanonicalJSONObjectEntry: Equatable, Sendable {
    public let name: String
    public let value: CanonicalJSONValue
}

public indirect enum CanonicalJSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case string(String)
    case number(Double)
    case array([CanonicalJSONValue])
    case object([CanonicalJSONObjectEntry])
}
```

The object factory rejects duplicate names. Serialization escapes control
characters per RFC 8785, leaves `/` unescaped, sorts keys by unsigned UTF-16
code units, maps negative zero to `0`, rejects non-finite numbers, and formats
the shortest `Double.description` digits using ECMAScript fixed/scientific
thresholds `-6 <= exponent < 21`.

- [ ] **Step 4: Implement domain separation and SHA-256**

Use CryptoKit:

```swift
public struct CanonicalDigest: Equatable, Sendable {
    public let hex: String
}

public enum CanonicalDigestV1 {
    public static func canonicalize(_ value: CanonicalJSONValue) throws -> Data;
    public static func digest(
        domain: String,
        document: CanonicalJSONValue
    ) throws -> CanonicalDigest;
}
```

- [ ] **Step 5: Run GREEN and Swift suite**

```bash
swift test --package-path local-ios-agent/toolkit --filter CanonicalDigestTests
swift test --package-path local-ios-agent/toolkit
```

Expected: fixture parity passes and all Swift tests pass.

- [ ] **Step 6: Commit**

```bash
git add local-ios-agent/toolkit
git commit -m "feat: add swift canonical digest parity"
```

---

### Task 3: Portable Rust LLM Slot and Requirement Contracts

**Files:**
- Create: `local-ios-agent/rust-core/src/llm_contracts/mod.rs`
- Create: `local-ios-agent/rust-core/src/llm_contracts/requirements.rs`
- Create: `local-ios-agent/rust-core/src/llm_contracts/slot.rs`
- Modify: `local-ios-agent/rust-core/src/lib.rs`
- Modify: `local-ios-agent/rust-core/src/user_customization/agent_profile.rs`
- Modify: `local-ios-agent/rust-core/src/user_customization/mod.rs`
- Create: `local-ios-agent/rust-core/tests/contract/llm_slot_v2.rs`
- Modify: `local-ios-agent/rust-core/tests/contract.rs`

**Interfaces:**
- Produces: `AgentLLMRequirements`, `LLMSlotV2`, `LLMCapabilityRequirement`, `LLMInputModality`, `LLMBindingSchema`, `AgentProfileLLMBinding`.

- [ ] **Step 1: Write failing tagged-binding tests**

Tests must prove a profile contains exactly one of:

```rust
pub enum AgentProfileLLMBinding {
    LegacyV1(AgentProfileModelBinding),
    HostSlotV2(LLMSlotV2),
}
```

They also assert that V2 requirements serialize without provider/model/path or
credential fields and that `agent-requirements:v1` is stable under set insertion order.

- [ ] **Step 2: Run RED**

```bash
cargo test --test contract llm_slot_v2 -- --nocapture
```

- [ ] **Step 3: Implement the minimal contracts**

`AgentLLMRequirements` must contain slot ID, sorted capability requirements,
sorted input modalities, decimal-string context budget, streaming requirement,
and tool-calling mode. `LLMSlotV2` contains requirements plus optional model
family/model ID hints only. Existing `model_binding()` remains as a compatibility
view for `LegacyV1`; V2 returns `None`.

- [ ] **Step 4: Run GREEN and existing profile tests**

```bash
cargo test --test contract llm_slot_v2 -- --nocapture
cargo test --test contract agent_profile_contract -- --nocapture
```

- [ ] **Step 5: Commit**

```bash
git add local-ios-agent/rust-core
git commit -m "feat: add portable llm slot v2 contracts"
```

---

### Task 4: Swift LLM Contracts, Target Revisions, Capabilities, and Parameters

**Files:**
- Modify: `local-ios-agent/toolkit/Package.swift`
- Create the remaining `LocalAgentLLMContracts` and `LocalAgentLLMCore` files listed in File Structure.
- Create: `local-ios-agent/toolkit/Tests/LocalAgentLLMContractsTests/LLMContractsTests.swift`
- Create: `local-ios-agent/toolkit/Tests/LocalAgentLLMCoreTests/AgentHostConfigurationTests.swift`
- Create: `local-ios-agent/toolkit/Tests/LocalAgentLLMCoreTests/CapabilityMatrixTests.swift`
- Create: `local-ios-agent/toolkit/Tests/LocalAgentLLMCoreTests/LLMParameterSystemTests.swift`

**Interfaces:**
- Produces immutable `LLMTargetRevision`, `AgentHostConfiguration`, generic capability observations/snapshots, and resolved semantic parameters.

- [ ] **Step 1: Write failing revision and capability tests**

Tests assert target/config revisions are immutable, one Agent profile revision
selects exactly one target revision, unknown capability never satisfies a
requirement, and the lowest verified numeric limit wins.

- [ ] **Step 2: Run RED**

```bash
swift test --package-path local-ios-agent/toolkit --filter LocalAgentLLMCoreTests
```

- [ ] **Step 3: Implement contract value types**

Use provider-neutral public types:

```swift
public enum LLMTargetKind: String, Codable, Sendable { case local, cloud }
public enum SupportState: String, Codable, Sendable { case supported, unsupported, unknown }

public struct LLMTargetRevision: Codable, Equatable, Sendable {
    public let targetID: String
    public let revision: UInt64
    public let kind: LLMTargetKind
    public let modelID: String
    public let defaultParameters: GenerationConfiguration
}

public struct AgentHostConfiguration: Codable, Equatable, Sendable {
    public let bindingID: String
    public let revision: UInt64
    public let agentProfileID: String
    public let agentProfileRevision: UInt64
    public let llmSlotID: String
    public let llmTargetID: String
    public let llmTargetRevision: UInt64
    public let parameterOverrides: GenerationConfiguration
}
```

- [ ] **Step 4: Implement capability and parameter resolution**

Support canonical semantic IDs including `sampling.temperature`,
`sampling.top_p`, `sampling.top_k`, and `reasoning.effort`. Reject unsupported,
out-of-range, mutually exclusive, or conditionally disabled values rather than
silently dropping them.

- [ ] **Step 5: Run GREEN and commit**

```bash
swift test --package-path local-ios-agent/toolkit --filter LocalAgentLLMCoreTests
swift test --package-path local-ios-agent/toolkit
git add local-ios-agent/toolkit
git commit -m "feat: add swift llm configuration foundation"
```

---

### Task 5: Agent Package V2 Translation and Non-Runnable Readiness

**Files:**
- Modify: `local-ios-agent/rust-core/src/agent_package/manifest.rs`
- Modify: `local-ios-agent/rust-core/src/agent_package/validator.rs`
- Modify: `local-ios-agent/rust-core/src/agent_package/installer.rs`
- Modify: `local-ios-agent/rust-core/src/agent_package/lockfile.rs`
- Modify: `local-ios-agent/rust-core/tests/contract/agent_package_agent_os.rs`
- Modify: `local-ios-agent/rust-core/tests/integration/agent_lifecycle_profile_to_runtime.rs`
- Create: `local-ios-agent/rust-core/tests/fixtures/agent_package/v2_portable_llm_slot.json`

**Interfaces:**
- Consumes: Task 3 `LLMSlotV2`.
- Produces: schema-v2 portable package records and a deterministic schema-v1 translator.

- [ ] **Step 1: Write failing translation/install tests**

Assert a schema-v1 import becomes `HostSlotV2`, keeps provider/model only as
optional non-binding hints, drops credential/path fields, and installs with
`needs_llm_binding`. Assert schema-v2 rejects Provider Profile, API key,
CredentialRef, Base URL, installation ID, and local path fields.

- [ ] **Step 2: Run RED**

```bash
cargo test --test contract agent_package_agent_os -- --nocapture
```

- [ ] **Step 3: Implement translation and tagged persistence**

Native schema-v2 packages carry `llm_slot`; schema-v1 decoding is immediately
translated before repository writes. Package locks store requirements and hints,
never the source concrete binding.

- [ ] **Step 4: Prove V2 is not executable**

The run attempt must fail before `RunSnapshotResolver::resolve_model_binding`
with `execution.host_slot_v2_not_runnable`, while the existing development
`legacy_v1` profile still resolves and runs.

- [ ] **Step 5: Run GREEN and commit**

```bash
cargo test --test contract agent_package_agent_os -- --nocapture
cargo test --test integration agent_lifecycle_profile_to_runtime -- --nocapture
git add local-ios-agent/rust-core
git commit -m "feat: translate agent packages to llm slot v2"
```

---

### Task 6: Durable Agent OS State Store and Host-Binding Sagas

**Files:**
- Create the Rust `storage/agent_os_state` files listed above.
- Create: `local-ios-agent/rust-core/src/llm_contracts/host_binding.rs`
- Modify: `local-ios-agent/rust-core/src/storage/mod.rs`
- Create: `local-ios-agent/rust-core/tests/contract/host_binding_saga.rs`
- Create: `local-ios-agent/rust-core/tests/integration/agent_os_state_sqlite.rs`
- Create: `local-ios-agent/toolkit/Sources/LocalAgentLLMCore/LLMStore.swift`
- Create: `local-ios-agent/toolkit/Sources/LocalAgentLLMCore/AgentHostBindingSaga.swift`
- Create: `local-ios-agent/toolkit/Tests/LocalAgentLLMCoreTests/AgentHostBindingSagaTests.swift`

**Interfaces:**
- Produces Rust `prepare_profile_publish`, `commit_profile_publish`, `begin_package_binding`, `attach_host_binding` and Swift `stageHostBinding`, `activateHostBinding`, `reconcileHostBindings`.

- [ ] **Step 1: Write failing saga/state-store tests**

Inject failure after each stage and assert exact idempotency-key replay,
binding ID/revision/hash equality, `host_unbound` after Rust commit but before
Swift activation, and convergence after reopen.

- [ ] **Step 2: Run RED**

```bash
cargo test --test contract host_binding_saga -- --nocapture
swift test --package-path local-ios-agent/toolkit --filter AgentHostBindingSagaTests
```

- [ ] **Step 3: Add SQLite tables and transaction APIs**

Create tables for `global_run_lease`, `host_binding_operations`,
`host_binding_cross_links`, and `run_preparations`. Use explicit state strings,
unique idempotency keys, opaque digest columns, and compare-and-swap updates.

- [ ] **Step 4: Implement both saga halves and reconciliation**

Rust validates only operation token digest, slot/requirements hash, and opaque
binding tuple/receipt. Swift owns the target behind the tuple. Exact retries
return the original operation; conflicting retries fail closed.

- [ ] **Step 5: Run GREEN and commit**

```bash
cargo test --test integration agent_os_state_sqlite -- --nocapture
swift test --package-path local-ios-agent/toolkit --filter AgentHostBindingSagaTests
git add local-ios-agent/rust-core local-ios-agent/toolkit
git commit -m "feat: add durable host binding sagas"
```

---

### Task 7: Durable Route-Neutral Global Run Lease

**Files:**
- Create: `local-ios-agent/rust-core/src/llm_contracts/global_run_lease.rs`
- Modify: `local-ios-agent/rust-core/src/execution/execution_service.rs`
- Modify: `local-ios-agent/rust-core/src/execution/run_lifecycle.rs`
- Modify: `local-ios-agent/rust-core/src/ffi_bridge.rs`
- Create: `local-ios-agent/rust-core/tests/contract/global_run_lease.rs`
- Modify: `local-ios-agent/rust-core/tests/integration/runtime_execution_lifecycle.rs`

**Interfaces:**
- Consumes: Task 6 `AgentOSStateStore`.
- Produces: `acquire_legacy`, `acquire_preparation`, `promote_preparation`, `begin_release`, `complete_release`, and `recover_old_epoch`.

- [ ] **Step 1: Write failing CAS and ordering tests**

Tests prove the lease is acquired before the legacy resolver, a busy lease
prevents snapshot creation, resolver/plan/worker-start failure compensates, and
concurrent legacy/V2 acquisition has one winner.

- [ ] **Step 2: Run RED**

```bash
cargo test --test contract global_run_lease -- --nocapture
```

- [ ] **Step 3: Implement lease state transitions**

Use `preparing | active | releasing`, monotonically increasing generation,
owner run/preparation IDs, schema tag, host epoch, and preparation expiration.
Every update uses this compare-and-swap shape in one transaction:

```sql
update global_run_lease
set lease_generation = ?1,
    owner_run_id = ?2,
    preparation_id = ?3,
    binding_schema = ?4,
    host_process_epoch = ?5,
    state = ?6,
    preparation_expiration = ?7
where singleton_id = 1
  and lease_generation = ?8
  and state = ?9;
```

Empty acquisition inserts the singleton row with `singleton_id = 1`; a zero
affected-row count returns `execution.global_run_busy` or a stale-generation
error according to the current row.

- [ ] **Step 4: Gate the legacy route and release terminal runs**

Acquire before `resolve_and_persist`. Retain the lease for waiting-tool and
approval states; release after final, failure, cancellation, and Rust-owned
cleanup. Do not change the current model binding resolver or worker client.

- [ ] **Step 5: Run GREEN and commit**

```bash
cargo test --test contract global_run_lease -- --nocapture
cargo test --test integration runtime_execution_lifecycle -- --nocapture
git add local-ios-agent/rust-core
git commit -m "feat: gate agent runs with durable global lease"
```

---

### Task 8: Non-Runnable Two-Phase Preparation and Cleanup Records

**Files:**
- Create: `local-ios-agent/rust-core/src/llm_contracts/preparation.rs`
- Modify: `local-ios-agent/rust-core/src/run_snapshot/snapshot.rs`
- Modify: `local-ios-agent/rust-core/src/run_snapshot/snapshot_service.rs`
- Create: `local-ios-agent/rust-core/tests/contract/run_preparation.rs`
- Create: `local-ios-agent/toolkit/Sources/LocalAgentLLMCore/RunPreparationCoordinator.swift`
- Create: `local-ios-agent/toolkit/Tests/LocalAgentLLMCoreTests/RunPreparationCoordinatorTests.swift`

**Interfaces:**
- Produces the Phase A/B/C records and cleanup state machine, but no host-backed worker execution.

- [ ] **Step 1: Write failing preparation lifecycle tests**

Cover preview freeze, five-minute renewal with thirty-minute ceiling,
single-use tokens, registered-session identity matching, commit rejection,
cleanup command deduplication, exact close receipt, and old-epoch release.

- [ ] **Step 2: Run RED**

```bash
cargo test --test contract run_preparation -- --nocapture
swift test --package-path local-ios-agent/toolkit --filter RunPreparationCoordinatorTests
```

- [ ] **Step 3: Implement Rust preparation records**

`preview_run` acquires `preparing` and persists frozen provider-neutral digests.
`register_prepared_session` authenticates but does not consume the token.
`commit_start` validates all public bindings, then atomically begins the normal
prepared-session abort/cleanup path and returns
`execution.host_slot_v2_not_runnable` in Phase 1 without consuming the token as
a run commit or starting a worker. The same provider-neutral validation method
is the entry point Phase 4 will call before its atomic run commit.
`begin_abort_preparation` persists one cleanup identity and
`confirm_prepared_session_closed` releases only the exact lease.

- [ ] **Step 4: Implement Swift coordinator state validation**

Swift stores target/config/capability/parameter snapshots and opaque binding
digests, but Phase 1 uses a fake backend resource so no provider/C++ session or
network request exists.

- [ ] **Step 5: Run GREEN and commit**

```bash
cargo test --test contract run_preparation -- --nocapture
swift test --package-path local-ios-agent/toolkit --filter RunPreparationCoordinatorTests
git add local-ios-agent/rust-core local-ios-agent/toolkit
git commit -m "feat: add llm run preparation contracts"
```

---

### Task 9: C ABI and Swift Bridge DTOs

**Files:**
- Modify: `local-ios-agent/rust-core/src/ffi_bridge.rs`
- Modify: `local-ios-agent/toolkit/Sources/CLocalAgentRuntime/include/CLocalAgentRuntime.h`
- Modify: `local-ios-agent/toolkit/Sources/LocalAgentBridge/RustAgentOSBridgeGateway.swift`
- Modify: `local-ios-agent/toolkit/Sources/LocalAgentBridge/RustRuntimeClient.swift`
- Modify: `local-ios-agent/toolkit/Sources/LocalAgentBridge/AgentOSDTOs.swift`
- Modify: `local-ios-agent/rust-core/tests/integration/ffi_bridge.rs`
- Modify: `local-ios-agent/toolkit/Tests/LocalAgentBridgeTests/RustRuntimeClientContractTests.swift`

**Interfaces:**
- Exposes JSON/C ABI operations for host-binding sagas and preparation lifecycle; all DTOs remain provider-neutral on the Rust side.

- [ ] **Step 1: Write failing Rust/Swift ABI tests**

Round-trip preview, renewal, session registration, abort cleanup, binding stage
receipt commit, and exact stable errors. Assert forbidden provider/credential/
path keys are absent from every Rust DTO.

- [ ] **Step 2: Run RED**

```bash
cargo test --test integration ffi_bridge -- --nocapture
swift test --package-path local-ios-agent/toolkit --filter RustRuntimeClientContractTests
```

- [ ] **Step 3: Add C functions and Swift gateway cases**

Each FFI function follows the existing caller-owned JSON string convention and
panic boundary. No function invokes Swift callbacks or starts V2 execution in
Phase 1.

- [ ] **Step 4: Run GREEN and commit**

```bash
cargo test --test integration ffi_bridge -- --nocapture
swift test --package-path local-ios-agent/toolkit --filter RustRuntimeClientContractTests
git add local-ios-agent/rust-core local-ios-agent/toolkit
git commit -m "feat: expose llm phase one bridge contracts"
```

---

### Task 10: Migration Lint, Contract Runner, and Phase 1 Acceptance

**Files:**
- Create: `local-ios-agent/rust-core/tests/fixtures/architecture/legacy_llm_allowlist.txt`
- Modify: `local-ios-agent/rust-core/tests/lint/architecture_agent_os.rs`
- Create: `local-ios-agent/scripts/run-llm-phase-1-contracts.sh`
- Modify: `local-ios-agent/docs/superpowers/specs/2026-07-10-swift-llm-system-design.md` only to record implemented status/evidence, without changing architecture.

**Interfaces:**
- Produces one repeatable Phase 1 verification entry point.

- [ ] **Step 1: Write failing architecture lint tests**

The lint records every pre-existing legacy provider/model/router occurrence by
path and symbol, rejects new occurrences, rejects V2 concrete Provider/model
fields in Rust, and asserts the allowlist count never grows.

- [ ] **Step 2: Run RED**

```bash
cargo test --test lint architecture_agent_os -- --nocapture
```

- [ ] **Step 3: Add the contract runner**

The script runs:

```bash
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml
swift test --package-path local-ios-agent/toolkit
local-ios-agent/scripts/test-check-rust-ffi-panic-strategy.sh
```

It exits non-zero on the first failure and does not run provider smoke tests or
network operations.

- [ ] **Step 4: Run full Phase 1 verification**

```bash
local-ios-agent/scripts/run-llm-phase-1-contracts.sh
git diff --check
git status --short
```

Expected: Rust and Swift suites pass, FFI panic strategy passes, architecture
allowlist does not grow, and only intentional Phase 1 files are modified.

- [ ] **Step 5: Commit**

```bash
git add local-ios-agent
git commit -m "test: lock llm phase one architecture"
```

## Phase 1 Completion Gate

Phase 1 is complete only when all ten tasks are checked and the contract runner
passes from a clean worktree. Completion does not authorize local model loading,
cloud credentials, provider egress, or host-backed generation; those remain
blocked behind Phases 2–4.
