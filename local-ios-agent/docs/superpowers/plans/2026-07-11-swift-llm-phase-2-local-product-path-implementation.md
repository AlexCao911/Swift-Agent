# Swift LLM Phase 2 Local Product Path Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a directly testable Swift-owned local-model product path that accepts only a signed official catalog, downloads and atomically installs model artifacts, manages disk/RAM lifecycle, and invokes the existing C++ v2 inference boundary without adding local-model semantics to Rust.

**Architecture:** `LocalAgentLLMLocal` owns catalog trust, SQLite installation/download state, filesystem policy, parameter mapping, and the single-loaded-model actor. C++ retains the compiled engine registry, model-format validation, chat-template rendering, loading, generation, cancellation, and unload. Phase 2 proves a direct Swift → C++ path; Phase 3 reuses the common capability/parameter contracts, Phase 4 wraps this runtime behind host sessions and Rust events, and Phase 5 adds Model Center UI and removes legacy routes.

**Tech Stack:** Swift 6, SwiftPM, Foundation `URLSession`, CryptoKit Ed25519/SHA-256, Apple SQLite3, C++17, the existing `local_agent_inference.h` v2 C ABI, llama.cpp fixtures, Swift Testing, and shell contract runners.

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
- Rust receives no catalog entry, artifact URL, installation ID, filesystem path, engine ID, model format, or C++ option. `host_slot_v2` remains non-runnable until Phase 4.
- Phase 2 does not implement Provider Profiles, API keys, Keychain, egress, remote adapters, Rust host callbacks, event envelopes, Agent tool loops, Model Center UI, or legacy removal.
- Local paths remain internal to `LocalAgentLLMLocal`. Public summaries expose opaque installation IDs and display-safe byte counts only.
- Raw artifact hashes are named `artifactSHA256` and mean SHA-256 over exact artifact bytes. They are not `CanonicalDigestV1` values.
- The official catalog signature covers RFC 8785 canonical bytes of the complete unsigned catalog payload. It does not introduce an unregistered generic digest.
- No automatic fallback to another local model, engine, or cloud route.

## Phase Boundary and File Map

Create one focused Swift target rather than placing local product behavior in `LocalAgentLLMCore`:

```text
toolkit/Sources/LocalAgentLLMLocal/
  LocalModelManifest.swift           signed catalog DTOs and manifest invariants
  OfficialModelCatalog.swift         bundled/remote trust and rollback policy
  LocalModelStore.swift              normalized SQLite repository and CAS state
  LocalModelPaths.swift              private directory/staging/final path resolver
  LocalDiskPolicy.swift              free-space preflight and reservation math
  ModelDownloadTransport.swift       injectable background-transfer boundary
  URLSessionModelDownloadTransport.swift
  ModelDownloadCoordinator.swift     one-active FIFO queue and pause/resume
  LocalModelInstaller.swift          byte/hash verification and atomic promotion
  LocalModelReconciler.swift         launch repair of tasks/staging/records
  LocalModelDeletionService.swift    guarded recoverable deletion
  CppInferenceClient.swift           C ABI ownership and JSON mapping
  LocalToolCallCodec.swift           Swift-only local tool-call parsing
  LocalModelRuntime.swift            one-loaded-model/generation actor
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

The direct native bridge is built as a separate SwiftPM package product from the repository root. The legacy Rust build may compile the same sources during Phases 2–4, but the new Swift target never calls through Rust and the C++ target never imports Rust headers.

---

### Task 1: Add the Local Swift Target and Direct C++ Package Boundary

**Files:**
- Create: `Package.swift`
- Create: `toolkit/Sources/LocalAgentLLMLocal/CppInferenceClient.swift`
- Create: `toolkit/Tests/LocalAgentLLMLocalTests/CppInferencePackagingTests.swift`
- Modify: `toolkit/Package.swift`
- Modify: `scripts/run-local-inference-cpp-contracts.sh`

**Interfaces:**
- Produces SwiftPM product `LocalAgentInferenceNative` from `inference/`.
- Produces SwiftPM product `LocalAgentLLMLocal` depending on `LocalAgentLLMContracts`, `LocalAgentLLMCore`, `CSQLite`, and `LocalAgentInferenceNative`.
- Produces `CppInferenceRegistryAPI`, an injectable Swift registry protocol; no product code outside the local target imports the C module.

- [ ] **Step 1: Write the failing package-boundary test**

Add:

```swift
import LocalAgentLLMLocal
import Testing

@Test func debugNativeRegistryIsReachableDirectlyFromSwift() throws {
    let engines = try CppInferenceRegistry.live.listEngines()
    #expect(engines.contains { $0.engineID == "mock" && $0.testOnly })
}
```

Add a source scan asserting `LocalAgentInferenceNative` is imported only by `LocalAgentLLMLocal` and that no new Rust source contains `local_agent_engine_`, `model_path`, or `LocalModelInstallation`.

- [ ] **Step 2: Run RED**

```bash
swift test --package-path toolkit --filter CppInferencePackagingTests
```

Expected: fail because neither package product nor Swift local target exists.

- [ ] **Step 3: Add the native package and local target**

The root `Package.swift` defines one C++ target with `path: "inference"`, public headers in `include`, C++17, and debug-only `LOCAL_AGENT_ENABLE_TEST_ENGINES`. Include only `c_api`, `core`, `backends/mock`, `backends/llama_cpp`, and `backends/litert`; exclude `tests`. Keep llama.cpp/LiteRT availability behind the existing compile definitions and external link settings.

In `toolkit/Package.swift` add `.package(path: "..")`, the `LocalAgentLLMLocal` library/target/test target, and the native product dependency.

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
    let parameters: [CppParameterDescriptor]
}

package struct CppParameterDescriptor: Decodable, Equatable, Sendable {
    let backendOption: String
    let valueType: String
    let minimum: Double?
    let maximum: Double?
}
```

`CppInferenceRegistry.live` implements engine list/capability calls and correct `char *` release. Task 9 adds the handle-owning generation client after Task 8 freezes the expanded ABI.

- [ ] **Step 4: Run GREEN and native regressions**

```bash
scripts/run-local-inference-cpp-contracts.sh
swift test --package-path toolkit --filter CppInferencePackagingTests
```

Expected: C++ contracts pass and the debug registry contains test-only `mock`; a release registry test still excludes `mock`.

- [ ] **Step 5: Commit**

```bash
git add Package.swift toolkit/Package.swift toolkit/Sources/LocalAgentLLMLocal \
  toolkit/Tests/LocalAgentLLMLocalTests scripts/run-local-inference-cpp-contracts.sh
git commit -m "build: expose local inference directly to swift"
```

---

### Task 2: Implement the Signed Official Local Model Catalog

**Files:**
- Create: `toolkit/Sources/LocalAgentLLMLocal/LocalModelManifest.swift`
- Create: `toolkit/Sources/LocalAgentLLMLocal/OfficialModelCatalog.swift`
- Create: `toolkit/Sources/LocalAgentLLMLocal/LocalCapabilityObservationFactory.swift`
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
- Create: `apps/LocalAgentApp/LocalAgentApp/Resources/OfficialLocalModelCatalog.v1.json`

**Interfaces:**
- Produces `OfficialModelCatalogLoader.load(bundled:remote:lastAcceptedRevision:) -> AcceptedLocalModelCatalog`.
- Produces immutable `LocalModelRevisionManifest` values keyed by `(modelID, revision)`.
- Produces signed-catalog `modelSupports` capability observations with exact model/catalog subjects and registered evidence/observation digests; it does not trust a pre-resolved snapshot embedded in the manifest.
- The bundled production catalog is valid and signed but may expose only release-approved entries; test fixtures use a separate test key and cannot be accepted by production construction.

- [ ] **Step 1: Write failing trust and schema tests**

Cover valid Ed25519 signature, wrong key, changed URL/hash/size after signing, unsupported schema, duplicate model revision, duplicate artifact role/path, non-HTTPS URL, path traversal, zero sizes, unknown engine, unsupported OS/device, rollback below the last accepted revision, and remote failure falling back to the trusted bundled catalog.

Also cover a higher signed catalog revision revoking a model revision: the catalog returns `.revoked` and invalidates its capability observations immediately. A missing entry is treated as superseded/unknown, not as an implicit revocation; explicit revocations are carried in the signed payload as `[LocalModelRevisionID]`. Task 9 proves the runtime rejects that disposition while leaving installed files for explicit deletion.

Use this public shape:

```swift
public struct LocalModelRevisionID: Hashable, Codable, Sendable {
    public let modelID: String
    public let revision: UInt64
}

public struct AcceptedLocalModelCatalog: Equatable, Sendable {
    public enum Source: String, Sendable { case bundled, remote }
    public let catalogRevision: UInt64
    public let models: [LocalModelRevisionID: LocalModelRevisionManifest]
    public let revokedModelRevisions: Set<LocalModelRevisionID>
    public let source: Source
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

- [ ] **Step 2: Run RED**

```bash
swift test --package-path toolkit --filter OfficialModelCatalogTests
```

Expected: fail because catalog types and signature validation do not exist.

- [ ] **Step 3: Implement canonical signature verification and invariants**

Decode an envelope containing `schema_version`, `catalog_revision`, `models`, and an unpadded-base64url `signature`. Convert the unsigned payload to `CanonicalJSONValue`, call `CanonicalDigestV1.canonicalize`, and verify with `Curve25519.Signing.PublicKey.isValidSignature`. Do not hash ordinary `JSONEncoder` bytes.

Validation returns stable `LLMFailure` codes including:

```text
download.catalog_signature_invalid
download.catalog_schema_unsupported
download.catalog_revision_rollback
download.catalog_manifest_invalid
```

Reject remote catalog errors without replacing the last trusted bundled/accepted value. Do not put a catalog-refresh network client in this task; Phase 2 accepts injected remote bytes, while the app-level scheduler remains Phase 5.

Bring the Phase 1 capability DTO up to the full 7/10 design without breaking existing initializers: add `CapabilitySource`, complete `CapabilitySubject`, `ValidationScope`, invalidation triggers, engine/adapter version, evidence digest, and observation digest with provider-neutral default values. `LocalCapabilityObservationFactory` creates `modelSupports` observations whose subject pins `modelID`, model revision, and catalog revision; source is `signedLocalCatalog`, authority is `authoritative`, expiry is absent, and invalidation includes catalog revision, engine version, app build, and OS capability changes. Compute `capability-evidence:v1` and `capability-observation:v1` from the exact fixture schemas; never use the artifact SHA-256 as capability evidence.

Extend `CapabilityMatrix.resolve` to accept a `CapabilityResolutionPolicy`. `.local` requires non-expired matching `modelSupports` and `engineCanExecute` dimensions for every positive capability; authoritative negative wins and a missing/subject-mismatched dimension resolves to `unknown`. Phase 3 will add its cloud policy rather than weakening `.local`.

- [ ] **Step 4: Run GREEN**

```bash
swift test --package-path toolkit --filter OfficialModelCatalogTests
swift test --package-path toolkit --filter LocalCapabilityObservationTests
swift test --package-path toolkit --filter CapabilityMatrixTests
```

- [ ] **Step 5: Commit**

```bash
git add toolkit/Sources/LocalAgentLLMContracts/LLMCapabilities.swift \
  toolkit/Sources/LocalAgentLLMCore/CapabilityMatrix.swift \
  toolkit/Sources/LocalAgentLLMLocal toolkit/Tests/LocalAgentLLMCoreTests \
  toolkit/Tests/LocalAgentLLMLocalTests contracts/canonical-digest-v1/fixtures \
  apps/LocalAgentApp/LocalAgentApp/Resources/OfficialLocalModelCatalog.v1.json
git commit -m "feat: verify the official local model catalog"
```

---

### Task 3: Add Normalized SQLite Installation and Download State

**Files:**
- Modify: `toolkit/Sources/LocalAgentLLMCore/SQLiteConnection.swift`
- Create: `toolkit/Sources/LocalAgentLLMLocal/LocalModelStore.swift`
- Create: `toolkit/Tests/LocalAgentLLMLocalTests/LocalModelStoreTests.swift`

**Interfaces:**
- Produces `LocalModelStore(fileURL:)` and `LocalModelStore.inMemory()`.
- Produces SQL-CAS methods for installation state, artifact progress, download queue order, resume data, filesystem operation intent, and RAM-use leases.
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
```

Test exact state transitions:

```text
not_installed -> queued -> downloading -> paused -> downloading
downloading -> verifying -> installed
queued|downloading|paused|verifying -> failed
failed -> queued (explicit user retry only)
installed -> deleting -> deleted
```

`not_installed` and `deleted` are derived states represented by absence of an installation row, matching the design's requirement that completed deletion removes the record. Explicit download cancellation removes the task, staging data, reservation, and row atomically after filesystem cleanup. Reject every unspecified transition and stale `state_revision`. Test two reopened stores cannot both win the same CAS, failed multi-row writes roll back, resume `Data` round-trips as SQLite BLOB, and a public installation summary contains no path/URL/hash.

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

- [ ] **Step 4: Run GREEN and Core regressions**

```bash
swift test --package-path toolkit --filter LocalModelStoreTests
swift test --package-path toolkit --filter LLMStoreTests
```

- [ ] **Step 5: Commit**

```bash
git add toolkit/Sources/LocalAgentLLMCore/SQLiteConnection.swift \
  toolkit/Sources/LocalAgentLLMLocal/LocalModelStore.swift \
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
- Produces `ModelDownloadTransport` with start/restore/pause/cancel operations.
- Produces actor `ModelDownloadCoordinator` with FIFO queue and at most one active artifact transfer.
- Persists background task identifiers, validators, progress, and opaque resume data before publishing state.

- [ ] **Step 1: Write failing queue, pause/resume, and restoration tests**

Use a deterministic fake transport to prove: FIFO ordering; only one active model artifact transfer; pause stores resume data when supplied; resume uses the same artifact identity; invalid resume data clears only that artifact and restarts it from zero; ETag/Last-Modified mismatch restarts safely; duplicate enqueue is idempotent; cancellation removes transport task and reservation; network failure enters `failed` with `download.network_failed`; process restoration reattaches known tasks and cancels/quarantines unknown tasks.

- [ ] **Step 2: Run RED**

```bash
swift test --package-path toolkit --filter ModelDownloadCoordinatorTests
```

- [ ] **Step 3: Implement the transport seam and actor**

Use:

```swift
package protocol ModelDownloadTransport: Sendable {
    func start(_ request: ArtifactDownloadRequest, resumeData: Data?) async throws -> ModelDownloadTransfer
    func restoredTransfers() async throws -> [RestoredModelDownload]
    func pause(taskIdentifier: Int) async throws -> Data?
    func cancel(taskIdentifier: Int) async
    func setBackgroundEventsCompletionHandler(_ handler: @escaping @Sendable () -> Void) async
}

package struct ModelDownloadTransfer: Sendable {
    let taskIdentifier: Int
    let events: AsyncThrowingStream<ModelDownloadEvent, Error>
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

package enum ModelDownloadEvent: Equatable, Sendable {
    case progress(receivedBytes: UInt64, expectedBytes: UInt64)
    case completed(stagedFileURL: URL, etag: String?, lastModified: String?)
}

package struct RestoredModelDownload: Equatable, Sendable {
    let taskIdentifier: Int
    let installationID: String
    let artifactID: String
}
```

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
```

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
- Create: `toolkit/Sources/LocalAgentLLMLocal/LocalModelDeletionService.swift`
- Create: `toolkit/Tests/LocalAgentLLMLocalTests/LocalModelDeletionServiceTests.swift`
- Modify: `toolkit/Sources/LocalAgentLLMLocal/LocalModelStore.swift`

**Interfaces:**
- Produces durable `LocalModelUseLease` owned by `LocalModelRuntime` while loaded/session-active.
- Produces `LocalModelDeletionService.delete(installationID:)` with an intent/trash/commit protocol.
- Deletion never mutates Agent bindings; later readiness reports the exact missing installation.

- [ ] **Step 1: Write failing deletion tests**

Reject deletion while loaded, session-active, verifying, or downloading. Require the caller to cancel a paused/downloading installation first. Prove an installed unused model is moved to private trash before its record is removed, a crash after trash move completes on launch, a duplicate delete is idempotent, and deleting one installation does not affect another revision.

- [ ] **Step 2: Run RED**

```bash
swift test --package-path toolkit --filter LocalModelDeletionServiceTests
```

- [ ] **Step 3: Implement leases and recoverable deletion**

Use:

```swift
package struct LocalModelUseLease: Equatable, Sendable {
    enum Purpose: String, Sendable {
        case loaded
        case activeSession = "active_session"
    }

    let leaseID: String
    let installationID: String
    let purpose: Purpose
    let hostProcessEpoch: String
}
```

Acquire/release through SQL CAS. `delete` transactionally checks zero leases, writes `delete_installation` intent, and changes `installed -> deleting`; filesystem code moves the directory to `.trash/<operationID>`; a final transaction removes artifact/installation rows and marks the operation complete. `LocalModelReconciler` finishes incomplete deletion intents.

- [ ] **Step 4: Run GREEN**

```bash
swift test --package-path toolkit --filter LocalModelDeletionServiceTests
swift test --package-path toolkit --filter LocalModelReconcilerTests
```

- [ ] **Step 5: Commit**

```bash
git add toolkit/Sources/LocalAgentLLMLocal/LocalModelStore.swift \
  toolkit/Sources/LocalAgentLLMLocal/LocalModelDeletionService.swift \
  toolkit/Tests/LocalAgentLLMLocalTests/LocalModelDeletionServiceTests.swift
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
- Modify: `scripts/run-local-inference-cpp-contracts.sh`

**Interfaces:**
- Adds non-allocating validation calls `local_agent_model_validate` and `local_agent_generation_validate`.
- Engine capabilities report supported model formats, canonical parameter mappings/ranges, modalities, streaming/cancellation/usage, and verified maximum context where known.
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

Tests reject unknown schema, role/content type, attachment/buffer mismatch, unsupported tool schema, unapproved template source/ID, unsupported parameter, out-of-range value, concurrent generation, unload during active generation, and validation that accidentally loads weights. Prove llama.cpp receives messages/tools/template and performs rendering immediately before tokenization; Swift-selected codec is not interpreted as Agent policy by C++.

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

- [ ] **Step 4: Run GREEN**

```bash
scripts/run-local-inference-cpp-contracts.sh
```

Expected final line: `local inference C++ contracts passed`.

- [ ] **Step 5: Commit**

```bash
git add inference scripts/run-local-inference-cpp-contracts.sh
git commit -m "feat: formalize local inference v2 contracts"
```

---

### Task 9: Implement the Swift C++ Adapter and Single-Model RAM Runtime

**Files:**
- Create: `toolkit/Sources/LocalAgentLLMContracts/LLMBackendEvent.swift`
- Modify: `toolkit/Sources/LocalAgentLLMContracts/LLMFailure.swift`
- Modify: `toolkit/Sources/LocalAgentLLMLocal/CppInferenceClient.swift`
- Create: `toolkit/Sources/LocalAgentLLMLocal/LocalGenerationConfigurationResolver.swift`
- Create: `toolkit/Sources/LocalAgentLLMLocal/LocalToolCallCodec.swift`
- Create: `toolkit/Sources/LocalAgentLLMLocal/LocalModelRuntime.swift`
- Create: `toolkit/Tests/LocalAgentLLMLocalTests/CppInferenceClientTests.swift`
- Create: `toolkit/Tests/LocalAgentLLMLocalTests/LocalGenerationConfigurationResolverTests.swift`
- Create: `toolkit/Tests/LocalAgentLLMLocalTests/LocalModelRuntimeTests.swift`
- Create: `toolkit/Tests/LocalAgentLLMLocalTests/LocalToolCallCodecTests.swift`

**Interfaces:**
- Produces common backend payloads that Phase 3 adapters and Phase 4 event envelopes can reuse, without adding event sequence/session-handle logic now.
- Produces actor `LocalModelRuntime` with `idle/loading/ready/generating/cancelling/unloading` state and one loaded installation.
- Produces `prepare`, `generate`, `cancel`, `unload`, `handleCriticalMemoryPressure`, and `unloadForRouteSwitch`.

- [ ] **Step 1: Write failing adapter/runtime tests**

Using a fake C++ API, prove: selection does not load; first `prepare` verifies installed state and loads; preparing the same installation is idempotent; preparing a different installation cancels/finishes any generation, unloads old RAM weights, then loads new; only one generation starts; cancellation is idempotent and waits for C++ stop/unwind; release occurs before another generation; critical memory warning unloads when idle; critical warning during generation requests cancellation then unloads; cloud route switch unloads RAM but preserves disk record; C error JSON maps to stable `local_engine.*` failures.

Prove a catalog-revoked revision cannot prepare or generate, but remains installed and deletable; a catalog-superseded/missing revision resolves capabilities to unknown and also cannot run without an active signed manifest.

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

- [ ] **Step 2: Run RED**

```bash
swift test --package-path toolkit --filter CppInferenceClientTests
swift test --package-path toolkit --filter LocalGenerationConfigurationResolverTests
swift test --package-path toolkit --filter LocalModelRuntimeTests
swift test --package-path toolkit --filter LocalToolCallCodecTests
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
    var events: AsyncThrowingStream<CppTokenEvent, Error> { get }
    func cancel()
    func release()
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

The Phase 4 bridge will add `commandID`, session/run/turn IDs, sequence, event ID/digest, and lifecycle watchdog facts; do not add those here.

Extend `LLMFailure` with defaulted `recoveryAction: LLMRecoveryAction?` and `redactedDiagnostics: [String: String]` so existing Phase 1 call sites remain source-compatible while `local_engine.*`, `download.*`, and `installation.*` failures satisfy the main design's safe recovery contract.

Use move-only-by-convention private wrapper classes whose `deinit` releases C handles. The runtime actor explicitly releases generation before unloading model, and model before releasing engine. C callbacks copy JSON before returning and feed a bounded `AsyncThrowingStream` continuation; callback code never calls Rust.

Acquire a durable loaded-use lease before C++ load, retain it through `ready`, and release it only after successful unload. Acquire an active-session lease for generation and release after terminal/cancel unwind.

Expose only installation identities and canonical contracts at the actor surface:

```swift
public struct LocalRuntimeReadiness: Equatable, Sendable {
    public let installationID: String
    public let capabilities: CapabilitySnapshot
    public let parameterSchema: LLMParameterSchema
}

public actor LocalModelRuntime {
    public func prepare(installationID: String) async throws -> LocalRuntimeReadiness
    public func generate(
        input: AgentLLMInput,
        attachments: [LocalResolvedAttachment],
        toolSchema: CanonicalJSONValue?,
        targetDefaults: GenerationConfiguration,
        hostOverrides: GenerationConfiguration
    ) async throws -> AsyncThrowingStream<LLMBackendEvent, Error>
    public func cancel() async
    public func unload() async throws
    public func unloadForRouteSwitch() async throws
    public func handleCriticalMemoryPressure() async
}
```

`prepare` resolves the private path and signed load template inside the module. `generate` resolves and validates parameters once, matches every attachment reference to exactly one supplied RGB buffer, then maps parameters to C++ names; neither method accepts a path, engine option, template ID, or artifact URL from its caller.

- [ ] **Step 4: Run GREEN and all Swift regressions**

```bash
swift test --package-path toolkit --filter CppInferenceClientTests
swift test --package-path toolkit --filter LocalGenerationConfigurationResolverTests
swift test --package-path toolkit --filter LocalModelRuntimeTests
swift test --package-path toolkit --filter LocalToolCallCodecTests
swift test --package-path toolkit
```

- [ ] **Step 5: Commit**

```bash
git add toolkit/Sources/LocalAgentLLMContracts/LLMBackendEvent.swift \
  toolkit/Sources/LocalAgentLLMContracts/LLMFailure.swift \
  toolkit/Sources/LocalAgentLLMLocal toolkit/Tests/LocalAgentLLMLocalTests
git commit -m "feat: add the swift local model runtime"
```

---

### Task 10: Add Phase 2 Integration, Architecture Gates, and Evidence

**Files:**
- Create: `toolkit/Tests/LocalAgentLLMLocalTests/LocalProductPathIntegrationTests.swift`
- Create: `toolkit/Sources/LocalAgentLLMLocalSmoke/main.swift`
- Create: `rust-core/tests/lint/llm_phase_two_architecture.rs`
- Create: `scripts/run-llm-phase-2-contracts.sh`
- Create: `scripts/run-llm-phase-2-release-smoke.sh`
- Modify: `toolkit/Package.swift`
- Modify: `docs/superpowers/specs/2026-07-10-swift-llm-system-design.md`
- Modify: `docs/model-providers/cpp-inference-backend-architecture.md`
- Modify: `docs/model-providers/ondevice-minicpm-boundary.md`

**Interfaces:**
- Produces one deterministic Phase 2 verification command.
- Produces evidence for a signed catalog → download → verify → atomic install → direct Swift → fake C++ stream → cancel/unload/delete flow.
- Freezes boundaries that Phase 3–5 must consume rather than redefine.

- [ ] **Step 1: Write failing end-to-end and architecture tests**

End-to-end tests use a signed test catalog, in-process HTTP fixture/fake transport, temporary volume, SQLite reopen, and mock C++ engine. Cover happy path, insufficient space, corrupted artifact, pause/restart/resume, process reconciliation, delete-while-loaded rejection, generation cancellation, and final unload/delete.

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

Add a Swift source lint that only `LocalAgentLLMLocal` imports the native inference module, only local storage code accesses absolute model paths, C++ contains no URLSession/catalog/download/SQLite/API-key symbols, and no Model Center UI imports the local target yet.

- [ ] **Step 2: Run RED**

```bash
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test lint llm_phase_two_architecture -- --nocapture
swift test --package-path toolkit --filter LocalProductPathIntegrationTests
```

- [ ] **Step 3: Add the unified runner and update evidence docs**

`scripts/run-llm-phase-2-contracts.sh` runs, in order:

```bash
scripts/run-llm-phase-1-contracts.sh
scripts/run-local-inference-cpp-contracts.sh
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml --test lint llm_phase_two_architecture -- --nocapture
swift test --package-path toolkit
```

It must not access the network, require a production model/API key, start a Rust V2 run, or run UI tests. Optional device/real-model smoke remains separately gated by environment variables and cannot substitute for deterministic contracts.

Add a `LocalAgentLLMLocalSmoke` executable that resolves one already verified installation, loads it through `LocalModelRuntime`, submits one canonical text request, observes a terminal event, unloads, and exits non-zero on any skipped or failed step. `scripts/run-llm-phase-2-release-smoke.sh` runs that executable once for every engine enabled in the release catalog. It requires explicit `LOCAL_AGENT_RELEASE_CATALOG`, installation-root, and engine/model fixture environment variables; the release workflow treats missing variables as failure rather than a skip. Keep this real-model gate separate from ordinary CI because model artifacts are large, but require it before an engine becomes user-selectable.

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
  toolkit/Sources/LocalAgentLLMLocalSmoke toolkit/Package.swift \
  scripts/run-llm-phase-2-contracts.sh scripts/run-llm-phase-2-release-smoke.sh docs
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

The handoff contracts are:

- Phase 3 reuses `CapabilitySnapshot`, `LLMParameterSchema`, `GenerationConfiguration`, `LLMBackendEvent`, and the no-fallback rule for cloud adapters.
- Phase 4 wraps `LocalModelRuntime` behind Swift-owned opaque sessions, durable command acknowledgement, lifecycle watchdogs, and Rust event envelopes; it does not move local paths/config into Rust.
- Phase 5 injects catalog/install/runtime summaries into Model Center UI, migrates selections to `AgentHostConfiguration`, and removes legacy Rust provider/local inference construction only after parity.
