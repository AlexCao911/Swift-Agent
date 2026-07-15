# Swift LLM Phase 3 Cloud Product Path Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a directly testable Swift-owned cloud LLM product path with immutable Provider Profile revisions, generation-pinned Keychain credentials, digest-bound egress approval, capability-aware parameters, and explicit adapters for OpenAI, Claude, Gemini, Grok, DeepSeek, MiniMax, and GLM without adding provider semantics to Rust.

**Architecture:** `LocalAgentLLMCloud` owns cloud profile state, credentials, egress, exact-origin networking, provider wire codecs, provider-private continuation, discovery, validation, and cloud session lifecycle. Shared wire codecs remove JSON/SSE duplication, while one semantic adapter per provider owns model-specific parameters, continuation, errors, and terminal rules. Phase 3 proves a direct Swift cloud path with secret-free fixtures; `host_slot_v2` remains non-runnable until Phase 4 wraps the exact prepared cloud session behind the Rust host bridge.

**Tech Stack:** Swift 6, SwiftPM, Foundation `URLSession`, Security/Keychain Services, CryptoKit Ed25519/SHA-256, Apple SQLite3, RFC 8785 `CanonicalDigestV1`, Server-Sent Events, Swift Testing, Xcode iOS Simulator tests, and shell contract runners.

**Design authority:** `docs/superpowers/specs/2026-07-10-swift-llm-system-design.md`, especially Cloud Provider System, Egress and Approval, Capability Matrix, Parameter System, Persistence, Retry and Recovery, Testing Strategy, and Phase 3 migration sections.

## Global Constraints

- Work only in `/Users/alexandercou/Projects/Alex-agent/.worktrees/llm-runtime-provider-design/local-ios-agent` on `codex/llm-runtime-provider-design`.
- Execute tasks sequentially with one Agent; do not dispatch subagents.
- Use test-driven development: add a focused failing test, observe the expected failure, implement the minimum behavior, rerun focused and regression suites, then commit.
- Target iOS/iPadOS 17+ and macOS 14+ test hosts. Cloud generations use process-bound, non-background `URLSession`; only local model downloads use background sessions.
- Rust remains the provider-neutral Agent kernel. No Rust product type may gain a Provider Profile, Base URL, credential reference/generation, API key, provider preset, provider model ID, provider request field, or adapter kind.
- C++ remains local-inference-only and is unchanged by Phase 3.
- Phase 3 adds no production Model Center or Provider Profile editor UI. Approval and credential-entry presentation are injected protocols; Phase 5 supplies their user-facing screens.
- `host_slot_v2` remains non-runnable. Phase 3 must not route a production Rust Agent run through a cloud adapter or alter the legacy production resolver.
- Exactly one App-created 256-bit `HostProcessEpoch` is injected into Rust, local Swift, and cloud Swift. The cloud subsystem never generates a second epoch.
- At most one Agent run, one prepared cloud session, and one cloud generation are active globally. Switching to cloud first asks the local runtime to unload RAM; it never deletes installed model files.
- Provider API keys exist only in generation-specific Keychain items using `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. They never enter SQLite, Rust/FFI DTOs, logs, diagnostics, exports, fixtures, snapshots, crash messages, or source control.
- Provider Profiles default to `statelessRequired`; adapters must encode no-storage controls where supported and resend validated semantic history. This mode forbids API-managed conversation resources but does not promise zero provider operational/account retention. Provider-side response/interaction state requires a new immutable Profile revision plus explicit retention approval bound into egress and capability state.
- `CredentialSlotState` is the only credential-generation authority. Provider Profile state contains only `credentialRef`; every validation or preparation key user owns one durable generation-pinned `CredentialUseLease`.
- A credential slot in `rotating` or `deleting` rejects new use leases. Rotation and deletion require zero use leases and use persisted idempotent operation state plus Keychain tombstones.
- Every remote request is HTTPS, exact-origin authorized, generation-pinned, adapter validated, and tagged `generation | validation | discovery` before credential resolution or `URLSessionTask` creation. Generation requests additionally require a validated disclosure authorization; validation/discovery require the matching fixed no-user-data seal.
- Base URLs reject embedded credentials, loopback, link-local, multicast, private, documentation, benchmark, and otherwise reserved IP ranges. Redirects cannot change scheme, host, or effective port.
- URLSession preflight rejects empty, mixed public/private, or changed-to-forbidden DNS answers, but Phase 3 does not claim actual peer-IP pinning or complete DNS-rebinding prevention.
- Initial and resumed requests each carry a `GenerationDisclosure` bound to exact semantic content and source revisions. Sensitive scope expansion pauses before the affected request and requires an incremental grant.
- Approval summaries contain only stable enums, manifest-controlled tool display keys, counts, and coarse size buckets. No contact name, calendar title, filename, path, URL, query, tool argument, or content snippet is display/log metadata.
- Wire compatibility is not semantic compatibility. OpenAI Responses, OpenAI Chat Completions, Anthropic Messages, and Gemini Interactions are shared codecs; seven provider semantic adapters remain explicit.
- Provider-private response IDs, reasoning content required for continuation, thought blocks, encrypted content, and signatures stay in the in-memory Swift provider session. Only explicitly user-displayable reasoning summaries become `reasoningSummaryDelta`.
- Capability unknown is not supported. Provider model lists prove availability only; probes prove only their exact exercised scope; a manual model ID begins conservatively unknown.
- Phase 3 publishes only cloud text/tool capabilities. Image/audio/video/document input remains unknown, and attachment-bearing cloud turns fail before egress because there is no byte resolver, upload/inline lifecycle, or cleanup path.
- Provider-documented ignored parameters are unsupported and rejected. Adapters map only canonical semantic parameter IDs; provider field names never leave `LocalAgentLLMCloud`.
- Automatic local/cloud/provider/model fallback is forbidden. A changed Profile revision, origin, target revision, model ID, credential generation, catalog revision, or adapter version invalidates the matching readiness evidence.
- Deterministic CI uses secret-free recorded fixtures and an injected transport/Keychain vault. It does not access the network or require a production API key.
- Optional live smoke reads an already provisioned Keychain credential reference; it never accepts a key via command-line argument, environment variable, fixture, or file.

## Phase Boundary and File Map

Create one focused cloud target:

```text
toolkit/Sources/LocalAgentLLMCloud/
  ProviderPreset.swift                 seven shipped presets and codec/auth strategies
  ProviderProfile.swift                immutable revisions, state, archive summaries
  ProviderProfileStore.swift           normalized SQLite repository and CAS operations
  ProviderCredentialStore.swift        Keychain vault, slots, leases, rotation/deletion
  CredentialOperationReconciler.swift  launch repair and Keychain tombstones
  ProviderEgressPolicy.swift           origin grants, turn authorization, audit chain
  CloudSemanticTurnValidator.swift     complete semantic request/disclosure recomputation
  CloudWireContracts.swift             unsendable adapter wire request/response contracts
  CloudRequestAuthorization.swift      tagged generation/validation/discovery seals
  CloudHTTPTransport.swift             exact-origin authorized URLSession boundary
  SSEEventParser.swift                 bounded incremental SSE framing
  CloudProviderAdapter.swift           adapter/session protocols and private state boundary
  CloudGenerationConfigurationResolver.swift
  OpenAIResponsesAdapter.swift         OpenAI Responses semantics
  XAIAdapter.swift                     xAI semantics over Responses
  OpenAIChatCompletionsCodec.swift      shared chat-completions wire codec
  DeepSeekAdapter.swift                DeepSeek continuation/thinking semantics
  GLMAdapter.swift                     GLM interleaved/preserved thinking semantics
  AnthropicMessagesCodec.swift          shared Messages wire codec
  AnthropicMessagesAdapter.swift       Claude semantics
  MiniMaxAdapter.swift                 MiniMax semantics over Messages
  GeminiInteractionsAdapter.swift      Gemini Interactions and thought signatures
  CloudCapabilityCatalog.swift         signed maintained cloud capability catalog
  CloudCapabilityObservationFactory.swift
  CloudModelDiscoveryService.swift
  ProviderValidationService.swift
  PreparedCloudSession.swift           immutable sanitized cloud session snapshot
  CloudLLMRuntime.swift                one-session/generation cloud runtime actor
  CloudLLMSubsystem.swift              ordered startup and route-switch composition
  Resources/OfficialCloudCapabilityCatalog.v1.json
  Resources/OfficialCloudCapabilityCatalogKeys.v1.json
```

Provider fixture files live under `toolkit/Tests/LocalAgentLLMCloudTests/Fixtures/<provider>/` and contain only synthetic prompts, fake IDs, fake signatures, and redacted errors. No fixture is captured from a user request.

The four codec families are fixed:

| Codec | Semantic adapters |
| --- | --- |
| OpenAI Responses | OpenAI, xAI/Grok |
| OpenAI Chat Completions | DeepSeek, Zhipu/GLM |
| Anthropic Messages | Anthropic/Claude, MiniMax |
| Gemini Interactions | Google/Gemini |

Official protocol references are versioned evidence, not runtime dependencies:

- OpenAI Responses: <https://developers.openai.com/api/reference/resources/responses/methods/create>
- Claude streaming and thinking display: <https://platform.claude.com/docs/en/build-with-claude/streaming> and <https://platform.claude.com/docs/en/build-with-claude/extended-thinking>
- Gemini Interactions and streaming: <https://ai.google.dev/gemini-api/docs/interactions-overview> and <https://ai.google.dev/gemini-api/docs/streaming>
- xAI Responses and reasoning: <https://docs.x.ai/developers/model-capabilities/text/generate-text> and <https://docs.x.ai/developers/model-capabilities/text/reasoning>
- DeepSeek API and thinking mode: <https://api-docs.deepseek.com/> and <https://api-docs.deepseek.com/guides/thinking_mode/>
- MiniMax Anthropic-compatible API: <https://platform.minimax.io/docs/api-reference/text-anthropic-api>
- GLM HTTP, tool calling, and thinking: <https://docs.bigmodel.cn/cn/guide/develop/http/introduction>, <https://docs.bigmodel.cn/cn/guide/capabilities/function-calling>, and <https://docs.bigmodel.cn/cn/guide/capabilities/thinking-mode>

---

### Task 1: Add the Cloud Swift Target and Provider-Neutral Turn Contracts

**Files:**
- Create: `toolkit/Sources/LocalAgentLLMContracts/GenerationDisclosure.swift`
- Create: `toolkit/Sources/LocalAgentLLMContracts/LLMToolResult.swift`
- Modify: `toolkit/Sources/LocalAgentLLMContracts/LLMBackendEvent.swift`
- Create: `toolkit/Sources/LocalAgentLLMCloud/ProviderPreset.swift`
- Create: `toolkit/Sources/LocalAgentLLMCloud/CloudSemanticTurnValidator.swift`
- Create: `toolkit/Sources/LocalAgentLLMCloud/CloudWireContracts.swift`
- Create: `toolkit/Sources/LocalAgentLLMCloud/CloudProviderAdapter.swift`
- Create: `toolkit/Tests/LocalAgentLLMContractsTests/GenerationDisclosureTests.swift`
- Create: `toolkit/Tests/LocalAgentLLMCloudTests/CloudProviderBoundaryTests.swift`
- Create: `toolkit/Tests/LocalAgentLLMCloudTests/CloudSemanticTurnValidatorTests.swift`
- Modify: `toolkit/Package.swift`
- Create: `contracts/canonical-digest-v1/fixtures/generation-disclosure-cloud-v1.json`
- Create: `contracts/canonical-digest-v1/fixtures/provider-retention-approval-cloud-v1.json`
- Create: `contracts/canonical-digest-v1/fixtures/credential-use-lease-cloud-v1.json`
- Create: `contracts/canonical-digest-v1/fixtures/egress-approval-summary-cloud-v1.json`
- Create: `contracts/canonical-digest-v1/fixtures/egress-scope-grant-cloud-v1.json`
- Create: `contracts/canonical-digest-v1/fixtures/egress-generation-authorization-cloud-v1.json`
- Create: `contracts/canonical-digest-v1/fixtures/egress-subject-cloud-v1.json`
- Create: `contracts/canonical-digest-v1/fixtures/egress-attestation-cloud-v1.json`
- Create: `contracts/canonical-digest-v1/fixtures/egress-audit-chain-cloud-v1.json`
- Modify: `toolkit/Tests/LocalAgentLLMContractsTests/CanonicalDigestTests.swift`
- Modify: `toolkit/Sources/LocalAgentLLMContracts/CanonicalDigest.swift`
- Modify: `contracts/canonical-digest-v1/registry.json`
- Modify: `rust-core/src/canonical_digest.rs`
- Modify: `rust-core/tests/contract/canonical_digest_v1.rs`

**Interfaces:**
- Produces the `LocalAgentLLMCloud` library/test target depending only on `LocalAgentLLMContracts`, `LocalAgentLLMCore`, `CSQLite`, `Security`, and Foundation.
- Produces the complete provider-neutral `GenerationDisclosure`, `SafeDisplaySummary`, and normalized tool-result contracts used by egress and later Phase 4 commands.
- Produces `LLMBackendEvent.reasoningSummaryDelta`; raw reasoning has no public event case.
- Produces complete `CloudGenerationTurnCandidate`, sealed `ValidatedCloudGenerationTurn`, and the sole factory that recomputes `agent-input:v1` plus `source-revisions:v1` from the real semantic request.
- Produces unsendable `CloudWireRequest` plus `CloudProviderAdapter`/`CloudProviderSession` encode/decode seams; no provider SDK or transport dependency is introduced.

- [ ] **Step 1: Write failing contract and package tests**

Add tests that construct a start disclosure and an expanded tool-result disclosure, assert stable set ordering through the shared digest fixture, and prove no raw text appears in either summary. Register `provider-retention-approval:v1` in the shared registry/Swift/Rust lists and prove identical fixture bytes/digest without teaching Rust its fields. Build complete start/resume semantic candidates and prove that changing a message, canonical tool schema, source revision, attachment identity/revision/content digest, one tool-result value, or provider-required normalized semantic history rejects the disclosure. Add a source-boundary test requiring the cloud target and rejecting `import LocalAgentLLMCloud` from Rust, C++, `LocalAgentLLMLocal`, or production Model Center files.

```swift
@Test func disclosureDigestBindsTurnContentSourcesAndSafeSummary() throws {
    let disclosure = GenerationDisclosure(
        schemaVersion: "1",
        generationTurnID: "turn-2",
        contentDigest: String(repeating: "a", count: 64),
        sourceRevisionDigest: String(repeating: "b", count: 64),
        dataClasses: [.text, .contacts],
        highestSensitivity: .sensitive,
        safeDisplaySummary: SafeDisplaySummary(
            sourceKinds: [.conversation, .toolResult],
            addedItemCounts: [.init(dataClass: .contacts, count: 2)],
            approximateAddedSize: .lessThanOneKiB,
            triggeringToolDisplayKeys: ["contacts.search"]
        )
    )
    #expect(try disclosure.computedDigest().hex == fixtureDigest("generation-disclosure-cloud-v1.json"))
}

@Test func validatorRejectsDisclosureForDifferentContinuationHistory() throws {
    let candidate = fixtureCandidate(
        semanticHistory: .array([.string("assistant-turn-1")]),
        disclosure: fixtureDisclosure
    )
    #expect(throws: CloudTurnValidationFailure.self) {
        try validator.validate(candidate.replacingSemanticHistory(
            .array([.string("different-history")])
        ))
    }
}
```

- [ ] **Step 2: Run RED**

```bash
swift test --package-path toolkit --filter GenerationDisclosureTests
swift test --package-path toolkit --filter CloudProviderBoundaryTests
swift test --package-path toolkit --filter CloudSemanticTurnValidatorTests
```

Expected: fail because the disclosure/tool-result types, complete semantic validator, cloud target, digest fixtures, and reasoning-summary event do not exist.

- [ ] **Step 3: Add the exact shared contracts and cloud protocols**

```swift
public enum EgressDataClass: String, Codable, CaseIterable, Hashable, Sendable {
    case text, memory, contacts, files, calendar, photos, location, attachment
    case toolResult = "tool_result"
    case unknownData = "unknown_data"
}

public enum DataSensitivity: String, Codable, Comparable, Sendable {
    case routine, `private`, sensitive, highlySensitive = "highly_sensitive", unknown
}

public enum EgressSourceKind: String, Codable, Hashable, Sendable {
    case conversation, memory, contacts, files, calendar, photos, location
    case attachment
    case toolResult = "tool_result"
    case other
}

public enum EgressSizeBucket: String, Codable, Sendable {
    case none
    case lessThanOneKiB = "less_than_1_kib"
    case oneToOneHundredKiB = "1_to_100_kib"
    case oneHundredKiBToOneMiB = "100_kib_to_1_mib"
    case greaterThanOneMiB = "greater_than_1_mib"
}

public struct GenerationDisclosure: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let generationTurnID: String
    public let contentDigest: String
    public let sourceRevisionDigest: String
    public let dataClasses: Set<EgressDataClass>
    public let highestSensitivity: DataSensitivity
    public let safeDisplaySummary: SafeDisplaySummary
    public func computedDigest() throws -> CanonicalDigest
}

public struct NormalizedToolResult: Codable, Equatable, Sendable {
    public let callID: String
    public let toolName: String
    public let result: CanonicalJSONValue
    public let isError: Bool
    public let dataClasses: Set<EgressDataClass>
    public let highestSensitivity: DataSensitivity
}

public typealias LLMBackendEventStream = AsyncThrowingStream<LLMBackendEvent, Error>

public struct ProviderPresetID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public static let openAI = Self(rawValue: "openai")
    public static let anthropic = Self(rawValue: "anthropic")
    public static let gemini = Self(rawValue: "gemini")
    public static let xAI = Self(rawValue: "xai")
    public static let deepSeek = Self(rawValue: "deepseek")
    public static let miniMax = Self(rawValue: "minimax")
    public static let glm = Self(rawValue: "glm")
}

public enum ProviderRetentionMode: String, Codable, Equatable, Sendable {
    case statelessRequired = "stateless_required"
    case providerStateApproved = "provider_state_approved"
}

package struct CloudResolvedAttachmentIdentity: Equatable, Sendable {
    let attachmentID: String
    let revision: UInt64
    let contentDigest: String
    let mediaType: String
    let byteCount: UInt64
}

package protocol CloudAttachmentIdentityResolving: Sendable {
    func resolveIdentities(
        for input: AgentLLMInput,
        sourceRevisionDocument: CanonicalJSONValue
    ) throws -> [CloudResolvedAttachmentIdentity]
}

package struct CloudGenerationTurnCandidate: Equatable, Sendable {
    let input: AgentLLMInput
    let canonicalToolSchema: CanonicalJSONValue
    let sourceRevisionDocument: CanonicalJSONValue
    let resolvedAttachments: [CloudResolvedAttachmentIdentity]
    let toolResults: [NormalizedToolResult]
    let providerRequiredSemanticHistory: CanonicalJSONValue
    let disclosure: GenerationDisclosure
    let resolvedParameters: GenerationConfiguration
}

package struct ValidatedCloudGenerationTurn: Equatable, Sendable {
    package let semantic: CloudGenerationTurnCandidate
    package let contentDigest: CanonicalDigest
    package let sourceRevisionDigest: CanonicalDigest
    fileprivate init(
        semantic: CloudGenerationTurnCandidate,
        contentDigest: CanonicalDigest,
        sourceRevisionDigest: CanonicalDigest
    ) {
        self.semantic = semantic
        self.contentDigest = contentDigest
        self.sourceRevisionDigest = sourceRevisionDigest
    }
}

package struct CloudWireRequest: Equatable, Sendable {
    let method: String
    let path: String
    let queryItems: [URLQueryItem]
    let headers: [String: String]
    let body: Data?
}

package struct CloudProviderSessionContext: Equatable, Sendable {
    let targetID: LLMTargetID
    let targetRevision: UInt64
    let providerProfileID: String
    let providerProfileRevision: UInt64
    let modelID: String
    let retentionMode: ProviderRetentionMode
    let retentionApprovalRevision: UInt64?
    let retentionApprovalDigest: String?
    let hostProcessEpoch: HostProcessEpoch
}

package protocol CloudSemanticTurnValidating: Sendable {
    func validate(
        _ candidate: CloudGenerationTurnCandidate
    ) throws -> ValidatedCloudGenerationTurn
}

package struct SSEEvent: Equatable, Sendable {
    let event: String?
    let id: String?
    let retryMilliseconds: UInt64?
    let data: Data
}
```

`DataSensitivity.<` uses the declared enum order. Missing tool labels normalize to `.unknownData` plus `.unknown`; they never default to routine text. `GenerationDisclosure.computedDigest()` builds the exact `generation-disclosure:v1` typed document and rejects any caller-supplied digest field.

`CloudAttachmentIdentityResolving` is an identity-only authority: it resolves revision/content digest/media type/size for every referenced attachment but never returns bytes or an upload handle. `CloudSemanticTurnValidator.validate(_:)` builds the complete `agent-input:v1` document from ordered messages, canonical tool schema, those authoritative attachment identities, complete tool-result batch, and provider-required semantic history; it separately builds `source-revisions:v1` from the exact source document and attachment revisions. It recomputes both digests and compares them with the disclosure before calling the fileprivate initializer. It rejects malformed digest strings, duplicate source/attachment identities, an attachment reference without one matching identity, and any caller-supplied precomputed semantic sub-digest. Phase 3 tests use a package-private fixture authority plus fake attachment-identity resolver that invokes this production validator; only Phase 4 supplies the Rust disclosure.

Append `provider-retention-approval:v1` to the shared registry and both implementation allowlists, update the registered-domain count from 32 to 33, and include its golden in both Swift and Rust fixture loops. Rust verifies only domain registration/canonical bytes/digest and gains no retention parser.

Define only the provider-neutral cloud seam:

```swift
package protocol CloudProviderAdapter: Sendable {
    var adapterID: String { get }
    var adapterVersion: String { get }
    var presetID: ProviderPresetID { get }
    func makeSession(_ context: CloudProviderSessionContext) throws -> any CloudProviderSession
}

package protocol CloudProviderSession: AnyObject, Sendable {
    func encodeStart(_ turn: ValidatedCloudGenerationTurn) throws -> CloudWireRequest
    func encodeResume(_ turn: ValidatedCloudGenerationTurn) throws -> CloudWireRequest
    func decode(_ events: AsyncThrowingStream<SSEEvent, Error>) -> LLMBackendEventStream
    func cancel() async
    func close() async
}
```

Task 1 deliberately exposes only a validated but unauthorised encode seam so the package compiles before egress exists. Task 5 replaces both encode parameters with package-internal `AuthorizedCloudGenerationTurn`; no production adapter registry or runtime may be constructed until that replacement lands. `CloudWireRequest` cannot send itself, contains no credential/authentication value, and is accepted by no transport until Task 6 policy-seals it.

- [ ] **Step 4: Run GREEN and regressions**

```bash
swift test --package-path toolkit --filter GenerationDisclosureTests
swift test --package-path toolkit --filter CloudProviderBoundaryTests
swift test --package-path toolkit --filter CloudSemanticTurnValidatorTests
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml \
  --test contract canonical_digest_v1 -- --nocapture
scripts/run-llm-phase-2-contracts.sh
```

Expected: new contract tests and Swift/Rust shared digest fixtures pass, all Phase 2 contracts stay green, and the cloud target has no Provider SDK or App UI dependency.

- [ ] **Step 5: Commit**

```bash
git add toolkit/Package.swift toolkit/Sources/LocalAgentLLMContracts \
  toolkit/Sources/LocalAgentLLMCloud toolkit/Tests/LocalAgentLLMContractsTests \
  toolkit/Tests/LocalAgentLLMCloudTests contracts/canonical-digest-v1/fixtures \
  contracts/canonical-digest-v1/registry.json rust-core/src/canonical_digest.rs \
  rust-core/tests/contract/canonical_digest_v1.rs
git commit -m "feat: add cloud llm turn contracts"
```

---

### Task 2: Add Provider Presets, Immutable Profiles, Exact Origins, and SQLite State

**Files:**
- Modify: `toolkit/Sources/LocalAgentLLMCloud/ProviderPreset.swift`
- Create: `toolkit/Sources/LocalAgentLLMCloud/ProviderProfile.swift`
- Create: `toolkit/Sources/LocalAgentLLMCloud/ProviderProfileStore.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCore/LLMStore.swift`
- Create: `toolkit/Sources/LocalAgentLLMCore/LLMStoreSchema.swift`
- Create: `toolkit/Tests/LocalAgentLLMCloudTests/ProviderPresetTests.swift`
- Create: `toolkit/Tests/LocalAgentLLMCloudTests/ProviderProfileStoreTests.swift`
- Create: `toolkit/Tests/LocalAgentLLMCloudTests/LLMStoreSchemaV2Tests.swift`
- Modify: `toolkit/Tests/LocalAgentLLMCoreTests/LLMStoreTests.swift`

**Interfaces:**
- Produces exactly seven shipped `ProviderPreset` values with explicit auth, codec, discovery, validation, and semantic-adapter IDs.
- Produces immutable `ProviderProfileRevision` with default stateless retention, final version-2 `ProviderProfileState`, canonical `EgressOrigin`, archival, and exact-revision reads.
- Produces the complete normalized Phase 3 schema in the existing `LocalAgent/LLM/llm-state.sqlite`; later Tasks populate fixed tables but do not change DDL or persisted payload shape. `local-models.sqlite` remains separate.
- Produces one atomic schema migration v1 → v2 with rollback, exact old-version reopen, and future-version rejection.

- [ ] **Step 1: Write failing preset, origin, revision, reopen, and migration tests**

Assert the preset ID set is exactly `openai`, `anthropic`, `gemini`, `xai`, `deepseek`, `minimax`, and `glm`; every default URL is HTTPS and contains no credentials. Test immutable revision insertion, default stateless retention, equal-revision idempotence, conflicting equal revision rejection, monotonic revision creation, archive-without-key-deletion, exact cloud target pinning, two-store reopen, and stale CAS. Schema fixtures must cover an empty and populated v1 database, every DDL failure rollback boundary, the exact final v2 table/index set, reopen after each later Task's legal row shape, unknown `record_schema_version`/enum tag rejection, and refusal to open `user_version = 3`.

```swift
@Test func profileRevisionAndOriginArePinnedExactly() async throws {
    let profile = ProviderProfileRevision(
        profileID: "provider-main",
        revision: 1,
        presetID: .openAI,
        displayName: "OpenAI",
        baseURL: URL(string: "https://api.openai.com/v1")!,
        credentialRef: "credential-main",
        retentionMode: .statelessRequired
    )
    let stored = try await store.publish(profile)
    #expect(stored.origin == EgressOrigin(scheme: "https", host: "api.openai.com", port: 443))
    let forbidden = ProviderProfileRevision(
        profileID: "provider-private",
        revision: 1,
        presetID: .openAI,
        displayName: "Forbidden",
        baseURL: URL(string: "https://127.0.0.1/v1")!,
        credentialRef: "credential-main",
        retentionMode: .statelessRequired
    )
    await #expect(throws: ProviderProfileFailure.self) {
        try await store.publish(forbidden)
    }
}
```

- [ ] **Step 2: Run RED**

```bash
swift test --package-path toolkit --filter ProviderPresetTests
swift test --package-path toolkit --filter ProviderProfileStoreTests
swift test --package-path toolkit --filter LLMStoreSchemaV2Tests
```

Expected: fail because presets, profile/retention DTOs, origin validation, the complete Phase 3 schema, record decoders, and atomic migration v2 are absent.

- [ ] **Step 3: Implement presets and immutable profile storage**

```swift
public struct ProviderProfileRevision: Codable, Equatable, Sendable {
    public let profileID: String
    public let revision: UInt64
    public let presetID: ProviderPresetID
    public let displayName: String
    public let baseURL: URL
    public let credentialRef: String
    public let retentionMode: ProviderRetentionMode
}

public struct EgressOrigin: Codable, Equatable, Hashable, Sendable {
    public let scheme: String
    public let host: String
    public let port: UInt16
}

public enum ProviderRevisionLifecycle: String, Codable, Sendable {
    case active, archived
}

public struct ProviderValidationEvidenceIdentity: Codable, Equatable, Sendable {
    public let modelID: String
    public let origin: EgressOrigin
    public let credentialGeneration: UInt64
    public let retentionMode: ProviderRetentionMode
    public let retentionApprovalRevision: UInt64?
    public let retentionApprovalDigest: String?
    public let catalogRevision: UInt64
    public let adapterID: String
    public let adapterVersion: String
    public let evidenceDigest: String
    public let expiresAt: Date
}

public enum ProviderProfileValidationState: Equatable, Sendable {
    case unvalidated
    case validated(ProviderValidationEvidenceIdentity)
    case invalidated(reasonCode: String)
}

public struct ProviderProfileState: Equatable, Sendable {
    public let profileID: String
    public let profileRevision: UInt64
    public var validationState: ProviderProfileValidationState
    public var approvedEgressOrigin: EgressOrigin?
    public var retentionApprovalRevision: UInt64?
    public var retentionApprovalDigest: String?
    public var catalogRevision: UInt64?
    public var stateRevision: UInt64
}

package protocol ProviderOriginValidating: Sendable {
    func validate(_ baseURL: URL) async throws -> EgressOrigin
}
```

Preset defaults and codec assignments are exact:

```text
openai    https://api.openai.com/v1                 bearer         openai_responses
anthropic https://api.anthropic.com/v1              x-api-key      anthropic_messages
gemini    https://generativelanguage.googleapis.com/v1beta x-goog-api-key gemini_interactions
xai       https://api.x.ai/v1                       bearer         openai_responses
deepseek  https://api.deepseek.com                  bearer         openai_chat_completions
minimax   https://api.minimax.io/anthropic/v1       x-api-key      anthropic_messages
glm       https://open.bigmodel.cn/api/paas/v4      bearer         openai_chat_completions
```

MiniMax and Anthropic share a header shape but retain different semantic IDs. GLM uses catalog/manual discovery unless a fixture-proven model-list endpoint is added later. `EgressOrigin` lowercases/punycode-normalizes the host, uses the effective default port, removes no path from `baseURL`, and rejects a non-HTTPS scheme, user-info, fragment, invalid port, literal or resolved reserved address, or an origin-changing normalization. `ProviderProfileStore` receives `ProviderOriginValidating`; deterministic tests inject a fake resolver/policy, while Task 6 supplies the live stable-public-address implementation. Publishing never performs an unowned network request.

Move base schema setup to `LLMStoreSchema.ensureBaseSchema(_:)`. It reads `PRAGMA user_version`, creates v1 tables only when missing, and never writes a lower version. `ProviderProfileStore` opens the same `llm-state.sqlite` and runs one `BEGIN IMMEDIATE` v1 → v2 migration. The complete v2 table set is created now:

```sql
provider_profile_revisions(profile_id, revision, preset_id, origin, credential_ref, retention_mode, lifecycle, record_schema_version, record_json)
provider_profile_state(profile_id, profile_revision, retention_approval_revision, retention_approval_digest, catalog_revision, state_revision, record_schema_version, record_json)
llm_target_revisions(target_id, revision, kind, model_id, profile_id, profile_revision, record_schema_version, record_json)
provider_origin_approvals(profile_id, profile_revision, approval_revision, origin, record_schema_version, record_json)
provider_retention_approvals(profile_id, profile_revision, approval_revision, retention_mode, behavior, window_class, decision, approval_digest, record_schema_version, record_json)
credential_creation_operations(operation_id, credential_ref, generation, phase, record_schema_version, record_json)
credential_slots(credential_ref, current_generation, lifecycle, operation_id, record_schema_version, record_json)
credential_use_leases(lease_id, credential_ref, generation, purpose, preparation_id, host_epoch, lifecycle, revision, record_schema_version, record_json)
credential_operation_tombstones(operation_id, credential_ref, operation_kind, phase, record_schema_version, record_json)
credential_key_tombstones(tombstone_id, credential_ref, generation, phase, record_schema_version, record_json)
egress_scope_grants(grant_id, run_id, profile_id, profile_revision, credential_generation, retention_mode, retention_approval_revision, retention_approval_digest, record_schema_version, record_json)
egress_generation_authorizations(authorization_id, generation_turn_id, grant_id, credential_generation, record_schema_version, record_json)
egress_audit_records(audit_id, run_id, generation_turn_id, previous_chain_digest, chain_digest, record_schema_version, record_json)
cloud_catalog_state(catalog_id, catalog_revision, key_id, payload_digest, record_schema_version, record_json)
cloud_capability_observations(observation_digest, profile_id, profile_revision, model_id, credential_generation, expires_at, record_schema_version, record_json)
provider_validation_records(validation_id, profile_id, profile_revision, model_id, credential_generation, expires_at, record_schema_version, record_json)
prepared_cloud_sessions(session_id, preparation_id, proposed_run_id, host_epoch, lifecycle, record_schema_version, record_json)
cloud_session_tombstones(session_id, close_revision, disposition, record_schema_version, record_json)
sanitized_llm_snapshots(snapshot_id, run_id, preparation_id, host_epoch, record_schema_version, record_json)
```

All identity/revision columns participate in declared unique indexes and CAS predicates; no table contains a credential value. Each JSON object repeats required integer `record_schema_version = 2`. Implement explicit tagged encoders/decoders for every policy enum, including the final validation-state shape above; synthesized enum Codable is forbidden. Any DDL or authoritative payload change after Task 2 requires a future user-version migration and is outside this Phase 3 plan. Set `PRAGMA user_version = 2` only after every table/index succeeds; injected failure rolls back all DDL/data changes.

- [ ] **Step 4: Run GREEN, reopen, and Phase 2 regression tests**

```bash
swift test --package-path toolkit --filter ProviderPresetTests
swift test --package-path toolkit --filter ProviderProfileStoreTests
swift test --package-path toolkit --filter LLMStoreSchemaV2Tests
swift test --package-path toolkit --filter LLMStoreTests
scripts/run-llm-phase-2-contracts.sh
```

Expected: exact presets/origins/retention pass, v1 data reopens under the complete v2 schema, every injected migration failure leaves v1 intact, future/unknown records fail closed, stale writers lose CAS, and Phase 2 remains green.

- [ ] **Step 5: Commit**

```bash
git add toolkit/Sources/LocalAgentLLMCloud/ProviderPreset.swift \
  toolkit/Sources/LocalAgentLLMCloud/ProviderProfile.swift \
  toolkit/Sources/LocalAgentLLMCloud/ProviderProfileStore.swift \
  toolkit/Sources/LocalAgentLLMCore/LLMStore.swift \
  toolkit/Sources/LocalAgentLLMCore/LLMStoreSchema.swift \
  toolkit/Tests/LocalAgentLLMCloudTests toolkit/Tests/LocalAgentLLMCoreTests/LLMStoreTests.swift
git commit -m "feat: persist immutable cloud provider profiles"
```

---

### Task 3: Store Generation-Pinned Credentials in Keychain and Acquire Use Leases

**Files:**
- Create: `toolkit/Sources/LocalAgentLLMCloud/ProviderCredentialStore.swift`
- Create: `toolkit/Sources/LocalAgentLLMCloud/SecurityCredentialVault.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCloud/ProviderProfileStore.swift`
- Create: `toolkit/Tests/LocalAgentLLMCloudTests/ProviderCredentialStoreTests.swift`
- Create: `apps/LocalAgentApp/LocalAgentAppTests/Integration/CloudCredentialKeychainTests.swift`
- Modify: `apps/LocalAgentApp/LocalAgentApp.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces tracked `CredentialCreationOperation`, `CredentialSlotState`, lifecycle, `CredentialUseLease`, and the sole transaction that selects a generation and inserts its lease.
- Produces `CredentialVault` and live `SecurityCredentialVault`; the live item account is generation-specific and uses `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- Produces closure-scoped credential resolution that rechecks the live lease and generation before every request.
- Produces validation and preparation lease purposes; no session caches plaintext credentials.

- [ ] **Step 1: Write failing vault, generation-authority, lease, and no-secret persistence tests**

Cover the complete initial publication sequence, same-operation replay, conflicting operation input, staged/final Keychain account names, `creating` lease/profile-publication rejection, active-slot lease acquisition, `rotating`/`deleting` rejection, exact generation resolution, validation lease release, preparation lease promotion to `sessionBound`, close lifecycle, old-epoch cleanup, concurrent acquire CAS, missing Keychain item, and SQLite/source scans for the sentinel secret. Add an iOS Simulator Keychain test that writes a random staged key, promotes it to the final account, reads its attributes, verifies `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, and deletes it in `defer`.

```swift
@Test func leasePinsTheOnlySlotGenerationBeforeCredentialRead() async throws {
    try await credentials.createSlot(
        credentialRef: "shared-key",
        initialSecret: SecretBytes(utf8: "fixture-secret"),
        operationID: "create-1"
    )
    let lease = try await credentials.acquireUseLease(
        credentialRef: "shared-key",
        purpose: .preparation,
        preparationID: "prep-1",
        hostProcessEpoch: epoch
    )
    #expect(lease.generation == 1)
    #expect(try await credentials.slot("shared-key")?.currentGeneration == 1)
}
```

- [ ] **Step 2: Run RED**

```bash
swift test --package-path toolkit --filter ProviderCredentialStoreTests
xcodebuild test -project apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  -only-testing:LocalAgentAppTests/CloudCredentialKeychainTests
```

Expected: fail because the credential vault, creation saga/slot/lease behavior, and hosted Keychain test do not exist; Task 2's empty v2 tables already exist.

- [ ] **Step 3: Implement secret-safe vault and transactional leases**

```swift
public struct CredentialSlotState: Codable, Equatable, Sendable {
    public let credentialRef: String
    public var currentGeneration: UInt64
    public var lifecycle: CredentialSlotLifecycle
}

public enum CredentialSlotLifecycle: Codable, Equatable, Sendable {
    case creating(operationID: String, generation: UInt64)
    case active
    case rotating(operationID: String, expectedGeneration: UInt64, nextGeneration: UInt64)
    case deleting(operationID: String, expectedGeneration: UInt64)
}

public enum CredentialUsePurpose: String, Codable, Sendable {
    case validation, preparation
}

public enum CredentialUseLifecycle: String, Codable, Sendable {
    case acquired
    case sessionBound = "session_bound"
    case closing
}

public struct CredentialUseLease: Codable, Equatable, Sendable {
    public let leaseID: String
    public let credentialRef: String
    public let generation: UInt64
    public let purpose: CredentialUsePurpose
    public let preparationID: String?
    public let hostProcessEpoch: HostProcessEpoch
    public var revision: UInt64
    public var lifecycle: CredentialUseLifecycle
}
```

`SecretBytes` is a final `@unchecked Sendable`, non-Codable, non-Equatable, non-printable class backed by mutable bytes and zeroes them on deinit. Its initializer copies caller-owned bytes, its closure access never exposes the backing storage, and it documents the narrow synchronization invariant required by `@unchecked Sendable`. `CredentialVault` keys items by service + `credentialRef` + decimal generation; staged items also include operation ID. The production vault uses generic-password Keychain Services, `kSecAttrSynchronizable = false`, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, and returns `credential.missing` without a provider request when absent.

Use the normalized tables created by Task 2; this Task does not execute DDL. Initial creation is:

```text
transaction: insert CredentialCreationOperation(intent, operation ID, generation 1)
Keychain: write operation-named staged generation-1 item
transaction: insert CredentialSlotState(generation 1, creating(operation ID, 1)); mark operation slot_published
Keychain: promote staged account to final credentialRef/generation account
transaction: CAS creating -> active and mark operation complete
```

Every boundary is persisted by operation ID. `creating` rejects new profile references, lease acquisition, validation, and resolution. `acquireUseLease` performs one SQLite transaction: require active, read the one current generation, insert the lease, and return it. `withCredential(for:operation:)` re-reads the lease/slot, verifies the generation is still current and lifecycle admissible, reads Keychain, invokes the closure, and erases the temporary secret. It never returns a reusable key string.

- [ ] **Step 4: Run GREEN and secret scans**

```bash
swift test --package-path toolkit --filter ProviderCredentialStoreTests
xcodebuild test -project apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  -only-testing:LocalAgentAppTests/CloudCredentialKeychainTests
rg -n 'fixture-secret|api[_-]?key\s*=' toolkit/Sources apps/LocalAgentApp/LocalAgentApp rust-core/src
```

Expected: store/hosted tests pass; source scan finds no persisted fixture secret or hard-coded production key.

- [ ] **Step 5: Commit**

```bash
git add toolkit/Sources/LocalAgentLLMCloud toolkit/Tests/LocalAgentLLMCloudTests \
  apps/LocalAgentApp/LocalAgentAppTests/Integration/CloudCredentialKeychainTests.swift \
  apps/LocalAgentApp/LocalAgentApp.xcodeproj/project.pbxproj
git commit -m "feat: pin cloud credentials with keychain leases"
```

---

### Task 4: Reconcile Credential Creation, Rotation, Logical-Profile Deletion, and Startup

**Files:**
- Create: `toolkit/Sources/LocalAgentLLMCloud/CredentialOperationReconciler.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCloud/ProviderCredentialStore.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCloud/ProviderProfileStore.swift`
- Create: `toolkit/Tests/LocalAgentLLMCloudTests/CredentialRotationTests.swift`
- Create: `toolkit/Tests/LocalAgentLLMCloudTests/CredentialOperationReconcilerTests.swift`

**Interfaces:**
- Produces idempotent creation recovery, `rotateCredential`, `beginCredentialDeletion`, and startup reconciliation operations.
- Rotation invalidates every validation, availability observation, egress grant, and readiness row scoped to the old generation across every profile sharing the slot.
- Archiving one revision never deletes a slot; logical-profile deletion performs reference/lease checks before the slot CAS.
- Recovery never labels old Keychain material as a new generation.

- [ ] **Step 1: Write failing race and crash-boundary tests**

Cover creation crashes after intent, staged write, slot publication, final-account promotion, and activation; preparation lease wins versus rotation CAS; rotation wins versus later lease; shared-profile invalidation; staged-key write failure; crash before rotation publish; crash after rotation publish before old-item deletion; deletion with another revision/profile reference; deletion with binding operation; deletion with acquired/sessionBound/closing lease; crash before/after Keychain deletion; exact idempotent replay; and conflicting operation ID. Assert recovery deletes only a staged account named by a persisted creation operation and never performs an untracked orphan scan.

```swift
@Test func rotationAndLeaseAcquisitionHaveExactlyOneWinner() async throws {
    async let lease = credentials.acquireUseLease(
        credentialRef: "shared",
        purpose: .preparation,
        preparationID: "prep-race",
        hostProcessEpoch: epoch
    )
    async let rotation = credentials.rotateCredential(
        credentialRef: "shared",
        expectedGeneration: 1,
        replacement: SecretBytes(utf8: "replacement"),
        operationID: "rotate-race"
    )
    let outcomes = await capturedOutcomes(lease, rotation)
    #expect(outcomes.successCount == 1)
}
```

- [ ] **Step 2: Run RED**

```bash
swift test --package-path toolkit --filter CredentialRotationTests
swift test --package-path toolkit --filter CredentialOperationReconcilerTests
```

Expected: fail because slot lifecycle CAS, invalidation, tombstone phases, and reconciliation are absent.

- [ ] **Step 3: Implement exact creation recovery, rotation, and deletion sagas**

Creation recovery is phase-directed: before slot publication it deletes the exact operation-named staged item and aborts the intent; after a `creating` slot exists it finishes staged-to-final promotion and CASes that same slot active. A final item without the matching operation/slot is reported as `credential.untracked_keychain_item` and is never adopted or deleted automatically.

Rotation phases are persisted and idempotent:

```text
active(generation N), zero leases
  -> rotating(operation, expected N, next N+1)
  -> staged Keychain item N+1
  -> publish N+1 + invalidate N-scoped state + active
  -> tombstone old item N
  -> delete old item N
  -> tombstone complete
```

Before publication, recovery deletes the staged item and returns the same slot to generation N active. After publication, recovery must finish old-item deletion; it never rolls generation backward. Deletion phases are:

```text
active(generation N), zero references, zero leases
  -> deleting(operation, expected N)
  -> tombstone deletion_started
  -> delete generation N Keychain item
  -> tombstone key_deleted
  -> delete slot row and complete tombstone
```

Logical-profile deletion first prevents new sessions and archives all its revisions. It deletes a credential slot only if no non-archived revision from any logical profile, pending host-binding operation, retained prepared/cloud snapshot, or use lease references it. Revision archival never calls credential deletion.

- [ ] **Step 4: Run GREEN and restart regressions**

```bash
swift test --package-path toolkit --filter CredentialRotationTests
swift test --package-path toolkit --filter CredentialOperationReconcilerTests
swift test --package-path toolkit --filter ProviderProfileStoreTests
```

Expected: every injected crash converges, sharing/reference rules hold, and the race always has one winner.

- [ ] **Step 5: Commit**

```bash
git add toolkit/Sources/LocalAgentLLMCloud toolkit/Tests/LocalAgentLLMCloudTests
git commit -m "feat: reconcile cloud credential lifecycle"
```

---

### Task 5: Bind Exact Egress Origins and Every Generation Turn to Approval

**Files:**
- Create: `toolkit/Sources/LocalAgentLLMCloud/ProviderEgressPolicy.swift`
- Create: `toolkit/Sources/LocalAgentLLMCloud/EgressDigestDocuments.swift`
- Create: `toolkit/Sources/LocalAgentLLMCloud/ProviderRetentionPolicy.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCloud/CloudProviderAdapter.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCloud/ProviderProfileStore.swift`
- Create: `toolkit/Tests/LocalAgentLLMCloudTests/ProviderEgressPolicyTests.swift`
- Create: `toolkit/Tests/LocalAgentLLMCloudTests/EgressDigestTests.swift`
- Modify: `toolkit/Tests/LocalAgentLLMContractsTests/CanonicalDigestTests.swift`

**Interfaces:**
- Produces exact-origin and explicit provider-retention approval, `EgressScopeGrant`, `GenerationEgressAuthorization`, private `EgressSubject`, and append-only audit-chain records.
- Produces `EgressApprovalPrompting` and `ProviderRetentionApprovalPrompting`; injected presentation receives only exact origin, documented retention behavior, and safe summaries.
- Produces package-internal `AuthorizedCloudGenerationTurn` wrapping only a sealed `ValidatedCloudGenerationTurn`; adapters cannot encode an unvalidated or unauthorised semantic request.
- Produces a denial boundary that stops the affected request and returns `egress.denied`; Phase 4 later maps it to `execution.egress_denied`.

- [ ] **Step 1: Write failing origin, initial/incremental grant, digest, and privacy tests**

Test origin approval once per exact Profile revision, default stateless mode without a retention prompt, explicit provider-state approval/evidence, rejection when `providerStateApproved` lacks its exact approval revision, invalidation after origin/generation/retention change, routine text reuse within scope, changed content producing a new turn authorization, contact/tool-result expansion requiring a new grant, unknown labels forcing high sensitivity, denial before adapter encoding/credential resolution, denial after tool results before resume encoding/transport, prior-grant digest linkage, append-only audit hash chaining, and JSON/log/source scans proving raw values never enter summaries.

```swift
@Test func sensitiveToolResultPausesBeforeTheAffectedRequest() async throws {
    let expandedDisclosure = disclosure(
        turnID: "turn-2",
        classes: [.text, .contacts, .toolResult],
        sensitivity: .sensitive,
        toolDisplayKeys: ["contacts.search"]
    )
    let validated = try validator.validate(toolResumeCandidate(
        disclosure: expandedDisclosure
    ))
    prompt.nextDecision = .deny
    await #expect(throws: LLMFailure.self) {
        try await policy.authorizeTurn(
            validated,
            session: session,
            priorGrant: initialGrant
        )
    }
    #expect(transport.requestCount == 0)
    #expect(credentials.resolveCount == 0)
}
```

- [ ] **Step 2: Run RED**

```bash
swift test --package-path toolkit --filter ProviderEgressPolicyTests
swift test --package-path toolkit --filter EgressDigestTests
```

Expected: fail because grants, authorizations, approval prompting, private subjects, and audit rows do not exist.

- [ ] **Step 3: Implement the egress state and canonical documents**

```swift
public struct EgressScopeGrant: Codable, Equatable, Sendable {
    public let grantID: String
    public let runID: String
    public let providerProfileID: String
    public let providerProfileRevision: UInt64
    public let origin: EgressOrigin
    public let credentialGeneration: UInt64
    public let retentionMode: ProviderRetentionMode
    public let retentionApprovalRevision: UInt64?
    public let retentionApprovalDigest: String?
    public let allowedDataClasses: Set<EgressDataClass>
    public let maximumSensitivity: DataSensitivity
    public let decisionRevision: UInt64
    public let issuedAt: Date
    public let expiresAt: Date?
    public let revokedAt: Date?
    public let grantDigest: String
}

public enum ProviderRetentionWindowClass: String, Codable, Equatable, Sendable {
    case oneDay = "one_day"
    case sevenToThirtyDays = "seven_to_thirty_days"
    case thirtyOneToSixtyDays = "thirty_one_to_sixty_days"
    case providerConfigured = "provider_configured"
    case unknown
}

public struct ProviderRetentionApproval: Codable, Equatable, Sendable {
    public let providerProfileID: String
    public let providerProfileRevision: UInt64
    public let origin: EgressOrigin
    public let retentionMode: ProviderRetentionMode
    public let behavior: ProviderRetentionBehavior
    public let disclosedWindowClass: ProviderRetentionWindowClass
    public let decisionRevision: UInt64
    public let issuedAt: Date
    public let approvalDigest: String
}

public struct GenerationEgressAuthorization: Codable, Equatable, Sendable {
    public let authorizationID: String
    public let generationTurnID: String
    public let disclosureDigest: String
    public let approvalSummaryDigest: String
    public let scopeGrantID: String
    public let scopeGrantDigest: String
    public let credentialGeneration: UInt64
    public let retentionMode: ProviderRetentionMode
    public let retentionApprovalRevision: UInt64?
    public let retentionApprovalDigest: String?
    public let issuedAt: Date
    public let expiresAt: Date
    public let authorizationDigest: String
}

public enum ProviderRetentionBehavior: String, Codable, Equatable, Sendable {
    case serverSideConversationState = "server_side_conversation_state"
}

public struct ProviderRetentionDisclosure: Codable, Equatable, Sendable {
    public let behavior: ProviderRetentionBehavior
    public let windowClass: ProviderRetentionWindowClass
}

package struct AuthorizedCloudGenerationTurn: Equatable, Sendable {
    package let validated: ValidatedCloudGenerationTurn
    package let authorization: GenerationEgressAuthorization
    package let targetID: LLMTargetID
    package let targetRevision: UInt64
    package let profileID: String
    package let profileRevision: UInt64
    package let origin: EgressOrigin
    package let credentialRef: String
    package let credentialGeneration: UInt64
    package let credentialUseLeaseID: String
    package let credentialUseLeaseDigest: String
    package let retentionMode: ProviderRetentionMode
    package let retentionApprovalRevision: UInt64?
    package let retentionApprovalDigest: String?

    fileprivate init(
        validated: ValidatedCloudGenerationTurn,
        authorization: GenerationEgressAuthorization,
        targetID: LLMTargetID,
        targetRevision: UInt64,
        profileID: String,
        profileRevision: UInt64,
        origin: EgressOrigin,
        credentialRef: String,
        credentialGeneration: UInt64,
        credentialUseLeaseID: String,
        credentialUseLeaseDigest: String,
        retentionMode: ProviderRetentionMode,
        retentionApprovalRevision: UInt64?,
        retentionApprovalDigest: String?
    ) {
        self.validated = validated
        self.authorization = authorization
        self.targetID = targetID
        self.targetRevision = targetRevision
        self.profileID = profileID
        self.profileRevision = profileRevision
        self.origin = origin
        self.credentialRef = credentialRef
        self.credentialGeneration = credentialGeneration
        self.credentialUseLeaseID = credentialUseLeaseID
        self.credentialUseLeaseDigest = credentialUseLeaseDigest
        self.retentionMode = retentionMode
        self.retentionApprovalRevision = retentionApprovalRevision
        self.retentionApprovalDigest = retentionApprovalDigest
    }
}

public protocol EgressApprovalPrompting: Sendable {
    func requestOriginApproval(_ origin: EgressOrigin, profileName: String) async -> EgressDecision
    func requestScopeApproval(
        origin: EgressOrigin,
        summary: EgressApprovalDisplaySummary
    ) async -> EgressDecision
}

public protocol ProviderRetentionApprovalPrompting: Sendable {
    func requestProviderStateApproval(
        profileName: String,
        origin: EgressOrigin,
        disclosure: ProviderRetentionDisclosure
    ) async -> EgressDecision
}
```

Replace the temporary Task 1 semantic method parameters now that authorization exists:

```swift
package protocol CloudProviderSession: AnyObject, Sendable {
    func encodeStart(_ turn: AuthorizedCloudGenerationTurn) throws -> CloudWireRequest
    func encodeResume(_ turn: AuthorizedCloudGenerationTurn) throws -> CloudWireRequest
    func decode(_ events: AsyncThrowingStream<SSEEvent, Error>) -> LLMBackendEventStream
    func cancel() async
    func close() async
}
```

Only `ProviderEgressPolicy` can seal an `AuthorizedCloudGenerationTurn`. It wraps `ValidatedCloudGenerationTurn` and binds grant/authorization IDs, exact target/profile/origin/credential-generation/retention identity, but still contains no credential bytes. An adapter can produce an unsendable `CloudWireRequest` from that wrapper; Task 6 adds the second policy seal required before transport.

`EgressApprovalDisplaySummary` stays in `LocalAgentLLMCloud`; it includes disclosure digest, prior grant digest, safe summary, newly added classes, and `egress-approval-summary:v1`. Exact grant/authorization/subject/audit documents implement their registered digest domains and reject noncanonical decimal/timestamp fields.

Ordering is mandatory:

```text
validate disclosure digest and source/content binding
  -> validate exact approved origin
  -> validate stateless mode or exact provider-retention approval revision
  -> compare private current grant
  -> prompt only for scope expansion
  -> persist grant/authorization/audit row
  -> acquire or revalidate CredentialUseLease
  -> return AuthorizedCloudGenerationTurn
```

`statelessRequired` is the preset/profile default and does not prompt for provider state. `providerStateApproved` requires a dedicated `ProviderRetentionApproval` using `provider-retention-approval:v1`; its revision/digest describes the provider's documented retention window class and is bound to the Profile state, scope grant, authorization, egress subject, and later capability snapshot. A mode change creates a Profile revision and cannot reuse an earlier grant. Free-form provider policy text is not part of the digest or logs; presets supply stable disclosed behavior/window enums.

The policy never accepts free-form tool names. `triggeringToolDisplayKeys` must be a subset of the signed tool manifest keys supplied by the caller; otherwise the summary is replaced by `.unknownData`/`.unknown` and cannot reduce approval.

- [ ] **Step 4: Run GREEN and common digest regressions**

```bash
swift test --package-path toolkit --filter ProviderEgressPolicyTests
swift test --package-path toolkit --filter EgressDigestTests
swift test --package-path toolkit --filter CanonicalDigestTests
```

Expected: grants bind exact origin/profile/generation/retention/turn, denial makes zero adapter/credential/network calls, and all new fixtures pass.

- [ ] **Step 5: Commit**

```bash
git add toolkit/Sources/LocalAgentLLMCloud toolkit/Tests/LocalAgentLLMCloudTests \
  toolkit/Tests/LocalAgentLLMContractsTests/CanonicalDigestTests.swift \
  contracts/canonical-digest-v1/fixtures
git commit -m "feat: authorize cloud egress per generation"
```

---

### Task 6: Add Exact-Origin URLSession Transport, Bounded SSE, and Redacted Failures

**Files:**
- Create: `toolkit/Sources/LocalAgentLLMCloud/CloudHTTPTransport.swift`
- Create: `toolkit/Sources/LocalAgentLLMCloud/CloudRequestAuthorization.swift`
- Create: `toolkit/Sources/LocalAgentLLMCloud/SSEEventParser.swift`
- Create: `toolkit/Sources/LocalAgentLLMCloud/CloudTransportPolicy.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCloud/ProviderEgressPolicy.swift`
- Create: `toolkit/Tests/LocalAgentLLMCloudTests/SSEEventParserTests.swift`
- Create: `toolkit/Tests/LocalAgentLLMCloudTests/CloudHTTPTransportTests.swift`
- Create: `toolkit/Tests/LocalAgentLLMCloudTests/Fixtures/transport/`

**Interfaces:**
- Consumes Task 1 `CloudWireRequest` and produces sealed `AuthorizedCloudHTTPRequest`, tagged `generation | validation | discovery`, plus `CloudHTTPTransport` and live `URLSessionCloudHTTPTransport`.
- Produces a bounded incremental SSE parser preserving event name, ID, retry, and multiline data.
- Produces exact-origin redirect, public-address preflight, response-limit, cancellation, retry-after, and redaction policy without claiming URLSession peer-IP pinning.
- The transport receives a closure-scoped credential separately from the adapter request; adapter DTOs never contain an API key header/value.

- [ ] **Step 1: Write failing SSE and transport-policy tests**

Cover fragmented UTF-8 and CR/LF boundaries, multiline `data`, comment/ping events, empty events, maximum line/event sizes, invalid UTF-8, 200 SSE, JSON error responses, 401/403, 404 model missing, 429 with date/seconds `Retry-After`, 5xx, cancellation, same-origin relative redirect, cross-origin redirect, HTTPS downgrade, embedded credentials, every IPv4/IPv6 reserved class, and hostname resolving to mixed public/private addresses. Authorization tests reject a bare `CloudWireRequest`, generation wire paired with a validation/discovery seal, changed Profile/origin/path/lease/retention identity, user-derived fields in a no-user-data request class, and a public-at-validation answer that changes to private at immediate pre-task preflight.

```swift
@Test func changedToPrivatePreflightAnswerFailsBeforeURLSessionTask() async throws {
    resolver.answers = [
        [.ipv4("1.1.1.1")],
        [.ipv4("127.0.0.1")],
    ]
    await #expect(throws: LLMFailure.self) {
        try await transport.stream(authorizedRequest).collect()
    }
    #expect(protocolStub.transmittedBodyCount == 0)
}
```

The fake starts with an injected globally routable address at Profile validation and changes to loopback at the immediate pre-task check. Separate classification fixtures prove documentation/test-net ranges are reserved; the test transport never sends to any injected address. Do not label this test complete DNS-rebinding prevention: URLSession does not expose a pre-connect peer-pin hook.

- [ ] **Step 2: Run RED**

```bash
swift test --package-path toolkit --filter SSEEventParserTests
swift test --package-path toolkit --filter CloudHTTPTransportTests
```

Expected: fail because tagged policy seals, transport policy, URLSession delegate, and SSE parser are absent.

- [ ] **Step 3: Implement the authorized transport boundary**

```swift
package enum CloudRequestClass: String, Equatable, Sendable {
    case generation
    case discovery
    case accountValidation = "account_validation"
    case modelValidation = "model_validation"
}

package struct GenerationRequestSeal: Equatable, Sendable {
    let generationAuthorizationID: String
    let generationAuthorizationDigest: String
    let disclosureDigest: String
}

package struct NonGenerationRequestSeal: Equatable, Sendable {
    let originApprovalRevision: UInt64
    let presetEncoderID: String
    let requestClass: CloudRequestClass
}

package enum CloudRequestAuthorization: Equatable, Sendable {
    case generation(GenerationRequestSeal)
    case discovery(NonGenerationRequestSeal)
    case validation(NonGenerationRequestSeal)
}

package struct AuthorizedCloudHTTPRequest: Sendable {
    package let wire: CloudWireRequest
    package let authorization: CloudRequestAuthorization
    package let profileID: String
    package let profileRevision: UInt64
    package let origin: EgressOrigin
    package let credentialUseLeaseID: String
    package let credentialUseLeaseDigest: String
    package let credentialGeneration: UInt64
    package let retentionMode: ProviderRetentionMode
    package let retentionApprovalRevision: UInt64?
    package let retentionApprovalDigest: String?
    fileprivate init(
        wire: CloudWireRequest,
        authorization: CloudRequestAuthorization,
        profileID: String,
        profileRevision: UInt64,
        origin: EgressOrigin,
        credentialUseLeaseID: String,
        credentialUseLeaseDigest: String,
        credentialGeneration: UInt64,
        retentionMode: ProviderRetentionMode,
        retentionApprovalRevision: UInt64?,
        retentionApprovalDigest: String?
    ) {
        self.wire = wire
        self.authorization = authorization
        self.profileID = profileID
        self.profileRevision = profileRevision
        self.origin = origin
        self.credentialUseLeaseID = credentialUseLeaseID
        self.credentialUseLeaseDigest = credentialUseLeaseDigest
        self.credentialGeneration = credentialGeneration
        self.retentionMode = retentionMode
        self.retentionApprovalRevision = retentionApprovalRevision
        self.retentionApprovalDigest = retentionApprovalDigest
    }
}

package protocol CloudHTTPTransport: Sendable {
    func stream(_ request: AuthorizedCloudHTTPRequest) async throws -> AsyncThrowingStream<SSEEvent, Error>
    func json(_ request: AuthorizedCloudHTTPRequest) async throws -> Data
}
```

Declare `AuthorizedCloudHTTPRequest` in `ProviderEgressPolicy.swift` beside the policy so only that file can call its fileprivate initializer; `CloudRequestAuthorization.swift` holds the tagged request-class and validation/discovery authorization payload types. `sealGenerationRequest(wire, authorizedTurn:)` binds Profile revision, exact origin, credentialRef/generation, use-lease ID/digest, retention identity, disclosure/authorization digests, adapter ID, and the exact `CloudWireRequest`. `sealValidationRequest(wire, originApprovalRevision:lease:requestClass:)` accepts only `.discovery`, `.accountValidation`, or `.modelValidation`, the matching validation lease, a preset-owned encoder, and its declared metadata-only/fixed-synthetic body. No validation/discovery request fabricates a GenerationDisclosure.

The complete call chain is mandatory:

```text
CloudSemanticTurnValidator.validate(candidate)
  -> ProviderEgressPolicy.authorizeTurn(validated)
  -> CloudProviderSession.encodeStart/encodeResume(authorized)
  -> ProviderEgressPolicy.sealGenerationRequest(wire, authorized)
  -> CloudHTTPTransport.stream(sealed)
```

Discovery and connectivity use `codec.encodeNoUserDataRequest(class)` → `sealValidationRequest` → transport. A bare `CloudWireRequest` has no transport overload.

`URLSessionCloudHTTPTransport` is initialized with `ProviderCredentialStore`. Immediately before constructing the task, it calls `withCredential(for:operation:)`, revalidates the authorization-bound lease, and injects the preset-defined authentication header inside that closure. The secret is never returned to an adapter, persisted in `CloudWireRequest`, captured by the stream, or retained after task creation.

The live transport uses `.ephemeral`, disables cookies and URL cache, sets finite connect/resource timeouts from preset policy, and never uses a background identifier. The shared `ProviderOriginValidating` implementation rejects literal/resolved forbidden or mixed answers at Profile validation; the transport resolves again immediately before task creation and rejects empty, mixed, or changed-to-forbidden answers before handing body bytes to URLSession. Redirect delegate accepts only the same normalized `EgressOrigin` and re-applies the Base URL prefix rule.

URLSession performs its normal hostname/SNI/certificate trust. A server-trust challenge does not reveal or pin the actual peer address, so the implementation must not claim that a challenge-time DNS lookup proves the connected peer. The documented guarantee is exact-origin/path enforcement plus DNS preflight risk reduction—not complete rebinding prevention.

`SSEEventParser` limits a line to 64 KiB, one assembled event to 1 MiB, and buffered undecoded bytes to 2 MiB. HTTP error bodies are capped at 16 KiB, decoded only into known safe error fields, and then discarded. `LLMFailure.redactedDiagnostics` may contain provider semantic ID, status class, request ID after character validation, and retry-after duration; it never contains body, URL query, headers, prompt, model output, or credential.

- [ ] **Step 4: Run GREEN and leak scans**

```bash
swift test --package-path toolkit --filter SSEEventParserTests
swift test --package-path toolkit --filter CloudHTTPTransportTests
rg -n 'print\(|debugPrint\(|String\(data:.*body|allHTTPHeaderFields' toolkit/Sources/LocalAgentLLMCloud
```

Expected: transport fixtures pass with zero real network access; leak scan finds no body/header logging path.

- [ ] **Step 5: Commit**

```bash
git add toolkit/Sources/LocalAgentLLMCloud toolkit/Tests/LocalAgentLLMCloudTests
git commit -m "feat: add authorized cloud streaming transport"
```

---

### Task 7: Implement OpenAI Responses and xAI/Grok Semantics

**Files:**
- Create: `toolkit/Sources/LocalAgentLLMCloud/OpenAIResponsesAdapter.swift`
- Create: `toolkit/Sources/LocalAgentLLMCloud/XAIAdapter.swift`
- Create: `toolkit/Tests/LocalAgentLLMCloudTests/OpenAIResponsesAdapterTests.swift`
- Create: `toolkit/Tests/LocalAgentLLMCloudTests/XAIAdapterTests.swift`
- Create: `toolkit/Tests/LocalAgentLLMCloudTests/Fixtures/openai/`
- Create: `toolkit/Tests/LocalAgentLLMCloudTests/Fixtures/xai/`

**Interfaces:**
- Produces one OpenAI Responses wire codec and two explicit semantic adapters.
- Normalizes text, user-displayable reasoning summary, function-call deltas/batches, usage, finish reason, authentication/rate-limit errors, and terminal enforcement.
- Defaults both providers to `store: false`, resends complete validated semantic history, and retains encrypted/provider-private continuation items only inside the session. Response-ID continuation is allowed only for an explicitly approved stateful Profile revision.
- Maps canonical parameters separately for OpenAI and xAI; xAI reasoning incompatibilities are not applied to OpenAI.

- [ ] **Step 1: Add failing secret-free fixture tests**

For both providers cover request encoding, start/resume, text stream, reasoning-summary stream, tool-call argument fragments, two ordered calls, mixed text/tool calls, tool results, usage, response completion, unknown event, malformed/incomplete terminal, authentication, 429, cancellation, and redacted errors. Under `statelessRequired`, assert exact `store: false`, absence of `previous_response_id`, complete semantic-history resend, and encrypted reasoning continuation where required. Under `providerStateApproved`, assert the exact retention-approval revision before allowing response-ID continuation. Add xAI-specific tests for `reasoning.effort`, its documented default server storage behavior being overridden, and rejection of reasoning-incompatible presence/frequency/stop controls rather than silently sending them.

```swift
@Test func openAIResponsesProducesOneOrderedToolBatch() async throws {
    let events = try await decodeFixture("openai/responses-two-tools.sse")
    #expect(events.completedToolCallIDs == ["call_weather", "call_calendar"])
    #expect(events.terminal == .generationCompleted(.init(
        outcome: .toolCallsReady,
        orderedCallIDs: ["call_weather", "call_calendar"],
        finishReason: .toolCalls
    )))
}
```

- [ ] **Step 2: Run RED**

```bash
swift test --package-path toolkit --filter OpenAIResponsesAdapterTests
swift test --package-path toolkit --filter XAIAdapterTests
```

Expected: fail because the Responses codec/adapters and fixtures do not exist.

- [ ] **Step 3: Implement shared wire parsing and separate semantics**

The shared codec owns `/responses`, `stream: true`, canonical input items, function tools, function-call output items, SSE event decoding, response IDs, and terminal assembly. The semantic adapters own supported parameter IDs, model/catalog constraints, request options, model-list strategy, error mapping, and continuation rules.

```swift
package struct OpenAIResponsesAdapter: CloudProviderAdapter {
    let presetID: ProviderPresetID = .openAI
    let adapterID = "openai.responses"
    let adapterVersion = "1"
}

package struct XAIAdapter: CloudProviderAdapter {
    let presetID: ProviderPresetID = .xAI
    let adapterID = "xai.responses"
    let adapterVersion = "1"
}
```

Only `reasoning.summary`/provider-declared summary events map to `.reasoningSummaryDelta`. Raw reasoning text and encrypted content stay in private continuation. Stateless mode encodes `store: false`, includes the provider-required encrypted content, and uses the validator-bound full semantic history rather than a server response ID. Stateful mode requires `providerStateApproved` and the sealed retention approval. The codec requires one terminal response event; it never infers completion from EOF. Tool call order is first `output_item.added` appearance, arguments must finish as one valid JSON value, and mixed text becomes a preamble when the terminal outcome is `toolCallsReady`.

- [ ] **Step 4: Run GREEN and all transport tests**

```bash
swift test --package-path toolkit --filter OpenAIResponsesAdapterTests
swift test --package-path toolkit --filter XAIAdapterTests
swift test --package-path toolkit --filter CloudHTTPTransportTests
```

Expected: both adapters pass the same wire invariants while retaining separate semantic/parameter behavior.

- [ ] **Step 5: Commit**

```bash
git add toolkit/Sources/LocalAgentLLMCloud/OpenAIResponsesAdapter.swift \
  toolkit/Sources/LocalAgentLLMCloud/XAIAdapter.swift \
  toolkit/Tests/LocalAgentLLMCloudTests
git commit -m "feat: add openai and xai cloud adapters"
```

---

### Task 8: Implement OpenAI Chat Wire Support with DeepSeek and GLM Semantics

**Files:**
- Create: `toolkit/Sources/LocalAgentLLMCloud/OpenAIChatCompletionsCodec.swift`
- Create: `toolkit/Sources/LocalAgentLLMCloud/DeepSeekAdapter.swift`
- Create: `toolkit/Sources/LocalAgentLLMCloud/GLMAdapter.swift`
- Create: `toolkit/Tests/LocalAgentLLMCloudTests/DeepSeekAdapterTests.swift`
- Create: `toolkit/Tests/LocalAgentLLMCloudTests/GLMAdapterTests.swift`
- Create: `toolkit/Tests/LocalAgentLLMCloudTests/Fixtures/deepseek/`
- Create: `toolkit/Tests/LocalAgentLLMCloudTests/Fixtures/glm/`

**Interfaces:**
- Produces one OpenAI Chat Completions SSE codec and separate DeepSeek/GLM semantic state machines.
- Preserves DeepSeek `reasoning_content` across every thinking tool-call continuation that requires it.
- Preserves GLM interleaved/preserved reasoning content and `clear_thinking` policy inside the session.
- Uses only complete client-supplied semantic history; DeepSeek/GLM adapters define no server-side response-ID continuation and therefore satisfy `statelessRequired` without a storage flag.
- Rejects provider/model parameters marked ignored or incompatible by the signed catalog/adapter.

- [ ] **Step 1: Add failing DeepSeek and GLM fixture tests**

Cover fragmented indexed tool calls, multiple calls, text/reasoning deltas, tool-result continuation, usage, `[DONE]`, finish reasons, missing terminal, 400 caused by missing continuation state, auth/rate errors, and cancellation. DeepSeek tests require exact unchanged `reasoning_content` after a tool call. GLM tests require exact interleaved reasoning plus `thinking.type`/`clear_thinking` mapping and never expose preserved reasoning as a public summary.

```swift
@Test func deepSeekToolResumeReturnsReasoningContentUnchanged() async throws {
    let session = try makeDeepSeekSession(fixture: "deepseek/thinking-tool-call.sse")
    _ = try await session.start(startTurn).collect()
    let request = try await session.encodedResume(toolResults: [weatherResult])
    #expect(request.json["messages"][1]["reasoning_content"].string == fixtureReasoning)
}
```

- [ ] **Step 2: Run RED**

```bash
swift test --package-path toolkit --filter DeepSeekAdapterTests
swift test --package-path toolkit --filter GLMAdapterTests
```

Expected: fail because the chat codec and provider continuation states are absent.

- [ ] **Step 3: Implement the shared codec and private continuation states**

`OpenAIChatCompletionsCodec` owns message/tool JSON shapes, `data:` SSE chunks, `choices[].delta`, indexed tool argument assembly, usage, finish reason, and `[DONE]`. It emits internal reasoning deltas to the semantic adapter; it never decides whether those deltas are displayable or must be retained.

DeepSeek maps canonical `reasoning.effort` and its `thinking.type` only when the exact catalog model schema supports them. For a thinking tool turn it stores the complete assistant message—including `reasoning_content`, content, and ordered tool calls—and resends it unchanged before ordered tool results. GLM stores reasoning content when interleaved/preserved thinking is enabled and maps the canonical reasoning mode to `thinking.type`; `clear_thinking` remains a provider-private derived field, not a canonical parameter.

EOF before a valid `finish_reason` plus `[DONE]` is `stream.interrupted`; after any public event it is terminal and not automatically retried.

- [ ] **Step 4: Run GREEN and cross-codec regressions**

```bash
swift test --package-path toolkit --filter DeepSeekAdapterTests
swift test --package-path toolkit --filter GLMAdapterTests
swift test --package-path toolkit --filter OpenAIResponsesAdapterTests
```

Expected: both chat-based providers pass their private continuation rules without changing Responses behavior.

- [ ] **Step 5: Commit**

```bash
git add toolkit/Sources/LocalAgentLLMCloud/OpenAIChatCompletionsCodec.swift \
  toolkit/Sources/LocalAgentLLMCloud/DeepSeekAdapter.swift \
  toolkit/Sources/LocalAgentLLMCloud/GLMAdapter.swift \
  toolkit/Tests/LocalAgentLLMCloudTests
git commit -m "feat: add deepseek and glm cloud adapters"
```

---

### Task 9: Implement Anthropic Messages with Claude and MiniMax Semantics

**Files:**
- Create: `toolkit/Sources/LocalAgentLLMCloud/AnthropicMessagesCodec.swift`
- Create: `toolkit/Sources/LocalAgentLLMCloud/AnthropicMessagesAdapter.swift`
- Create: `toolkit/Sources/LocalAgentLLMCloud/MiniMaxAdapter.swift`
- Create: `toolkit/Tests/LocalAgentLLMCloudTests/AnthropicMessagesAdapterTests.swift`
- Create: `toolkit/Tests/LocalAgentLLMCloudTests/MiniMaxAdapterTests.swift`
- Create: `toolkit/Tests/LocalAgentLLMCloudTests/Fixtures/anthropic/`
- Create: `toolkit/Tests/LocalAgentLLMCloudTests/Fixtures/minimax/`

**Interfaces:**
- Produces one Anthropic Messages event codec and separate Claude/MiniMax semantic adapters.
- Preserves complete thinking/signature blocks for tool continuation without exposing raw thinking.
- Maps Claude thinking deltas to user-displayable summaries only when the sealed request encoded `thinking.display = summarized`; the response has no separate summary marker.
- Treats MiniMax-documented ignored parameters such as `top_k` or `stop_sequences` as unsupported, not accepted no-ops.

- [ ] **Step 1: Add failing Messages fixture tests**

Cover `message_start`, text blocks, `tool_use` blocks, `input_json_delta`, two tool calls, thinking/signature deltas, `thinking.display = summarized` versus `omitted`, `message_delta` usage/stop reason, `message_stop`, ping/unknown events, tool-result continuation, auth/rate/error events, malformed block indexes, incomplete JSON, EOF, and cancellation. Assert an ordinary `thinking_delta` becomes `.reasoningSummaryDelta` only when the exact sealed request selected summarized display; omitted mode exposes no thinking delta and still preserves the signature. MiniMax fixtures must use its own endpoint/preset and parameter schema even when the event shape matches Anthropic.

```swift
@Test func signedThinkingBlockStaysPrivateAndRoundTripsForToolResume() async throws {
    let session = try makeAnthropicSession(fixture: "anthropic/thinking-tool-use.sse")
    let publicEvents = try await session.start(startTurn).collect()
    #expect(!publicEvents.contains(where: { $0.textContains(fixtureThinking) }))
    let resume = try await session.encodedResume(toolResults: [weatherResult])
    #expect(resume.containsUnchangedThinkingSignature(fixtureSignature))
}
```

- [ ] **Step 2: Run RED**

```bash
swift test --package-path toolkit --filter AnthropicMessagesAdapterTests
swift test --package-path toolkit --filter MiniMaxAdapterTests
```

Expected: fail because the Messages codec, provider adapters, and private thinking-block state do not exist.

- [ ] **Step 3: Implement Messages block assembly and provider semantics**

The codec owns `/messages`, `anthropic-version` header support, system/messages/tools/tool_result wire shapes, block indexes, text/tool/thinking/signature assembly, usage, and terminal validation. Authentication header selection remains preset-owned: Anthropic and MiniMax both use `x-api-key`, but their base paths, versions, discovery, models, and semantic schemas remain distinct.

Claude maps supported `reasoning.token_budget` or catalog-declared adaptive thinking controls plus canonical display policy. When the sealed request encoded `thinking.display = summarized`, ordinary thinking blocks/`thinking_delta` contain the requested user-displayable summary and may map to `.reasoningSummaryDelta`; when it encoded `omitted`, no thinking delta is public and the signature remains private. The adapter never looks for a nonexistent response summary tag. MiniMax maps its supported temperature/top-p/max-output/thinking controls, rejects documented ignored fields, and retains the entire assistant block list unchanged in tool-use history.

Both adapters require `message_stop`; stop reason `tool_use` requires one complete ordered batch, while `end_turn` requires none. An unknown event is ignored only if it does not violate block/terminal state; unknown terminal substitution is forbidden.

- [ ] **Step 4: Run GREEN and shared-codec regressions**

```bash
swift test --package-path toolkit --filter AnthropicMessagesAdapterTests
swift test --package-path toolkit --filter MiniMaxAdapterTests
swift test --package-path toolkit --filter DeepSeekAdapterTests
```

Expected: Messages fixtures pass, private thinking/signatures round-trip exactly, and no raw thinking appears in public events.

- [ ] **Step 5: Commit**

```bash
git add toolkit/Sources/LocalAgentLLMCloud/AnthropicMessagesCodec.swift \
  toolkit/Sources/LocalAgentLLMCloud/AnthropicMessagesAdapter.swift \
  toolkit/Sources/LocalAgentLLMCloud/MiniMaxAdapter.swift \
  toolkit/Tests/LocalAgentLLMCloudTests
git commit -m "feat: add anthropic and minimax cloud adapters"
```

---

### Task 10: Implement Gemini Interactions and Thought-Signature Continuation

**Files:**
- Create: `toolkit/Sources/LocalAgentLLMCloud/GeminiInteractionsAdapter.swift`
- Create: `toolkit/Tests/LocalAgentLLMCloudTests/GeminiInteractionsAdapterTests.swift`
- Create: `toolkit/Tests/LocalAgentLLMCloudTests/Fixtures/gemini/`

**Interfaces:**
- Produces the native Gemini Interactions adapter using `POST /interactions` and named SSE events.
- Normalizes `model_output`, `thought_summary`, `function_call`, usage, required-action, and terminal status.
- Encodes `store: false` and stateless full-history/signature continuation by default. It retains/uses an interaction ID only for an explicitly `providerStateApproved` Profile revision.
- Re-specifies tools, system instruction, and generation configuration on each interaction continuation as required by the provider contract.

- [ ] **Step 1: Add failing Gemini fixture tests**

Cover `interaction.created`, status updates, model-output text steps, thought-summary and thought-signature deltas, two function-call steps with argument deltas, required-action terminal, function-result continuation, usage by modality, completed terminal, `error`, failed/cancelled/incomplete/budget-exceeded statuses, unknown step/event, malformed index, missing signature on stateless continuation, auth/rate errors, cancellation, and EOF. Default fixtures assert `store: false`, no `previous_interaction_id`, complete semantic-history resend, and private signature round-trip. A separate approved-state fixture asserts `store: true`, matching retention-approval revision, and use of `previous_interaction_id`.

```swift
@Test func statelessInteractionResendsHistoryAndPrivateThoughtSignature() async throws {
    let session = try makeGeminiSession(fixture: "gemini/two-functions.sse")
    let first = try await session.start(startTurn).collect()
    #expect(first.completedToolCallIDs == ["fn_weather", "fn_calendar"])
    let resume = try await session.encodedResume(toolResults: results)
    #expect(resume.json["store"].bool == false)
    #expect(resume.json["previous_interaction_id"] == nil)
    #expect(resume.containsCompleteValidatedSemanticHistory)
    #expect(!resume.debugDescription.contains("thought_signature_fixture"))
}
```

- [ ] **Step 2: Run RED**

```bash
swift test --package-path toolkit --filter GeminiInteractionsAdapterTests
```

Expected: fail because the Gemini Interactions state machine and fixtures are absent.

- [ ] **Step 3: Implement Gemini-native interaction streaming**

Use `x-goog-api-key` from the credential vault, never a query-string key. Encode `model`, semantic input, `stream: true`, system instruction, function tools, and adapter-validated generation configuration. The parser follows named events:

```text
interaction.created
interaction.status_update
step.start
step.delta
step.stop
interaction.completed
error
```

`model_output/text` becomes `.textDelta`; `thought/thought_summary` becomes `.reasoningSummaryDelta`; `thought_signature` is retained privately; `function_call/arguments_delta` becomes the normalized tool-call stream. `interaction.completed` with status `requires_action` plus complete function calls becomes `toolCallsReady`; status `completed` with no calls becomes `finalResponse`. Status `failed`, `cancelled`, `incomplete`, or `budget_exceeded` maps to the matching terminal failure/cancellation; these are statuses, not SSE event names. `error` is the streaming failure event. The adapter requires exact step indexes, one stop per start, and a provider terminal.

Phase 3 defaults to stateless continuation: encode `store: false`, resend complete validated semantic history, and return all required thought blocks/signatures unchanged. `previous_interaction_id` is forbidden in this mode. Only an exact `providerStateApproved` Profile/grant/capability snapshot may encode `store: true` and use the private prior interaction ID. Both modes re-specify tools, system instruction, and generation configuration; both drop IDs/signatures at session close or host-epoch change.

- [ ] **Step 4: Run GREEN and all adapter fixture suites**

```bash
swift test --package-path toolkit --filter GeminiInteractionsAdapterTests
swift test --package-path toolkit --filter LocalAgentLLMCloudTests
```

Expected: Gemini passes and every provider fixture suite remains secret-free and green.

- [ ] **Step 5: Commit**

```bash
git add toolkit/Sources/LocalAgentLLMCloud/GeminiInteractionsAdapter.swift \
  toolkit/Tests/LocalAgentLLMCloudTests
git commit -m "feat: add gemini interactions adapter"
```

---

### Task 11: Add Signed Cloud Capabilities, Discovery, Validation, and Parameter Resolution

**Files:**
- Create: `toolkit/Sources/LocalAgentLLMCloud/CloudCapabilityCatalog.swift`
- Create: `toolkit/Sources/LocalAgentLLMCloud/CloudCapabilityObservationFactory.swift`
- Create: `toolkit/Sources/LocalAgentLLMCloud/CloudModelDiscoveryService.swift`
- Create: `toolkit/Sources/LocalAgentLLMCloud/ProviderValidationService.swift`
- Create: `toolkit/Sources/LocalAgentLLMCloud/CloudGenerationConfigurationResolver.swift`
- Create: `toolkit/Sources/LocalAgentLLMCloud/Resources/OfficialCloudCapabilityCatalog.v1.json`
- Create: `toolkit/Sources/LocalAgentLLMCloud/Resources/OfficialCloudCapabilityCatalogKeys.v1.json`
- Create: `toolkit/Sources/CloudCapabilityCatalogSigner/main.swift`
- Create: `scripts/sign-cloud-capability-catalog.sh`
- Create: `contracts/cloud-capability-catalog-v1/schema.json`
- Modify: `toolkit/Package.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCore/CapabilityMatrix.swift`
- Create: `toolkit/Tests/LocalAgentLLMCloudTests/CloudCapabilityCatalogTests.swift`
- Create: `toolkit/Tests/LocalAgentLLMCloudTests/CloudModelDiscoveryTests.swift`
- Create: `toolkit/Tests/LocalAgentLLMCloudTests/ProviderValidationServiceTests.swift`
- Create: `toolkit/Tests/LocalAgentLLMCloudTests/CloudGenerationConfigurationResolverTests.swift`
- Create: `contracts/canonical-digest-v1/fixtures/capability-evidence-cloud-v1.json`
- Create: `contracts/canonical-digest-v1/fixtures/capability-observation-cloud-v1.json`
- Create: `contracts/canonical-digest-v1/fixtures/capability-snapshot-cloud-v1.json`
- Create: `contracts/canonical-digest-v1/fixtures/resolved-parameters-cloud-v1.json`
- Modify: `toolkit/Tests/LocalAgentLLMContractsTests/CanonicalDigestTests.swift`
- Modify: `rust-core/tests/contract/canonical_digest_v1.rs`

**Interfaces:**
- Produces a signed maintained cloud capability catalog with rollback/revocation protection and no credential/profile data.
- Produces live model discovery plus manual Model ID entry; model-list membership creates availability evidence only.
- Produces two-stage validation using a generation-pinned validation lease plus Task 6 tagged discovery/validation policy seals; no GenerationDisclosure is fabricated.
- Adds `CapabilityResolutionPolicy.cloud`, which requires compatible adapter, endpoint, and exact model observations; availability cannot supply model semantics.
- Binds Provider retention mode/approval revision into the exact cloud capability subject and hard-limits Phase 3 cloud attachment modalities to unknown.
- Produces immutable semantic plus concrete provider generation configuration and `resolved-parameters:v1` digest.

- [ ] **Step 1: Write failing trust, authority, validation, and parameter tests**

Cover valid/invalid signature, key status, catalog rollback/equal-revision conflict, model revocation, provider/preset mismatch, manual unknown model, live-list availability only, 24-hour default expiry, account probe with no user content, model probe fixed synthetic input/minimal output/stream terminal, tagged discovery/validation seals, rejection of a generation-class seal, validation lease release on every result, invalidation after profile/origin/generation/retention/model/catalog/adapter change, retention/continuation incompatibility, authoritative negative precedence, numeric lowest bound, unsupported/ignored parameters, conditional reasoning conflicts, provider field mapping, and model switch pruning. Assert image/audio/video/document remain unknown even if a catalog/provider fixture claims support, and attachment-bearing input fails before egress.

```swift
@Test func providerListCannotOverclaimToolCallingOrContext() async throws {
    let discovery = try await service.discoverModels(profile: profile, lease: validationLease)
    let listed = try #require(discovery.first { $0.modelID == "fixture-model" })
    #expect(listed.observations.allSatisfy { $0.dimension == .availabilityValidated })
    let snapshot = CapabilityMatrix.resolve(
        observations: listed.observations,
        subject: exactSubject,
        policy: .cloud,
        now: now
    )
    #expect(snapshot.support(for: "tool_calling") == .unknown)
}
```

- [ ] **Step 2: Run RED**

```bash
swift test --package-path toolkit --filter CloudCapabilityCatalogTests
swift test --package-path toolkit --filter CloudModelDiscoveryTests
swift test --package-path toolkit --filter ProviderValidationServiceTests
swift test --package-path toolkit --filter CloudGenerationConfigurationResolverTests
```

Expected: fail because the signed catalog, cloud resolution policy, discovery/validation services, and cloud parameter resolver are absent.

- [ ] **Step 3: Implement catalog, discovery, probes, and resolution**

The catalog signed payload contains schema/key/catalog revision, adapter semantic ID/version range, provider model identity/revision, declared capability observations, canonical parameter schema/defaults, continuation mode, and revocations. Its Ed25519/JCS trust and monotonic acceptance mirror the local catalog but live entirely in `LocalAgentLLMCloud`.

Discovery merges by exact model ID without upgrading authority:

```text
provider list -> transient availability observation
signed catalog -> model semantic observations and parameter schema
manual ID      -> exact identity with unknown semantics
```

Validation sequence is fixed; discovery/account/model probes encode the provider's no-storage option whenever available even when the Profile permits stateful generation, because probes have no continuation:

```text
approved exact origin
  -> acquire validation CredentialUseLease
  -> encode preset-owned discovery/account request with no conversation data
  -> seal as discovery/account_validation and send
  -> optional exact model probe using fixed synthetic text and <= 8 output tokens
  -> seal as model_validation and send
  -> require stream start/text-or-tool/terminal only for exercised scopes
  -> persist generation-keyed observations with expiresAt
  -> release validation lease
```

Task 11 populates Task 2's final version-2 `ProviderProfileValidationState`; it does not change DDL, `record_schema_version`, or enum shape. `ProviderProfileState` remains the only persisted validation projection; no adapter keeps a second readiness flag.

`CapabilityResolutionPolicy.cloud` requires an authoritative/verified positive `adapterCanEncode`, compatible `endpointSupports`, and authoritative signed `modelSupports`; an authoritative negative in any matching dimension wins. The exact subject includes retention mode and approval revision, and the selected continuation mode must be compatible. `availabilityValidated` affects readiness only. Manual unknown models can run routine text only after an exact text/stream probe and still cannot satisfy unproven tool, structured, reasoning, or context requirements. In Phase 3, `imageInput`, `audioInput`, `videoInput`, and `documentInput` are always unknown and `CloudSemanticTurnValidator` rejects an attachment-bearing cloud route with `capability.cloud_attachment_path_unavailable` before authorization; there is no attachment byte/upload implementation in this plan.

The parameter resolver layers catalog defaults → target defaults → host overrides, invokes `LLMParameterSystem`, applies the exact adapter/model schema, and returns:

```swift
package struct ResolvedCloudGenerationConfiguration: Equatable, Sendable {
    let semantic: GenerationConfiguration
    let providerFields: CanonicalJSONValue
    let digest: String
}
```

Provider field names stay package-internal. Documented ignored fields are absent from supported schema and therefore fail before request encoding.

- [ ] **Step 4: Run GREEN and capability/parameter regressions**

```bash
swift test --package-path toolkit --filter CloudCapabilityCatalogTests
swift test --package-path toolkit --filter CloudModelDiscoveryTests
swift test --package-path toolkit --filter ProviderValidationServiceTests
swift test --package-path toolkit --filter CloudGenerationConfigurationResolverTests
swift test --package-path toolkit --filter CapabilityMatrixTests
swift test --package-path toolkit --filter LLMParameterSystemTests
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml \
  --test contract canonical_digest_v1 -- --nocapture
```

Expected: signed semantics, live availability, probes, manual IDs, retention identity, and tagged non-generation authorization retain distinct authority; attachment modalities stay unknown; all parameters are capability-driven and adapter-validated; Swift and Rust reproduce identical cloud capability/parameter fixture bytes and digests without Rust parsing their provider meaning.

- [ ] **Step 5: Commit**

```bash
git add toolkit/Package.swift toolkit/Sources/LocalAgentLLMCloud \
  toolkit/Sources/LocalAgentLLMCore/CapabilityMatrix.swift \
  toolkit/Sources/CloudCapabilityCatalogSigner toolkit/Tests \
  scripts/sign-cloud-capability-catalog.sh contracts/cloud-capability-catalog-v1 \
  contracts/canonical-digest-v1/fixtures rust-core/tests/contract/canonical_digest_v1.rs
git commit -m "feat: validate cloud model capabilities"
```

---

### Task 12: Add the Direct Swift Cloud Runtime, Integration Gates, and Evidence

**Files:**
- Create: `toolkit/Sources/LocalAgentLLMCloud/PreparedCloudSession.swift`
- Create: `toolkit/Sources/LocalAgentLLMCloud/CloudLLMRuntime.swift`
- Create: `toolkit/Sources/LocalAgentLLMCloud/CloudLLMSubsystem.swift`
- Create: `toolkit/Tests/LocalAgentLLMCloudTests/PreparedCloudSessionTests.swift`
- Create: `toolkit/Tests/LocalAgentLLMCloudTests/CloudLLMRuntimeTests.swift`
- Create: `toolkit/Tests/LocalAgentLLMCloudTests/CloudProductPathIntegrationTests.swift`
- Create: `rust-core/tests/lint/llm_phase_three_architecture.rs`
- Modify: `rust-core/tests/lint.rs`
- Create: `scripts/run-llm-phase-3-contracts.sh`
- Create: `scripts/run-llm-phase-3-live-smoke.sh`
- Modify: `docs/superpowers/specs/2026-07-10-swift-llm-system-design.md`
- Create: `docs/model-providers/cloud-provider-adapter-architecture.md`

**Interfaces:**
- Produces immutable, persisted, sanitized `PreparedCloudSession` bound to exact target/binding/profile/origin/model/generation/lease/capability/parameters/egress/epoch identity.
- Produces `CloudLLMRuntime`, a one-session/one-generation actor with start, resume, cancel, close, old-epoch recovery, and route-switch unload ordering.
- Produces one deterministic Phase 3 verification command with no network or key.
- Produces optional live smoke that accepts only an existing Keychain `credentialRef` plus non-secret profile/model IDs.
- Freezes Phase 4 handoff: no production Rust V2 run starts, but all Swift-private session/credential/egress identity required by the future host registration exists.

- [ ] **Step 1: Write failing prepared-session, runtime, integration, and architecture tests**

Prepared-session tests cover random 256-bit session IDs, exact target/profile/binding/generation/retention/lease/digest/epoch persistence, no secret/request/path fields, reopen, close tombstone, and old-epoch cleanup. Runtime tests cover one session/generation, local-unload-before-cloud-open, mismatched message/tool-schema/source/attachment/tool-result/continuation disclosure, attachment-path rejection, resume scope expansion, credential generation and retention recheck, stateless versus approved-state provider continuation, tagged wire sealing, rejection of bare/cross-class wire requests, text/final, mixed text/tool batch, one batched resume, cancel-once, close/release lease, stream interruption after output, bounded retry before output, no fallback, and restart interruption.

The integration test executes:

```text
publish profile revision
  -> store fake key through CredentialVault
  -> approve exact origin
  -> assert stateless retention and no provider-state approval
  -> discover/validate fixture model through tagged validation seals/lease
  -> create exact cloud LLMTargetRevision and active AgentHostConfiguration
  -> prepare immutable cloud session under preparation lease
  -> build complete semantic candidate and validate fixture start disclosure
  -> authorize, encode, generation-seal, then send
  -> receive two ordered tool calls
  -> label results, rebuild complete semantic history, validate disclosure
  -> require incremental approval, encode, generation-seal, resume once
  -> receive final text/usage/terminal
  -> close session, release lease, rotate key, require revalidation
```

Architecture lint rejects Provider/Profile/Base URL/credential/key/adapter symbols in new Rust V2 code, any Rust allowlist growth, any C++ cloud symbol, any API-key-bearing Codable/public DTO, direct `URLSession` use outside `CloudHTTPTransport`, any transport overload accepting bare `CloudWireRequest`, public/package construction of `ValidatedCloudGenerationTurn` or `AuthorizedCloudHTTPRequest`, direct Keychain use outside `SecurityCredentialVault`, adapters without fixture suites, and release presets whose adapter/catalog fixture gate is incomplete.

- [ ] **Step 2: Run RED**

```bash
swift test --package-path toolkit --filter PreparedCloudSessionTests
swift test --package-path toolkit --filter CloudLLMRuntimeTests
swift test --package-path toolkit --filter CloudProductPathIntegrationTests
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml \
  --test lint llm_phase_three_architecture -- --nocapture
```

Expected: fail because the prepared runtime, integration runner, and Phase 3 architecture lint are absent.

- [ ] **Step 3: Implement prepared cloud sessions and the one-session runtime**

```swift
public struct PreparedCloudSession: Codable, Equatable, Sendable {
    public let sessionID: String
    public let preparationID: String
    public let proposedRunID: String
    public let targetID: LLMTargetID
    public let targetRevision: UInt64
    public let bindingID: String
    public let bindingRevision: UInt64
    public let bindingHash: String
    public let requirementsHash: String
    public let providerProfileID: String
    public let providerProfileRevision: UInt64
    public let origin: EgressOrigin
    public let credentialRef: String
    public let credentialGeneration: UInt64
    public let retentionMode: ProviderRetentionMode
    public let retentionApprovalRevision: UInt64?
    public let retentionApprovalDigest: String?
    public let credentialUseLeaseID: String
    public let credentialUseLeaseDigest: String
    public let modelID: String
    public let capabilitySnapshotDigest: String
    public let resolvedParametersDigest: String
    public let initialDisclosureDigest: String
    public let scopeGrantID: String
    public let generationAuthorizationID: String
    public let opaqueEgressSubjectDigest: String
    public let egressAttestationDigest: String
    public let hostProcessEpoch: HostProcessEpoch
    public let adapterID: String
    public let adapterVersion: String
}
```

The struct has no secret, provider request/response, raw reasoning, response body, absolute local path, or live handle pointer. Its SQLite row stores only sanitized JSON plus indexed identity/CAS fields.

`prepareSession(context:hostConfiguration:target:)` requires an active exact binding, active non-archived Profile revision, approved exact origin, exact retention mode/approval revision, current generation-keyed validation, sufficient retention-bound cloud capability snapshot, valid parameter resolution, a validator-sealed initial turn, initial disclosure authorization, and one preparation use lease. It persists the snapshot before creating a provider session. Direct Phase 3 tests supply preparation/proposed-run IDs; Phase 4 maps the Rust preview and registration to the same fields without re-resolving target, capability, parameters, credential generation, retention, or egress.

Phase 3 computes and persists the complete main-design `EgressSubject` and `EgressAttestation` identities, but does not call the current Rust Phase 1 `commit_start` or reinterpret its simplified attestation shape. Phase 4 first aligns Rust public recomputation/registration with these canonical documents, then makes the exact prepared session runnable. Until then `host_slot_v2` remains non-runnable and the legacy production route is unchanged.

`startGeneration`/`resumeGeneration` first use `CloudAttachmentIdentityResolving` and construct `CloudGenerationTurnCandidate` from the exact messages, canonical tool schema, source-revision document, authoritative attachment identities, complete tool-result batch, and provider-required normalized semantic history supplied by the Phase 3 fixture authority or future Phase 4 command. Opaque response IDs/thinking/signatures remain separate and never enter this digest. `CloudSemanticTurnValidator` recomputes both disclosure digests and returns `ValidatedCloudGenerationTurn`; attachment-bearing candidates then fail the Phase 3 capability gate before egress. The runtime rechecks exact retention/capability/lease state and obtains `AuthorizedCloudGenerationTurn`; the adapter encodes an unsendable wire request; policy seals it as `.generation`; only then does transport resolve Keychain and create URLSession. Discovery/account/model probes follow their tagged no-user-data sealing path. Runtime retry is allowed only before any reasoning summary, text, tool call, or usage event and preserves the same validated semantic turn, authorization, and sealed retention mode. Cancel and close are idempotent; close waits for task completion, drops private continuation, marks the lease closing, persists the session tombstone, then removes the lease. A new epoch closes old snapshots/leases before model discovery or preparation becomes available.

`CloudLLMSubsystem.bootstrap` order is:

```text
open/migrate ProviderProfileStore
  -> reconcile credential operations/tombstones
  -> remove old-epoch validation/preparation leases and cloud sessions
  -> load and verify signed cloud catalog
  -> build preset/adapter registry and exact-origin transport
  -> expose discovery/validation/runtime
```

Before a cloud session opens its first task, it invokes an injected `LocalRouteUnloading.unloadForCloudRouteSwitch()` and awaits success. `LocalAgentLLMCloud` does not import `LocalAgentLLMLocal`; App composition supplies the adapter in Phase 5.

- [ ] **Step 4: Add the deterministic and optional live runners**

`scripts/run-llm-phase-3-contracts.sh` runs, in order:

```bash
scripts/run-llm-phase-2-contracts.sh
CARGO_NET_OFFLINE=true cargo test --manifest-path rust-core/Cargo.toml \
  --test lint llm_phase_three_architecture -- --nocapture
swift test --package-path toolkit
xcodebuild test -project apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  -only-testing:LocalAgentAppTests/CloudCredentialKeychainTests
```

The script unsets only known provider credential variables (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`, `XAI_API_KEY`, `DEEPSEEK_API_KEY`, `MINIMAX_API_KEY`, and `ZHIPUAI_API_KEY`) before launching tests; it does not reject unrelated CI credentials. Fixture transport is mandatory, the deterministic runner never invokes the live-smoke script, and network tools remain disallowed by the test harness.

`scripts/run-llm-phase-3-live-smoke.sh` requires:

```text
LOCAL_AGENT_CLOUD_SMOKE_PROVIDER_PROFILE_ID
LOCAL_AGENT_CLOUD_SMOKE_PROVIDER_PROFILE_REVISION
LOCAL_AGENT_CLOUD_SMOKE_MODEL_ID
LOCAL_AGENT_CLOUD_SMOKE_CREDENTIAL_REF
```

It rejects any key/token/secret environment variable, reads the already provisioned generation through `ProviderCredentialStore`, sends one fixed synthetic prompt with no user data, requires text plus a valid terminal, closes, and never records the response. It is manual and cannot substitute for fixture CI.

Update the main design with a dated Phase 3 evidence section and explicitly retain Phase 4 host bridge plus Phase 5 UI/migration/legacy removal as unfinished.

- [ ] **Step 5: Run the final pre-commit gate**

```bash
scripts/run-llm-phase-3-contracts.sh
git diff --check
git status --short
```

Expected: Phase 1/2 regressions, C++, Rust lints, all Swift fixture/runtime tests, and the hosted Keychain contract pass; only Task 12 files are uncommitted and no network credential was required.

- [ ] **Step 6: Commit**

```bash
git add toolkit/Sources/LocalAgentLLMCloud toolkit/Tests/LocalAgentLLMCloudTests \
  apps/LocalAgentApp/LocalAgentAppTests/Integration/CloudCredentialKeychainTests.swift \
  apps/LocalAgentApp/LocalAgentApp.xcodeproj/project.pbxproj \
  rust-core/tests/lint.rs rust-core/tests/lint/llm_phase_three_architecture.rs \
  scripts/run-llm-phase-3-contracts.sh scripts/run-llm-phase-3-live-smoke.sh \
  docs/superpowers/specs/2026-07-10-swift-llm-system-design.md \
  docs/model-providers/cloud-provider-adapter-architecture.md
git commit -m "test: lock the llm phase three cloud path"
```

- [ ] **Step 7: Re-run after commit**

```bash
scripts/run-llm-phase-3-contracts.sh
git status --short
```

Expected: exit code 0 and an empty worktree.

## Phase 3 Completion Gate

Phase 3 is complete only when all twelve tasks are checked and the unified runner passes from a clean worktree. Completion means the cloud subsystem is independently usable and fixture-testable from Swift; it does not mean a Rust `host_slot_v2` Agent run is executable or that Provider UI is shipped.

The closure gate requires all of these to be mechanically proven:

- exactly seven provider presets exist, each with an explicit semantic adapter and complete secret-free fixture suite;
- shared wire codecs do not merge provider semantic state, parameter support, continuation, validation, or error rules;
- API keys exist only in generation-specific ThisDeviceOnly Keychain items, and every request resolves through a live `CredentialUseLease`;
- creation/rotation/deletion sagas, use-lease races, shared-slot references, tombstones, and every injected crash boundary converge without scanning, exposing, adopting, or relabeling untracked key material;
- the complete Phase 3 SQLite schema is created atomically at v2, later Tasks perform no DDL/payload-shape mutation, and old/future/unknown records follow the specified reopen/fail-closed rules;
- revision archival cannot delete a credential slot, while logical-profile deletion cannot pass active reference/lease checks;
- every start/resume candidate is rehashed from complete semantic input into a non-forgeable validated turn before approval or adapter encoding;
- every validation/start/resume request is tagged and policy-sealed for its exact request class before credential resolution or task creation; transport has no bare-wire API;
- stateless/no-storage is the default; provider state requires an immutable Profile revision plus explicit approval bound into egress and capability snapshots;
- approval summaries and audit rows contain no raw user/tool data, and unknown labels conservatively expand scope;
- transport enforces HTTPS, exact origin/path prefix, public-address preflight, redirect restrictions, bounded SSE/error parsing, cancellation, and redaction while making no peer-IP-pinning claim;
- provider-private reasoning/signatures/response IDs never cross the normalized backend event contract or enter persistence;
- every tool turn ends in one complete ordered batch, mixed text is a preamble, and one ordered result batch resumes the provider session;
- discovery, signed catalog semantics, probe evidence, capability authority/expiry, and manual unknown IDs remain distinct;
- cloud attachment modalities remain unknown and attachment-bearing turns fail before egress;
- canonical parameters are intersected with the exact adapter/model schema and provider-documented ignored fields fail before encoding;
- `PreparedCloudSession` binds exact target, binding, Profile revision, origin, retention approval, model, generation lease, capability, parameters, disclosure/grant/authorization, adapter, and App epoch without a secret;
- one cloud session/generation is active, route switching unloads local RAM first, cancellation/close are idempotent, and restart drops all private continuation/old-epoch leases;
- Rust/C++ boundaries do not grow, the legacy production route stays runnable, and `host_slot_v2` stays non-runnable until Phase 4;
- deterministic CI performs no live provider request and optional smoke accepts only an existing Keychain credential reference.

## Phase 4 Handoff

Phase 4 must consume, not redefine:

- `GenerationDisclosure`, `NormalizedToolResult`, and `LLMBackendEvent`;
- complete `CloudGenerationTurnCandidate` inputs and the
  `ValidatedCloudGenerationTurn` factory boundary;
- start/resume command payloads carrying exact canonical messages, tool schema,
  source/attachment revisions, complete tool-result batch, and provider-required
  normalized semantic history, while opaque provider continuation stays Swift-only;
- exact immutable `PreparedCloudSession` identity and its credential-use-lease digest;
- retention-bound capability/parameter/egress attestation digests and expiration;
- tagged generation/validation/discovery request sealing and the no-bare-wire
  transport boundary;
- `CloudLLMRuntime.startGeneration`, `resumeGeneration`, `cancel`, and `closeSession` semantics;
- provider-private in-memory continuation and old-epoch interruption;
- one-session/one-generation and no-fallback rules.

Phase 4 adds the Rust command outbox, Swift command ledger, session handles, acknowledgements, event envelopes/receipts, watchdogs, prepared-session registration/cleanup, and runnable V2 worker. It does not move Provider Profile, origin, credential generation, API format, model discovery, capability resolution, or parameter mapping into Rust.
