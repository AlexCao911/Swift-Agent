# Swift LLM Phase 2 Local Product Path Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a directly testable Swift-owned local-model product path that accepts only a signed official catalog, downloads and atomically installs model artifacts, manages disk/RAM lifecycle, and invokes the existing C++ v2 inference boundary without adding local-model semantics to Rust.

**Architecture:** `LocalAgentLLMLocal` owns catalog trust, SQLite installation/download state, filesystem policy, parameter mapping, and the single-loaded-model actor. C++ retains the compiled engine registry, model-format validation, chat-template rendering, loading, generation, cancellation, and unload. Phase 2 proves a direct Swift → C++ path; Phase 3 reuses the common capability/parameter contracts, Phase 4 wraps this runtime behind host sessions and Rust events, and Phase 5 adds Model Center UI and removes legacy routes.

**Tech Stack:** Swift 6, SwiftPM, Foundation `URLSession`, CryptoKit Ed25519/SHA-256, Apple SQLite3, C++17, the existing `local_agent_inference.h` v2 C ABI, llama.cpp fixtures, Swift Testing, and shell contract runners.

**Review revision:** 2026-07-11 — closes native-artifact ownership, catalog acceptance, restored-download events, epoch lease recovery, immutable local sessions, C-handle/backpressure ownership, SQLite ownership, engine identity, and path-boundary findings.

## Global Constraints

- Work only in `/Users/alexandercou/Projects/Alex-agent/.worktrees/llm-runtime-provider-design/local-ios-agent` on `codex/llm-runtime-provider-design`.
- Execute tasks sequentially with one Agent; do not dispatch subagents.
- Use test-driven development: add a focused failing test, observe the expected failure, implement the minimum behavior, rerun focused and regression suites, then commit.
- Target iOS/iPadOS 17+ and macOS 14+ test hosts; no runtime-downloaded native code, dylibs, frameworks, or inference engines.
- V1 accepts only the bundled or remotely refreshed official signed catalog. Arbitrary URLs, file import, Hugging Face browsing, and user-authored manifests remain absent.
- Multiple verified installations may remain on disk. Exactly zero or one local model may be loaded in RAM, and it loads only for real use.
- Switching model unloads the old RAM model but never deletes its installation. Switching to cloud is represented by `LocalModelRuntime.unloadForRouteSwitch()`; Phase 3/4 call it later.
- Exactly one local generation may be active. Downloading never loads a model; selecting/configuring never loads a model.
- Swift owns catalog trust, download/resume data, paths, hashes, disk policy, installation records, capability composition, canonical parameters, tool-call parsing, and runtime orchestration.
- C++ owns only compiled engine discovery, model/load/generation validation, format-specific prompt/template rendering, load, stream, cancel, release, and unload.
- App, SwiftPM, and Rust test hosts resolve the C ABI from one `LocalAgentInferenceNative.xcframework`; standalone C++ unit-test executables may compile source directly but are never linked into product/test hosts.
- Rust receives no catalog entry, artifact URL, installation ID, filesystem path, engine ID, model format, or C++ option. `host_slot_v2` remains non-runnable until Phase 4.
- Phase 2 does not implement Provider Profiles, API keys, Keychain, egress, remote adapters, Rust host callbacks, event envelopes, Agent tool loops, Model Center UI, or legacy removal.
- Local paths remain internal to `LocalAgentLLMLocal`. Public summaries expose opaque installation IDs and display-safe byte counts only.
- Raw artifact hashes are named `artifactSHA256` and mean SHA-256 over exact artifact bytes. They are not `CanonicalDigestV1` values.
- The official catalog signature covers RFC 8785 canonical bytes of the complete `signed` catalog object; only the outer `signature` field is excluded. It does not introduce an unregistered generic digest.
- No automatic fallback to another local model, engine, or cloud route.

## Phase Boundary and File Map

Create one focused Swift target rather than placing local product behavior in `LocalAgentLLMCore`:

```text
toolkit/Sources/LocalAgentLLMLocal/
  LocalModelManifest.swift           signed catalog DTOs and manifest invariants
  LocalModelCatalogCanonicalDocument.swift
  OfficialModelCatalog.swift         bundled/remote trust and rollback policy
  OfficialModelCatalogService.swift  verification plus monotonic durable acceptance
  LocalModelStore.swift              normalized SQLite repository and CAS state
  LocalModelPaths.swift              private directory/staging/final path resolver
  LocalDiskPolicy.swift              free-space preflight and reservation math
  ModelDownloadTransport.swift       injectable background-transfer boundary
  URLSessionModelDownloadTransport.swift
  ModelDownloadCoordinator.swift     one-active FIFO queue and pause/resume
  LocalModelInstaller.swift          byte/hash verification and atomic promotion
  LocalModelReconciler.swift         launch repair of tasks/staging/records
  LocalModelStartupRecovery.swift    epoch, catalog, filesystem, download recovery gate
  LocalModelDeletionService.swift    guarded recoverable deletion
  CppInferenceClient.swift           C ABI ownership and JSON mapping
  CppEventChannel.swift              lossless bounded C callback backpressure
  LocalToolCallCodec.swift           Swift-only local tool-call parsing
  PreparedLocalSession.swift         immutable local run/session snapshot
  LocalModelRuntime.swift            one-loaded-model/generation actor
  LocalLLMSubsystem.swift            one-shot ordered composition/bootstrap
```

The existing C++ files remain under `inference/`; Phase 2 extends them instead of moving model management into C++:

```text
inference/include/local_agent_inference.h
inference/core/engine_capabilities.h
inference/core/model_config.h/.cpp
inference/core/generation_request.h/.cpp
inference/backends/llama_cpp/llama_cpp_prompt.h/.cpp
inference/c_api/local_agent_inference.cpp
```

The C++ sources produce exactly one `LocalAgentInferenceNative.xcframework`. Swift imports and links that artifact directly. Legacy Rust declares the same artifact as an unbundled native dependency and never compiles or embeds a second copy; the final App/test-host linker is the only link owner. The new Swift target never calls through Rust and C++ never imports Rust headers.

---

### Task 1: Add the Local Swift Target and Direct C++ Package Boundary

**Files:**
- Create: `scripts/build-local-agent-inference-xcframework.sh`
- Create: `scripts/test-local-inference-app-link.sh`
- Create: `inference/include/module.modulemap`
- Create: `toolkit/Sources/LocalAgentLLMLocal/CppInferenceClient.swift`
- Create: `toolkit/Tests/LocalAgentLLMLocalTests/CppInferencePackagingTests.swift`
- Create: `apps/LocalAgentApp/LocalAgentAppTests/Integration/LocalInferenceNativeLinkTests.swift`
- Modify: `.gitignore`
- Modify: `toolkit/Package.swift`
- Modify: `rust-core/build.rs`
- Modify: `scripts/build-local-inference-xcode.sh`
- Modify: `scripts/run-local-inference-cpp-contracts.sh`
- Modify: `apps/LocalAgentApp/LocalAgentApp.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces the sole native binary `artifacts/LocalAgentInferenceNative.xcframework` with macOS, iOS Simulator, and iPhoneOS static-library slices.
- Produces SwiftPM product `LocalAgentLLMLocal` depending on `LocalAgentLLMContracts`, `LocalAgentLLMCore`, `CSQLite`, and `LocalAgentInferenceNative`.
- Produces `CppInferenceRegistryAPI`, an injectable Swift registry protocol; no product code outside the local target imports the C module.
- Rust `staticlib` contains unresolved references to this ABI but no `local_agent_*` definition; App/test hosts resolve both Swift and legacy Rust calls from the one XCFramework slice.

- [ ] **Step 1: Write the failing package-boundary test**

Add:

```swift
import LocalAgentLLMLocal
import Testing

@Test func shippedNativeRegistryIsReachableDirectlyFromSwift() throws {
    let engines = try CppInferenceRegistry.live.listEngines()
    #expect(engines.allSatisfy { !$0.testOnly && $0.engineID != "mock" })
}
```

Add a source scan asserting `LocalAgentInferenceNative` is imported only by `LocalAgentLLMLocal` and that no new Rust source contains `local_agent_engine_`, `model_path`, or `LocalModelInstallation`.

Add link-ownership tests that fail while `rust-core/build.rs` still invokes `clang++` over `inference/`: build the Rust staticlib with its legacy local feature, run `nm`, and assert it does not define any `local_agent_engine_*`, `local_agent_model_*`, or `local_agent_generation_*` symbol. Build a Simulator App test host and an unsigned generic-iPhoneOS archive, then assert the final binary defines each exported C ABI symbol exactly once.

- [ ] **Step 2: Run RED**

```bash
scripts/test-local-inference-app-link.sh
```

Expected: fail because Rust still compiles/bundles C++ objects and the App does not link a Swift-owned native artifact.

- [ ] **Step 3: Add the native package and local target**

`scripts/build-local-agent-inference-xcframework.sh` compiles `inference/c_api`, `core`, and enabled production backends once per Apple slice, archives each slice, copies `local_agent_inference.h` plus `module.modulemap`, and runs `xcodebuild -create-xcframework`. The artifact never defines `LOCAL_AGENT_ENABLE_TEST_ENGINES`; mock C++ is compiled only into standalone source-level contract executables, while Swift runtime tests inject a fake `CppInferenceAPI`. The output directory is reproducible, gitignored, and built by repository bootstrap/CI before Swift package resolution or Rust linking.

In `toolkit/Package.swift`, add a local `.binaryTarget(name: "LocalAgentInferenceNative", path: "../artifacts/LocalAgentInferenceNative.xcframework")`, the `LocalAgentLLMLocal` library/target/test target, processed local resources, and `.linkedLibrary("c++")`. Add `LocalAgentLLMLocal` to the App and App-test framework phases without routing any Agent run through it.

Replace the compile/archive loop in `rust-core/build.rs` with selection of the matching slice from `LOCAL_AGENT_INFERENCE_XCFRAMEWORK` and emit `cargo:rustc-link-lib=static:-bundle=local_agent_inference_native`. The default/`+bundle` behavior is forbidden because it would copy the archive into the Rust staticlib; the explicit `-bundle` modifier leaves final symbol resolution to the App/test host. `scripts/build-local-inference-xcode.sh` builds the XCFramework first, passes the same path to Cargo and SwiftPM, and never builds a second native archive.

Define the registry seam before calling the C ABI:

```swift
package protocol CppInferenceRegistryAPI: Sendable {
    func listEngines() throws -> [CppEngineDescriptor]
    func capabilities(engineID: String) throws -> CppEngineCapabilities
}

package struct CppEngineDescriptor: Decodable, Equatable, Sendable {
    let engineID: String
    let displayName: String
    let testOnly: Bool
    let capabilities: CppEngineCapabilities
}

package struct CppEngineCapabilities: Decodable, Equatable, Sendable {
    let supportedModelFormats: Set<String>
    let supportsVision: Bool
    let supportsStreaming: Bool
    let supportsCancellation: Bool
    let supportsTokenUsage: Bool
    let maxContextTokens: UInt64?
}
```

Task 1 decodes only fields emitted by the current C++ registry. Task 8 adds ABI/engine identity and backend parameter descriptors to C++ and the Swift DTO together; C++ never emits canonical Swift parameter IDs. `CppInferenceRegistry.live` implements the current engine list/capability calls and correct `char *` release.

- [ ] **Step 4: Run GREEN and native regressions**

```bash
scripts/run-local-inference-cpp-contracts.sh
swift test --package-path toolkit --filter CppInferencePackagingTests
scripts/test-local-inference-app-link.sh
```

Expected: C++ contracts pass, the shipped artifact registry excludes `mock`, the Rust staticlib defines no native inference ABI symbol, the Simulator App links/tests, the unsigned generic-iPhoneOS archive links, and each final host contains one definition per C ABI export.

- [ ] **Step 5: Commit**

```bash
git add .gitignore inference/include/module.modulemap rust-core/build.rs toolkit \
  apps/LocalAgentApp/LocalAgentApp.xcodeproj/project.pbxproj \
  apps/LocalAgentApp/LocalAgentAppTests/Integration/LocalInferenceNativeLinkTests.swift \
  scripts/build-local-agent-inference-xcframework.sh scripts/build-local-inference-xcode.sh \
  scripts/run-local-inference-cpp-contracts.sh scripts/test-local-inference-app-link.sh
git commit -m "build: give local inference one native artifact"
```

---

### Task 2: Implement the Signed Official Local Model Catalog

**Files:**
- Create: `toolkit/Sources/LocalAgentLLMLocal/LocalModelManifest.swift`
- Create: `toolkit/Sources/LocalAgentLLMLocal/OfficialModelCatalog.swift`
- Create: `toolkit/Sources/LocalAgentLLMLocal/LocalModelCatalogCanonicalDocument.swift`
- Create: `toolkit/Sources/LocalAgentLLMLocal/LocalCapabilityObservationFactory.swift`
- Create: `toolkit/Sources/LocalAgentLLMLocal/Resources/OfficialLocalModelCatalog.v1.json`
- Create: `toolkit/Sources/LocalAgentLLMLocal/Resources/OfficialLocalModelCatalogKeys.v1.json`
- Create: `toolkit/Sources/LocalModelCatalogSigner/main.swift`
- Create: `contracts/local-model-catalog-v1/schema.json`
- Create: `scripts/sign-local-model-catalog.sh`
- Modify: `toolkit/Package.swift`
- Modify: `toolkit/Sources/LocalAgentLLMContracts/LLMCapabilities.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCore/CapabilityMatrix.swift`
- Create: `toolkit/Tests/LocalAgentLLMLocalTests/OfficialModelCatalogTests.swift`
- Create: `toolkit/Tests/LocalAgentLLMLocalTests/LocalCapabilityObservationTests.swift`
- Modify: `toolkit/Tests/LocalAgentLLMCoreTests/CapabilityMatrixTests.swift`
- Create: `contracts/canonical-digest-v1/fixtures/capability-evidence-local-catalog-v1.json`
- Create: `contracts/canonical-digest-v1/fixtures/capability-observation-local-catalog-v1.json`
- Create: `toolkit/Tests/LocalAgentLLMLocalTests/Fixtures/catalog-valid.json`
- Create: `toolkit/Tests/LocalAgentLLMLocalTests/Fixtures/catalog-rollback.json`
- Create: `toolkit/Tests/LocalAgentLLMLocalTests/Fixtures/catalog-test-public-key.txt`

**Interfaces:**
- Produces pure `OfficialModelCatalogVerifier.verify(envelope:keyRing:) -> VerifiedLocalModelCatalog`; Task 3 owns monotonic durable acceptance.
- Produces immutable `LocalModelRevisionManifest` values keyed by `(modelID, revision)`.
- Produces signed-catalog `modelSupports` capability observations with exact model/catalog subjects and registered evidence/observation digests; it does not trust a pre-resolved snapshot embedded in the manifest.
- Produces one canonical signed-document builder shared by release signing and runtime verification.
- The bundled production catalog and public key ring are SwiftPM resources embedded in the App's `LocalAgentLLMLocal` resource bundle. Test fixtures use a distinct key ID/key and cannot be accepted by production construction.

- [ ] **Step 1: Write failing trust and schema tests**

Cover valid Ed25519 signature, unknown/revoked key ID, changed URL/hash/size/revocation after signing, unsupported schema, duplicate model revision, duplicate artifact role/path, non-HTTPS URL, path traversal, zero sizes, unknown engine, unsupported OS/device, and precision boundaries above `2^53`. Test that release resources exist through `Bundle.module`, decode with the production key ring, and are present in a built App resource bundle. Add a repository scan proving no production private key, seed, or signing environment value is committed.

Also cover a higher signed catalog revision revoking a model revision: the catalog returns `.revoked` and invalidates its capability observations immediately. A missing entry is treated as superseded/unknown, not as an implicit revocation; explicit revocations are carried in the signed payload as `[LocalModelRevisionID]`. Task 9 proves the runtime rejects that disposition while leaving installed files for explicit deletion.

Use this public shape:

```swift
public struct LocalModelRevisionID: Hashable, Codable, Sendable {
    public let modelID: String
    public let revision: UInt64
}

public struct VerifiedLocalModelCatalog: Equatable, Sendable {
    public let catalogRevision: UInt64
    public let keyID: String
    public let models: [LocalModelRevisionID: LocalModelRevisionManifest]
    public let revokedModelRevisions: Set<LocalModelRevisionID>
    package let canonicalSignedBytes: Data
    package let signature: Data
}

public struct LocalModelArtifactManifest: Codable, Equatable, Sendable {
    public let artifactID: String
    public let role: LocalModelArtifactRole
    public let relativePath: String
    public let downloadURL: URL
    public let byteSize: UInt64
    public let artifactSHA256: String
}

public struct LocalModelRevisionManifest: Codable, Equatable, Sendable {
    public let id: LocalModelRevisionID
    public let displayName: String
    public let family: String
    public let engineID: String
    public let modelFormat: String
    public let artifacts: [LocalModelArtifactManifest]
    public let installedByteSize: UInt64
    public let minimumOSMajor: Int
    public let supportedDeviceClasses: Set<LocalDeviceClass>
    public let estimatedMemoryClass: LocalMemoryClass
    public let declaredCapabilities: [LocalCapabilityDeclaration]
    public let parameterSchema: LLMParameterSchema
    public let parameterDefaults: GenerationConfiguration
    public let loadTemplate: LocalEngineLoadTemplate
    public let chatTemplate: LocalChatTemplateSelector
    public let toolCallCodecID: String?
}

public enum LocalModelArtifactRole: String, Codable, Sendable {
    case weights, tokenizer, multimodalProjection = "multimodal_projection", chatTemplate = "chat_template"
}

public enum LocalDeviceClass: String, Codable, Sendable {
    case phone, tablet
}

public enum LocalMemoryClass: String, Codable, Sendable {
    case small, medium, large
}

public struct LocalCapabilityDeclaration: Codable, Equatable, Sendable {
    public let capabilityID: String
    public let value: CapabilityValue
}

public struct LocalEngineLoadTemplate: Codable, Equatable, Sendable {
    public let contextTokens: UInt64
    public let requiredArtifactRoles: Set<LocalModelArtifactRole>
    public let manifestControlledOptions: [String: CanonicalJSONValue]
}

public struct LocalChatTemplateSelector: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case gguf, catalogArtifact = "catalog_artifact" }
    public let source: Source
    public let templateID: String
}
```

Define `VerifiedLocalModelCatalog` beside the verifier with an explicit `fileprivate` initializer; no other source file or external caller can construct a trusted candidate.

- [ ] **Step 2: Run RED**

```bash
swift test --package-path toolkit --filter OfficialModelCatalogTests
```

Expected: fail because catalog types and signature validation do not exist.

- [ ] **Step 3: Implement canonical signature verification and invariants**

Use exactly this envelope:

```json
{
  "signed": {
    "schema_version": "1",
    "key_id": "local-catalog-2026-01",
    "catalog_revision": "1",
    "models": [],
    "revoked_model_revisions": []
  },
  "signature": "unpadded-base64url-ed25519-signature"
}
```

`LocalModelCatalogCanonicalDocument` converts the complete `signed` object to `CanonicalJSONValue`; signing and verification both call that one builder followed by `CanonicalDigestV1.canonicalize`. `catalog_revision`, every model `revision`, artifact `byte_size`, `installed_byte_size`, context limit, and other `UInt64` values are unsigned base-10 strings without leading zeros, then range-checked into Swift `UInt64`. Model and revocation arrays use the order stored in the signed document; duplicate identities are rejected. The signature therefore covers schema, key ID, revision, models, artifact URLs/hashes/sizes, and all revocations. Ordinary `JSONEncoder` bytes are never signed or verified.

`OfficialLocalModelCatalogKeys.v1.json` is the only production key-ring location and contains `key_id`, unpadded-base64url Ed25519 public key, and status `active | revoked`. The matching private seed exists only in the release signing system secret named `LOCAL_MODEL_CATALOG_SIGNING_SEED`; `scripts/sign-local-model-catalog.sh` refuses a missing key ID/seed, sends neither to stdout, signs through `LocalModelCatalogSigner`, and commits only the envelope/public key ring. Runtime code has no signing API.

Validation returns stable `LLMFailure` codes including:

```text
download.catalog_signature_invalid
download.catalog_schema_unsupported
download.catalog_manifest_invalid
download.catalog_key_unknown
download.catalog_key_revoked
```

The pure verifier does not accept a caller-authored `lastAcceptedRevision` and does not choose fallback state. Task 3 persists and selects accepted catalog state. Do not put a catalog-refresh network client in this task; Phase 2 accepts injected remote bytes, while the app-level scheduler remains Phase 5.

Bring the Phase 1 capability DTO up to the full 7/10 design without breaking existing initializers: add `CapabilitySource`, complete `CapabilitySubject`, `ValidationScope`, invalidation triggers, engine/adapter version, evidence digest, and observation digest with provider-neutral default values. Extend `CapabilitySnapshot` with exact subject, sorted contributing observation digests, and nearest expiry; its existing capabilities-only initializer supplies explicit test defaults. `LocalCapabilityObservationFactory` creates `modelSupports` observations whose subject pins `modelID`, model revision, and catalog revision; source is `signedLocalCatalog`, authority is `authoritative`, expiry is absent, and invalidation includes catalog revision, engine version, app build, and OS capability changes. Compute `capability-evidence:v1` and `capability-observation:v1` from the exact fixture schemas; never use the artifact SHA-256 as capability evidence.

Extend `CapabilityMatrix.resolve` to accept an exact `CapabilitySubject` plus `CapabilityResolutionPolicy`. `.local` requires non-expired subject-matching `modelSupports` and `engineCanExecute` dimensions for every positive capability; authoritative negative wins and a missing/subject-mismatched dimension resolves to `unknown`. Phase 3 will add its cloud policy rather than weakening `.local`.

- [ ] **Step 4: Run GREEN**

```bash
swift test --package-path toolkit --filter OfficialModelCatalogTests
swift test --package-path toolkit --filter LocalCapabilityObservationTests
swift test --package-path toolkit --filter CapabilityMatrixTests
scripts/test-local-inference-app-link.sh --require-catalog-resources
```

- [ ] **Step 5: Commit**

```bash
git add toolkit/Sources/LocalAgentLLMContracts/LLMCapabilities.swift \
  toolkit/Sources/LocalAgentLLMCore/CapabilityMatrix.swift \
  toolkit/Sources/LocalAgentLLMLocal toolkit/Sources/LocalModelCatalogSigner \
  toolkit/Tests/LocalAgentLLMCoreTests toolkit/Tests/LocalAgentLLMLocalTests \
  toolkit/Package.swift contracts/canonical-digest-v1/fixtures \
  contracts/local-model-catalog-v1/schema.json scripts/sign-local-model-catalog.sh
git commit -m "feat: verify the official local model catalog"
```

---

### Task 3: Add Normalized SQLite Installation and Download State

**Files:**
- Modify: `toolkit/Sources/LocalAgentLLMCore/SQLiteConnection.swift`
- Create: `toolkit/Sources/LocalAgentLLMLocal/LocalModelStore.swift`
- Create: `toolkit/Sources/LocalAgentLLMLocal/OfficialModelCatalogService.swift`
- Create: `toolkit/Tests/LocalAgentLLMLocalTests/LocalModelStoreTests.swift`

**Interfaces:**
- Produces `LocalModelStore(fileURL:)`, `LocalModelStore.default(appSupportRoot:)`, and `LocalModelStore.inMemory()` for the dedicated `local-models.sqlite` database.
- Produces `OfficialModelCatalogService.accept(bundled:remote:)` with signature verification plus monotonic SQL CAS; callers never supply the accepted revision.
- Produces SQL-CAS methods for installation state, artifact progress, download queue order, resume data, filesystem operation intent, and RAM-use leases.
- Reserves normalized `prepared_local_sessions` rows for Task 9's sanitized immutable local session snapshots and old-epoch closure.
- Stores absolute paths only in this local repository; public records return opaque IDs.

- [ ] **Step 1: Write failing schema, reopen, rollback, and CAS tests**

Require `PRAGMA user_version = 1` and normalized tables:

```text
local_catalog_state
local_installations
local_artifacts
local_download_queue
local_disk_reservations
local_filesystem_operations
local_model_use_leases
prepared_local_sessions
```

Assert the database path is exactly `<Application Support>/LocalAgent/LLM/local-models.sqlite`; the Phase 1/Core store remains the separate `llm-state.sqlite`. Each database owns its own `PRAGMA user_version` and migration coordinator. Mark `local-models.sqlite`, `-wal`, `-shm`, model artifacts, staging, and resume state excluded from iCloud backup because all are device-specific/reconstructable; `llm-state.sqlite` keeps its existing policy.

Test exact state transitions:

```text
not_installed -> queued -> downloading -> paused -> downloading
downloading -> verifying -> installed
queued|downloading|paused|verifying -> failed
failed -> queued (explicit user retry only)
installed -> deleting -> deleted
```

`not_installed` and `deleted` are derived states represented by absence of an installation row, matching the design's requirement that completed deletion removes the record. Reject every unspecified transition and stale `state_revision`. Test two reopened stores cannot both win the same CAS, failed multi-row writes roll back, resume `Data` round-trips as SQLite BLOB, and a public installation summary contains no path/URL/hash.

Add catalog acceptance tests: first launch atomically accepts the verified bundled revision; a higher verified remote revision replaces it; invalid remote bytes leave persisted/bundled accepted state unchanged; equal content is idempotent; equal revision/different canonical bytes conflicts; lower revision returns `download.catalog_revision_rollback`; injected crash cannot advance only the revision or only the envelope; reopen re-verifies the persisted envelope/key and never falls back to an older bundled catalog. Corrupt/unknown-key persisted accepted state fails closed as `download.catalog_state_invalid` instead of resetting its monotonic floor.

- [ ] **Step 2: Run RED**

```bash
swift test --package-path toolkit --filter LocalModelStoreTests
```

- [ ] **Step 3: Extend the SQLite primitive and implement the repository**

Make `SQLiteConnection` and `SQLiteValue` package-visible. Add `.integer(Int64)` and `.blob(Data)` bindings plus typed `SQLiteRow` accessors without changing existing `LLMStore` behavior.

Use these state types:

```swift
public enum LocalInstallationState: String, Codable, Sendable {
    case queued, downloading, paused, verifying, installed, deleting, failed
}

package struct LocalInstallationRecord: Sendable {
    let installationID: String
    let modelRevision: LocalModelRevisionID
    let state: LocalInstallationState
    let stateRevision: UInt64
    let rootPath: String
    let failureCode: String?
}
```

All multi-table operations use `BEGIN IMMEDIATE`. Duplicate `(model_id, model_revision)` is rejected by a unique index. Resume data is never JSON/base64 text.

`local_catalog_state` is a singleton row containing accepted revision, exact canonical signed bytes, signature, key ID, and accepted timestamp. `OfficialModelCatalogService` verifies an immutable candidate first, then calls:

```swift
public struct AcceptedLocalModelCatalog: Equatable, Sendable {
    public enum Source: String, Sendable { case bundled, remote, persisted }
    public let verified: VerifiedLocalModelCatalog
    public let source: Source
    public let acceptedAt: Date
}

package func acceptVerifiedCatalog(
    _ candidate: VerifiedLocalModelCatalog,
    expectedAcceptedRevision: UInt64?
) throws -> AcceptedLocalModelCatalog
```

The transaction CASes the stored revision, envelope bytes, signature, and key ID together. `acceptVerifiedCatalog` is package-internal and an architecture test allows only `OfficialModelCatalogService` to call it. `AcceptedLocalModelCatalog` adds only source/acceptance metadata to the already verified candidate. Startup always reads/re-verifies this row before considering bundled or injected remote bytes.

Filesystem work is never described as atomic with SQLite. `local_filesystem_operations` stores `promote_installation`, `cancel_download`, and `delete_installation` intents with `pending | filesystem_applied | committed` state. A cancel first persists intent/task/reservation identities, then cancels the transport and cleans staging, then transactionally removes rows; `LocalModelReconciler` compensates any crash boundary.

- [ ] **Step 4: Run GREEN and Core regressions**

```bash
swift test --package-path toolkit --filter LocalModelStoreTests
swift test --package-path toolkit --filter LLMStoreTests
```

- [ ] **Step 5: Commit**

```bash
git add toolkit/Sources/LocalAgentLLMCore/SQLiteConnection.swift \
  toolkit/Sources/LocalAgentLLMLocal/LocalModelStore.swift \
  toolkit/Sources/LocalAgentLLMLocal/OfficialModelCatalogService.swift \
  toolkit/Tests/LocalAgentLLMLocalTests/LocalModelStoreTests.swift
git commit -m "feat: persist local model lifecycle in sqlite"
```

---

### Task 4: Implement Private Paths, Disk Preflight, and Reservations

**Files:**
- Create: `toolkit/Sources/LocalAgentLLMLocal/LocalModelPaths.swift`
- Create: `toolkit/Sources/LocalAgentLLMLocal/LocalDiskPolicy.swift`
- Create: `toolkit/Tests/LocalAgentLLMLocalTests/LocalDiskPolicyTests.swift`

**Interfaces:**
- Produces `LocalModelPaths` with stable staging/final/trash paths inside one app-owned root.
- Produces `LocalDiskPolicy.preflight(_:volume:) -> LocalDiskReservation`.
- Produces injectable `LocalVolumeCapacity` so tests never depend on host free space.

- [ ] **Step 1: Write failing path and capacity tests**

Assert traversal and symlink escape are rejected, all final/staging renames stay on one volume, each directory gets `URLResourceKey.isExcludedFromBackupKey = true`, and the reserve is:

```swift
max(512 * 1_024 * 1_024, manifest.installedByteSize / 10)
```

Required bytes are remaining artifact bytes plus installation/verification overhead plus the reserve. Simultaneous queued installations cannot reserve the same free bytes. Insufficient space returns `download.insufficient_disk` with display-safe `requiredBytes`/`availableBytes`, never an automatic deletion.

- [ ] **Step 2: Run RED**

```bash
swift test --package-path toolkit --filter LocalDiskPolicyTests
```

- [ ] **Step 3: Implement path confinement and centralized policy**

Expose only opaque/public storage data:

```swift
public struct LocalStorageRequirement: Equatable, Sendable {
    public let remainingDownloadBytes: UInt64
    public let verificationOverheadBytes: UInt64
    public let safetyReserveBytes: UInt64
}

package struct LocalDiskReservation: Sendable {
    let reservationID: String
    let installationID: String
    let reservedBytes: UInt64
}
```

Use resource-value capacity APIs (`volumeAvailableCapacityForImportantUsage`) behind the injected protocol. Store reservation rows transactionally through `LocalModelStore`; release them after install/failure/cancel.

The exact service seam is:

```swift
package protocol LocalVolumeCapacity: Sendable {
    func availableImportantUsageBytes(at root: URL) throws -> UInt64
}

package func preflight(
    installationID: String,
    manifest: LocalModelRevisionManifest,
    completedArtifactBytes: UInt64,
    volume: any LocalVolumeCapacity
) async throws -> LocalDiskReservation
```

- [ ] **Step 4: Run GREEN**

```bash
swift test --package-path toolkit --filter LocalDiskPolicyTests
```

- [ ] **Step 5: Commit**

```bash
git add toolkit/Sources/LocalAgentLLMLocal/LocalModelPaths.swift \
  toolkit/Sources/LocalAgentLLMLocal/LocalDiskPolicy.swift \
  toolkit/Tests/LocalAgentLLMLocalTests/LocalDiskPolicyTests.swift
git commit -m "feat: enforce local model disk policy"
```

---

### Task 5: Add the One-Active Background Download Queue

**Files:**
- Create: `toolkit/Sources/LocalAgentLLMLocal/ModelDownloadTransport.swift`
- Create: `toolkit/Sources/LocalAgentLLMLocal/URLSessionModelDownloadTransport.swift`
- Create: `toolkit/Sources/LocalAgentLLMLocal/ModelDownloadCoordinator.swift`
- Create: `toolkit/Tests/LocalAgentLLMLocalTests/ModelDownloadCoordinatorTests.swift`

**Interfaces:**
- Produces `ModelDownloadTransport` with one permanent task-identified event stream shared by new and restored tasks.
- Produces actor `ModelDownloadCoordinator` with FIFO queue and at most one active artifact transfer.
- Persists background task identifiers, validators, progress, and opaque resume data before publishing state.
- Produces `restore(pendingCancellations:)`, which reattaches known tasks, completes durable cancel intents, and only then starts the next queued transfer.

- [ ] **Step 1: Write failing queue, pause/resume, and restoration tests**

Use a deterministic fake transport to prove: FIFO ordering; only one active model artifact transfer; pause stores resume data when supplied; resume uses the same artifact identity; invalid resume data clears only that artifact and restarts it from zero; ETag/Last-Modified mismatch restarts safely; duplicate enqueue is idempotent; network failure enters `failed` with `download.network_failed`; process restoration reattaches known tasks and receives their later progress/completion/failure through the same event stream; unknown restored tasks are cancelled/quarantined. Crash-inject cancellation before transport cancel, after cancel acknowledgement, and after staging cleanup to prove the durable `cancel_download` intent converges without claiming filesystem/SQLite atomicity.

- [ ] **Step 2: Run RED**

```bash
swift test --package-path toolkit --filter ModelDownloadCoordinatorTests
```

- [ ] **Step 3: Implement the transport seam and actor**

Use:

```swift
package protocol ModelDownloadTransport: Sendable {
    var events: AsyncStream<ModelDownloadTransportEvent> { get }
    func start(_ request: ArtifactDownloadRequest, resumeData: Data?) async throws -> Int
    func restoredTasks() async throws -> [RestoredModelDownload]
    func pause(taskIdentifier: Int) async throws -> Data?
    func cancel(taskIdentifier: Int) async
    func setBackgroundEventsCompletionHandler(_ handler: @escaping @Sendable () -> Void) async
}

package struct ArtifactDownloadRequest: Equatable, Sendable {
    let installationID: String
    let artifactID: String
    let url: URL
    let expectedBytes: UInt64
    let stagingURL: URL
    let etag: String?
    let lastModified: String?
}

package enum ModelDownloadTransportEvent: Equatable, Sendable {
    case progress(taskIdentifier: Int, receivedBytes: UInt64, expectedBytes: UInt64)
    case completed(taskIdentifier: Int, stagedFileURL: URL, etag: String?, lastModified: String?)
    case failed(taskIdentifier: Int, failure: LLMFailure)
}

package struct RestoredModelDownload: Equatable, Sendable {
    let taskIdentifier: Int
    let installationID: String
    let artifactID: String
}

package struct PendingTransportCancellation: Equatable, Sendable {
    let operationID: String
    let taskIdentifier: Int
    let installationID: String
}
```

`ModelDownloadCoordinator.restore(pendingCancellations: [PendingTransportCancellation])` consumes the restored task list and shared event stream before the coordinator is exposed.

The coordinator subscribes to `events` immediately when constructed, before it asks for restored tasks or exposes any public method. The live transport creates one `.unbounded` `AsyncStream` for its lifetime and every delegate event includes `taskIdentifier`; it never creates a per-start stream. Download progress may be coalesced by the coordinator into the latest persisted byte count, but completed/failed events are never dropped. Restored and newly created tasks therefore share one routing path.

The live transport uses a background `URLSessionConfiguration` on iOS and a deterministic identifier derived from the app bundle plus installation subsystem name. Delegate callbacks copy temporary files immediately into the installation staging directory. It retains the system background-events completion handler until `urlSessionDidFinishEvents`; Phase 5 only forwards the application callback and does not own download state. Swift actor state is advisory; SQLite is authoritative after restart.

- [ ] **Step 4: Run GREEN**

```bash
swift test --package-path toolkit --filter ModelDownloadCoordinatorTests
```

- [ ] **Step 5: Commit**

```bash
git add toolkit/Sources/LocalAgentLLMLocal/ModelDownloadTransport.swift \
  toolkit/Sources/LocalAgentLLMLocal/URLSessionModelDownloadTransport.swift \
  toolkit/Sources/LocalAgentLLMLocal/ModelDownloadCoordinator.swift \
  toolkit/Tests/LocalAgentLLMLocalTests/ModelDownloadCoordinatorTests.swift
git commit -m "feat: add resumable local model downloads"
```

---

### Task 6: Verify Artifacts, Install Atomically, and Reconcile Launch State

**Files:**
- Create: `toolkit/Sources/LocalAgentLLMLocal/LocalModelInstaller.swift`
- Create: `toolkit/Sources/LocalAgentLLMLocal/LocalModelReconciler.swift`
- Create: `toolkit/Tests/LocalAgentLLMLocalTests/LocalModelInstallerTests.swift`
- Create: `toolkit/Tests/LocalAgentLLMLocalTests/LocalModelReconcilerTests.swift`

**Interfaces:**
- Produces `LocalModelInstaller.verifyAndInstall(installationID:manifest:)`.
- Produces injected `LocalModelConfigValidator.validate(_:)`; Task 9 supplies the live C++ validator after Task 8 adds its non-loading ABI.
- Produces `LocalModelReconciler.reconcileAtLaunch()` before downloads/runtime become available.
- Installation becomes visible only after every signed artifact passes exact size and SHA-256.

- [ ] **Step 1: Write failing verification and crash-boundary tests**

Use this validator seam:

```swift
package protocol LocalModelConfigValidator: Sendable {
    func validate(
        manifest: LocalModelRevisionManifest,
        artifactPathsByRole: [LocalModelArtifactRole: URL]
    ) throws
}
```

Cover correct multi-artifact install, wrong byte size, one-bit SHA mismatch, missing required artifact, unexpected file, engine incompatibility, interruption before/after filesystem rename, stale staging removal, final directory without committed record, committed record without directory, backup exclusion, and idempotent replay after each injected crash boundary.

Require stable failures:

```text
installation.checksum_mismatch
installation.engine_incompatible
installation.interrupted
```

- [ ] **Step 2: Run RED**

```bash
swift test --package-path toolkit --filter LocalModelInstallerTests
swift test --package-path toolkit --filter LocalModelReconcilerTests
```

- [ ] **Step 3: Implement staged verification and recoverable promotion**

Stream file bytes through `CryptoKit.SHA256`; never load model weights into `Data`. Before rename, call the injected `LocalModelConfigValidator` with paths resolved from the signed manifest. The fake validator proves installer behavior in this task; Task 9 binds its live implementation to `local_agent_model_validate` after the ABI lands in Task 8. Persist a `promote_installation` filesystem operation intent, atomically rename `.staging/<installationID>` to `installed/<installationID>` on the same volume, then CAS `verifying -> installed` and clear the intent.

Launch reconciliation rules are deterministic:

```text
intent + final directory + verifying record -> finish installed commit
intent + staging directory + verifying record -> reverify then retry promotion
installed record + missing final directory -> failed(installation.interrupted)
orphan staging without active record/task -> remove staging
orphan final directory without committed identity -> move to trash, then remove
cancel_download intent -> return PendingTransportCancellation; do not delete staging/task rows before transport cancellation is confirmed
```

```swift
package struct LocalFilesystemRecoveryResult: Equatable, Sendable {
    let pendingTransportCancellations: [PendingTransportCancellation]
}
```

`reconcileAtLaunch() -> LocalFilesystemRecoveryResult` contains pending task IDs/cancel operation IDs. Task 7 passes that result to `ModelDownloadCoordinator.restore(pendingCancellations:)`; the coordinator cancels/reattaches the restored URLSession task through the unified event path, then commits staging/reservation/row cleanup. This preserves the required filesystem-repair-before-download-exposure order without pretending SQLite can cancel a system task.

- [ ] **Step 4: Run GREEN**

```bash
swift test --package-path toolkit --filter LocalModelInstallerTests
swift test --package-path toolkit --filter LocalModelReconcilerTests
```

- [ ] **Step 5: Commit**

```bash
git add toolkit/Sources/LocalAgentLLMLocal/LocalModelInstaller.swift \
  toolkit/Sources/LocalAgentLLMLocal/LocalModelReconciler.swift \
  toolkit/Tests/LocalAgentLLMLocalTests/LocalModelInstallerTests.swift \
  toolkit/Tests/LocalAgentLLMLocalTests/LocalModelReconcilerTests.swift
git commit -m "feat: verify and atomically install local models"
```

---

### Task 7: Add Guarded Deletion and Model-Use Leases

**Files:**
- Create: `toolkit/Sources/LocalAgentLLMCore/HostProcessEpoch.swift`
- Create: `toolkit/Sources/LocalAgentLLMLocal/LocalModelStartupRecovery.swift`
- Create: `toolkit/Sources/LocalAgentLLMLocal/LocalModelDeletionService.swift`
- Create: `toolkit/Tests/LocalAgentLLMLocalTests/LocalModelStartupRecoveryTests.swift`
- Create: `toolkit/Tests/LocalAgentLLMLocalTests/LocalModelDeletionServiceTests.swift`
- Modify: `toolkit/Sources/LocalAgentLLMLocal/LocalModelStore.swift`

**Interfaces:**
- Produces durable `LocalModelUseLease` owned by `LocalModelRuntime` while loaded/session-active.
- Produces one 256-bit Swift `HostProcessEpoch` and ordered `LocalModelStartupRecovery.run`; Task 9's subsystem factory cannot expose a downloader/runtime before this result exists.
- Produces `LocalModelDeletionService.delete(installationID:)` with an intent/trash/commit protocol.
- Deletion never mutates Agent bindings; later readiness reports the exact missing installation.

- [ ] **Step 1: Write failing deletion tests**

Reject deletion while loaded, session-active, verifying, or downloading. Require the caller to cancel a paused/downloading installation first. Prove an installed unused model is moved to private trash before its record is removed, a crash after trash move completes on launch, a duplicate delete is idempotent, and deleting one installation does not affect another revision.

Reopen a database containing loaded/session leases and prepared local sessions from an old epoch and prove startup recovery atomically marks sessions closed plus leases `ended_epoch` before deletion/readiness checks. Inject a failure at each recovery stage and assert no successful recovery token is returned. Assert this exact order:

```text
generate new Swift host epoch
open/migrate local-models.sqlite
atomically end every active use lease from another epoch
re-verify and accept persisted/bundled catalog state
reconcile promote/cancel/delete filesystem intents and installation records
subscribe to the permanent download event stream and restore background tasks
return LocalStartupRecoveryResult to Task 9; it alone may construct/expose runtime
```

- [ ] **Step 2: Run RED**

```bash
swift test --package-path toolkit --filter LocalModelDeletionServiceTests
```

- [ ] **Step 3: Implement leases and recoverable deletion**

Use:

```swift
public struct HostProcessEpoch: RawRepresentable, Codable, Equatable, Sendable {
    public let rawValue: String
}

package struct LocalModelUseLease: Equatable, Sendable {
    enum Purpose: String, Sendable {
        case loaded
        case activeSession = "active_session"
    }

    enum State: String, Sendable {
        case active
        case released
        case endedEpoch = "ended_epoch"
    }

    let leaseID: String
    let installationID: String
    let purpose: Purpose
    let hostProcessEpoch: HostProcessEpoch
    let state: State
    let leaseRevision: UInt64
}
```

Acquire/release through SQL CAS. `delete` transactionally checks zero leases, writes `delete_installation` intent, and changes `installed -> deleting`; filesystem code moves the directory to `.trash/<operationID>`; a final transaction removes artifact/installation rows and marks the operation complete. `LocalModelReconciler` finishes incomplete deletion intents.

`HostProcessEpoch.generate()` obtains 32 bytes from `SecRandomCopyBytes`, encodes unpadded base64url, and is created once by App composition. `recoverLocalSessionsAndUseLeasesForNewEpoch` is one `BEGIN IMMEDIATE` transaction that closes old-epoch `prepared_local_sessions` and changes their active leases to `ended_epoch`; only active current-epoch rows block load/delete. App termination implies old C++ RAM resources no longer exist, so no C++ callback is attempted during old-epoch recovery.

`LocalModelStartupRecovery` has one internal entry:

```swift
package struct LocalStartupRecoveryResult: Sendable {
    let hostProcessEpoch: HostProcessEpoch
    let acceptedCatalog: AcceptedLocalModelCatalog
}

package enum LocalModelStartupRecovery {
    static func run(
        store: LocalModelStore,
        hostProcessEpoch: HostProcessEpoch,
        bundledCatalog: Data,
        remoteCatalog: Data?,
        reconciler: LocalModelReconciler,
        downloads: ModelDownloadCoordinator
    ) async throws -> LocalStartupRecoveryResult
}
```

- [ ] **Step 4: Run GREEN**

```bash
swift test --package-path toolkit --filter LocalModelDeletionServiceTests
swift test --package-path toolkit --filter LocalModelReconcilerTests
swift test --package-path toolkit --filter LocalModelStartupRecoveryTests
```

- [ ] **Step 5: Commit**

```bash
git add toolkit/Sources/LocalAgentLLMCore/HostProcessEpoch.swift \
  toolkit/Sources/LocalAgentLLMLocal/LocalModelStartupRecovery.swift \
  toolkit/Sources/LocalAgentLLMLocal/LocalModelStore.swift \
  toolkit/Sources/LocalAgentLLMLocal/LocalModelDeletionService.swift \
  toolkit/Tests/LocalAgentLLMLocalTests/LocalModelDeletionServiceTests.swift \
  toolkit/Tests/LocalAgentLLMLocalTests/LocalModelStartupRecoveryTests.swift
git commit -m "feat: guard local model deletion with use leases"
```

---

### Task 8: Formalize the C++ v2 Message, Tool, Template, Capability, and Parameter Contract

**Files:**
- Modify: `inference/include/local_agent_inference.h`
- Modify: `inference/core/engine_capabilities.h`
- Modify: `inference/core/engine_registry.cpp`
- Modify: `inference/core/model_config.h`
- Modify: `inference/core/model_config.cpp`
- Modify: `inference/core/generation_request.h`
- Modify: `inference/core/generation_request.cpp`
- Modify: `inference/backends/llama_cpp/llama_cpp_prompt.h`
- Modify: `inference/backends/llama_cpp/llama_cpp_prompt.cpp`
- Modify: `inference/c_api/local_agent_inference.cpp`
- Modify: `inference/tests/generation_request_contract.cpp`
- Create: `inference/tests/validation_contract.cpp`
- Modify: `inference/tests/llama_cpp_prompt_contract.cpp`
- Modify: `toolkit/Sources/LocalAgentLLMLocal/CppInferenceClient.swift`
- Modify: `toolkit/Tests/LocalAgentLLMLocalTests/CppInferencePackagingTests.swift`
- Modify: `scripts/run-local-inference-cpp-contracts.sh`

**Interfaces:**
- Adds non-allocating validation calls `local_agent_model_validate` and `local_agent_generation_validate`.
- Engine descriptors report ABI version, exact engine build/version, supported model formats, backend option descriptors/ranges, modalities, streaming/cancellation/usage, and verified maximum context where known.
- Generation request v2 carries canonical messages, optional canonical tool schema, manifest-approved template selector, codec ID, and concrete mapped sampling options.

- [ ] **Step 1: Write failing C/C++ contract tests**

Require this request shape:

```json
{
  "schema_version":"2",
  "messages":[
    {"role":"system","content":[{"type":"text","text":"Be concise"}]},
    {"role":"user","content":[{"type":"text","text":"hello"}]}
  ],
  "tool_schema":{"tools":[{"name":"search","input_schema":{"type":"object"}}]},
  "template":{"source":"gguf","id":"catalog-approved"},
  "tool_call_codec_id":"json_tool_calls_v1",
  "sampling":{"temperature":0.2,"top_p":0.9,"top_k":40,"min_p":0.05,
              "repeat_penalty":1.1,"max_new_tokens":128,"seed":42,
              "stop_sequences":["</tool>"]}
}
```

Tests reject unknown schema, role/content type, attachment/buffer mismatch, unsupported tool schema, unapproved template source/ID, unsupported parameter, out-of-range value, concurrent generation, unload during active generation, and validation that accidentally loads weights. Prove llama.cpp receives messages/tools/template and performs rendering immediately before tokenization; Swift-selected codec is not interpreted as Agent policy by C++. Assert every production engine reports `abi_version = "2"` and a non-empty reproducible `engine_version`; changing the compiled backend version changes the capability observation subject in Task 9.

- [ ] **Step 2: Run RED**

```bash
scripts/run-local-inference-cpp-contracts.sh
```

Expected: fail at generation/validation/template tests because v2 currently accepts flat string messages and exposes no validation/parameter-schema calls.

- [ ] **Step 3: Extend the ABI and core structures**

Add:

```c
LocalAgentStatus local_agent_model_validate(
    LocalAgentEngineHandle *engine,
    const char *model_config_json
);
LocalAgentStatus local_agent_generation_validate(
    LocalAgentModelHandle *model,
    const char *generation_request_json
);
LocalAgentStatus local_agent_engine_parameter_schema(
    LocalAgentEngineHandle *engine,
    char **out_json
);
```

Keep returned string ownership with `local_agent_string_free`. Model validation parses and checks config without creating a model handle. Generation validation uses an already loaded model's format/context/template constraints but does not create a generation handle. `local_agent_model_unload` remains the explicit RAM-release operation and returns a stable busy failure until the one active generation has unwound.

Replace `PromptMessage.content: std::string` with typed content parts and add `CanonicalToolSchema`, `ChatTemplateSelector`, and optional codec ID. Preserve raw tool-call text in stream data; C++ does not parse or execute tools.

Extend the Swift DTO in the same task, after the C++ JSON is available:

```swift
package struct CppEngineDescriptor: Decodable, Equatable, Sendable {
    let engineID: String
    let abiVersion: String
    let engineVersion: String
    let displayName: String
    let testOnly: Bool
    let capabilities: CppEngineCapabilities
}

package struct CppParameterDescriptor: Decodable, Equatable, Sendable {
    let backendOption: String
    let valueType: String
    let minimum: Double?
    let maximum: Double?
}
```

`CppEngineCapabilities` gains `backendParameters: [CppParameterDescriptor]`. C++ emits only concrete backend option names such as `top_p`, `top_k`, or `repeat_penalty`; Task 9's Swift mapping owns the association with semantic IDs such as `sampling.top_p`.

Engine identity is reproducible rather than a runtime timestamp: mock reports `mock-v2`; llama.cpp reports `<pinned upstream commit>+local-adapter-v2` from a compile definition supplied by the XCFramework build; a vendor-enabled LiteRT build reports its vendor build ID plus `local-adapter-v2`. The release artifact build fails when an enabled production backend lacks its version input.

- [ ] **Step 4: Run GREEN**

```bash
scripts/run-local-inference-cpp-contracts.sh
```

Expected final line: `local inference C++ contracts passed`.

- [ ] **Step 5: Commit**

```bash
git add inference toolkit/Sources/LocalAgentLLMLocal/CppInferenceClient.swift \
  toolkit/Tests/LocalAgentLLMLocalTests/CppInferencePackagingTests.swift \
  scripts/run-local-inference-cpp-contracts.sh
git commit -m "feat: formalize local inference v2 contracts"
```

---

### Task 9: Implement the Swift C++ Adapter and Single-Model RAM Runtime

**Files:**
- Create: `toolkit/Sources/LocalAgentLLMContracts/LLMBackendEvent.swift`
- Modify: `toolkit/Sources/LocalAgentLLMContracts/LLMFailure.swift`
- Modify: `toolkit/Sources/LocalAgentLLMLocal/CppInferenceClient.swift`
- Create: `toolkit/Sources/LocalAgentLLMLocal/LocalGenerationConfigurationResolver.swift`
- Create: `toolkit/Sources/LocalAgentLLMLocal/PreparedLocalSession.swift`
- Create: `toolkit/Sources/LocalAgentLLMLocal/CppEventChannel.swift`
- Create: `toolkit/Sources/LocalAgentLLMLocal/LocalToolCallCodec.swift`
- Create: `toolkit/Sources/LocalAgentLLMLocal/LocalModelRuntime.swift`
- Create: `toolkit/Sources/LocalAgentLLMLocal/LocalLLMSubsystem.swift`
- Create: `contracts/canonical-digest-v1/fixtures/resolved-parameters-local-v1.json`
- Create: `contracts/canonical-digest-v1/fixtures/capability-snapshot-local-v1.json`
- Create: `toolkit/Tests/LocalAgentLLMLocalTests/CppInferenceClientTests.swift`
- Create: `toolkit/Tests/LocalAgentLLMLocalTests/LocalGenerationConfigurationResolverTests.swift`
- Create: `toolkit/Tests/LocalAgentLLMLocalTests/LocalModelRuntimeTests.swift`
- Create: `toolkit/Tests/LocalAgentLLMLocalTests/PreparedLocalSessionTests.swift`
- Create: `toolkit/Tests/LocalAgentLLMLocalTests/CppEventChannelTests.swift`
- Create: `toolkit/Tests/LocalAgentLLMLocalTests/LocalLLMSubsystemTests.swift`
- Create: `toolkit/Tests/LocalAgentLLMLocalTests/LocalToolCallCodecTests.swift`

**Interfaces:**
- Produces common backend payloads that Phase 3 adapters and Phase 4 event envelopes can reuse, without adding event sequence/session-handle logic now.
- Produces immutable `PreparedLocalSession` pinned to installation/catalog/capability/parameter/template/codec revisions and both local use leases.
- Produces actor `LocalModelRuntime` with `idle/loading/ready/prepared/generating/awaitingToolResult/cancelling/sessionTerminal/unloading/quarantined` state and one loaded installation/session.
- Produces one-shot `LocalLLMSubsystem.bootstrap` that exposes downloader/runtime only after Task 7 recovery.

- [ ] **Step 1: Write failing adapter/runtime tests**

Using a fake C++ API, prove: selection does not load; first session preparation verifies installed state and loads; preparing the same installation reuses the one loaded model; preparing a different installation requires closing the prior session, unloads old RAM weights, then loads new; only one generation starts; cancellation is idempotent and waits for C++ stop/unwind; release occurs before another generation; critical memory warning unloads when idle; critical warning during generation requests cancellation then unloads; cloud route switch unloads RAM but preserves disk record; C error JSON maps to stable `local_engine.*` failures.

Prove `PreparedLocalSession` uses a non-reused 256-bit random session ID and freezes installation `stateRevision`, model/catalog revision, exact capability snapshot and `capability-snapshot:v1` digest, exact resolved configuration and `resolved-parameters:v1` digest, chat-template selector, tool codec, host epoch, loaded-model lease ID, and active-session lease ID. Persist that sanitized immutable record and its active-session lease in one SQLite transaction; it contains no paths or C handles, and closed IDs remain tombstoned for the epoch. `startGeneration` and `resumeGeneration` accept only its session ID plus turn input/attachments/tool schema; neither accepts defaults, overrides, capabilities, template, codec, paths, or engine options. A `toolCallsReady` terminal moves to `awaitingToolResult`, retains both leases and the immutable snapshot, and only `resumeGeneration` may start the next turn. Final/cancel/failure makes the generation terminal but retains the active-session lease until explicit `closeSession` confirms all generation/session resources are released.

Prove a catalog-revoked revision cannot prepare or generate, but remains installed and deletable; a catalog-superseded/missing revision resolves capabilities to unknown and also cannot run without an active signed manifest.

After session preparation, accepting a non-revoking higher catalog revision does not mutate its pinned snapshot or digests. An explicit revocation of the pinned model never re-resolves/falls back: it rejects the next not-yet-started start/resume, moves the session terminal, and requires normal close; an already executing C++ turn is cancelled through the same confirmed cancellation path.

Prove the adapter converts compiled-engine descriptors into authoritative `engineCanExecute` observations scoped to the exact engine/version/app build, intersects them with the signed manifest's exact `modelSupports` observations through `CapabilityResolutionPolicy.local`, uses the lowest verified context bound, and returns `unknown` when either dimension or subject match is missing.

Test canonical parameter mapping:

```text
sampling.temperature          -> sampling.temperature
sampling.top_p                -> sampling.top_p
sampling.top_k                -> sampling.top_k
sampling.min_p                -> sampling.min_p
sampling.repetition_penalty   -> sampling.repeat_penalty
generation.max_output_tokens  -> sampling.max_new_tokens
generation.seed               -> sampling.seed
generation.stop_sequences     -> sampling.stop_sequences
```

Unsupported or invalid values fail before `local_agent_generation_start`. Test the `json_tool_calls_v1` codec parses a complete ordered batch in Swift and never sends tool semantics into C++. Its mixed-output rule is fixed: text before the first tool-call envelope is emitted once as visible assistant preamble and retained for later context; envelope bytes and any unframed text after tool-call parsing begins are not shown or added to context; malformed trailing content fails the turn rather than being guessed. The terminal event uses `toolCallsReady`, first-appearance `orderedCallIDs`, and `finishReason = tool_calls`.

`LocalGenerationConfigurationResolver` must exercise the exact precedence from the 7/10 design: signed catalog defaults → immutable `LLMTarget` defaults → `AgentHostConfiguration` overrides → C++ engine constraints → device safety policy. Add a test for every precedence edge, reject rather than silently drop unsupported controls, and prove manifest-controlled load parameters (`context_tokens`, thread/GPU policy, multimodal projection and template selector) cannot be overridden by an Agent profile in V1.

Add native ownership tests: two concurrent/duplicate explicit closes invoke each C release function once; a successful close exchanges the stored pointer to nil so `deinit` is a no-op; a failed unload returns the wrapper to open state and runtime retains its loaded lease; generation release/cancel failure retains the active-session lease and enters `quarantined`; C++ load failure releases the provisional loaded lease; generation-start failure releases/ends only the new active-session lease. Old-epoch recovery remains the only way to clear a quarantined lease after process death.

Push more token/tool-argument events than the configured native queue capacity while delaying the Swift consumer. Assert producer callback blocks, no event is dropped/reordered, cancellation unblocks the read thread, and terminal/error is observed exactly once. An `AsyncThrowingStream` buffering policy is forbidden for C token delivery.

- [ ] **Step 2: Run RED**

```bash
swift test --package-path toolkit --filter CppInferenceClientTests
swift test --package-path toolkit --filter LocalGenerationConfigurationResolverTests
swift test --package-path toolkit --filter LocalModelRuntimeTests
swift test --package-path toolkit --filter LocalToolCallCodecTests
swift test --package-path toolkit --filter PreparedLocalSessionTests
swift test --package-path toolkit --filter CppEventChannelTests
swift test --package-path toolkit --filter LocalLLMSubsystemTests
```

- [ ] **Step 3: Implement ownership-safe handles and runtime actor**

Define the final native seam; `CppInferenceClient.live` implements it and also conforms to Task 6's `LocalModelConfigValidator`:

```swift
package protocol CppInferenceAPI: Sendable {
    func listEngines() throws -> [CppEngineDescriptor]
    func validateModel(_ request: CppModelLoadRequest) throws
    func load(_ request: CppModelLoadRequest) throws -> any CppLoadedModelAPI
}

package protocol CppLoadedModelAPI: AnyObject, Sendable {
    func validateGeneration(_ request: CppGenerationRequest) throws
    func start(_ request: CppGenerationRequest) throws -> any CppGenerationAPI
    func unload() throws
}

package protocol CppGenerationAPI: AnyObject, Sendable {
    var events: CppTokenEventSequence { get }
    func cancel() throws
    func release() throws
}

package struct CppModelLoadRequest: Equatable, Sendable {
    let engineID: String
    let modelID: String
    let modelFormat: String
    let artifactPathsByRole: [String: String]
    let contextTokens: UInt64
    let manifestLoadOptions: [String: CanonicalJSONValue]
    let template: LocalChatTemplateSelector
}

package struct CppGenerationRequest: Equatable, Sendable {
    let input: AgentLLMInput
    let attachments: [LocalResolvedAttachment]
    let canonicalToolSchema: CanonicalJSONValue?
    let template: LocalChatTemplateSelector
    let toolCallCodecID: String?
    let concreteOptions: [String: CanonicalJSONValue]
}

public struct LocalResolvedAttachment: Equatable, Sendable {
    public let attachmentID: String
    public let rgb8: Data
    public let width: UInt32
    public let height: UInt32
}

package enum CppTokenEvent: Equatable, Sendable {
    case textDelta(String)
    case usage(inputTokens: UInt64?, outputTokens: UInt64?)
    case completed(rawFinishReason: String)
}

package struct CppTokenEventSequence: AsyncSequence, Sendable {
    typealias Element = CppTokenEvent
    struct AsyncIterator: AsyncIteratorProtocol {
        mutating func next() async throws -> CppTokenEvent?
    }
    func makeAsyncIterator() -> AsyncIterator
}
```

Define reusable payloads and complete their concrete types in the same file:

```swift
public struct NormalizedToolCall: Equatable, Sendable {
    public let callID: String
    public let name: String
    public let argumentsJSON: String
}

public struct LLMUsage: Equatable, Sendable {
    public let inputTokens: UInt64?
    public let outputTokens: UInt64?
}

public enum LLMFinishReason: String, Equatable, Sendable {
    case stop, toolCalls = "tool_calls", length, contentFiltered = "content_filtered", other
}

public enum LLMGenerationOutcome: String, Equatable, Sendable {
    case finalResponse = "final_response"
    case toolCallsReady = "tool_calls_ready"
}

public struct LLMBackendCompletion: Equatable, Sendable {
    public let outcome: LLMGenerationOutcome
    public let orderedCallIDs: [String]
    public let finishReason: LLMFinishReason
}

public enum LLMBackendEvent: Equatable, Sendable {
    case textDelta(String)
    case toolCallStarted(callID: String, name: String)
    case toolCallArgumentsDelta(callID: String, delta: String)
    case toolCallCompleted(NormalizedToolCall)
    case usageUpdated(LLMUsage)
    case generationCompleted(LLMBackendCompletion)
    case cancelled
}
```

The Phase 4 bridge will add `commandID`, run/turn IDs, event sequence, event ID/digest, and lifecycle watchdog facts around this Swift-owned local session; do not add Rust event-envelope state here.

Extend `LLMFailure` with defaulted `recoveryAction: LLMRecoveryAction?` and `redactedDiagnostics: [String: String]` so existing Phase 1 call sites remain source-compatible while `local_engine.*`, `download.*`, and `installation.*` failures satisfy the main design's safe recovery contract.

Every private C wrapper owns `LockedHandleState { open(pointer), closing(pointer), closed }`. Explicit close atomically changes `open -> closing`, calls C exactly once, then changes to `closed` and erases the pointer only on success; failure restores `open(pointer)`. Concurrent close waits for/observes the same result. `deinit` invokes the same close-once primitive only when state remains open, so it cannot release a nil/already-closed raw handle. Runtime explicitly releases generation before model and model before engine, and retains wrappers/leases after any uncertain failure.

`CppEventChannel` is a condition-variable-backed bounded queue measured by event count and UTF-8 bytes. C reads run on a dedicated native thread; the synchronous C callback copies the JSON event and blocks when the queue is full until `CppTokenEventSequence.next()` drains capacity. Normal operation preserves every token and tool-argument delta. Cancellation first marks the channel stopping and wakes a blocked callback so it can return `LOCAL_AGENT_STATUS_CANCELLED`, then invokes C++ cancellation from a different thread; already queued events drain before one cancelled terminal. No `AsyncStream`/`AsyncThrowingStream` buffering policy sits between the callback and consumer. Callback code never calls Rust or the Swift runtime actor.

Acquire a provisional durable loaded-use lease before C++ load, retain it through `ready`, and release it only after successful unload. Acquire the active-session lease while creating `PreparedLocalSession` and retain it across every `toolCallsReady -> awaitingToolResult -> resumeGeneration` turn and every generation-terminal state until `closeSession` succeeds. C++ load failure releases the provisional loaded lease. Cancel/release/close/unload failure never releases the corresponding lease merely because Swift requested cleanup.

Expose only installation identities and canonical contracts at the actor surface:

```swift
public struct PreparedLocalSession: Equatable, Sendable {
    public let sessionID: String
    public let installationID: String
    public let installationStateRevision: UInt64
    public let modelRevision: LocalModelRevisionID
    public let catalogRevision: UInt64
    public let capabilitySnapshot: CapabilitySnapshot
    public let capabilitySnapshotDigest: String
    public let resolvedConfiguration: GenerationConfiguration
    public let resolvedParametersDigest: String
    public let template: LocalChatTemplateSelector
    public let toolCallCodecID: String?
    public let hostProcessEpoch: HostProcessEpoch
    public let loadedModelLeaseID: String
    public let activeSessionLeaseID: String
}

public actor LocalModelRuntime {
    public func prepareSession(
        installationID: String,
        targetDefaults: GenerationConfiguration,
        hostOverrides: GenerationConfiguration
    ) async throws -> PreparedLocalSession
    public func startGeneration(
        sessionID: String,
        input: AgentLLMInput,
        attachments: [LocalResolvedAttachment],
        toolSchema: CanonicalJSONValue?
    ) async throws -> LLMBackendEventSequence
    public func resumeGeneration(
        sessionID: String,
        input: AgentLLMInput,
        attachments: [LocalResolvedAttachment],
        toolSchema: CanonicalJSONValue?
    ) async throws -> LLMBackendEventSequence
    public func cancel(sessionID: String) async throws
    public func closeSession(sessionID: String) async throws
    public func unload() async throws
    public func unloadForRouteSwitch() async throws
    public func handleCriticalMemoryPressure() async
}

public struct LLMBackendEventSequence: AsyncSequence, Sendable {
    public typealias Element = LLMBackendEvent
    public struct AsyncIterator: AsyncIteratorProtocol {
        public mutating func next() async throws -> LLMBackendEvent?
    }
    public func makeAsyncIterator() -> AsyncIterator
}
```

`prepareSession` resolves private paths and signed load template inside the module, composes exact model/engine capability observations, resolves parameters once, computes both registered digests from golden-tested schemas, and atomically inserts `prepared_local_sessions` plus the active-session lease before returning. `startGeneration`/`resumeGeneration` load only the immutable snapshot by session ID, match every attachment reference to exactly one supplied RGB buffer, and map its frozen semantic parameters to C++ names. Startup recovery marks every old-epoch prepared local session closed together with ending its leases; it never attempts generation continuation.

`LocalLLMSubsystem.bootstrap` generates the one Swift host epoch, opens the dedicated store, constructs the permanent download event subscription, calls Task 7 recovery, then creates `LocalModelRuntime` around the live C++ client. Its initializer and components remain private until all stages succeed. The public factory uses bundled resources/live adapters; a package-only overload injects fakes for tests:

```swift
public struct LocalLLMSubsystem: Sendable {
    public static func bootstrap(
        appSupportRoot: URL,
        remoteCatalog: Data?
    ) async throws -> LocalLLMSubsystem

    package static func bootstrap(
        appSupportRoot: URL,
        bundledCatalog: Data,
        remoteCatalog: Data?,
        transport: any ModelDownloadTransport,
        inference: any CppInferenceAPI
    ) async throws -> LocalLLMSubsystem
}
```

- [ ] **Step 4: Run GREEN and all Swift regressions**

```bash
swift test --package-path toolkit --filter CppInferenceClientTests
swift test --package-path toolkit --filter LocalGenerationConfigurationResolverTests
swift test --package-path toolkit --filter LocalModelRuntimeTests
swift test --package-path toolkit --filter LocalToolCallCodecTests
swift test --package-path toolkit --filter PreparedLocalSessionTests
swift test --package-path toolkit --filter CppEventChannelTests
swift test --package-path toolkit --filter LocalLLMSubsystemTests
swift test --package-path toolkit
```

- [ ] **Step 5: Commit**

```bash
git add toolkit/Sources/LocalAgentLLMContracts/LLMBackendEvent.swift \
  toolkit/Sources/LocalAgentLLMContracts/LLMFailure.swift \
  toolkit/Sources/LocalAgentLLMLocal toolkit/Tests/LocalAgentLLMLocalTests \
  contracts/canonical-digest-v1/fixtures
git commit -m "feat: add the swift local model runtime"
```

---

### Task 10: Add Phase 2 Integration, Architecture Gates, and Evidence

**Files:**
- Create: `toolkit/Tests/LocalAgentLLMLocalTests/LocalProductPathIntegrationTests.swift`
- Create: `apps/LocalAgentApp/LocalAgentAppTests/Integration/LocalInferenceReleaseSmokeTests.swift`
- Create: `rust-core/tests/lint/llm_phase_two_architecture.rs`
- Create: `scripts/run-llm-phase-2-contracts.sh`
- Create: `scripts/run-llm-phase-2-release-smoke.sh`
- Modify: `scripts/test-local-inference-app-link.sh`
- Modify: `toolkit/Package.swift`
- Modify: `docs/superpowers/specs/2026-07-10-swift-llm-system-design.md`
- Modify: `docs/model-providers/cpp-inference-backend-architecture.md`
- Modify: `docs/model-providers/ondevice-minicpm-boundary.md`

**Interfaces:**
- Produces one deterministic Phase 2 verification command.
- Produces evidence for a signed catalog → download → verify → atomic install → direct Swift → fake C++ stream → cancel/unload/delete flow.
- Freezes boundaries that Phase 3–5 must consume rather than redefine.

- [ ] **Step 1: Write failing end-to-end and architecture tests**

End-to-end tests use a signed test catalog, in-process HTTP fixture/fake transport, temporary volume, SQLite reopen, and injected fake `CppInferenceAPI`. Cover happy path, insufficient space, corrupted artifact, pause/restart/resume, process reconciliation, delete-while-loaded rejection, generation cancellation, and final unload/delete. Native C++ mock remains confined to standalone C++ contract executables and is absent from App/SwiftPM artifacts.

The Rust lint rejects new references to:

```text
OfficialModelCatalog
LocalModelManifest
LocalModelInstallation
artifactSHA256
downloadURL
modelPath
engineID
CppInference
```

outside the pre-existing legacy allowlist. It also proves `host_slot_v2` remains non-runnable and the legacy Phase 1 allowlist count does not grow.

Add a Swift source lint that only `LocalAgentLLMLocal` imports the native inference module. Package-private paths may be used by `LocalModelPaths`, store, disk policy, downloader/transport, installer/reconciler, deletion service, runtime, and C++ adapter, but may not leave `LocalAgentLLMLocal`, enter a `public` DTO, Rust, UI, `AgentHostConfiguration`, logs, or diagnostics. C++ contains no URLSession/catalog/download/SQLite/API-key symbols, and no Model Center UI imports the local target yet.

Add artifact-ownership lints: `rust-core/build.rs` has no C++ compiler/archive invocation; Rust uses `static:-bundle`; SwiftPM/App reference the same XCFramework path; `nm` finds no native inference definition inside the Rust staticlib and exactly one definition in each final App/test host.

- [ ] **Step 2: Run RED**

```bash
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test lint llm_phase_two_architecture -- --nocapture
swift test --package-path toolkit --filter LocalProductPathIntegrationTests
```

- [ ] **Step 3: Add the unified runner and update evidence docs**

`scripts/run-llm-phase-2-contracts.sh` runs, in order:

```bash
scripts/build-local-agent-inference-xcframework.sh
scripts/run-llm-phase-1-contracts.sh
scripts/run-local-inference-cpp-contracts.sh
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test lint llm_phase_two_architecture -- --nocapture
swift test --package-path toolkit
scripts/test-local-inference-app-link.sh --require-catalog-resources
```

It must not access the network, require a production model/API key, start a Rust V2 run, or run UI tests. Optional device/real-model smoke remains separately gated by environment variables and cannot substitute for deterministic contracts.

`LocalInferenceReleaseSmokeTests` runs inside the `LocalAgentApp` iOS Simulator test host. It resolves one already verified installation, loads it through `LocalModelRuntime`, submits one canonical text request, observes a terminal event, closes the immutable local session, unloads, and fails on any skipped step. `scripts/run-llm-phase-2-release-smoke.sh` builds the one XCFramework, runs `xcodebuild test` for that test on the pinned iPhone and iPad Simulator destinations, and reruns the generic-iPhoneOS unsigned archive/link gate. It requires explicit release catalog, installation-root, and engine/model fixture environment variables; the release workflow treats missing variables as failure. Keep this real-model gate separate from ordinary CI because artifacts are large, but require it before an engine becomes user-selectable.

Update the main design with a dated Phase 2 evidence section stating exactly what is implemented and explicitly stating what remains Phase 3 (cloud), Phase 4 (host session bridge/runnable V2), and Phase 5 (Model Center UI/migration/legacy removal).

- [ ] **Step 4: Run the final clean-worktree gate**

```bash
scripts/run-llm-phase-2-contracts.sh
git diff --check
git status --short
```

Expected: Phase 1 stays green, all C++ and Swift local tests pass, architecture lints pass, and only Task 10 files are uncommitted.

- [ ] **Step 5: Commit**

```bash
git add rust-core/tests/lint/llm_phase_two_architecture.rs \
  toolkit/Tests/LocalAgentLLMLocalTests/LocalProductPathIntegrationTests.swift \
  apps/LocalAgentApp/LocalAgentAppTests/Integration/LocalInferenceReleaseSmokeTests.swift \
  toolkit/Package.swift scripts/run-llm-phase-2-contracts.sh \
  scripts/run-llm-phase-2-release-smoke.sh scripts/test-local-inference-app-link.sh docs
git commit -m "test: lock the llm phase two local path"
```

- [ ] **Step 6: Re-run after commit**

```bash
scripts/run-llm-phase-2-contracts.sh
git status --short
```

Expected: exit code 0 and an empty worktree.

## Phase 2 Completion Gate

Phase 2 is complete only when all ten tasks are checked and the unified runner passes from a clean worktree. Completion means the local product subsystem is independently usable and testable from Swift, not that an Agent `host_slot_v2` run is executable.

The review closure gate additionally requires all of these to be mechanically proven:

- one XCFramework is the only product/test-host definition site for the native C ABI; Rust never bundles a copy;
- accepted catalog state includes signed revocations/key ID, uses lossless integer strings, is embedded in the App, and advances only through verified monotonic SQL CAS;
- restored URLSession tasks and new tasks deliver through the same task-identified event channel;
- old-epoch local sessions/use leases close before filesystem/download/runtime exposure;
- every generation turn references one immutable persisted `PreparedLocalSession` and preserves it across tool continuation;
- explicit C-handle close and `deinit` share one close-once state machine, while token/tool deltas use lossless bounded backpressure;
- `local-models.sqlite` is a separate device-local database and every filesystem/SQLite boundary has a durable compensating intent;
- C++ reports ABI/engine identity and backend options only; Swift owns canonical capability/parameter mapping; and
- package-private model paths remain inside the local module and never enter public DTOs, Rust, UI, host configuration, logs, or diagnostics.

The handoff contracts are:

- Phase 3 reuses `CapabilitySnapshot`, `LLMParameterSchema`, `GenerationConfiguration`, `LLMBackendEvent`, and the no-fallback rule for cloud adapters.
- Phase 4 maps its opaque host session to Phase 2's immutable `PreparedLocalSession`, then wraps `startGeneration`/`resumeGeneration`/`closeSession` with durable command acknowledgement, lifecycle watchdogs, and Rust event envelopes; it does not re-resolve parameters or move local paths/config into Rust.
- Phase 5 injects catalog/install/runtime summaries into Model Center UI, migrates selections to `AgentHostConfiguration`, and removes legacy Rust provider/local inference construction only after parity.
