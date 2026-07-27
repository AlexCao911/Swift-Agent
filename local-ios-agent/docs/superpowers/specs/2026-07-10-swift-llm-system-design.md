# Swift-Owned LLM System Design

**Status:** Revised after architecture review; pending final approval

**Date:** 2026-07-10

**Last reviewed:** 2026-07-11

**Target:** iPhone and iPad

## Summary

The product needs one coherent LLM subsystem that can use either a downloaded
local model or a configured cloud provider without leaking model-management or
provider-specific concepts into the Rust agent kernel.

The ownership rule is deliberately strict:

```text
Rust
  owns only the agent kernel and a provider-neutral LLM client port

Swift
  owns the complete product LLM system

C++
  owns only local model inference execution
```

Swift therefore owns model selection, local model installation, cloud provider
profiles, credentials, capability and parameter metadata, egress approval,
backend routing, runtime configuration, and the lifecycle of each LLM session.
Rust produces model-neutral agent requests and consumes normalized stream
events. C++ loads a validated local model configuration, generates, streams,
cancels, and unloads.

The first release supports one active agent run globally. It does not run
multiple agents or multiple generations concurrently.

## Goals

- Compose each Agent Profile revision with one explicit, revision-pinned local
  or cloud LLM target in the Swift host layer.
- Keep all LLM product state and behavior in Swift.
- Keep provider wire formats and local engine details out of Rust.
- Keep model download and file lifecycle details out of C++.
- Support a curated local model catalog with download, verification,
  pause/resume, deletion, and disk-space management.
- Support OpenAI, Claude, Gemini, xAI/Grok, DeepSeek, MiniMax, and GLM through
  Swift provider adapters.
- Store cloud API keys only in Keychain.
- Normalize streaming, tool calls, usage, cancellation, and failures across
  local and cloud backends.
- Expose a capability-aware parameter system for local sampling controls and
  provider-specific reasoning controls.
- Make capability and parameter compatibility explicit before a run starts.

## Non-Goals

- Arbitrary local model URLs, user-imported files, or Hugging Face repositories.
- Runtime-downloaded native inference engines, dylibs, or frameworks.
- Concurrent agent runs or concurrent LLM generations.
- Automatic local-to-cloud or cloud-to-local fallback.
- Resuming an in-progress generation after the app process is terminated.
- Persisting raw provider reasoning state, thought signatures, or API payloads.
- Giving Rust ownership of Provider Profiles, model catalogs, installations,
  concrete model bindings, or inference backend selection. Rust retains only a
  portable LLM slot and opaque host-binding cross-links.
- Giving C++ ownership of downloads, Provider Profiles, API keys, or Agent
  Profiles.

## Confirmed Product Decisions

1. The target is iOS and iPadOS, with one design shared by iPhone and iPad.
2. Local models come only from the official curated catalog in v1.
3. Multiple installed local models may remain on disk.
4. At most one local model may be loaded in RAM.
5. A model enters RAM only when it is about to be used.
6. Switching local models unloads the old model from RAM but does not delete it.
7. Switching to cloud inference unloads any local model from RAM.
8. Only one agent run may be active globally.
9. Each Agent Profile revision has an explicit LLM target revision through
   Swift `AgentHostConfiguration`.
10. The product does not silently fall back to another model.
11. Cloud model discovery combines the provider API, a maintained capability
    catalog, and manual Model ID entry.
12. Cloud egress origin is approved once per Provider Profile; high-sensitivity
    input requires an additional per-run approval.
13. Generation parameters use model defaults plus Agent Profile overrides.

## Architecture Review Resolution

The implementation is blocked unless all review corrections below remain true:

| Review concern | Required resolution |
| --- | --- |
| Rust was asked to validate Provider Profile and origin semantics it does not own | Swift validates all provider/egress semantics and returns a versioned opaque egress attestation whose public binding fields alone are checked by Rust |
| Cross-language digests had no canonicalization protocol | One domain-separated `CanonicalDigestV1` based on RFC 8785 JSON defines schemas, field inclusion, ordering, Unicode, numbers, and shared golden fixtures |
| Credential replacement could silently change the account used by an active run | Every key replacement advances a slot-owned generation used by validation, grants, sessions, attestations, and snapshots; generation use leases block rotation across any active key user |
| Opaque session handles and sequence-only event deduplication allowed ABA/conflicting duplicates | Random epoch-bound non-reusable handles plus canonical event envelopes and sequence/digest conflict detection |
| Command acceptance was confused with backend stop/close completion | Separate command acknowledgement, backend-start, generation-terminal, and session-closed signals with independent watchdogs |
| Legacy and V2 execution paths did not share an authoritative single-run gate | One durable Rust global run lease covers preparation, legacy start, V2 commit, restart recovery, and terminal release |
| Disclosure metadata could not explain an incremental approval safely | Rust supplies a grant-neutral enum/count/size summary and Swift adds a private grant-delta summary; neither contains raw contact, file, calendar, memory, or tool-result data |
| Egress approval was not bound to actual generation content | Freeze and digest the initial model input, attach a `GenerationDisclosure` to every generation turn, and require incremental approval before an affected remote request |
| Replacing `ModelBinding` before switching the production resolver would break legacy runs | Introduce versioned `LLMSlotV2` alongside legacy bindings, switch execution in Phase 4, and remove the legacy path only in Phase 5 |
| Rust-to-Swift commands could be lost or replayed as duplicate provider requests | Transactional Rust outbox, sequenced command envelopes, synchronous copy receipts, asynchronous acknowledgements, Swift deduplication, and bounded acknowledgement timeouts |
| A bare `completed` event could not distinguish final output from a tool-call turn | Structured generation terminal outcomes, complete ordered tool-call batches, and explicit mixed text/tool-call semantics |
| Profile publication did not persist the staged host-binding identity | Commit the exact binding ID, revision, and hash into the Rust opaque cross-link and require exact-match activation/reconciliation |
| A fixed two-minute preparation token could expire during approval or local loading | Use a digest-preserving rotating preparation lease, then keep the ready host attestation short-lived |
| Archiving one Provider Profile revision could delete a key shared by newer revisions | Separate revision archival from logical-profile deletion and delete a credential slot only after reference and active-session checks |
| A session created before `commit_start` had no durable close command or admissible close receipt | Register every prepared session, abort through a preparation-scoped cleanup outbox, and release the global lease only after an exact idempotent prepared-session-close receipt |
| Credential generation had per-profile copies and rotation could race a preparation | Make `CredentialSlotState` the sole generation authority; every key user holds a durable generation lease and rotation first CASes an unused active slot to `rotating` |
| Token, capability-evidence, and audit digests were used without registered schemas | Register every cross-boundary, cross-store, reconciliation, identity, or policy digest; reserve explicitly named private hashes for non-authoritative Swift diagnostics only |
| Terminal/stale event return values did not define sequence consumption | Allocate sequence only at Swift-to-Rust handoff and define, for every result, whether the sequence and receipt are committed and whether the same envelope is retried |
| Synchronous Rust-Swift call under the runtime mutex | Resumable Rust worker, lock-free outbound host callback, independent event FFI, bounded backpressure, and explicit cancellation races |
| Swift needs resolved requirements before it can prepare | Mandatory preview -> Swift prepare/attest -> Rust commit protocol with a digest-bound rotating lease and short-lived ready attestation |
| Rust and Swift persist related state in separate stores | Portable Rust LLM slots, Swift host bindings, idempotent profile/package/run sagas, and startup reconciliation |
| Provider continuation is memory-only across restart | Host-process epochs, pre-replay interruption of every LLM-dependent run, invalidated pending actions, and host tool effect idempotency |
| GGUF/custom prompt formatting is model-format-specific | Swift selects canonical messages/tools/template; C++ performs engine/model-format rendering; Swift parses normalized tool calls |
| Capability claims had insufficient provenance | Dimensioned observations with exact target/model scope, authority, revision, time, expiry, and invalidation rules |

## Architectural Boundary

```text
Swift App / Agent Host
  |
  | requests preview
  v
Rust Agent Kernel
  |-- acquires the route-neutral preparing global run lease
  |-- resolves portable LLMSlot and AgentLLMRequirements
  |-- returns preparation token and requirements
  |
  v
Swift LLM System
  |-- resolves AgentHostConfiguration and LLMTarget
  |-- validates capability, parameters, readiness, and egress
  |-- returns opaque LLMSessionHandle and host attestation
  |
  v
Rust Agent Kernel
  |-- promotes the global run lease and commits run snapshot/worker state
  |-- emits host LLM commands without holding runtime mutex
  |
  |-- agent loop
  |-- context assembly
  |-- memory
  |-- tool orchestration
  |-- run lifecycle
  |-- provider-neutral LLMClient port
  |
  | command vtable        ^ independent event submission
  v                       |
Swift LLMRuntimeCoordinator
  |                         |
  | local                   | cloud
  v                         v
Swift Local Adapter       Swift Provider Adapter
  |                         |
  v                         v
C++ Engine               URLSession
```

### Rust Owns

- Agent loop and run state.
- Context, memory, tool schemas, tool execution orchestration, and tool results.
- Provider-neutral `AgentLLMInput`, `LLMStreamEvent`, and `AgentLLMFailure`
  contracts.
- A provider-neutral cancellation request.
- Portable `LLMSlot`, `AgentLLMRequirements`, and requirement hashes, including
  required tool calling, input modalities, minimum context size, and streaming.
- Preparation tokens, the two-phase run protocol, and opaque host-binding
  cross-links.
- The authoritative durable global Agent run lease shared by every execution
  route.
- The resumable agent worker and durable run transitions.
- Test mocks for the abstract LLM client port.

Rust does not own or interpret:

```text
ProviderProfile
API key or CredentialRef
Base URL
Model ID selection
local model path
model installation state
provider adapter kind
local engine ID
generation parameter mapping
provider reasoning state
LLM target resolution
```

### Swift Owns

- The complete LLM control plane and product data model.
- Agent-to-LLM composition through `AgentHostConfiguration`.
- Host-binding saga state, idempotency keys, and reconciliation.
- Official local and cloud model catalogs.
- Provider Profiles and model discovery.
- Capability Matrix and parameter schemas.
- Local downloads, installation records, file verification, and disk policy.
- Keychain storage and credential resolution.
- Egress disclosure, approval, allowlisting, and audit metadata.
- Local RAM lifecycle and cloud session lifecycle.
- Provider request encoding and streaming response decoding.
- Provider-specific continuation state for thinking and tool loops.
- Normalization of stream events, tool calls, usage, and errors.
- Sanitized LLM run snapshots and LLM diagnostics.
- An advisory in-process run reservation for UI responsiveness; Rust remains
  authoritative.

### C++ Owns

- A registry of inference engines compiled and signed with the app.
- Engine capability reporting.
- Local model config validation.
- Model-format-specific chat-template rendering.
- Local model loading and unloading.
- Generation start, token/structured-delta streaming, cancellation, and release.
- Local usage metadata where the engine can provide it.

C++ does not own:

```text
model catalog synchronization
downloads or resume data
checksums or catalog trust
installation records
disk-space policy
Provider Profiles
cloud HTTP
API keys
Agent Profiles
tool execution
```

## Proposed Swift Module Layout

The LLM system should be split into focused Swift package targets rather than
placed directly in the app target.

```text
local-ios-agent/toolkit/Sources/
  LocalAgentLLMContracts/
    CanonicalDigest.swift
    LLMInput.swift
    LLMStreamEvent.swift
    LLMCapabilities.swift
    LLMParameters.swift
    LLMFailure.swift

  LocalAgentLLMCore/
    AgentHostConfiguration.swift
    AgentHostBindingSaga.swift
    LLMTarget.swift
    CapabilityMatrix.swift
    CapabilityObservation.swift
    LLMParameterSystem.swift
    LLMRuntimeCoordinator.swift
    LLMSessionRegistry.swift
    LLMBridgeActor.swift
    LLMStore.swift

  LocalAgentLLMLocal/
    OfficialModelCatalog.swift
    LocalModelManifest.swift
    ModelDownloadCoordinator.swift
    LocalModelStore.swift
    LocalDiskPolicy.swift
    LocalModelRuntime.swift
    CppInferenceAdapter.swift

  LocalAgentLLMCloud/
    ProviderPreset.swift
    ProviderProfile.swift
    ProviderProfileStore.swift
    ProviderCredentialStore.swift
    ProviderValidationService.swift
    ProviderEgressPolicy.swift
    CloudProviderAdapter.swift
    OpenAIResponsesAdapter.swift
    AnthropicMessagesAdapter.swift
    GeminiAdapter.swift
    XAIAdapter.swift
    DeepSeekAdapter.swift
    MiniMaxAdapter.swift
    GLMAdapter.swift

local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Models/
  ModelCenterView.swift
  ModelCenterViewModel.swift
  LocalModelDetailView.swift
  ProviderProfileEditor.swift
  ModelParameterEditor.swift
```

Concrete filenames may be refined in implementation plans, but the module
boundaries are architectural requirements.

## Canonical Cross-Language Digests

Ordinary Swift `JSONEncoder` output and Rust `serde_json` output remain valid
transport encodings, but they are never hashed directly. Every structured
digest in the authoritative scope defined below uses `CanonicalDigestV1`.

```text
CanonicalDigestV1(domain, typed digest document)
  canonicalBytes = RFC 8785 JCS(typed digest document)
  preimage = UTF8(domain) || 0x00 || canonicalBytes
  digest = SHA-256(preimage), serialized as 64 lowercase hex characters
```

The typed digest document has a required string `schema_version: "1"` and
stable snake-case field names independent of Swift `CodingKeys` or Rust serde
defaults. Registered domains are lowercase ASCII and cannot contain NUL.
Canonicalization rules are:

- Input is I-JSON: duplicate object names and invalid Unicode such as lone
  surrogates are rejected.
- Object names are sorted recursively as unsigned UTF-16 code units; escaping
  and finite binary64 number serialization follow RFC 8785 exactly.
- Text is valid UTF-8 and is not Unicode-normalized. Canonically equivalent but
  scalar-distinct strings intentionally produce different digests.
- Semantic sets are encoded as arrays sorted lexicographically by each
  element's canonical UTF-8 bytes. Semantic arrays preserve their declared
  order.
- Optional fields are omitted. `null` is forbidden unless a digest schema
  explicitly declares a tagged `null` case; missing and null are never treated
  as equivalent.
- `UInt64`, counters, byte sizes, and other integers that may exceed the JSON
  safe-integer range are decimal strings with no leading zeros. Timestamps are
  UTC RFC 3339 strings with exactly millisecond precision. Binary values are
  unpadded base64url strings.
- NaN and infinities are rejected. Negative zero canonicalizes as RFC 8785
  requires.

Registered V1 domains and coverage are:

| Domain | Required digest coverage | Excluded |
| --- | --- | --- |
| `agent-host-binding:v1` | Binding/profile/slot/target identities, requirements hash, and parameter overrides | Credential, Provider payload, resolved local path |
| `agent-requirements:v1` | Slot ID, capability/modality/context/streaming/tool requirements | Host target and Provider fields |
| `conversation-frame:v1` | Frame identity, revision, ordered entries, and referenced blobs | UI-only state |
| `execution-plan:v1` | Ordered Agent plan steps and policy-relevant metadata | Runtime timestamps |
| `tool-schema:v1` | Ordered tool identities plus complete input/output/data-label schemas | Tool implementation pointers |
| `source-revisions:v1` | Ordered frame, memory, context, and attachment identity/revision tuples | Source content |
| `legacy-profile-source:v1` | Source Profile ID/revision, historical record schema version, and complete immutable legacy source record | Migration attempt, selected target, host binding, and migration outcome |
| `agent-input:v1` | Complete canonical semantic generation request: ordered messages/history, complete canonical tool schema, full normalized tool-result batch, provider-required semantic continuation history, attachment identities/revisions, and memory/context revisions | Provider wire encoding, credential, and diagnostics |
| `generation-disclosure:v1` | Turn ID, content/source digests, sorted data classes, sensitivity, and grant-neutral safe source summary | Raw source content and grant identity |
| `capability-attestation:v1` | Generic Agent capability values plus contributing observation digests/expiry | Provider-specific claims and evidence body |
| `resolved-parameters:v1` | Sorted canonical semantic parameter IDs and resolved non-secret values | Provider/C++ field names |
| `preparation-token:v1` | Preparation ID, proposed run ID, token generation, and random token bytes encoded as unpadded base64url | Bound preview fields, which are covered by `preparation-binding:v1` |
| `preparation-binding:v1` | Preparation/run IDs, bound digest set, token generation, host epoch, and expiry | Raw token value |
| `saga-token:v1` | Operation kind, stable operation ID, token generation, and random token bytes encoded as unpadded base64url | Staged host-binding details |
| `host-binding-staging-receipt:v1` | Operation/token digest, profile/slot/requirements, and binding ID/revision/hash | Swift target details |
| `host-command-payload:v1` | Complete typed command payload | Command delivery metadata |
| `host-command-envelope:v1` | Command ID, run/session/epoch/sequence/turn, kind, complete canonical payload, and complete canonical disclosure | Dispatch attempts and wall-clock receipt time |
| `credential-use-lease:v1` | Immutable lease/credential-slot/generation/purpose/preparation/epoch identities | Credential value, Provider payload, session handle, and mutable local lifecycle/revision |
| `prepared-session-registration:v1` | Preparation/proposed-run/session/snapshot identities, host epoch, binding hash, and `credential-use-lease:v1` digest when remote | Provider route and credential value |
| `prepared-session-cleanup-command:v1` | Cleanup command/preparation/proposed-run/session/epoch identities, preparation cleanup sequence, reason code, and registration digest | Provider route and credential value |
| `prepared-session-closed-receipt:v1` | Cleanup command/preparation/proposed-run/session/epoch identities, cleanup sequence, registration digest, and close disposition | Provider diagnostics |
| `llm-event-envelope:v1` | Event ID, run/session/epoch/turn/sequence, event kind, and complete event payload | Local arrival time and diagnostics |
| `llm-event-receipt:v1` | Session/epoch/run, event sequence, event ID/digest, and accepted or terminally ignored disposition | Raw payload and local arrival time |
| `capability-evidence:v1` | Evidence schema/source/version plus the complete redacted typed evidence used by policy | Raw provider response, credential, and diagnostics |
| `capability-observation:v1` | Complete dimension/value/source/authority/subject/version/time/scope/invalidation fields plus evidence digest | Raw evidence body |
| `capability-snapshot:v1` | Exact route subject including Provider retention mode/approval revision/digest when cloud, resolved generic capabilities, sorted contributing observation digests, and nearest expiry | Provider-specific evidence body |
| `provider-retention-approval:v1` | Provider/Profile revision, exact origin, retention mode, disclosed provider storage behavior/window class, decision, approval revision, and issue time | Raw user data, credential, and provider payload |
| `egress-approval-summary:v1` | Swift-only disclosure digest, prior scope-grant digest, grant-neutral source summary, and newly added data classes | Raw source content |
| `egress-scope-grant:v1` | Grant/profile-revision/origin/credential-generation/retention-mode/retention-approval identities, approved scope, decision, revision, issue time, and revocation/expiry | Credential value and raw source content |
| `egress-generation-authorization:v1` | Authorization/turn/disclosure/approval-summary/scope-grant/retention identities, decision, issue time, and expiry | Credential value and raw source content |
| `egress-subject:v1` | Swift-only tagged local `not_applicable` decision or cloud Provider Profile revision, exact origin, credential generation, Provider retention mode/approval revision/digest, scope grant, approval-summary digest, and per-turn authorization | Credential value |
| `egress-attestation:v1` | Preparation/run/session/snapshot identities, prepared-session-registration, binding/requirements/disclosure/capability/parameter digests, host epoch, expiry, and opaque egress-subject digest | Parsed provider fields |
| `egress-audit-chain:v1` | Previous chain head, generation turn, disclosure/grant/authorization audit digests, decision, and timestamp | Raw source content, credential, and provider payload |
| `host-tool-effect-result:v1` | Effect/run/turn/call/tool identities, normalized safe result/failure, replay classification, and completion metadata | Raw device API object and private diagnostics |

`payloadDigest` is the `host-command-payload:v1` result.
`commandEnvelopeDigest` covers the whole command and therefore changes when the
same payload is paired with a different `GenerationDisclosure`. `bindingHash`,
`modelInputDigest`, `contentDigest`, and `eventDigest` use their corresponding
registered domains. Preparation and saga token digests are computed from the
complete typed token document, but the raw random token bytes are erased after
consumption and never replace the independently verified binding document.

Every digest used across Swift/Rust, across the two stores, in a persisted
cross-link or receipt, for idempotency/reconciliation, or in a security or
capability decision must have a registered domain and golden fixture here.
Swift may use an explicitly named `privateDiagnosticHash` for ephemeral local
telemetry only; such a value must never cross FFI, enter a cross-store link,
select a policy outcome, or be described as an attestation/evidence digest.
Adding any other authoritative digest requires registering its domain and exact
include/exclude schema first; ad hoc hashes are forbidden.

A hash over raw file bytes is not a structured digest document. Such a field
must name its algorithm and byte subject, for example
`artifactSHA256 = SHA-256(exact downloaded artifact bytes)`, and its raw-byte
contract must be defined by the signed manifest. It must not be reused as a
`CanonicalDigestV1` value or an untyped generic `hash`.

The registry and golden fixtures live under
`local-ios-agent/contracts/canonical-digest-v1/`. Each fixture contains the
typed source document, expected JCS UTF-8 bytes, and expected SHA-256. Tests
cover map/set insertion order, omitted versus null, composed versus decomposed
Unicode, numeric boundaries, disclosure-only command changes, and malformed
documents. Both languages pass the common canonicalizer corpus and every
domain they compute or recompute. A consumer of an opaque inner digest does not
implement that inner DTO merely to run its fixture: in particular, Rust does
not acquire Provider, credential, grant, or Swift capability-evidence parsers.

## Core Swift Data Model

### LLM Target

An `LLMTarget` is the product-level selectable inference target.

```swift
struct LLMTargetID: Hashable, Codable, Sendable {
    let rawValue: String
}

struct LLMTargetRevision: Hashable, Codable, Sendable {
    let targetID: LLMTargetID
    let revision: UInt64
    let kind: LLMTargetKind
    let modelID: String
    let defaultParameters: GenerationConfiguration
}

enum LLMTargetKind: Codable, Sendable {
    case local(installationID: String)
    case cloud(providerProfileID: String, providerProfileRevision: UInt64)
}
```

Target revisions are immutable. Editing a target creates a new revision. An
active run keeps the revision with which it started.

### Agent Host Configuration

The Rust Agent Profile stays provider- and model-neutral, but retains a
portable LLM slot and its agent-owned requirements:

```text
LLMSlot
  slot ID
  AgentLLMRequirements
  optional portable model hint
```

The slot expresses what the Agent needs, not which provider, model, credential,
or local installation should satisfy it. Swift binds that slot to an LLM target.

```swift
struct AgentHostConfiguration: Codable, Sendable {
    let bindingID: String
    let bindingRevision: UInt64
    let agentProfileID: String
    let agentProfileRevision: UInt64
    let llmSlotID: String
    let requirementsHash: String
    let llmTargetID: LLMTargetID
    let llmTargetRevision: UInt64
    let parameterOverrides: GenerationConfiguration
}
```

`bindingHash` is `CanonicalDigestV1(agent-host-binding:v1, ...)` over the
non-secret `AgentHostConfiguration` revision. It excludes the API key and
resolved local path.

The UI may present this composition as part of Agent Profile editing, but the
record belongs to the Swift host layer and is not stored in the Rust agent
definition.

## Two-Phase Run Preparation

Swift cannot prepare an LLM session before Rust has resolved the Agent's tool,
modality, context, and sensitivity requirements. Rust cannot commit the run
before Swift has resolved and attested a ready LLM target. Run start is
therefore a mandatory two-phase protocol.

### Phase A: Rust Preview

```text
preview_run(start request)
  -> RunPreparationPreview
```

Rust first acquires the `preparing` state of the durable global run lease, then
uses the existing `RunSnapshotService.preview` path as the starting point and
previews the execution plan and context requirements without starting the
worker or persisting a run snapshot. It also assembles the canonical first-turn
`AgentLLMInput`, freezes its canonical digest and exact source revisions in the
pending preparation record, and computes its disclosure metadata. The first
`start_generation` command must use canonical bytes whose digest matches that
frozen record; reconstruction with any changed source is rejected.

The result contains only agent and host-neutral requirements:

```text
preparation ID
preparation token
proposed Rust run ID
agent profile ID and revision
conversation frame reference and digest
execution plan digest
AgentLLMRequirements
tool schema digest
frozen initial AgentLLMInput ID and modelInputDigest
memory/context/attachment revision digest
initial GenerationDisclosure
required input modalities
streaming/tool-calling requirements
requested context budget
expiration time
```

The preparation ID is stable for reconciliation. The preparation token is
random, single-use, and bound to that ID, the proposed run ID, and all listed
digests. It begins as a five-minute preparation lease. Rust persists a pending
preparation record, not a run lifecycle record. The proposed run ID is reserved
for this preparation and cannot be reused. Restart invalidates every
uncommitted preparation through the registered-session/old-epoch cleanup rules
below.

While Swift is waiting for user approval or loading a local model, it may call:

```text
renew_preparation(
  current token,
  bound digest set,
  host process epoch,
  renewal idempotency key)
  -> rotated preparation token and new expiration
```

Renewal consumes the old token, preserves the preparation ID, proposed run ID,
and frozen input, and succeeds only when every bound digest and the host epoch
are unchanged. Each renewal extends the lease by five minutes, up to thirty
minutes total from preview. It cannot change the frozen input, any Rust-owned
digest, or the disclosed egress scope; Swift binding, capability, and parameter
claims remain subject to the final attestation checks. When Swift becomes
ready, its host attestation is valid for two minutes; `commit_start` must
consume the current rotated token within that shorter ready window. Exceeding
the total lease requires a new preview and approval flow.

Preview does not send prompt content to a provider, resolve a Swift credential,
load a model, or create a Rust run lifecycle record. Freezing is a local Rust
operation; Swift receives the content digest and disclosure during preparation,
not permission to transmit the content.

### Phase B: Swift Preparation

Swift consumes `RunPreparationPreview` and:

1. Resolves the exact `AgentHostConfiguration` and LLM target revision.
2. Validates capabilities against `AgentLLMRequirements`.
3. Resolves effective generation parameters and context bounds.
4. Performs readiness and egress checks.
5. Obtains any required user approval.
6. For a cloud target, atomically acquires a generation-pinned
   `CredentialUseLease` before reading the Keychain item.
7. Allocates the local or cloud `LLMSessionHandle` and persists the sanitized
   Swift LLM snapshot in `preparing` state, without opening backend resources.
8. Registers the prepared session with Rust before attempting `commit_start`.
9. Only after registration succeeds, loads/opens the provider or C++ session,
   finalizes the ready snapshot/attestation, and attempts `commit_start`.

Swift returns a host attestation:

```text
host attestation schema version
preparation ID
preparation token
proposed Rust run ID
host binding ID, revision, and hash
LLMSessionHandle
Swift LLM snapshot ID
Agent requirements hash
capability attestation and hash
resolved parameter hash
initial disclosure digest
prepared-session-registration digest
host process epoch
attestation expiration
opaque egress-subject digest
EgressAttestationDigest
```

Registration is a separate idempotent pre-commit boundary:

```text
register_prepared_session(
  current preparation token,
  preparation registration idempotency key,
  proposed run ID,
  session handle,
  Swift snapshot ID,
  host epoch,
  binding hash,
  prepared-session-registration digest)
```

Rust persists the exact registration in the pending preparation record. A
prepared session is not considered registered until Swift receives that
receipt. Registration authenticates the current token but does not consume or
rotate it; the same token remains available for `commit_start` or abort. Swift
must not load a local model for this preparation, create a URLSession task, or
open provider/C++ session resources before the registration receipt. If
registration is rejected, it releases its credential-use lease and marks the
Swift snapshot aborted; Rust has no registered session to clean up. Once
registered, even a partially opened or failed backend is covered by the durable
cleanup protocol. The registration digest is also covered by the final host
attestation so `commit_start` cannot substitute another handle or snapshot.

### Host and Egress Attestation Boundary

Swift is solely responsible for resolving and validating Provider Profile
revision, exact origin, credential availability/generation, origin approval,
scope grant, and per-turn egress authorization. Those fields remain in the
Swift LLM snapshot and egress ledger.

For every local or cloud preparation, Swift creates a versioned private egress
subject. A cloud subject contains the provider/credential/grant fields; a local
subject contains a tagged `not_applicable` decision. Swift computes:

```text
opaqueEgressSubjectDigest =
  CanonicalDigestV1(egress-subject:v1, private Swift subject)

EgressAttestationDigest =
  CanonicalDigestV1(
    egress-attestation:v1,
    preparation ID + proposed run ID + session handle + Swift snapshot ID +
    binding hash + requirements hash + initial disclosure digest +
    capability attestation hash + resolved parameter hash +
    prepared-session-registration digest +
    host epoch + expiration +
    opaqueEgressSubjectDigest)
```

Rust receives the opaque subject digest and the outer attestation digest. It
recomputes only the outer digest from provider-neutral public binding fields,
checks the supported schema version, preparation/run/session/snapshot
identities, prepared-session registration,
binding/requirements/disclosure/capability/parameter hashes, host epoch, and
expiry, and stores the digest for cross-linking. Rust never receives or parses
Provider Profile, origin, CredentialRef, credential generation, grant,
authorization, or route details.

The digest provides deterministic binding and reconciliation inside the trusted
app host; it is not presented as a cryptographic trust boundary against Swift.

### Phase C: Rust Commit

```text
commit_start(preparation token, host attestation)
  -> RunHandle
```

Rust verifies that:

- the token exists, is unexpired, and has not been consumed;
- the profile, frame, plan, tool-schema, frozen model-input, and
  memory/context/attachment revision digests plus the initial disclosure digest
  are unchanged;
- the generic capability attestation satisfies `AgentLLMRequirements`;
- the session handle, Swift snapshot ID, and registration digest exactly match
  the persisted prepared-session registration;
- the host binding is present and matches that registration;
- the host epoch is current; and
- the versioned `EgressAttestationDigest` recomputes from the public binding
  fields and opaque Swift subject digest.

Rust then persists the Rust run snapshot, opaque host-binding cross-link, and
initial resumable worker state under the proposed run ID in one Rust
transaction. The token becomes consumed in that same transaction. The returned
`RunHandle` contains that exact ID. Only after commit does Rust enqueue the first
outbound LLM command, whose payload references the frozen input ID and must
match the committed `modelInputDigest`.

Rust does not interpret the target, provider, model, parameters, credential, or
route behind the attestation.

### Abort, Expiration, and Prepared-Session Cleanup

```text
begin_abort_preparation(
  preparation ID,
  current preparation token when still usable,
  cleanup idempotency key,
  reason: user_denied | preparation_failed | token_expired |
          commit_rejected | commit_conflict | host_shutdown)
  -> released_without_session | PreparedSessionCleanupEnvelope
```

`begin_abort_preparation` is the only normal path that abandons an uncommitted
preparation. In one Rust transaction it marks the preparation aborting or
expired, invalidates every unconsumed token, moves the global run lease to
`releasing`, and, when a prepared-session registration exists, persists a
preparation-scoped cleanup outbox row. That row is not a run-worker command and
does not pretend the proposed run ID was committed:

```text
PreparedSessionCleanupEnvelope
  schemaVersion
  cleanupCommandID
  preparationID
  proposedRunID
  sessionHandle
  hostProcessEpoch
  preparationCleanupSequence
  reason
  preparedSessionRegistrationDigest
  cleanupCommandDigest
```

`cleanupCommandDigest` is
`CanonicalDigestV1(prepared-session-cleanup-command:v1, envelope without the
digest field)`.

The dispatcher sends `close_prepared_session` with the same copy-receipt,
asynchronous acknowledgement, stable identity, retry, deduplication, and
timeout rules as the regular command outbox. Its acknowledgement entry is
`submit_prepared_session_cleanup_ack(preparationID, cleanupCommandID,
preparationCleanupSequence, accepted | rejected)`; it cannot be mistaken for a
committed-run command acknowledgement. Swift closes the registered provider/C++
session, releases its exact `CredentialUseLease` when remote, and then submits
the separate preparation lifecycle receipt:

```text
confirm_prepared_session_closed(
  cleanupCommandID,
  preparationID,
  proposedRunID,
  sessionHandle,
  hostProcessEpoch,
  preparationCleanupSequence,
  closeDisposition: closed | already_closed,
  preparedSessionClosedReceiptDigest)
```

`preparedSessionClosedReceiptDigest` is
`CanonicalDigestV1(prepared-session-closed-receipt:v1, receipt without the
digest field)`.

This receipt is deliberately not `LLMEventEnvelope.session_closed`: there is no
committed run or run event sequence. Rust accepts it only when every identity,
epoch, sequence, registration digest, and accepted cleanup command matches the
persisted cleanup row. It persists the close receipt and releases the global
run lease atomically. Exact duplicate aborts, commands, acknowledgements, and
close receipts return the original result; any identity/digest conflict is a
protocol error and never releases another preparation's lease.

A rejected cleanup acknowledgement or a close receipt received before an
accepted acknowledgement quarantines the preparation and keeps the lease
`releasing`; only an exact later completion or a new host epoch may release it.
V1 creates at most one cleanup command identity for a preparation. The first
terminal reason is retained; later abort/expiry calls return that operation
rather than creating another sequence or close attempt.

- User denial or preparation failure before registration releases the lease in
  the abort transaction. After registration it always uses the cleanup outbox.
- Token expiry invokes the same transaction internally and therefore does not
  require an otherwise invalid token. A later Swift abort with the same
  preparation and idempotency key receives the existing cleanup operation.
- A `commit_start` rejection or conflict after registration atomically begins
  this cleanup path before returning the failure. Swift marks its snapshot
  aborted only after it has accepted the cleanup identity.
- If cleanup acknowledgement or confirmation times out, the global lease stays
  `releasing` and the same envelope is redispatched. A new host epoch proves
  that the old process-bound session is gone and permits reconciliation to
  persist an `epoch_ended` close disposition and release the lease.
- Repeating renewal with an already rotated token returns the previously issued
  replacement only for the same idempotency key; otherwise the old token is
  stale.
- Repeating abort returns the previously committed no-session result or cleanup
  envelope.
- A consumed or expired token cannot start a run.
- Startup reconciliation drains preparation cleanup outboxes and reconciles
  prepared-session registrations, Swift credential-use leases, and close
  receipts before the UI allows a new run.

### Prepared LLM Session

Swift materializes the Phase B result as:

```swift
struct PreparedLLMSession: Sendable {
    let handle: LLMSessionHandle
    let capabilityAttestation: AgentLLMCapabilities
    let hostBindingID: String
    let hostBindingRevision: UInt64
    let hostBindingHash: String
    let preparedSessionRegistrationDigest: String
    let credentialUseLeaseID: String?
    let egressAttestationDigest: String
    let sanitizedSnapshot: LLMRunSnapshot
}
```

`LLMSessionHandle` is opaque to Rust. It never encodes a model path, Provider
Profile, API key, Base URL, engine ID, or adapter kind. Swift creates it from at
least 128 bits of cryptographically secure randomness and never reuses it within
a host epoch. The Swift session registry binds the handle to preparation ID,
run ID, host epoch, and binding hash. For a remote session it also binds the
exact credential-use lease ID, generation, and registered
`credential-use-lease:v1` digest. Rust persists only
the provider-neutral preparation/run/epoch/registration binding.
`credentialUseLeaseID` remains Swift-private; only its contribution to the
registered preparation digest crosses the boundary. Closed or expired handles
remain tombstoned for the rest of the epoch, preventing ABA.

## Rust-Swift LLM Client Port

The current synchronous `ExecutionModelClient::next_turn` contract and
`BridgeExecutionModelClient` mutex path are migration sources, not the target
bridge. Rust must not hold the runtime mutex while Swift performs generation or
while a host callback is running.

The target worker is a resumable state machine:

```text
ready
  -> awaiting_start_command_ack
  -> awaiting_generation_started
  -> consuming_llm_turn
  -> executing_tool_batch
  -> awaiting_resume_command_ack
  -> awaiting_generation_started
  -> consuming_llm_turn
  -> awaiting_cancel_command_ack -> awaiting_cancelled_terminal
  -> awaiting_close_command_ack -> awaiting_session_closed
  -> completed | failed | cancelled | interrupted
```

Agent policy, context assembly, tool routing, and completion semantics remain in
Rust. The worker scheduling and model-call implementation do change: a worker
transition persists state and a durable outbound host command in one
transaction, then returns without waiting for Swift.

Outbound commands are:

```text
start_generation(session_handle, generation_semantic_payload, generation_disclosure)
resume_generation(session_handle, generation_semantic_payload, generation_disclosure)
cancel_generation(session_handle)
close_session(session_handle)
capacity_available(session_handle)
```

The complete `generation_semantic_payload` contains the exact ordered
`AgentLLMInput`, canonical tool-schema document, source-revision document,
attachment identity/revision references, complete normalized tool-result batch
(empty on start), and provider-required normalized semantic history that Rust
expects Swift to resend. It contains no provider-encoded request, opaque
thinking/signature bytes, response ID, or credential. Swift resolves the
referenced attachment identities and combines the payload with its private
opaque continuation items; only the normalized semantic history participates
in `agent-input:v1`.

Rust computes a fresh `GenerationDisclosure` for every generation turn. The
start disclosure is bound to the frozen initial input. A resume disclosure is
bound to the complete canonical semantic request for that turn: all prior
content the adapter will resend, the full tool-result batch, and every context,
memory, or attachment revision newly included. Swift must validate the
disclosure before it lets an adapter encode or transmit the corresponding
remote request.

Swift performs that check through one non-forgeable semantic boundary:

```text
CloudGenerationTurnCandidate
  AgentLLMInput
  complete canonical tool-schema document
  complete source-revision document
  resolved attachment identity/revision/content-digest metadata
  complete normalized tool-result batch
  provider-required semantic continuation history
  resolved semantic parameters
  GenerationDisclosure supplied by Rust

CloudSemanticTurnValidator.validate(candidate)
  -> recompute agent-input:v1 from the complete semantic request
  -> recompute source-revisions:v1 from the exact source document
  -> compare both values with GenerationDisclosure
  -> return sealed ValidatedCloudGenerationTurn
```

`ValidatedCloudGenerationTurn` has no public or package initializer; only the
validator can create it. The adapter may accept only that sealed value or a
later egress-authorized wrapper around it. The validator does not trust a
caller-supplied `contentDigest`, `sourceRevisionDigest`, attachment digest, or
provider continuation digest. Phase 3 fixture tests use a package-private
fixture authority that executes the same validator; Phase 4 supplies the Rust
command disclosure and complete canonical documents without weakening the
factory.

### Durable Host Command Outbox

Every outbound operation uses a stable envelope:

```text
HostCommandEnvelope
  commandID
  runID
  sessionHandle
  hostProcessEpoch
  commandSequence
  generationTurnID, for start/resume
  kind
  payloadDigest
  disclosureDigest, for start/resume
  commandEnvelopeDigest
  GenerationDisclosure, for start/resume
  payload
```

`commandID` is globally unique and `commandSequence` is monotonically
increasing per session. Rust writes the worker transition and outbox row in the
same SQLite transaction. A committed outbox row is the sole authority for
dispatch; an in-memory enqueue without that row is forbidden. A terminal run
transition cancels pending non-cleanup commands and inserts one idempotent
`close_session` row. Its acknowledgement proves only that Swift claimed the
close command. The session is released only after a matching `session_closed`
event confirms that provider/C++ resources are gone.

The dispatcher wakes after commit and also scans pending rows, so failure
between transaction commit and callback invocation cannot strand a run. On a
new host epoch, restart invalidation cancels old-epoch rows before dispatch.

Swift keeps a per-session command ledger keyed by `commandID`. Receiving the
same ID, sequence, and `commandEnvelopeDigest` again returns the existing
acknowledgement without recreating a URLSession request or C++ generation.
Reusing an ID with a different sequence or envelope digest interrupts the run
with `llm.command.identity_conflict`.

Ledger entries and the handle tombstone remain until `session_closed`; Swift
cannot evict an identity merely because `close_session` was acknowledged.

For a previously unseen command ID, Swift accepts only the next sequence. A gap
returns `llm.command.sequence_gap`; reusing an accepted sequence with a different
ID returns `llm.command.sequence_conflict`. Rust never dispatches a later command
until the earlier envelope has a `copied` receipt or has been atomically
cancelled before Swift saw it, in which case its unseen sequence is released
for the replacement cleanup command. A new start/resume waits for asynchronous
acceptance of the previous lifecycle command; cancel/close may follow a copy
receipt so cancellation is not blocked by a lost asynchronous acknowledgement.

Delivery has two acknowledgement levels:

1. The synchronous vtable return reports `copied`, `backpressure`, or
   `host_unavailable`. Only `copied` means Swift owns an immutable copy in its
   bounded actor queue; it does not remove the Rust outbox row.
2. After the actor deduplicates and claims the command, Swift calls
   `submit_llm_command_ack(runtime, sessionHandle, commandID,
   commandSequence, accepted | rejected)`.
   `accepted` means Swift has claimed that identity and will not start it more
   than once in the current host epoch; it does not mean generation has
   completed or egress has been approved. Swift may acknowledge the command and
   wait in `awaiting_incremental_egress_approval`; the command deadline never
   times the user's approval decision.

A rejected acknowledgement carries a stable safe error. Rust marks that outbox
row terminal and fails or interrupts the run according to the error category;
it does not retry rejection with a new identity.

Rust retries `backpressure`, a missing copy receipt, or a missing asynchronous
acknowledgement with the same envelope identity. Start and resume commands have
a ten-second acknowledgement deadline with bounded redispatch during that
window. If no valid acknowledgement arrives, Rust interrupts the run with
`llm.command.ack_timeout`; it never creates a new command ID to guess whether
the provider request started. A late acknowledgement is treated as stale.

### Host Command Vtable

Swift registers a host command vtable when the runtime bridge is created. Rust
owns a serial outbound command queue and dispatches vtable calls only after all
runtime and repository mutex guards have been released.

The vtable callback receives an immutable byte pointer, length, and opaque
context pointer. Its rules are:

- Rust owns the command buffer for the duration of the callback.
- Swift copies the command before the callback returns.
- The Swift callback only attempts to enqueue the copied command onto the
  bounded `LLMBridgeActor` queue and returns the copy receipt promptly.
- The callback must not call any Rust FFI entry synchronously or wait for the
  main actor.
- Command delivery is serial per runtime and validated against
  `commandSequence`. Different runtimes do not share a command-order guarantee.

### Independent Event Submission

Swift delivers model and lifecycle events through a separate FFI entry after
the command callback has returned:

```text
submit_llm_event(runtime, event_envelope_bytes)
```

The envelope is:

```text
LLMEventEnvelope
  schemaVersion
  eventID
  sessionHandle
  hostProcessEpoch
  runID
  generationTurnID, absent only for session-level lifecycle events
  eventSequence
  eventDigest
  event
```

`eventID` contains at least 128 random bits and is never reused within a
session. `eventDigest` is
`CanonicalDigestV1(llm-event-envelope:v1, envelope without eventDigest)`.

Swift owns `event_envelope_bytes` for the duration of the FFI call; Rust copies
accepted envelopes before returning. The event entry takes the runtime mutex
only long enough to validate the canonical digest, handle/run/epoch/turn
binding, identity and sequence, append the event, advance the worker, and
enqueue any next outbound command. It never calls the Swift vtable while
holding the mutex.

The stream contract is provider-neutral:

```text
generation_started {
  commandID
  opaqueBackendOperationID
}
reasoning_summary_delta
text_delta
tool_call_started
tool_call_arguments_delta
tool_call_completed
usage_updated
generation_completed {
  generationTurnID
  outcome: final_response | tool_calls_ready
  orderedCallIDs
  finishReason
}
cancelled { cancelCommandID }
failed
session_closed { closeCommandID }
```

`finishReason` is provider-neutral: `stop`, `tool_calls`, `length`,
`content_filtered`, or `other`. The raw provider reason remains in redacted
Swift diagnostics. `orderedCallIDs` uses first-appearance order after adapter
normalization and is empty for every non-tool outcome.

The lifecycle meanings are distinct:

- `command_acknowledged` is the separate FFI acknowledgement that Swift copied,
  deduplicated, and claimed a command identity.
- `generation_started` means URLSession has created/resumed the request task or
  C++ has returned a live generation operation. It is not inferred from command
  acknowledgement or the first text token.
- `cancelled` is emitted only after the URLSession completion callback or C++
  engine confirms that the generation operation stopped.
- `session_closed` is emitted only after all provider/C++ session resources are
  released. Only then may Swift remove the command/event ledgers and live
  handle registry entry; the handle remains non-reusable for the epoch. For a
  local target this releases the generation/session, not necessarily the
  separately managed loaded model, which may remain `ready(model)` in RAM.

Rules:

- Swift prepares and owns every session handle.
- Rust may retain a handle only for the lifetime of its run.
- Closing is idempotent.
- Every generation event carries the `generationTurnID` from its acknowledged
  start/resume command and is rejected if it does not match the active turn.
- `session_closed` is the only event without a generation turn ID and must
  reference the accepted `close_session` command ID.
- Each session uses monotonically increasing event sequence numbers.
- Repeating the same sequence is an idempotent duplicate only when `eventID` and
  `eventDigest` both match the accepted receipt.
- Reusing a sequence with a different ID or digest returns
  `llm.event.sequence_conflict` and interrupts the run. Reusing an event ID with
  a different sequence or digest returns `llm.event.identity_conflict` and also
  interrupts the run.
- A sequence gap interrupts the session with `llm.event.sequence_gap`.
- Events after `generation_completed` for the same turn return
  `llm.event.turn_terminal` and are terminally ignored under the receipt rules
  below. A `tool_calls_ready` terminal keeps the session open for a later
  acknowledged resume turn.
- After `generation_completed(outcome: final_response)`, `cancelled`, or
  `failed`, further generation events return `llm.event.generation_terminal`;
  the matching `session_closed` event remains admissible.
- After `session_closed`, an exact replay of the retained terminal close receipt
  returns `duplicate`; every other later event returns
  `llm.event.closed_session` and is ignored.
- Events for an expired or unknown handle return `llm.event.stale_session` and
  are ignored.
- Provider-specific unknown events are handled in Swift and do not cross FFI.
- Provider reasoning signatures and raw thinking blocks never cross FFI.
- Tool calls cross FFI only in the normalized agent tool-call shape.
- Secrets and local paths never appear in port DTOs.
- `tool_call_completed` closes one decoded call but does not authorize tool
  execution. Rust waits for the terminal `generation_completed` event.
- `final_response` requires an empty `orderedCallIDs`; accumulated text becomes
  the final assistant answer and `finishReason` cannot be `tool_calls`.
- `tool_calls_ready` requires a non-empty ordered list that exactly matches all
  completed calls in that turn plus `finishReason: tool_calls`. Missing,
  duplicate, unknown, or still-open call IDs fail the run with
  `llm.turn.invalid_tool_batch`.
- V1 executes the complete tool-call batch sequentially in `orderedCallIDs`
  order, even when the model can emit parallel calls. Every call produces a
  normalized success or failure result. Rust persists the whole result set and
  sends one ordered result batch in the next `resume_generation` command.
- Text emitted in a `tool_calls_ready` turn is an assistant preamble: it may be
  streamed to the UI and is persisted once with that tool turn, but it is not a
  final answer. It remains part of Rust conversation context without being
  duplicated when Swift continues the provider-private session.
- The completed tool batch and its observations are persisted before a resume
  command/outbox row is created.
- Rust retains a durable event receipt ledger of
  `session + sequence -> eventID + eventDigest + disposition` using
  `llm-event-receipt:v1` until `session_closed`, so an accepted or terminally
  ignored duplicate remains verifiable after the inbound queue has drained.
  Close cleanup may compact that ledger, but the handle tombstone retains the
  final `session_closed` receipt through the host epoch so its exact replay
  remains a duplicate.

### Backpressure

Rust maintains a bounded per-session inbound event queue. V1 limits are 256
events and 2 MiB of copied event payloads. `submit_llm_event` returns one of:

```text
accepted
duplicate
backpressure
stale_session
turn_terminal
generation_terminal
closed_session
sequence_gap
sequence_conflict
identity_conflict
invalid_envelope
payload_too_large
```

The result contract is exact. `Consumes: new` means Rust advances the expected
sequence in the same transaction as the receipt; `already` means the sequence
was committed by the original delivery; `no` means the submitted sequence is
not advanced.

| Result | When returned | Consumes sequence | Persists receipt | Retry the same envelope |
| --- | --- | --- | --- | --- |
| `accepted` | Valid next event is appended/applied | new | yes, `accepted` | no |
| `duplicate` | Existing sequence has the same event ID and digest | already | existing receipt | no |
| `backpressure` | Valid next event cannot yet enter the bounded queue | no | no | yes, after capacity notification |
| `turn_terminal` | Valid next event arrived after that turn's terminal event | new | yes, `terminally_ignored` | no |
| `generation_terminal` | Valid next generation event arrived after generation terminal/cancel precedence | new | yes, `terminally_ignored` | no |
| `payload_too_large` | Valid expected event cannot fit even in an empty queue | new | yes, `terminal_failure` | no; Rust fails and closes the session |
| `stale_session` | Handle/epoch/run registration is unknown, expired, or from an older epoch | no | no | no; Swift drops it |
| `closed_session` | Close cleanup completed and this is not the exact retained close duplicate | no | no new receipt | no; Swift drops it |
| `sequence_gap` | Sequence is greater than the expected next value | no | no | no; Rust interrupts the session |
| `sequence_conflict` | An already consumed sequence has another ID or digest | already | existing conflicting receipt | no; Rust interrupts the session |
| `identity_conflict` | An existing event ID is reused with another sequence or digest | no new sequence | existing identity receipt | no; Rust interrupts the session |
| `invalid_envelope` | Schema, canonical digest, binding, or required field is invalid | no | no | no; Rust interrupts/quarantines the session |

Rust chooses one result deterministically in this order: structural/canonical
validation; handle/epoch lookup (including an exact retained close duplicate);
existing event-ID/sequence receipt comparison; expected-sequence validation;
turn/generation lifecycle validation; then queue capacity and application.
Thus a conflicting identity is never hidden as a terminal late event, and
backpressure is returned only for an otherwise acceptable next sequence.

Swift provider/C++ adapters filter raw late backend callbacks before assigning
an `eventID` or `eventSequence`. The per-session sequencer allocates both only
when an immutable envelope is about to cross FFI. Once an envelope is submitted,
Swift obeys the table; it never guesses whether a rejection consumed sequence.
In particular, terminally ignored events consume and persist a typed
`llm-event-receipt:v1`, allowing a later `session_closed` at N+1 without a gap.
After a close receipt is committed, Swift removes the raw-event sequencer and
filters any late backend callback locally, so `closed_session` has no later
valid sequence to preserve.

`backpressure` does not consume the rejected event's sequence number. Swift
suspends consumption of the URLSession byte stream or local token queue and
retries the exact same envelope after capacity notification. When the Rust queue
drops below both low-water marks (128 events and 1 MiB), Rust enqueues
`capacity_available(session_handle)` on the host vtable and dispatches it after
releasing the runtime mutex. Text and
reasoning-summary deltas may be coalesced up to 32 KiB or 50 ms before
submission. Tool-call, usage, and terminal events are never dropped. If one
event cannot fit in an empty queue, the session fails with
`llm.event.payload_too_large`.

### Cancellation Race

Cancellation is represented by a persisted Rust state transition and an
outbound cancel command.

- If a generation-terminal `generation_completed(outcome: final_response)`,
  `cancelled`, or `failed` event commits first, a later cancel is an idempotent
  no-op and Rust proceeds to close. A `tool_calls_ready` turn terminal does not
  block cancellation while tools are pending.
- If cancellation commits first, later non-cancellation generation events are
  returned as `generation_terminal` and consumed under the receipt matrix; the
  matching `cancelled` and eventual `session_closed` remain admissible.
- Swift invokes URLSession/C++ cancellation at most once per cancel command ID.
  It emits `cancelled` only after the backend confirms stop.
- The cancel command uses the normal ten-second command-acknowledgement
  deadline. After `accepted`, a separate ten-second backend-stop watchdog waits
  for `cancelled`. If it expires, Rust interrupts with
  `llm.cancel.stop_timeout`, enqueues `close_session`, and records that backend
  stop is unconfirmed; it does not claim that provider quota use ended.

### Start and Close Watchdogs

- Command acknowledgement never proves backend start or resource release.
- After the effective egress authorization exists, Swift starts a local
  ten-second operation-start watchdog. It must emit `generation_started` or a
  terminal `failed` event. Time spent waiting for user approval is excluded.
- `close_session` has the normal ten-second command-acknowledgement deadline.
  After `accepted`, Rust waits a separate ten seconds for `session_closed`.
- Missing `session_closed` produces `llm.session.close_timeout`. Rust may persist
  and expose the already determined logical Agent outcome, but the resource
  lifecycle/global lease remains `releasing`. Swift quarantines the handle and
  its ledgers until `session_closed` eventually arrives or the process epoch
  ends. A quarantined handle is never reused.

The bridge may use the project's JSON envelope conventions over the C ABI, but
the queue, ownership, ordering, backpressure, and race rules above are fixed by
this design rather than deferred to implementation.

## Official Local Model Catalog

### Catalog Trust

V1 accepts only models described by the official catalog.

The app ships with a bundled catalog so the model center remains usable offline.
It may fetch a newer catalog over HTTPS. A remote catalog is accepted only when:

- its schema version is supported;
- its monotonic catalog revision is not older than the accepted revision;
- an Ed25519 signature validates against a public key pinned in the app; and
- every artifact URL and hash is covered by the signed canonical manifest.

An invalid remote catalog is ignored and the last trusted catalog remains
active. The catalog update path cannot add native code or a new engine.

### Model Manifest

Each local model revision declares:

```text
model ID and revision
display name and family
engine ID
model format
artifact list and semantic role
artifact download URL
artifact byte size
artifact SHA-256
total installed size
supported devices and minimum OS
estimated memory class
declared capabilities
parameter schema and defaults
engine load configuration template
chat template source and ID
tool-call codec ID
```

Artifacts may include model weights, tokenizer data, multimodal projection
files, and chat templates. The manifest, not the user, determines which files
are required for a format.

Prompt ownership is split at the model-format boundary:

- Swift selects the manifest-approved chat template source/ID, constructs the
  canonical messages and tool schema payload, and chooses the output tool-call
  codec.
- C++ performs model-format-specific rendering, including GGUF/custom
  `llama_chat_apply_template` behavior, immediately before tokenization.
- Swift parses and normalizes tool-call output.
- C++ does not select tools, execute tools, or interpret Agent/tool semantics.

This preserves the existing llama.cpp v2 responsibility for GGUF chat-template
rendering without moving Agent policy into C++.

### Installation State

```text
not_installed
queued
downloading
paused
verifying
installed
deleting
failed
```

Failure details use stable codes:

```text
download.network_failed
download.resume_data_invalid
download.insufficient_disk
download.catalog_signature_invalid
installation.checksum_mismatch
installation.engine_incompatible
installation.interrupted
```

### Download and Atomic Installation

- `URLSession` background downloads provide system-managed continuation.
- V1 runs at most one active model download; additional downloads are queued.
- User pause stores resume data when the system supplies valid resume data.
- Resume failure restarts only the affected artifact.
- Artifacts download into a per-installation `.staging` directory.
- Every artifact is checked for exact byte size and SHA-256.
- All artifacts must pass before the installation becomes visible as installed.
- Installation uses an atomic rename within the same filesystem.
- Stale staging directories are reconciled at launch.
- Model directories are excluded from iCloud backup.
- Duplicate installations of the same model revision are rejected.

The disk preflight requires enough free space for remaining download bytes,
verification/installation overhead, and a safety reserve. The initial reserve is
the larger of 512 MiB or 10 percent of the package's installed size. This value
belongs to the centralized `LocalDiskPolicy` and can be adjusted without
changing download logic.

The app never automatically deletes an installed model in v1. When space is
insufficient, the user chooses which unused model to delete.

### Deletion

Deletion is allowed only if the installation is:

- not loaded in RAM;
- not part of an active LLM session;
- not being verified; and
- not being downloaded unless the user first cancels that download.

Deletion removes the installation directory and record in a recoverable
transaction. A launch-time reconciliation removes a record only after verifying
that the directory no longer exists.

## Local RAM and C++ Runtime Lifecycle

Swift owns the product runtime state:

```text
idle
  -> loading(model)
  -> ready(model)
  -> generating(model)
  -> awaiting_tool_result(model)
  -> generating(model)
  -> cancelling(model)
  -> ready(model)
  -> unloading(model)
  -> idle
```

Rules:

- Multiple model packages may be installed on disk.
- At most one model is loaded in RAM.
- Downloading a model does not load it.
- Selecting a model in an editor does not load it.
- Preparing a real run loads the selected local model.
- Switching to another local model unloads the old RAM model first.
- Switching to cloud unloads the local RAM model.
- An idle loaded model unloads immediately on a critical memory warning.
- A model cannot be deleted while loaded.
- Local tool-call parsing and normalization live in the Swift local adapter,
  not in C++.
- `start_generation` receives canonical messages, optional canonical tool schema
  payload, and a manifest-approved template selector. C++ renders the final
  model prompt using the selected engine's format-specific implementation.

The C++ boundary exposes the equivalent of:

```text
list_engines
engine_capabilities
engine_parameter_schema
validate_model_config
validate_load_options
validate_generation_options
load_model
unload_model
start_generation
read_stream
cancel_generation
release_generation
```

C++ may report backend parameter support, but Swift owns the canonical parameter
model, validation composition, persistence, and UI.

## Cloud Provider System

### Provider Profile

```swift
struct ProviderProfileRevision: Codable, Sendable {
    let id: String
    let revision: UInt64
    let presetID: String
    let displayName: String
    let baseURL: URL
    let credentialRef: String
    let retentionMode: ProviderRetentionMode
}

enum ProviderRetentionMode: String, Codable, Sendable {
    case statelessRequired
    case providerStateApproved
}

struct ProviderProfileState: Codable, Sendable {
    let profileID: String
    let profileRevision: UInt64
    var validationState: ProviderValidationState
    var approvedEgressOrigin: EgressOrigin?
    var retentionApprovalRevision: UInt64?
    var retentionApprovalDigest: String?
    var catalogRevision: UInt64?
}
```

Non-secret Provider Profile configuration is immutable by revision. Changing
the preset or Base URL creates a new revision. A cloud `LLMTargetRevision` pins
the Provider Profile revision it was validated against. Key replacement does
not rewrite that target revision, but it always advances the credential slot's
non-secret `credentialGeneration` and invalidates generation-scoped readiness.
`ProviderProfileState` never caches or copies that generation; every lookup
joins through its `credentialRef` to the one credential-slot row.
`validationState` is only a readiness projection derived from generation-keyed
validation evidence; it cannot supply or override a credential generation.

`retentionMode` is immutable by Provider Profile revision and defaults to
`statelessRequired`. Selecting `providerStateApproved` requires a separate,
explicit approval that discloses the preset's provider-side storage behavior;
the resulting non-secret approval revision is stored in `ProviderProfileState`.
Changing the mode creates a new Profile revision and invalidates origin/scope
grants, validation, capability snapshots, and prepared sessions. A
provider-state approval is bound into the egress scope grant and capability
snapshot; origin approval alone never opts into provider retention.

`statelessRequired` means the app does not request provider-managed
conversation/response resources and sends an explicit no-storage flag where
the API supports one. It does not claim that a provider has zero operational,
abuse-monitoring, or account-log retention outside that API control; Provider
Profile disclosure must not make that broader promise.

Provider presets supply a display name, default Base URL, authentication scheme,
wire codec, model-list strategy, validation strategy, and provider-semantic
adapter. Users may override the Base URL in the advanced profile editor.

Base URLs must use HTTPS. The profile validator rejects embedded credentials,
localhost, private/reserved address ranges, and redirects to a different origin.

### Wire Codecs and Provider Semantics

API compatibility is not treated as semantic equivalence.

```text
CloudProviderAdapter
  |
  |-- shared WireCodec
  |     OpenAI Responses
  |     OpenAI Chat Completions
  |     Anthropic Messages
  |     Gemini Interactions
  |
  `-- provider-specific semantics
        OpenAI
        Anthropic/Claude
        Google/Gemini
        xAI/Grok
        DeepSeek
        MiniMax
        Zhipu/GLM
```

Initial mappings:

| Provider | Preferred adapter boundary |
| --- | --- |
| OpenAI | OpenAI Responses |
| Claude | Anthropic Messages |
| Gemini | Gemini native adapter |
| Grok | OpenAI Responses codec plus xAI semantics |
| DeepSeek | OpenAI-compatible codec plus DeepSeek semantics |
| MiniMax | Anthropic-compatible codec plus MiniMax semantics |
| GLM | OpenAI-compatible codec plus GLM semantics |

Provider-specific semantics cover parameter availability, tool-call
continuation, reasoning-state preservation, model discovery, usage mapping,
error mapping, and stream completion rules.

Every adapter is retention-aware. Under `statelessRequired`, it must encode the
provider's no-storage control when one exists (`store: false` for Responses and
Gemini Interactions), must not use server-side response/interaction IDs for a
later turn, and must resend the complete validated semantic history plus any
provider-required encrypted continuation item. If the selected provider/model
cannot continue statelessly, the capability is unsupported for that Profile
revision. Only `providerStateApproved` may use server-side continuation IDs;
those IDs remain in memory and are still discarded on close or epoch change.

Protocol fixtures follow provider event semantics rather than inferred SDK
shapes:

- Claude summarized thinking is authorized by the request's exact
  `thinking.display = summarized` configuration. The response still uses
  ordinary thinking blocks and `thinking_delta`; the adapter may expose those
  deltas as a user-displayable summary only because the sealed request selected
  summarized display. It never waits for a nonexistent summary marker in the
  response.
- Gemini Interactions uses `error` as the streaming failure event.
  `failed`, `cancelled`, `incomplete`, and `budget_exceeded` are interaction
  status values, not substitute SSE event names. A terminal
  `interaction.completed` must be interpreted together with its status.

### Model Discovery

Cloud model selection combines three sources:

1. The provider's live model list, when available.
2. A signed, maintained cloud capability catalog.
3. A manually entered Model ID.

The provider list proves current availability but is not assumed to contain a
complete capability description. A manually entered unknown model begins with
conservative `unknown` capabilities and cannot be used by an Agent that requires
an unverified capability.

### Connectivity Validation

Validation has two explicit stages:

1. Account validation authenticates and attempts model discovery without user
   conversation data.
2. Model validation sends a fixed synthetic prompt with minimal output to prove
   that the selected model and streaming path are callable.

The UI discloses that model validation may consume a small amount of provider
quota. Validation is never run until egress for the exact origin is approved.

Changing the Base URL, credential generation, provider preset, or selected model
invalidates the relevant validation state. Validation evidence is keyed by
Provider Profile revision, model ID, exact origin, and credential generation. A
successful probe is evidence of current availability, not a permanent
capability override.

### Authorized Cloud Request Pipeline

No raw `CloudWireRequest` can reach transport. Generation and non-generation
traffic use separate policy entry points and one tagged sealed envelope:

```text
generation:
  validate complete semantic candidate
    -> ValidatedCloudGenerationTurn
  authorize disclosure/scope/retention
    -> AuthorizedCloudGenerationTurn
  adapter.encode(authorized turn)
    -> CloudWireRequest
  ProviderEgressPolicy.sealGenerationRequest(wire, turn authorization)
    -> AuthorizedCloudHTTPRequest(.generation)

discovery/validation:
  codec encodes a preset-declared no-user-data request class
    -> CloudWireRequest
  ProviderEgressPolicy.sealValidationRequest(
      wire,
      exact origin-approval revision,
      validation CredentialUseLease,
      request class: discovery | account_validation | model_validation)
    -> AuthorizedCloudHTTPRequest(.validation or .discovery)

transport.send(AuthorizedCloudHTTPRequest)
```

The policy revalidates the exact Profile revision, origin/path prefix,
credential generation/use lease, retention mode, request class, and relevant
authorization digest when sealing. Generation sealing rejects a wire request
whose turn/adapter/request digest does not match the authorization. Validation
and discovery sealing accept only preset-owned encoders and fixed synthetic or
metadata-only bodies; they never fabricate a `GenerationDisclosure` for a
request that contains no Agent/user data. Discovery and validation always use
the provider's no-storage option when available, even if the Profile allows
stateful generation, because probes never require continuation. `AuthorizedCloudHTTPRequest` has no
public or package initializer outside `ProviderEgressPolicy`, carries a tagged
`generation | validation | discovery` authorization, and is the only input to
`CloudHTTPTransport`.

### Keychain

- The API key is stored with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- Persistent stores contain only an opaque CredentialRef plus its non-secret
  generation metadata, never the credential value.
- A CredentialRef names a logical credential slot. Multiple immutable revisions
  of the same Provider Profile may reference that slot.
- The UI cannot read a saved key back as plaintext; it may replace or delete it.
- Archiving a Provider Profile revision never deletes its Keychain item.
- Deleting the entire logical Provider Profile first prevents new sessions and
  archives all of its revisions. `ProviderCredentialStore` deletes the Keychain
  generation items only after no non-archived profile revision, pending
  host-binding operation, or `CredentialUseLease` references the CredentialRef.
  A credential slot shared by another logical profile is retained until its
  final reference is removed.
- Key deletion uses an idempotent persisted tombstone: record deletion intent,
  delete the Keychain item, then mark completion. Startup reconciliation safely
  repeats an incomplete deletion without exposing the old credential.
- Credential resolution happens only after egress and approval checks pass.
- Credential values never enter logs, SQLite, FFI DTOs, diagnostics, exports, or
  provider error messages.

### Credential Generation and Rotation

There is one generation authority per logical credential slot:

```swift
struct CredentialSlotState: Codable, Sendable {
    let credentialRef: String
    var currentGeneration: UInt64
    var lifecycle: CredentialSlotLifecycle
}

enum CredentialSlotLifecycle: Codable, Sendable {
    case creating(operationID: String, generation: UInt64)
    case active
    case rotating(
        operationID: String,
        expectedGeneration: UInt64,
        nextGeneration: UInt64
    )
    case deleting(operationID: String, expectedGeneration: UInt64)
}

enum CredentialUsePurpose: String, Codable, Sendable {
    case validation
    case preparation
}

enum CredentialUseLifecycle: String, Codable, Sendable {
    case acquired
    case sessionBound
    case closing
}

struct CredentialUseLease: Codable, Sendable {
    let leaseID: String
    let credentialRef: String
    let generation: UInt64
    let purpose: CredentialUsePurpose
    let preparationID: String?
    let hostProcessEpoch: String
    var revision: UInt64
    var lifecycle: CredentialUseLifecycle
}
```

`credentialGeneration` is a monotonically increasing `UInt64` owned only by
`CredentialSlotState`; it is not a secret. `CredentialUseLease` rows are a
normalized table keyed by lease ID rather than copies inside Provider Profile
state. Every operation that resolves a generation-specific Keychain item,
including connectivity validation, acquires one first.

Phase B performs one Swift SQLite transaction that requires
`CredentialSlotState.lifecycle == active`, reads `currentGeneration`, and
inserts a preparation use lease pinned to that generation. Only after commit
may it read the matching Keychain item or open the provider session. Prepared
session creation then computes `credential-use-lease:v1`; the digest excludes
the session handle and later local lifecycle/revision transitions.
`prepared-session-registration:v1` binds that opaque lease digest to the
session handle, and successful `commit_start` promotes the row to
`sessionBound`. Abort cleanup, normal `session_closed`, or old-epoch
reconciliation releases it only after the provider task/session is gone. A
validation lease is short-lived and is released after its request has
completed.

Initial credential publication is itself an idempotent cross-Keychain/SQLite
saga; startup never scans Keychain and guesses whether an item is orphaned:

```text
1. persist CredentialCreationOperation(credentialRef, operationID, generation 1)
2. write a generation-1 staged Keychain item named by that operation
3. insert CredentialSlotState(generation 1, creating(operationID, 1))
4. promote the staged item to the final generation-specific account
5. in one transaction CAS the same slot to active and complete the operation
```

Credential-slot `creating` rejects active Profile publication, lease
acquisition, validation, and credential resolution. Before step 3,
reconciliation deletes only the staged item named by the recorded operation.
From step 3 onward it finishes promotion and activation; it never deletes or
adopts an untracked Keychain item. Replays with the same operation and input
are idempotent, while an operation/input mismatch is a conflict.

Product-level Provider Profile creation wraps that credential saga without a
second operation table:

```text
1. persist provider_profile_revisions lifecycle=creating with a stable operationID
2. run CredentialCreationOperation with that same operationID
3. verify the exact credential slot is active
4. transactionally activate the immutable Profile revision and its state row
```

The creation operation ID is lifecycle metadata in the revision's versioned
record envelope; it is not part of the active public Profile value. Startup
first reconciles credential operations, then `creating` Profile revisions. An
exact active slot completes Profile activation; an absent or rolled-back slot
archives the creating revision. Thus a crash after credential completion but
before Profile activation remains discoverable without scanning Keychain or
guessing which credential belongs to which Profile.

This authoritative lifecycle-envelope change is the Swift `LLMStore`
`user_version = 3` migration. It transactionally rebuilds only
`provider_profile_revisions`, converts every V2 active/archived envelope into
the tagged V3 lifecycle with no creation operation, restores indexes, and
updates the store version last. Rollback leaves an exact reopenable V2 store;
version 4 is rejected as future. Other unchanged table envelopes retain their
existing record schema.

The pinned generation feeds provider validation, the scope grant, per-turn
authorization, private egress subject, `LLMSessionHandle` registry entry,
provider session, and sanitized Swift run snapshot. Every remote request
verifies that its live use lease still pins the generation before resolving the
generation-specific Keychain item.

Because the private egress subject feeds `EgressAttestationDigest`, the host
attestation is generation-bound without exposing generation semantics to Rust.

Publishing a new key generation is forbidden while any `CredentialUseLease`
references that CredentialRef. The UI may wait, or ask the user to cancel the
run and wait for prepared-session cleanup or `session_closed`; it cannot
silently rotate under an active user.

Rotation is an idempotent Swift saga:

```text
1. in one SQLite transaction CAS
     lifecycle: active ->
       rotating(operation ID, expected generation, next generation)
   only when currentGeneration equals the expected generation and the slot has
   zero CredentialUseLease rows
2. write the new key to a generation-specific staged Keychain item
3. in one SQLite transaction verify the same operation/expected generation,
   advance currentGeneration, invalidate validation, availability, scope
   grants, and readiness bound to the old generation, and set lifecycle back
   to active
4. tombstone and delete the old generation-specific Keychain item
```

Entering `rotating` rejects every new use-lease acquisition with
`credential.rotating`, closing the check-to-use window before the new Keychain
write. If staging or publication fails, reconciliation deletes the staged next
item and CASes the same operation back to active on the old generation. The old
item is never deleted until publication is committed while the slot still has
zero users.

Deletion similarly CASes an unreferenced active slot with zero use leases to
`deleting(operationID, expectedGeneration)` before touching Keychain; that
state rejects new profile references and use leases. Rotation reconciliation may roll back only
while the old generation is still published; after the new generation is
published it completes old-item deletion. Deletion reconciliation may return
to active only before Keychain deletion begins; after that boundary it must
finish the tombstoned deletion. No recovery path labels old key material as a
new generation. When several logical profiles intentionally share one
credential slot, rotation invalidates all of their generation-scoped state and
the UI discloses that shared impact before the initial CAS.

### Provider Session Continuation

Swift owns an in-memory provider session object for every cloud run:

```text
pin credential generation
start(input)
stream normalized events
retain provider-private continuation state
submit normalized tool results
continue streaming
cancel
close
```

The session retains provider-private response IDs only when the exact Profile
revision is `providerStateApproved`. It may always retain reasoning content,
thinking blocks, encrypted items, and signatures needed for a stateless
continuation. When Rust returns a normalized tool result, Swift constructs the
complete semantic continuation history first, passes it through
`CloudSemanticTurnValidator`, and only then reconstructs the provider-specific
wire request. This state is memory-only and is dropped when the session closes.

Cloud inference uses process-bound, non-background URLSession tasks. Only model
downloads use background URLSession; a generation cannot outlive the host epoch
as a resumable app operation.

Reasoning summaries may cross the LLM client port only when the sealed request
selected a provider-documented summary mode and the matching response content
is defined as user-displayable under that mode. Raw private reasoning and
opaque continuation state do not cross the port.

## Egress and Approval

### Provider Origin Approval

Creating or editing a Provider Profile shows the exact egress origin:

```text
scheme + host + port
```

The user's approval is bound to the profile and exact origin. Changing any part
of the origin invalidates approval and validation.

Routine text inference does not repeatedly prompt after origin approval.

### Per-Run Sensitive Approval

Every start or resume command carries a provider-neutral disclosure:

```swift
struct GenerationDisclosure: Codable, Sendable {
    let schemaVersion: String
    let generationTurnID: String
    let contentDigest: String
    let sourceRevisionDigest: String
    let dataClasses: Set<EgressDataClass>
    let highestSensitivity: DataSensitivity
    let safeDisplaySummary: SafeDisplaySummary
    let disclosureDigest: String
}

struct SafeDisplaySummary: Codable, Sendable {
    let sourceKinds: Set<EgressSourceKind>
    let addedItemCounts: [EgressDataClassCount]
    let approximateAddedSize: EgressSizeBucket
    let triggeringToolDisplayKeys: Set<String>
}

struct EgressDataClassCount: Codable, Sendable {
    let dataClass: EgressDataClass
    let count: UInt64
}

// Swift-only; never crosses into Rust.
struct EgressApprovalDisplaySummary: Codable, Sendable {
    let disclosureDigest: String
    let priorScopeGrantDigest: String?
    let sourceSummary: SafeDisplaySummary
    let newlyAddedDataClasses: Set<EgressDataClass>
    let approvalSummaryDigest: String
}
```

`EgressSourceKind` is a stable enum such as `conversation`, `memory`,
`contacts`, `files`, `calendar`, `photos`, `location`, `attachment`,
`tool_result`, or `other`. Size uses coarse buckets (`none`, `<1 KiB`,
`1-100 KiB`, `100 KiB-1 MiB`, `>1 MiB`). Tool display keys must come from the
signed tool manifest and are localized by the app; no tool output can inject
free-form approval text. Phase 5 does not yet have a signed Tool Manifest
verification chain, so the trusted display-key set is fixed to empty and the
approval UI uses one localized generic tool label. Rust freezes an empty
`triggeringToolDisplayKeys`; Swift supplies an empty `signedToolDisplayKeys`
set and rejects non-empty preview keys. Function-schema text, tool metadata,
and tool output are never fallback trust sources. Specific tool labels require
a later signed-manifest design.

`disclosureDigest` is computed over the disclosure with that field omitted.
Rust constructs only the grant-neutral `SafeDisplaySummary`. Swift compares the
machine labels with its private current scope grant, creates
`EgressApprovalDisplaySummary`, and computes `approvalSummaryDigest` with the
`egress-approval-summary:v1` domain and that digest field omitted. The derived
summary is stored with the private grant/authorization and never crosses into
Rust.

Neither summary contains contact names, calendar titles, filenames,
paths, URLs, content snippets, queries, tool arguments, or raw values. It is
included in the appropriate canonical digest, so the exact summary shown for
approval is bound to the disclosure and private grant. Swift validates that
counts/classes are consistent with the machine labels; a missing or inconsistent
summary can only increase sensitivity to `unknown_data`, never reduce it. The
summary is explanatory metadata, not an independent source of authorization.

`contentDigest` covers the exact canonical input that Swift will give the
adapter for that generation turn. For the first turn it must equal the frozen
`modelInputDigest`. For a resume it covers the complete semantic request,
including any prior content the provider protocol requires Swift to resend, the
entire tool-result batch, and all new context. The Swift adapter rejects a
payload whose canonical digest or source revisions do not match the disclosure.

Tool manifests declare possible output data classes, and each normalized tool
result carries actual data-class and sensitivity labels. The resume disclosure
uses the conservative union of manifest declarations, result labels, and any
new context labels; a missing or unknown label defaults to high-sensitivity
`unknown_data` rather than routine text. A later component cannot downgrade a
label already attached by an earlier source.

High-sensitivity context, sensitive attachments, or tool results outside the
currently approved disclosure scope require an incremental per-run approval.
Swift moves the session to `awaiting_incremental_egress_approval` and does not
encode, credential, or create the affected network request until the new grant
is recorded. A user-approved scope grant is bound to run ID, allowed data
classes, maximum sensitivity, Provider Profile revision, and exact origin. For
cloud routes it is also bound to the pinned credential generation, immutable
Provider retention mode, and retention-approval revision/digest when stateful. For
every turn, Swift creates a derived `GenerationEgressAuthorization` bound to
that grant ID, credential generation, generation turn ID, content/source
digests, retention mode, and exact request scope. Changed content within the
approved scope receives a new derived authorization without another prompt; a
scope expansion or retention-mode change requires a new user grant. No
authorization can be reused for a later changed payload, credential generation,
or retention decision.

The scope-grant digest is
`CanonicalDigestV1(egress-scope-grant:v1, complete grant document)` and every
derived authorization digest is
`CanonicalDigestV1(egress-generation-authorization:v1, complete authorization
document)`. `priorScopeGrantDigest` and the egress audit chain refer only to
these registered values.

The incremental approval sheet shows the exact approved origin plus the
manifest-localized source kinds/tool names, added item counts, size bucket, and
new data classes from the Swift-only `EgressApprovalDisplaySummary`. It does not
offer a raw-data preview or log the underlying values.

If the user denies the initial disclosure, Swift aborts preparation before the
first outbound request. If the user denies an expanded disclosure after tools
have run, Swift submits non-retryable `egress_denied`; Rust terminates the run as
failed with `execution.egress_denied`. In both cases denial stops the affected
outbound request, not merely the first request in the run.

Local inference does not create a remote egress decision.

### Network Rules

- HTTPS only.
- Exact-origin allowlist.
- No embedded URL credentials.
- Literal private, loopback, link-local, documentation, benchmark, multicast,
  and otherwise reserved addresses are rejected.
- Hostname resolution is checked during Profile validation and immediately
  before task creation; empty, mixed public/private, or changed-to-forbidden
  answers are rejected before the request body is handed to URLSession.
- Redirects may not change origin.
- The process-bound URLSession transport uses normal hostname/SNI/certificate
  trust. Its preflight DNS classification reduces rebinding exposure but cannot
  prove that URLSession's actual peer IP equals a preflight answer. Phase 3 does
  not claim peer-IP pinning or complete DNS-rebinding prevention. Adding that
  guarantee would require a separately designed pinned-peer HTTP/TLS transport,
  not a server-trust challenge re-query.
- Audit records contain only redacted origin and disclosure identifiers.

## Capability Matrix

### Capability Shape

```swift
struct LLMCapabilities: Codable, Sendable {
    var textInput: SupportState
    var imageInput: SupportState
    var audioInput: SupportState
    var videoInput: SupportState
    var documentInput: SupportState
    var structuredOutput: SupportState
    var toolCalling: ToolCallingCapability
    var streaming: SupportState
    var cancellation: SupportState
    var reasoning: ReasoningCapability
    var contextWindowTokens: BoundedCapability<UInt64>
    var maxOutputTokens: BoundedCapability<UInt64>
    var usageReporting: SupportState
    var parameterSchema: LLMParameterSchema
}

enum SupportState: String, Codable, Sendable {
    case supported
    case unsupported
    case unknown
}
```

Tool calling distinguishes unsupported, sequential, and parallel model
emission. Parallel emission means one turn may return multiple call IDs; V1
still executes that complete batch sequentially. Reasoning capability describes
supported control modes without exposing a provider request field.

### Provenance

Every material capability is derived from structured observations rather than
a source-name list:

```swift
struct CapabilityObservation: Codable, Sendable {
    let capabilityID: String
    let dimension: CapabilityDimension
    let value: CapabilityValue
    let source: CapabilitySource
    let authority: CapabilityAuthority
    let subject: CapabilitySubject
    let adapterOrEngineVersion: String?
    let observedAt: Date
    let expiresAt: Date?
    let validationScope: ValidationScope
    let invalidationTriggers: Set<CapabilityInvalidationTrigger>
    let evidenceDigest: String
}

struct CapabilitySubject: Codable, Sendable {
    let adapterID: String?
    let engineID: String?
    let providerProfileID: String?
    let providerProfileRevision: UInt64?
    let credentialGeneration: UInt64?
    let providerRetentionMode: ProviderRetentionMode?
    let retentionApprovalRevision: UInt64?
    let retentionApprovalDigest: String?
    let llmTargetID: LLMTargetID?
    let llmTargetRevision: UInt64?
    let modelID: String?
    let modelRevision: String?
    let catalogRevision: UInt64?
}

enum CapabilityDimension: String, Codable, Sendable {
    case adapterCanEncode
    case engineCanExecute
    case endpointSupports
    case modelSupports
    case availabilityValidated
}
```

`evidenceDigest` is
`CanonicalDigestV1(capability-evidence:v1, redacted typed evidence)`. The
derived observation identity is
`CanonicalDigestV1(capability-observation:v1, complete observation)`, including
that evidence digest. Raw provider bodies and diagnostics are never evidence
documents. The resolved capability snapshot hash is
`CanonicalDigestV1(capability-snapshot:v1, exact subject + resolved values +
sorted contributing observation digests + nearest expiry)`. Therefore the
observation digest and snapshot hash carried by the generic Rust attestation
are registered values, not provider-adapter hashes.

`subject` records every identifier that scopes the observation. Fields may be
absent only when the observation is genuinely broader: for example, an adapter
encoding observation has an adapter ID but no model, while provider-list
availability has an exact Provider Profile revision and Model ID but may precede
creation of an LLM target. An observation can contribute to a run attestation
only when its populated subject fields match the selected route exactly.
Authenticated availability/validation observations must include the exact
credential generation and Profile retention mode/approval revision; static
catalog or adapter observations leave those fields absent.

The dimensions have distinct meanings:

- `adapterCanEncode` proves the shipped Swift adapter can represent the feature.
- `engineCanExecute` proves the compiled local engine can execute it.
- `endpointSupports` proves the selected Provider Profile revision exposes it.
- `modelSupports` describes the exact model revision's semantic capability.
- `availabilityValidated` proves only that the target was reachable and
  callable at a point in time.

Provider model-list membership may create only an
`availabilityValidated(model_exists)` observation. A generic connectivity probe
may create only the exact scopes it exercised, such as authentication,
streaming text, or a specific tool-call probe. Neither source may infer
multimodal, reasoning, context-window, or tool capabilities that it did not
exercise.

### Authority Rules

Authority is applied per dimension:

1. A shipped adapter or compiled engine is authoritative about what the app can
   encode or execute. Its explicit `unsupported` is a hard negative.
2. A signed official local model manifest is authoritative about intended local
   model capabilities, intersected with the engine observation.
3. A maintained provider/model capability catalog is authoritative about cloud
   model semantics for its exact model revision, intersected with adapter and
   endpoint observations.
4. Provider model lists are authoritative only for transient availability.
5. Validation probes are authoritative only for their recorded scope and
   lifetime.
6. Manual Model IDs begin with unknown model semantics.

A capability is `supported` only when the exact model plus the selected route's
adapter/engine requirements are supported and no authoritative dimension is
unsupported. An authoritative hard negative wins. Conflicting positive claims
without sufficient authority become `unknown`. Numeric limits use the lowest
non-expired verified bound.

### Time and Invalidation

- Adapter and engine observations have no wall-clock expiry but invalidate when
  the app build, adapter version, engine version, or relevant OS capability
  changes.
- Signed catalog observations remain valid until superseded, revoked, or made
  incompatible by an adapter/engine change.
- Provider model-list and connectivity observations receive an explicit
  `expiresAt` from the Provider Preset policy; the v1 default is 24 hours.
- A failed authentication, missing-model, or unsupported-feature response
  invalidates the matching observation immediately.
- Base URL revision, credential rotation, model ID, Provider Profile revision,
  catalog revision, adapter version, engine version, and app build are explicit
  invalidation triggers.

Expired observations do not contribute to an attestation. The Phase B
capability attestation contains the observation digest and nearest expiration;
`commit_start` rejects an expired or invalidated attestation.

Readiness is evaluated separately from capability and may block an otherwise
capable target because an installation, credential, approval, availability
validation, or compatible observation is missing.

Unknown never means supported. In particular, an unknown model is not assumed
to support tool calling, multimodal input, structured output, or reasoning
controls.

Phase 3 publishes only text input/output, streaming, cancellation, usage, and
tool-calling capability observations. `imageInput`, `audioInput`, `videoInput`,
and `documentInput` remain `unknown` even when provider marketing or a model
list claims support, because Phase 3 has no attachment byte resolver, upload or
inline encoder, lifetime cleanup, or data-label enforcement path. A cloud turn
that contains an attachment identity is digest-validated but rejected with
`capability.cloud_attachment_path_unavailable` before egress authorization.
Multimodal support requires a later design for resolved bytes/streams,
hash/size/media-type verification, disclosure labels, upload/inline lifecycle,
and cleanup tests; catalog data alone cannot enable it.

## Parameter System

### Canonical Parameter Definitions

Swift defines stable semantic IDs:

```text
sampling.temperature
sampling.top_p
sampling.top_k
sampling.min_p
sampling.repetition_penalty
generation.max_output_tokens
generation.seed
generation.stop_sequences
reasoning.effort
reasoning.token_budget
output.verbosity
```

Each definition includes:

```text
value type
generation or load scope
default value
minimum, maximum, and step
enumerated choices
dependencies
mutual exclusions
availability condition
provenance
```

Provider field names and C++ backend option names are not canonical parameter
IDs. Adapters map semantic values to concrete requests.

### Parameter Resolution

```text
catalog model defaults
  -> LLMTarget defaults
  -> AgentHostConfiguration overrides
  -> provider/engine constraints
  -> device safety policy
  -> ResolvedGenerationConfiguration
```

The resolved configuration is immutable for the run.

Rules:

- The UI renders only parameters supported by the selected model and adapter.
- Unsupported parameters are rejected rather than silently sent.
- A provider-documented ignored parameter is treated as unsupported.
- Conditional incompatibilities dynamically change the schema. For example,
  enabling a reasoning mode may disable sampling controls.
- Switching models preserves only parameters with compatible semantic IDs and
  valid values. Removed overrides are shown to the user.
- Local load parameters that can destabilize the app remain controlled by the
  signed model manifest and device policy in v1.
- Provider and engine adapters validate once more immediately before execution.
- Rust never receives provider parameter names or local engine option names.

## Durable Global Agent Run Lease

Rust owns one route-neutral lease row in its SQLite store:

```text
GlobalRunLease
  leaseGeneration
  ownerRunID
  preparationID, for host_slot_v2 preparation
  bindingSchema: legacy_v1 | host_slot_v2
  hostProcessEpoch
  state: preparing | active | releasing
  preparationExpiration, when preparing
```

The lease is the authority for the one-Agent-run product rule.
`ActiveExecutionRunRegistry` and the Swift coordinator are caches/gates, not
proof that the device is free.

Acquisition rules are:

1. Swift first takes its advisory actor reservation before invoking either
   route, preventing avoidable duplicate UI work.
2. `host_slot_v2 preview_run` performs a durable CAS from empty to
   `preparing` before preview resolution. Renewal updates the same lease
   generation. Preview failure, abort, or preparation expiry moves it through
   route cleanup and releases it.
3. `commit_start` performs another CAS that verifies lease generation,
   preparation ID, proposed run ID, token, and host epoch, then promotes
   `preparing -> active` in the same Rust transaction as the run snapshot,
   worker state, and first outbox row.
4. `legacy_v1 start_run` receives the current host epoch and performs the same
   empty-to-active CAS before `RunSnapshotResolver::resolve_and_persist` or plan
   creation. Resolution/start failure compensates and releases the lease.

A busy CAS returns `execution.global_run_busy`; neither route may fall through
to its resolver or create a second snapshot. A run terminal transition changes
the lease to `releasing`. Before commit, a registered V2 preparation releases
it only after the matching `prepared_session_closed` receipt; after commit, V2
releases it only after `session_closed`. Either may instead finish through
old-epoch recovery. Legacy releases it only after its Rust-owned backend/worker
cleanup completes. Thus a new run cannot start while a previous provider/C++
operation is merely acknowledged for close but may still be alive.

On bootstrap, every preparing, active, or releasing lease from an older host
epoch is reconciled before run replay or UI pending actions. Its route's
nonterminal run is interrupted, pending tool/approval/outbox work is
invalidated, process-bound backend state is treated as gone, and the lease is
released transactionally. This applies equally to `legacy_v1` and
`host_slot_v2` during Phase 4 coexistence.

## Global Runtime Coordinator

`LLMRuntimeCoordinator` is a Swift global actor-backed service. Its reservation
improves UX, but every start still requires the Rust durable lease CAS.

```text
idle
  -> preparing
  -> awaiting_initial_egress_approval
  -> loading_local | opening_cloud_session
  -> generating
  <-> awaiting_tool_result
  -> awaiting_incremental_egress_approval
  -> generating
  -> completing
  -> closing
  -> idle
```

Every non-terminal state may transition through:

```text
cancelling -> closing -> idle
failed -> closing -> idle
close_timeout -> quarantined
preparation_cleanup_timeout -> quarantined
quarantined -> idle, only after the matching prepared/run close receipt or a new host epoch
```

Invariants:

- There is at most one active agent/LLM session globally, enforced by the Rust
  lease rather than actor state alone.
- A new preparation/run is rejected while the durable lease is preparing,
  active, or releasing.
- `idle` requires the applicable `prepared_session_closed`, `session_closed`, or
  legacy cleanup result plus an empty Rust global run lease. A quarantined
  same-epoch session keeps the coordinator non-idle and blocks new runs.
- An active run cannot switch target or parameter revision.
- Editing configuration during a run affects only the next run.
- Local preparation verifies installation before loading C++.
- Cloud preparation unloads the local RAM model before opening the provider
  session.
- Tool execution occurs in Rust while the Swift LLM session remains reserved.
- A remote resume request cannot leave
  `awaiting_incremental_egress_approval` until its exact disclosure is granted.
- Cancellation is idempotent and propagates to Rust and the active URLSession
  task or C++ generation session.
- No backend or model fallback occurs automatically.
- Downloads may recover after process termination; generations do not.

## Persistence

Swift owns a versioned `LLMStore` abstraction with a SQLite implementation.

Phase 3 performs one transactionally complete `user_version = 2` migration
before any cloud behavior is enabled. Version 2 creates the final Phase 3 table
set up front, including currently empty tables whose behavior lands in later
tasks:

```text
provider_profile_revisions, provider_profile_state, llm_target_revisions
provider_origin_approvals, provider_retention_approvals
credential_creation_operations, credential_slots, credential_use_leases
credential_operation_tombstones, credential_key_tombstones
egress_scope_grants, egress_generation_authorizations, egress_audit_records
cloud_catalog_state, cloud_capability_observations, provider_validation_records
prepared_cloud_sessions, cloud_session_tombstones, sanitized_llm_snapshots
```

The migration preserves the existing host-binding/prepared-session tables,
runs under `BEGIN IMMEDIATE`, updates `PRAGMA user_version` only after all DDL
and indexes succeed, rolls back completely on injection at every statement,
and refuses to open a version newer than the runtime supports. Every table is
present in Task 2; later Phase 3 tasks add behavior and rows, not schema.

Every persisted JSON envelope has an indexed integer
`record_schema_version` column and the same required version inside
`record_json`. Security/policy enums use explicit tagged manual encoding;
synthesized Codable evolution is forbidden. Version-2 decoders accept only the
complete version-2 shape, except for fields explicitly documented as
non-authoritative optional metadata. An unknown record version or enum tag
fails closed. Any later DDL or authoritative payload-shape change requires
`user_version = 3`, a transactional migration, rollback tests, and reopen
fixtures for every older supported version; it cannot be smuggled into a later
Phase 3 task.

SQLite stores:

```text
Provider Profile metadata
Provider retention mode and non-secret approval revision/evidence digest
LLM Target revisions
AgentHostConfiguration revisions
capability catalog revision and provenance
parameter defaults and overrides
local installation records
download task and resume metadata
egress grants and validation state
private non-secret egress subjects and attestation digests
append-only generation disclosure/grant audit rows
CredentialSlotState, rotation/deletion operation intents and tombstones
credential creation operation intents and staged/finalized state
normalized CredentialUseLease rows
sanitized LLM run snapshots
```

SQLite never stores:

```text
API keys
raw provider payloads
provider-private reasoning or signatures
live LLMSessionHandle values
unredacted request/response bodies
```

Local file paths stay inside the Swift local-model subsystem. UI DTOs expose
opaque installation IDs and display-safe storage metadata.

Rust separately persists only the route-neutral global run lease, Agent-owned
preparation leases/digests, resumable worker state, opaque Swift cross-links and
egress attestation digests, host-command outbox rows, and event receipt ledger.
An outbox row may retain the normalized Agent input/tool-result payload only
until Swift acknowledges that command; Rust then removes the payload and keeps
the command identity and digest needed for audit/deduplication. Rust never
persists the provider-encoded request or a credential.

## Cross-Store Consistency

Rust and Swift use different SQLite stores and cannot share an ACID transaction.
Swift must not copy the Rust Agent Profile or Package records into its store.
Cross-store operations use an explicit saga with stable idempotency keys,
pending/active states, compensation, and startup reconciliation.

### Profile Publish Saga

```text
1. Rust prepare_profile_publish(idempotency_key)
     -> pending profile revision
     -> LLMSlot + requirements hash
     -> publish token

2. Swift stage_host_binding(publish token)
     -> pending AgentHostConfiguration binding ID, revision, and hash
     -> HostBindingStagingReceipt bound to
        CanonicalDigestV1(saga-token:v1, publish token), slot, and
        requirements hash

3. Rust commit_profile_publish(
       publish token,
       binding ID,
       binding revision,
       binding hash,
       HostBindingStagingReceipt)
     -> visible profile revision
     -> persisted opaque host-binding cross-link

4. Swift activate_host_binding(
       publish token,
       binding ID,
       binding revision,
       binding hash)
     -> active binding revision
```

Rules:

- Every step is idempotent by the same operation key.
- The pending Rust publication is already bound to profile revision, LLM slot
  ID, and requirements hash. At commit, Rust validates the staging receipt and
  atomically binds that pending record to the staged binding tuple. It rejects
  a receipt/token mismatch or a tuple that differs from the Swift staging
  result.
- A Swift staging failure aborts the pending Rust publication.
- A Rust commit failure deletes or expires the pending Swift binding.
- A crash after Rust commit but before Swift activation leaves the profile
  visible but `host_unbound`; it is not runnable.
- Startup reconciliation retries Swift activation only when binding ID,
  revision, hash, slot, and requirements match on both sides; otherwise it
  exposes a repair action.
- A committed Rust profile is not destructively rolled back merely because the
  host binding is temporarily unavailable.

This makes the failure state explicit instead of pretending the two databases
can commit atomically.

### Agent Package v2

The current package model manifest and concrete model selection are replaced in
Agent Package v2 by portable LLM slots:

```text
llm slot ID
required capabilities
required input modalities
minimum context budget
streaming and tool-calling requirements
optional model family or model ID hint
```

An Agent Package never contains a Provider Profile, API key, CredentialRef,
Base URL, local model path, installation ID, or Swift host binding.

Package installation remains one Rust transaction for the package, Agent
Profile, components, and portable LLM slot. It allocates a stable package
binding operation key and completes in `needs_llm_binding` readiness. The user
may then select an existing compatible target or finish creating one.

The package binding saga is:

```text
1. Rust begin_package_binding(installation ID, operation key)
     -> installed profile revision
     -> LLM slot + requirements hash
     -> package binding token

2. Swift stage_host_binding(package binding token)
     -> pending AgentHostConfiguration binding ID, revision, and hash
     -> HostBindingStagingReceipt bound to
        CanonicalDigestV1(saga-token:v1, package binding token)

3. Rust attach_host_binding(
       package binding token,
       binding ID,
       binding revision,
       binding hash,
       HostBindingStagingReceipt)
     -> package/profile readiness becomes host_binding_attached

4. Swift activate_host_binding(
       package binding token,
       binding ID,
       binding revision,
       binding hash)
     -> active binding revision and runnable readiness
```

Each step is idempotent. A failure before Rust attachment removes or expires the
pending Swift binding. A crash after attachment but before activation leaves the
profile visible but not runnable; startup reconciliation activates the matching
record or returns it to `needs_llm_binding` with a repair action. The staging
receipt is checked against the package token, slot, requirements, and full
binding tuple. Rust stores only the opaque binding ID/revision/hash and never
the target, provider, model, or path.

Export carries requirements and optional hints, not the device-local binding.

Legacy v1 packages are imported by translating their model manifest into an
optional hint plus a required LLM slot. Their concrete provider/model binding
is not installed into the new product path.

### Run Cross-Link

The two-phase run handshake is also the run saga. The Rust run snapshot stores:

```text
LLM slot ID and requirements hash
opaque host binding ID, revision, and hash
opaque Swift LLM snapshot ID
host process epoch
global run lease generation
opaque EgressAttestationDigest
stable preparation ID and final consumed token digest
```

The Swift LLM snapshot stores:

```text
proposed Rust run ID, which becomes the committed run ID
agent profile ID and revision
LLM slot ID
host binding ID, revision, and hash
host process epoch
private egress subject, credential generation plus CredentialUseLease ID/digest,
Provider retention mode plus approval revision/digest when remote, and
EgressAttestationDigest
stable preparation ID and final consumed token digest
LLM target and sanitized runtime configuration
```

Both `final consumed token digest` fields mean exactly
`CanonicalDigestV1(preparation-token:v1, the consumed token document)`; the
phrase does not introduce another digest schema. Profile-publish and
package-binding token digests similarly mean `saga-token:v1` with their exact
operation kind.

The stable preparation ID, shared digests, and idempotency key prove that both
snapshots describe the same preparation without making Rust understand the
target. A mismatch blocks the run and enters a repairable
`host_binding_conflict` state.

### Provider and Target Deletion

Provider Profile and LLM target revisions referenced by Agent bindings or run
snapshots are archived, not hard-deleted. Archiving:

- prevents new sessions;
- makes dependent Agent bindings not ready;
- retains immutable, non-secret revision metadata and hashes for explanation
  and audit; and
- permits garbage collection only after no binding, package install record, or
  retained run snapshot references the revision.

Credential deletion is a separate logical-Profile deletion operation governed
by the Keychain reference and active-session rules above. It is never a side
effect of archiving one revision or one LLM target.

Deleting an installed local model similarly leaves Agent bindings intact but
not ready, so the UI can identify the exact model that must be downloaded.

### Startup Reconciliation

Before a run can start, Swift and Rust exchange their latest operation
idempotency keys and reconcile:

```text
pending profile publications
pending and active host bindings
package installations awaiting LLM binding
pending run preparations
registered prepared sessions and preparation cleanup operations
run snapshot cross-links
credential slot operations and CredentialUseLease rows
archived provider/target revisions
```

Reconciliation is repeatable and converges pending operations to active,
aborted, expired, or repair-required. It never resolves a conflict by silently
choosing the latest target.

## Sanitized Run Snapshot

Swift records a run-level LLM snapshot containing:

```text
Rust run ID
agent profile ID and revision
LLM slot ID and requirements hash
host binding ID, revision, and hash
LLM target ID and revision
route class: local or cloud
model ID
credential generation plus CredentialUseLease ID/digest when remote
Provider retention mode and approval revision/digest when remote
capability snapshot hash
resolved non-secret generation parameters
initial modelInputDigest and source revision digest
initial egress disclosure, scope-grant, and generation-authorization IDs when remote
opaque egress-subject digest and EgressAttestationDigest
append-only generation disclosure/grant audit hash
adapter or engine version
host process epoch
global run lease generation
stable preparation ID and final consumed token digest
```

Here `capability snapshot hash` is `capability-snapshot:v1`, the disclosure and
grant audit hash is the current `egress-audit-chain:v1` head, and the final
token digest is `preparation-token:v1`. Each child audit row contributes its
registered disclosure/grant/authorization digests to the next chain document;
none of these labels permits an implementation-private hash.

Each generation disclosure and grant is an append-only child record keyed by
generation turn ID. The snapshot stores the current hash-chain head, so an
incremental approval can be audited without rewriting or exposing earlier
content.

The snapshot does not contain the API key, absolute local path, full request,
provider-private continuation state, or raw provider failure body.

Rust persists the opaque Swift snapshot ID, host binding ID/revision/hash,
process epoch, global run lease generation, `EgressAttestationDigest`, stable
preparation ID, and final token digest for cross-linking. Swift remains the
owner and resolver of the LLM target and runtime configuration behind that
snapshot.

## Failure Model

Swift uses stable error namespaces:

```text
configuration.*
capability.*
download.*
installation.*
credential.*
egress.*
local_engine.*
provider.*
transport.*
stream.*
generation.*
cancellation.*
```

Every failure contains:

```text
stable code
safe user-facing message
retryable flag
recovery action
redacted diagnostics
```

Only the following agent-relevant categories cross to Rust:

```text
not_ready
unsupported_capability
context_exceeded
egress_denied
rate_limited
generation_failed
stream_interrupted
cancelled
```

`execution.llm_continuation_lost` and
`execution.continuation_expired` are Rust run-recovery errors, not Swift
`AgentLLMFailure` categories, so they remain in the Rust execution namespace.
Likewise, `llm.preparation.*`, `llm.command.*`, `llm.event.*`, `llm.turn.*`,
`llm.cancel.*`, and `llm.session.*` describe Rust bridge protocol
violations/timeouts. They interrupt or fail the preparation/run
deterministically and are not remapped to a provider error.

Raw HTTP status details, response bodies, endpoints, and engine-private messages
remain in Swift diagnostics and must be redacted.

## Retry and Recovery

- Background model downloads resume when valid system resume data exists.
- A corrupted local artifact is redownloaded; it is never installed anyway.
- Launch reconciliation compares SQLite, staging directories, installed
  directories, URLSession tasks, and Keychain availability.
- A missing Keychain item produces `credential.missing`, not a provider call.
- Cloud auto-retry is allowed only before any text, reasoning summary, tool call,
  or usage event has been emitted.
- Retryable transport and provider-unavailable failures use bounded exponential
  backoff and respect `Retry-After`.
- A stream interruption after output is terminal for that generation and is not
  replayed automatically, preventing duplicate tool calls.
- Local load failure releases partial native resources before returning.
- Cancellation is terminal and idempotent.
- There is no automatic model fallback.
- On process termination, active runs become interrupted; live provider
  continuation state is not reconstructed in v1.

### Process Restart and Ephemeral Continuation

During Phase 4 coexistence, every `legacy_v1` and `host_slot_v2` preparation/run
plus the shared global lease is bound to the app host process epoch. A new app
process has an empty Swift session registry, no trustworthy legacy provider
continuation, and a new epoch. Before pending tools or approvals are exposed to
the UI, startup reconciliation finds every non-terminal Rust run whose snapshot
or lease references an older epoch.

Runtime bootstrap must be reordered accordingly: Swift supplies the new host
epoch before Rust reconstructs actionable waiting state. Rust opens storage,
invalidates older-epoch continuations transactionally, and only then runs any
remaining replay logic. The current `AgentRuntime::with_store` behavior that
calls `replay_waiting_runs` during construction must be split so LLM-dependent
runs cannot become actionable before invalidation.

An old-epoch uncommitted preparation is reconciled separately: Rust marks its
registered prepared session closed with the persisted `epoch_ended`
preparation-close disposition, cancels its cleanup outbox, and releases the
preparing/releasing global lease in one transaction. Swift deletes the matching
old-epoch `CredentialUseLease` only after confirming there is no current-process
task/session for it. No `run.interrupted` event is created because no run was
committed.

Affected committed-run states include:

```text
legacy_starting_or_running
awaiting_start_command_ack
awaiting_generation_started
consuming_llm_turn
executing_tool_batch
suspended_for_tool_approval
awaiting_incremental_egress_approval
awaiting_resume_command_ack
awaiting_cancel_command_ack
awaiting_cancelled_terminal
awaiting_close_command_ack
awaiting_session_closed
```

Rust performs one recovery transaction per affected run:

1. Append a terminal `run.interrupted` event with
   `execution.llm_continuation_lost`.
2. Mark the run interrupted and remove it from the active-run registry.
3. Invalidate every pending tool request and approval for that run.
4. Mark its preparation/session cross-link expired.
5. Cancel every pending old-epoch V2 host-command outbox row or mark the legacy
   backend continuation abandoned.
6. Release the matching durable global run lease after old-process resources
   are treated as gone.
7. Record the host epoch mismatch for diagnostics without persisting provider
   continuation state.

Only after these transactions commit may the app list actionable pending tools
or approvals. A late approval, rejection, tool result, command acknowledgement,
or stream event returns the stable error `execution.continuation_expired`. It
does not restart the model request, recreate a Provider Session, or append the
result to another run.

This intentionally replaces the current behavior that replays waiting-tool and
suspended runs after SQLite restart when either route depended on process-bound
model continuation state.

### Host Tool Effect Idempotency

Every host tool action receives a stable effect ID derived from run ID, tool
call ID, and tool name. Swift persists an effect ledger before executing a
side-effecting tool:

```text
prepared
committed(result digest and safe replay envelope)
outcome_unknown
```

The committed `result digest` is exactly
`CanonicalDigestV1(host-tool-effect-result:v1, safe replay result document)`.
It is not an adapter-private hash.

- Repeating a committed effect ID returns the recorded safe result and does not
  execute the effect again.
- A crash after `prepared` but before a committed result produces
  `outcome_unknown`; startup must not automatically re-execute it.
- Re-submitting an `outcome_unknown` effect returns
  `tool.effect_outcome_unknown` and requires a tool-specific reconciliation or
  user decision.
- Read-only tools may opt into safe retry only when their manifest declares the
  operation idempotent.

The design does not claim exactly-once execution for arbitrary device APIs. It
guarantees that recovery never blindly repeats a possibly committed side
effect.

## Testing Strategy

### Swift Contract Tests

- Swift passes every shared `CanonicalDigestV1` golden fixture and rejects
  malformed, null-ambiguous, non-finite, or unregistered digest documents.
- Capability authority, dimension, expiry, and invalidation rules.
- Provider-list and generic probes cannot overclaim model semantics.
- Conservative handling of unknown capabilities.
- Parameter range, dependency, and mutual exclusion validation.
- Parameter preservation and pruning on model switch.
- Target and Agent Host Configuration revision pinning.
- Global single-run state-machine invariants.
- Generation disclosures are bound to exact content/source digests; unknown
  tool-result labels conservatively require approval.
- `CloudSemanticTurnValidator` recomputes `agent-input:v1` and
  `source-revisions:v1` from messages, complete tool schema, source document,
  attachment identities, complete tool-result batch, and semantic continuation;
  no adapter accepts an unvalidated turn.
- Grant-neutral source summaries and Swift-only grant-delta summaries contain
  only manifest-controlled enums/keys, counts/buckets, and new classes; raw
  values cannot enter approval UI/logs.
- Provider/origin/credential/grant semantics remain inside the private egress
  subject while the public opaque attestation binds the required generic fields.
- Credential slot state is the only generation authority; a transactional use
  lease closes the preparation/rotation TOCTOU, and `rotating`/`deleting`
  reject every new key user.
- Credential creation is a persisted staged-item saga; crashes before and after
  slot publication reconcile by operation identity without scanning or guessing
  about orphan Keychain items.
- Rotation is blocked by validation/preparation/live/closing use leases;
  successful rotation increments generation and invalidates old
  validation/grants for every profile sharing the slot.
- Archiving one Provider Profile revision retains a CredentialRef still used by
  another revision; logical-profile deletion reconciles Keychain tombstones.
- The complete Phase 3 SQLite schema is created atomically at user version 2;
  all older-version reopen, rollback, future-version rejection, record-version,
  and unknown-tag fixtures pass before later cloud tasks add rows.
- Stateless retention is the default and adapter requests prove no-storage
  encoding; provider-side state requires a Profile revision plus retention
  approval bound into egress and capability state.
- Only tagged generation/validation/discovery requests can reach transport;
  bare wire requests and forged cross-class authorizations are rejected.
- Phase 3 cloud capabilities keep every attachment modality unknown and reject
  attachment-bearing turns before egress because no byte/upload path exists.
- URLSession tests prove exact origin/redirect rules and preflight rejection of
  literal, reserved, mixed, or changed-to-forbidden DNS answers; they do not
  claim peer-IP pinning.
- Sanitized snapshots and error redaction.

### Provider Adapter Fixture Tests

Each provider adapter has recorded, secret-free fixtures covering:

- request encoding;
- standard and reasoning parameter mapping;
- text streaming;
- tool-call argument deltas;
- mixed text/tool-call turns and ordered multi-call terminal batches;
- tool-result continuation;
- provider-private thinking/signature preservation;
- retention/no-storage request mapping and forbidden server-side continuation
  under `statelessRequired`;
- usage normalization;
- unknown event forward compatibility;
- rate-limit and authentication errors;
- cancellation command acceptance;
- command-acknowledged versus generation-started/cancelled/session-closed
  lifecycle signals; and
- terminal event enforcement.

Claude fixtures determine whether thinking deltas are displayable from the
sealed request's `thinking.display`, not a response-only marker. Gemini
fixtures use the `error` SSE event and treat failed/cancelled/incomplete/budget
outcomes as interaction status values.

CI must not require live provider credentials. Optional manual smoke tests may
use real credentials outside CI and must never record responses containing user
data or secrets.

### Local Model Tests

- Signed catalog verification and rollback protection.
- Download queue, pause, resume, and resume-data failure.
- Disk preflight and insufficient-space repair actions.
- SHA-256 mismatch.
- Atomic install and launch reconciliation.
- Backup exclusion.
- Delete-while-loaded rejection.
- Fake C++ engine load, generate, stream, cancel, and unload.
- GGUF/custom chat-template selection is rendered in C++ while tool-call output
  is parsed in Swift.
- One real smoke model per release engine in the appropriate release gate.

### Rust Boundary Tests

- Rust passes the common `CanonicalDigestV1` corpus and every domain it
  computes/recomputes; Swift-private inner-domain digests remain opaque, and
  ordinary serde JSON byte order never affects a digest.
- The agent kernel depends only on the abstract LLM client port.
- Rust product code does not construct or resolve Provider Profiles, model
  installations, Base URLs, credentials, model paths, or backend adapters.
- The resumable worker persists and yields before host generation.
- Worker state and each `HostCommandEnvelope` outbox row commit atomically;
  crash injection between commit, copy receipt, and command acknowledgement
  cannot strand a run or duplicate execution.
- No Swift host vtable callback occurs while the Rust runtime mutex is held.
- Event sequence duplication, gaps, terminal/stale return values, receipt
  persistence, retry decisions, and bounded backpressure follow the complete
  result matrix.
- Repeating an event sequence with a different event ID/digest interrupts;
  old-epoch or tombstoned handles never match a new session.
- Rust validates only the public binding of `EgressAttestationDigest` and has no
  Provider Profile, origin, credential-generation, or grant parser.
- Command acknowledgement cannot satisfy generation-start, cancel-stop, or
  session-close watchdogs.
- The route-neutral durable global run lease CAS admits exactly one legacy/V2
  owner and is released only after route cleanup.
- Cancellation/final-event races produce one deterministic terminal state.
- Preparation tokens rotate idempotently on valid renewal, expire at the total
  lease bound, abort idempotently, and reject stale input/source digests.
- A registered pre-commit session can leave `preparing` only through successful
  commit or an exact preparation-cleanup command/close receipt; denial, expiry,
  commit conflict, duplicate cleanup, lost acknowledgement, and restart are
  crash-injected.
- Start/resume command acknowledgement timeout and deduplication use the same
  command ID, sequence, and full command-envelope digest, including disclosure.
- Rust waits for `generation_completed`, rejects malformed tool batches, and
  executes a valid multi-call batch sequentially before one batched resume.
- Normalized text and tool-call events drive the resumable agent worker.
- Swift-side cancellation terminates the Rust run.
- A host LLM failure maps to the limited agent-facing failure taxonomy.
- During migration, architecture lint rejects growth of the checked-in legacy
  allowlist. After Phase 5 the broad allowlist is deleted: production Rust
  rejects provider or engine ownership everywhere except two targeted,
  non-executing read-only translation boundaries for known legacy Agent
  Profile records and schema-v1 Agent Package wire.

### End-to-End Tests

- Rust preview -> Swift prepare -> Rust commit starts exactly one run and links
  matching Rust/Swift snapshots.
- Failure injection at every Profile publish and Package binding saga boundary
  converges through compensation or startup reconciliation.
- Profile publication rejects a staged/committed binding ID, revision, or hash
  mismatch.
- Agent Profile -> Swift AgentHostConfiguration -> local fake engine -> Rust
  tool loop -> final response.
- Agent Profile -> Swift Provider fixture adapter -> Rust tool loop -> final
  response.
- Local/cloud switch affects only the next run.
- Missing download, credential, capability, or egress approval blocks before
  Rust starts the agent run.
- A sensitive tool result pauses before its resume network request, records an
  incremental digest-bound grant, and maps denial to
  `execution.egress_denied` without sending that result.
- A concurrent preparation-use-lease acquisition and rotation CAS has exactly
  one winner. Rotation is rejected during prepared/live use; after prepared
  cleanup or `session_closed`, it advances generation and requires fresh
  validation/grant before another request.
- User denial, token expiry, commit rejection, and commit conflict after
  prepared-session registration each persist the same idempotent cleanup
  command, and the global run lease remains releasing until its exact close
  receipt or old-epoch reconciliation.
- Crash injection after Rust outbox commit and before Swift acknowledgement
  redispatches the same command identity without a duplicate provider request.
- Conflicting duplicate event envelopes and an old-handle ABA attempt are
  rejected without advancing the worker.
- A late delta submitted after a turn/generation terminal is receipt-consumed,
  so the next `session_closed` sequence is accepted; stale/closed handles do not
  consume or ask Swift to retry.
- An accepted cancel without backend `cancelled` hits the stop watchdog; an
  accepted close without `session_closed` quarantines the session ledger.
- Concurrent `legacy_v1 start_run` and `host_slot_v2 commit_start` attempts
  produce one winner and one `execution.global_run_busy` without a losing
  snapshot/worker.
- `legacy_v1` remains runnable through Phases 1-3 while `host_slot_v2` remains
  non-runnable until the Phase 4 route switch.
- Restart invalidates legacy/V2 waiting-tool/approval state and releases the
  old-epoch global lease before pending actions are exposed; late results return
  `execution.continuation_expired`.
- A committed or outcome-unknown host tool effect is never automatically
  executed twice.

## Migration from the Current Codebase

The current repository contains Rust provider/model/inference product paths and
a Swift Model Center that projects Rust provider profiles. Migration must avoid
a permanent dual architecture.

### Transitional Schema and Routing Rules

The migration uses an explicit tagged schema rather than changing the meaning
of an existing field:

```text
legacy_v1
  llm_binding_schema_version = 1
  concrete ModelBinding
  resolved by the existing RunSnapshotResolver and ModelRoutingClient

host_slot_v2
  llm_binding_schema_version = 2
  portable LLMSlotV2 + AgentLLMRequirements
  concrete AgentHostConfiguration exists only in Swift
```

A persisted profile or package-install record has exactly one tag and never
stores both binding forms. Readers support both tags during migration. Writers
preserve the tag for existing on-device records: editing a `legacy_v1` profile
continues to write the legacy shape until an explicit migration action
succeeds, while a new `host_slot_v2` writer never creates a concrete Rust model
binding. A newly imported schema-v1 package file passes through the V1-to-V2
translator and is stored as `host_slot_v2`; schema-v2 packages already use that
shape. Both install as `needs_host_binding` and are not sent through the legacy
resolver.

During Phases 1-3, production execution accepts only `legacy_v1`; V2 records may
be created, installed, and host-bound for validation but remain not runnable.
Phase 4 dispatches `host_slot_v2` through the host-backed worker while retaining
the legacy route for unmigrated V1 records. Phase 5 removes the legacy writer,
resolver, and execution route in one product cutover. The final binary retains
one isolated, read-only, non-runnable Agent Profile translator so a device can
upgrade directly from an old store, and the existing Agent Package reader
retains a private schema-v1-wire-to-V2 translator. Both immediately produce
provider-neutral V2 values and cannot construct a provider, credential,
concrete model binding, URL, engine, local path, or executable legacy route.

Architecture lint uses a checked-in temporary allowlist containing each
pre-existing legacy occurrence as `path + owning item + forbidden symbol`, plus
a non-increasing total count. It rejects a new `ModelBinding`, Provider Registry,
or Rust inference-router dependency even inside an already listed file. The
allowlist must shrink when code moves and is deleted entirely in Phase 5.
Targeted source-shape tests remain only for the two migration-only translators;
they forbid execution/provider ownership and ensure concrete legacy wire values
are discarded after portable V2 requirements and redacted hints are derived.

### Phase 1: Contracts, Slots, and Consistency Foundation

- Add Swift/Rust `CanonicalDigestV1` implementations and shared golden fixtures
  before introducing any cross-language digest contract.
- Add the durable route-neutral global run lease and place the legacy
  `start_run` CAS before its resolver; do not otherwise change legacy model
  resolution/execution semantics.
- Add Swift LLM contract, core, storage, capability, and parameter targets.
- Add `AgentHostConfiguration` and immutable `LLMTarget` revisions.
- Introduce portable `LLMSlotV2` and `AgentLLMRequirements` alongside the
  unchanged legacy `ModelBinding` contract.
- Add Agent Package v2 requirements/hints and the legacy v1 translation rule.
- Add profile publish/install host-binding saga records, idempotency keys, and
  startup reconciliation.
- Add the `preview_run`/`renew_preparation`/`commit_start`/
  `register_prepared_session`/`begin_abort_preparation`/prepared-session cleanup
  contracts without switching the production worker yet.
- Keep `RunSnapshotResolver::resolve_model_binding` and the active legacy
  model route unchanged behind the new lease gate.

### Phase 2: Local Product Path

- Add official catalog, downloader, installer, disk policy, and local runtime.
- Connect Swift directly to the existing C++ v2 engine boundary.
- Formalize the C++ v2 canonical message/tool-schema input and chat-template
  selector so llama.cpp remains the format-specific renderer.
- Extend the C++ boundary for capabilities, parameters, explicit unload, and
  the message/template contract required by this design.

### Phase 3: Cloud Product Path

- Add Provider Profiles, Keychain storage, egress, validation, and provider
  adapters.
- Create the complete cloud `LLMStore` schema in one atomic v1-to-v2 migration;
  later Phase 3 tasks populate the fixed schema without changing it.
- Validate every complete semantic start/resume request into a sealed
  `ValidatedCloudGenerationTurn` before approval or provider encoding.
- Route adapter output through a tagged generation/validation/discovery policy
  seal; transport never accepts a bare wire request.
- Add digest-bound initial and incremental `GenerationDisclosure` grants,
  safe display summaries, opaque egress attestations, conservative tool-result
  labeling, authoritative credential slot state, generation use leases,
  creation/rotation sagas, and tombstones.
- Default every Provider Profile to stateless/no-storage requests. Provider-side
  retention is an explicit Profile-revision approval bound to egress and
  capability state.
- Publish text/tool cloud capabilities only; attachment modalities remain
  unknown until a separate byte/upload/cleanup design is implemented.
- Complete fixture coverage before exposing a provider preset in release UI.

### Phase 4: Host LLM Session Bridge

- Add opaque Swift-owned LLM session handles to the Rust-Swift boundary.
- Replace synchronous `ExecutionModelClient::next_turn` execution with the
  durable resumable worker state machine.
- Add the outbound command vtable and independent inbound event FFI entry.
- Add random epoch-bound session handles and canonical `LLMEventEnvelope`
  identity/sequence/digest validation.
- Add the transactional host-command outbox, copy receipts, command
  acknowledgements, deduplication, and acknowledgement deadlines.
- Prove that no Swift callback occurs while the Rust runtime mutex is held.
- Implement sequence handling, buffer ownership, bounded backpressure, late
  event behavior, and cancellation races.
- Implement structured generation terminal outcomes and complete ordered
  tool-call batches.
- Separate command acknowledgement, backend start, generation terminal, and
  session close signals/watchdogs.
- Implement host-process epoch recovery, continuation invalidation, and host
  tool effect idempotency.
- Replace the production `BridgeExecutionModelClient` provider path with a
  host-backed LLM client.
- Route `host_slot_v2` profiles through the host-backed worker; continue routing
  unmigrated `legacy_v1` profiles through the old path during this phase.
- Require both routes to use the same durable global run lease and host epoch;
  legacy waiting states follow the same restart interruption rule.
- Keep Rust Agent policy, context assembly, and tool semantics unchanged while
  changing the worker scheduling model.

### Phase 5: Product Adoption and Legacy Removal

- Replace current `ModelRoutingClient` behavior with the Swift LLM system.
- Remove provider construction from `AppBootstrapper` and
  `RustRuntimeConfiguration` product setup.
- Move Agent-to-model composition to Swift `AgentHostConfiguration`.
- Migrate Swift `LLMStore` V2→V3 before introducing the tagged Provider
  Profile creation lifecycle.
- Migrate the unified Rust runtime store V2→V3 once, creating Profile,
  component, and the single legacy-migration-record tables transactionally.
  Task-level repository behavior must not create tables opportunistically.
- Key every migration record with Rust-computed
  `legacy-profile-source:v1`; Swift treats it only as opaque identity.
- Before cutover, prove that each retained `legacy_v1` profile migrates to
  `host_slot_v2` only after its Swift host binding has been staged and verified;
  failed migrations leave the V1 record and route intact.
- Remove the production use of Rust `ModelBinding`, Provider Registry, local LLM
  provider, and Rust `InferenceRouter` after parity tests pass.
- Retain only the provider-neutral agent model-client trait and test mocks in
  Rust.
- Delete the old product route in the final cutover; do not maintain indefinite
  dual execution.
- Retain a narrow read-only Agent Profile translator and private Agent Package
  schema-v1 reader in the final binary for direct old-version upgrade. They are
  migration-only, provider-neutral, and cannot execute V1.
- Keep the complete component/tool/memory/voice/requirements graph inside Rust
  while creating the V2 successor. Swift receives only migration subject,
  source digest, display metadata, portable requirements, record state, and an
  optional redacted model hint.
- Keep durable host configurations, binding tuples, targets, and restored
  selections independent of `HostProcessEpoch`. Epoch binds preparations,
  sessions, runs, commands, and events created in the current launch.

Legacy stored provider selection may be imported only through a one-time,
read-only, redacted migration translator. No legacy plaintext secret is
migrated. Development environment providers remain debug-only and are not
treated as user profiles.

## Implementation Decomposition

This architecture is intentionally delivered through five independently
verifiable implementation plans:

1. Canonical digests, durable global run lease, portable LLM slots, Agent
   Package v2, cross-store saga, Swift LLM contracts, storage, capabilities,
   and parameters.
2. Local model catalog, download, disk management, and C++ runtime.
3. Cloud Provider Profiles, credential generations, Keychain, egress
   attestations/disclosures, and adapters.
4. Async Swift-Rust LLM session bridge, event envelopes, lifecycle watchdogs,
   two-phase run commit, and restart recovery.
5. Model Center UI, migration, and legacy cleanup.

The plans are sequential. Later plans must not redefine the ownership boundary
established here.

## Phase 1 Foundation Evidence (2026-07-11)

Phase 1 foundation is implemented on `codex/llm-runtime-provider-design` as
provider-neutral contracts only. The remediated boundary includes
Rust-authoritative preparation input derivation, atomic lease/preparation
lifecycle storage, acknowledged prepared-session cleanup, complete public
binding validation, actual Profile/Package host-binding states, Swift
target/capability/parameter types, transactional Swift SQLite state, and
provider-neutral JSON/C ABI DTOs.

Evidence is the repository-local `scripts/run-llm-phase-1-contracts.sh`, which
runs all Rust tests, rebuilds the Rust static library, runs all Swift tests, and
checks the Rust/Swift FFI panic strategy without provider smoke tests or network
operations. Architecture lint freezes the temporary legacy Rust LLM surface in
`rust-core/tests/fixtures/architecture/legacy_llm_allowlist.txt` and rejects
concrete provider, credential, URL, model-path, local-path, and host-target
fields in the new Rust V2 state contracts. It also rejects caller-authored
Phase A digests, split preparation writes, JSON-document LLM persistence,
raw-bearer persistence projections, host-binding FFI repository bypasses, and
prepared-start validation that does not require an active exact cross-link.

This status does not enable cloud credentials, egress, local model loading,
provider adapters, Swift host callbacks, or host-backed V2 generation. The
Phase 1 `commit_prepared_start` entry rehashes the frozen binding and model
input, validates registration/capability/egress digests plus the active exact
Profile/slot/binding cross-link, enters the prepared-session cleanup path, and returns
`execution.host_slot_v2_not_runnable` by design.

## Acceptance Criteria

Unless explicitly labeled as a migration invariant, these criteria describe
the Phase 5 end state. Earlier phases must satisfy the transitional schema and
lint rules above without pretending the legacy route is already gone.

- [ ] Rust production code does not own LLM targets, Provider Profiles, model
      installations, credentials, Base URLs, model paths, or backend selection.
- [ ] Rust runtime code never parses Provider Profile, origin,
      CredentialRef/generation, scope grant, or per-turn authorization; it
      validates only the generic public binding of a versioned opaque egress
      attestation. Migration-only readers may recognize fixed historical wire
      keys solely to discard them and may not expose or execute those values.
- [ ] Every cross-boundary, cross-store, reconciliation, identity, and policy
      digest uses a registered `CanonicalDigestV1` schema; Swift and Rust pass
      the applicable identical RFC 8785 golden fixtures.
- [ ] `legacy-profile-source:v1` binds the complete immutable historical
      Profile record and is computed only by Rust; Swift treats it as opaque.
- [ ] Rust Agent/Profile/Package contracts retain only portable LLM slots,
      requirements, and optional hints; they contain no device-local binding.
- [ ] The final binary retains only isolated, read-only translators for known
      legacy Agent Profile records and schema-v1 Agent Package wire. They emit
      V2 values immediately, are covered by targeted architecture tests, and
      expose no execution route.
- [ ] Swift is the sole product owner of local/cloud LLM selection and runtime
      configuration.
- [ ] C++ performs only local inference execution.
- [ ] C++ renders engine/model-format-specific chat templates; Swift owns
      template selection, canonical messages/tools, and tool-call parsing.
- [ ] Run start uses preview, Swift host preparation, and Rust commit with a
      rotating digest-preserving preparation lease and a short-lived ready
      attestation.
- [ ] A pre-commit session is durably registered and can be abandoned only by
      a preparation-scoped cleanup outbox and exact close receipt; denial,
      expiry, commit failure/conflict, duplicates, and restart cannot strand or
      prematurely release the global run lease.
- [ ] Rust never invokes the Swift host vtable while holding its runtime mutex.
- [ ] The Rust worker is resumable and receives Swift stream events through an
      independent FFI entry with defined ownership, sequencing, and backpressure.
- [ ] Session handles contain at least 128 random bits, are bound to
      preparation/run/epoch, remain tombstoned, and are never reused in an
      epoch.
- [ ] Event envelopes bind event ID, handle, epoch, run, turn, sequence, and
      payload digest; a conflicting duplicate interrupts instead of becoming a
      no-op.
- [ ] Every event submission result defines sequence consumption, durable
      receipt behavior, and retry behavior; adapters allocate sequence only at
      FFI handoff and filter raw late backend callbacks before allocation.
- [ ] Every Rust-to-Swift command is committed with worker state in a durable
      outbox and has stable identity, sequence, copy receipt, deduplication,
      acknowledgement, and timeout behavior.
- [ ] `command_acknowledged`, `generation_started`, generation terminal, and
      `session_closed` are distinct; cancel/close watchdogs wait for backend
      facts, and ledgers survive until `session_closed`.
- [ ] Profile publish, Package binding, and run cross-links use idempotent sagas
      and converge after every injected crash boundary.
- [ ] Profile and Package sagas persist the exact opaque binding ID, revision,
      and hash staged by Swift and reject cross-link mismatches.
- [ ] Durable host configuration/binding/target records carry no process epoch;
      every preparation/session/run/command/event uses the current launch
      epoch.
- [ ] Agent Package v2 carries LLM requirements/hints and no API key, device
      path, Provider Profile, or concrete host binding.
- [ ] One Agent Profile revision resolves to one explicit LLM target revision.
- [ ] A cloud LLM target revision pins one Provider Profile revision; changing
      its Base URL cannot silently alter an existing Agent configuration.
- [ ] A single durable Rust global run lease is acquired by CAS before either
      legacy or V2 resolution, admits only one run/preparation globally, and is
      released only after route cleanup.
- [ ] Installed models remain on disk until the user deletes them.
- [ ] Only the active local model may be loaded in RAM.
- [ ] Local downloads support pause, resume, verification, atomic install, and
      launch reconciliation.
- [ ] Local catalog manifests are signed and arbitrary imports are absent in v1.
- [ ] API keys exist only in Keychain and never cross into Rust.
- [ ] Initial credential publication is a persisted creation saga; recovery
      never scans and guesses whether a staged/final Keychain item is orphaned.
- [ ] Swift `LLMStore` V2→V3 and Rust runtime V2→V3 migrations are atomic,
      rollback-injected, reopen populated V2 fixtures without loss, and reject
      future version 4 before mutation.
- [ ] `CredentialSlotState` is the sole credential-generation authority;
      Provider Profile revisions keep only `credentialRef` and no generation
      copy.
- [ ] Validation, preparations, sessions, private egress attestations, and
      Swift snapshots pin generation through `CredentialUseLease`; rotation or
      deletion first CASes an unused active slot to a state that blocks every
      new user.
- [ ] Archiving a Provider Profile revision cannot delete a CredentialRef still
      used by another revision, host-binding operation, or credential-use
      lease.
- [ ] Egress approval is bound to exact provider origin.
- [ ] Provider retention defaults to stateless/no-storage; provider-side state
      requires an immutable Profile-revision choice and an explicit approval
      revision bound into scope grants and capability snapshots.
- [ ] Every remote start/resume request carries a disclosure bound to its exact
      content and source revisions; expanded sensitive tool data requires
      incremental approval before the affected request.
- [ ] Swift recomputes those digests from the complete semantic request,
      canonical tool schema, source revisions, attachment identities, tool
      results, and provider-required semantic history before an adapter can
      encode the turn.
- [ ] Cloud transport accepts only policy-sealed tagged generation,
      validation, or discovery requests; bare adapter wire output cannot send.
- [ ] Every approval uses a digest-bound grant-neutral source summary plus a
      Swift-only grant-delta summary of source enums, counts, size bucket,
      trusted tool-key set (empty in Phase 5), and new classes, with no raw
      user data.
- [ ] Until a signed Tool Manifest verification chain exists, trusted tool
      display keys are empty and approval uses a generic localized tool label;
      function schema, metadata, and tool output cannot inject approval text.
- [ ] OpenAI, Claude, Gemini, Grok, DeepSeek, MiniMax, and GLM have explicit
      Swift adapter semantics.
- [ ] Capability unknowns fail conservatively.
- [ ] Phase 3 reports cloud image/audio/video/document input as unknown and
      rejects attachment-bearing cloud turns until an attachment data lifecycle
      exists.
- [ ] Capability observations record dimension, authority, model revision,
      observed/expiry time, validation scope, and invalidation triggers.
- [ ] Parameter controls are capability-driven and adapter-validated.
- [ ] Provider-private thinking/signature state remains inside Swift sessions.
- [ ] Local and cloud sessions emit the same normalized agent event contract.
- [ ] A structured generation terminal event distinguishes final response from
      a complete ordered tool-call batch; V1 executes multi-call batches
      sequentially and resumes once with all results.
- [ ] Cancellation is idempotent and reaches Rust plus the active backend.
- [ ] Process restart atomically interrupts legacy and V2 non-terminal runs,
      invalidates pending tool/approval/outbox state, releases the old-epoch
      global lease, and rejects late results.
- [ ] Side-effecting host tools use effect IDs and never auto-repeat an
      outcome-unknown effect.
- [ ] No automatic model fallback occurs.
- [ ] Provider adapter CI uses secret-free fixtures rather than live keys.
- [ ] The Phase 3 SQLite v2 migration creates its complete final table/payload
      shape atomically and passes rollback, old-version reopen, future-version,
      and unknown-record/tag rejection tests.
- [ ] URLSession origin policy rejects literal/reserved/mixed or
      changed-to-forbidden preflight DNS answers without claiming actual peer-IP
      pinning or complete DNS-rebinding prevention.
- [ ] Migration keeps tagged `legacy_v1` and `host_slot_v2` records separate,
      preserves the legacy resolver until Phase 4, and forbids growth of the
      temporary architecture-lint allowlist.
- [ ] The legacy Rust provider product path is removed after migration parity.

## Phase 2 implementation evidence (2026-07-15)

Phase 2 now has a directly testable Swift-owned local product path. One signed
official catalog feeds one-at-a-time background download, pause/resume,
streaming SHA-256 verification, atomic installation, startup reconciliation,
guarded deletion, exact target/binding resolution, and a single-model RAM
runtime. `PreparedLocalSession` freezes the target revision, active binding
tuple, installation/catalog revisions, capability snapshot, resolved
parameters, template/codec, leases, and the App-owned host epoch. The Swift C++
adapter owns semantic parameter mapping, bounded lossless callback
backpressure, tool-call decoding, cancel/release ordering, and close-once native
handle borrows.

The native product is one package-contained
`LocalAgentInferenceNative.xcframework`. It is the only owner of the C ABI and
enabled vendor runtime objects; Rust links it only as a non-bundling legacy
consumer. Deterministic evidence is provided by
`scripts/run-llm-phase-2-contracts.sh`: Phase 1 regressions, C++ lifecycle and
cancel-arbiter contracts, Rust architecture lints, the complete Swift suite,
and Simulator/iPhoneOS final-link and catalog-resource checks. A separate
environment-gated release smoke runs an already verified real installation on
both iPhone and iPad Simulator before an engine is selectable.

The following work remains intentionally outside Phase 2:

- Phase 3 adds cloud Provider Profiles, Keychain credential slots, egress and
  incremental approval, provider adapters, and connectivity/capability probes
  while reusing the same normalized capabilities, parameters, and backend
  events.
- Phase 4 connects Rust's provider-neutral Agent worker to an opaque Swift host
  session with durable command acknowledgements, event sequencing, watchdogs,
  and preparation/egress validation. `host_slot_v2` remains non-runnable until
  that bridge exists.
- Phase 5 adds Model Center UI and migration, switches production Agent
  profiles to exact host targets, and removes the legacy Rust provider/local
  inference path only after parity is proven.

## Phase 3 implementation evidence (2026-07-18)

Phase 3 now provides a directly testable Swift-owned cloud product path while
leaving the Rust Agent worker unchanged. `CloudLLMSubsystem` opens the shared
SQLite v2 store, reconciles credential operations, interrupts old-epoch cloud
sessions and leases, verifies the signed official catalog, installs exactly
seven semantic adapters, and exposes Provider Profile, retention, egress,
validation, and one-session runtime services. App composition supplies the
single App-owned host epoch and an awaited local-route unloader; the cloud
module does not import the local inference module.

`CloudLLMRuntime` prepares only an exact active target and host binding. It
requires either a current exact catalog-backed validation or conservative
probe-only manual validation, plus the matching adapter, model,
credential-generation, and retention identity. It resolves target defaults
plus host overrides for catalog routes and rejects all parameters for manual
routes, resolves attachment
identities, and recomputes the complete `agent-input:v1`,
`source-revisions:v1`, and `generation-disclosure:v1` binding before egress.
The immutable sanitized `PreparedCloudSession` persists the target, binding,
requirements, Profile revision and origin, credential generation and use-lease
digest, retention identity, capability and parameter digests, scope and
authorization IDs, opaque egress subject, outer egress attestation, adapter,
and host epoch. It contains no key, request/response body, private reasoning,
absolute path, or live handle.

Every start and resume rechecks the exact Profile/target, retention approval,
credential slot and lease, explicit catalog-or-manual route source, installed
adapter, capability snapshot, and resolved parameters. Catalog routes recheck
the signed catalog; manual routes remain bound to nil catalog/model revisions
and cannot be silently promoted. The provider adapter can produce only a
tagged unsendable wire value; egress policy must seal it as the exact
generation class before the sole transport resolves Keychain material. Tool
calls terminate as one ordered batch, normalized labeled results are approved
incrementally and resumed once, and provider-private continuation remains in
the Swift session. A retry is bounded to one attempt and only before any
normalized reasoning summary, text, tool, or usage event. There is no model or
provider fallback. Cancel and close are idempotent, provider cancel/close occur
once, and lease closing plus the session tombstone is atomic.

Deterministic evidence is provided by
`scripts/run-llm-phase-3-contracts.sh`: it clears only the seven known provider
key variables, runs all Phase 2 gates, the Rust/Swift/C++ architecture lint,
the complete secret-free Swift fixture suite and product-path integration, and
the hosted iOS Keychain attribute test against one resolved Simulator UDID
(`LOCAL_AGENT_PHASE3_SIMULATOR_UDID` may explicitly override selection). The separate
`scripts/run-llm-phase-3-live-smoke.sh` is manual: it accepts only existing
Profile/model/credential references, rejects key/token/secret environment
variables, sends one fixed synthetic prompt, retains no response, and cannot
replace fixture CI.

The following work remains intentionally unfinished:

- Phase 4 aligns Rust public registration/attestation recomputation with these
  canonical Phase 3 documents and connects the provider-neutral worker through
  durable host commands, acknowledgements, event sequencing, watchdogs, and
  incremental disclosure failures. `host_slot_v2` remains non-runnable until
  that bridge lands.
- Phase 5 adds the iPhone/iPad Model Center and Provider Profile UI, migrates
  production Agent profiles to exact host targets, and removes the legacy Rust
  Provider/local path only after parity and recovery evidence pass.

## Phase 3.1 hardening evidence (2026-07-22)

Phase 3.1 closes the post-implementation reliability and provider-wire review
without changing the Rust Agent kernel or the C++ local-inference boundary.
The bounded outer `AsyncThrowingStream` now checks every yield result. A drop
fails with `runtime.cloud_consumer_backpressure`; terminal lifecycle state is
committed only after the matching terminal event is enqueued. Consumer
termination, explicit cancellation, and their race share one actor-isolated
cancel arbiter, so provider cancel occurs once and normal completion does not
cancel. This is a loss-detecting in-process handoff, not durable delivery:
Phase 4 still owns Rust/Swift command acknowledgements, event receipts,
sequences, watchdogs, and restart-safe outboxes.

Responses/xAI sessions now retain the complete ordered provider-private tool
batch decoded for the preceding turn. Resume requires exact ordered call IDs
and names, rejects missing/duplicate/reordered/extra/unrelated or already
consumed results with `cloud_adapter.tool_result_batch_mismatch`, and replays
the necessary function-call continuation items in stateless mode. The shared
OpenAI Chat decoder rejects a final terminal after any accumulated tool-call
fragment as `cloud_adapter.terminal_conflict`, and rejects empty or incomplete
tool batches as `cloud_adapter.tool_call_incomplete`.

Each of the seven semantic adapters now owns discovery, account-validation,
and model-validation request construction. Anthropic probe requests carry the
required version header while MiniMax does not inherit it. Validation and
discovery services retain policy, lease, evidence, and decoding ownership but
no longer guess provider wire headers or endpoints.

Manual validation evidence uses nil catalog and model revisions. Catalog
advances atomically invalidate current catalog-backed Profile states and scan
all validation records to delete only rows whose decoded subject is
catalog-backed; manual evidence and observations survive without acquiring
new catalog capabilities. Runtime route identity is explicit as
`catalog(entry)` or `manual(adapterID, modelID)`. Manual routes are stateless,
parameter-free, text-and-streaming only, and their resolved-parameter digest
binds the exact adapter, model, and manual source.

Every cloud generation now requires both `text_generation` and `streaming`.
The provider-neutral tool-schema gate treats `[]`, `{}`, and `{ "tools": [] }`
as empty, requires `tool_calling` only for a non-empty tool array, and rejects
unrelated or non-array object shapes with
`runtime.cloud_tool_schema_invalid`. Deterministic evidence is included in
`scripts/run-llm-phase-3-contracts.sh` and the dated Phase 3.1 design and
execution plan.

## Phase 4 implementation evidence (2026-07-27)

Phase 4 enables the provider-neutral `host_slot_v2` production route without
moving provider, model-file, credential, network, or C++ inference semantics
into Rust. Rust returns one exact-revision `ProfileExecutionRoute`; legacy
profiles continue through the existing model client, while V2 profiles must
enter the authoritative preview/register/commit preparation path. Swift never
infers a route from target availability and never falls back after stale,
tampered, or mismatched route data. Persisted V2 snapshots use the tagged
`HostSlotV2` binding with only requirements and an opaque cross-link.

The Rust worker now writes lifecycle state and a durable command outbox in one
SQLite authority. Stable command IDs, copy receipts, asynchronous
acknowledgements, event sequence receipts, terminal outcomes, ordered tool
batches, and independent acknowledgement/start/cancel/close watchdogs cover
the complete generation loop. Swift owns the local/cloud session and provider
continuation; Rust owns Agent planning, tool execution policy, formal
assistant output, retry/cancel state, and the global run lease. The shared
`HostAttestationV1Document` is recomputed on both sides from the frozen
authoritative input and exact binding.

App composition generates one host epoch and supplies it to Rust, local,
cloud, and the installed dispatcher. Startup closes old-epoch preparations,
sessions, outbox work, and legacy running state before exposing actions.
Suspend/resume preserves deadlines; shutdown quiesces and joins the dispatcher
before releasing Swift host state. Tool-effect receipts prevent blind replay
after outcome-unknown interruption, and ambiguous Phase C replies reconcile
before any preparation abort.

Deterministic evidence is provided by
`scripts/run-llm-phase-4-contracts.sh`. It clears the seven known provider key
variables, runs the complete Phase 3 gate first, then 427 Rust contract tests,
126 Rust integration tests, the Phase 4 architecture lint, the complete Swift
package suite, and the App host-composition test on explicitly selected
available iPhone and iPad Simulators. It uses only local fake engines and
secret-free cloud fixtures and never invokes the live-smoke runner.

Phase 5 remains deliberately separate: it adds the iPhone/iPad Model Center
and Provider Profile UI, publishes real user-selected exact host bindings,
migrates existing profiles, and removes the temporary legacy Rust
provider/local-inference path only after migration and parity evidence pass.

## Official API References

The adapter design was checked against official provider documentation on
2026-07-15. Provider presets and capability catalogs must be versioned because
these APIs and model-level constraints evolve.

- RFC 8785 JSON Canonicalization Scheme:
  <https://www.rfc-editor.org/rfc/rfc8785.html>
- OpenAI reasoning controls:
  <https://developers.openai.com/api/docs/guides/reasoning>
- OpenAI Responses API:
  <https://developers.openai.com/api/reference/resources/responses/methods/create>
- Claude streaming:
  <https://platform.claude.com/docs/en/build-with-claude/streaming>
- Claude extended thinking:
  <https://platform.claude.com/docs/en/build-with-claude/extended-thinking>
- Gemini Interactions and retention:
  <https://ai.google.dev/gemini-api/docs/interactions-overview>
- Gemini Interactions streaming:
  <https://ai.google.dev/gemini-api/docs/streaming>
- Gemini thinking:
  <https://ai.google.dev/gemini-api/docs/thinking>
- Gemini function calling:
  <https://ai.google.dev/gemini-api/docs/function-calling>
- Gemini thought signatures:
  <https://ai.google.dev/gemini-api/docs/generate-content/thought-signatures>
- xAI reasoning:
  <https://docs.x.ai/developers/model-capabilities/text/reasoning>
- xAI Responses storage and continuation:
  <https://docs.x.ai/developers/model-capabilities/text/generate-text>
- DeepSeek API introduction:
  <https://api-docs.deepseek.com/>
- DeepSeek thinking mode:
  <https://api-docs.deepseek.com/guides/thinking_mode>
- MiniMax Anthropic-compatible API:
  <https://platform.minimax.io/docs/api-reference/text-anthropic-api>
- GLM tool calling:
  <https://docs.bigmodel.cn/cn/guide/capabilities/function-calling>
- GLM thinking mode:
  <https://docs.bigmodel.cn/cn/guide/capabilities/thinking-mode>
