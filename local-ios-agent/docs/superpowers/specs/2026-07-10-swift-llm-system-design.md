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
| Credential replacement could silently change the account used by an active run | Every key replacement advances a pinned credential generation used by validation, grants, sessions, attestations, and snapshots; rotation cannot cross an active session |
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
transport encodings, but they are never hashed directly. Every digest that
crosses the Swift-Rust boundary uses `CanonicalDigestV1`.

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
| `agent-input:v1` | Ordered canonical messages, tool schemas, attachment references/revisions, memory/context revisions | Provider encoding and diagnostics |
| `generation-disclosure:v1` | Turn ID, content/source digests, sorted data classes, sensitivity, and grant-neutral safe source summary | Raw source content and grant identity |
| `capability-attestation:v1` | Generic Agent capability values plus contributing observation digests/expiry | Provider-specific claims and evidence body |
| `resolved-parameters:v1` | Sorted canonical semantic parameter IDs and resolved non-secret values | Provider/C++ field names |
| `preparation-binding:v1` | Preparation/run IDs, bound digest set, token generation, host epoch, and expiry | Raw token value |
| `host-binding-staging-receipt:v1` | Operation/token digest, profile/slot/requirements, and binding ID/revision/hash | Swift target details |
| `host-command-payload:v1` | Complete typed command payload | Command delivery metadata |
| `host-command-envelope:v1` | Command ID, run/session/epoch/sequence/turn, kind, complete canonical payload, and complete canonical disclosure | Dispatch attempts and wall-clock receipt time |
| `llm-event-envelope:v1` | Event ID, run/session/epoch/turn/sequence, event kind, and complete event payload | Local arrival time and diagnostics |
| `egress-approval-summary:v1` | Swift-only disclosure digest, prior scope-grant digest, grant-neutral source summary, and newly added data classes | Raw source content |
| `egress-subject:v1` | Swift-only tagged local `not_applicable` decision or cloud Provider Profile revision, exact origin, credential generation, scope grant, approval-summary digest, and per-turn authorization | Credential value |
| `egress-attestation:v1` | Preparation/run/session/snapshot identities, binding/requirements/disclosure/capability/parameter digests, host epoch, expiry, and opaque egress-subject digest | Parsed provider fields |

`payloadDigest` is the `host-command-payload:v1` result.
`commandEnvelopeDigest` covers the whole command and therefore changes when the
same payload is paired with a different `GenerationDisclosure`. `bindingHash`,
`modelInputDigest`, `contentDigest`, and `eventDigest` use their corresponding
registered domains. Adding another cross-boundary digest requires registering
its domain and exact include/exclude schema here; ad hoc hashes are forbidden.

Swift and Rust share golden fixtures under
`local-ios-agent/contracts/canonical-digest-v1/`. Each fixture contains the
typed source document, expected JCS UTF-8 bytes, and expected SHA-256. Tests
cover map/set insertion order, omitted versus null, composed versus decomposed
Unicode, numeric boundaries, disclosure-only command changes, and malformed
documents. Both implementations must pass the same fixtures before a bridge
schema can ship.

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
uncommitted preparation.

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
ready, its host attestation is valid for two minutes; `commit_start` must consume the current
rotated token within that shorter ready window. Exceeding the total lease
requires a new preview and approval flow.

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
6. Creates the local or cloud `LLMSessionHandle`.
7. Persists the sanitized Swift LLM snapshot.

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
host process epoch
attestation expiration
opaque egress-subject digest
EgressAttestationDigest
```

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
    host epoch + expiration +
    opaqueEgressSubjectDigest)
```

Rust receives the opaque subject digest and the outer attestation digest. It
recomputes only the outer digest from provider-neutral public binding fields,
checks the supported schema version, preparation/run/session/snapshot
identities, binding/requirements/disclosure/capability/parameter hashes, host
epoch, and expiry, and stores the digest for cross-linking. Rust never receives
or parses Provider Profile, origin, CredentialRef, credential generation,
grant, authorization, or route details.

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
- the host binding and Swift snapshot identifiers are present;
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

### Abort and Expiration

```text
abort_preparation(preparation token, reason)
```

- If Swift preparation fails or the user denies approval, Swift closes any
  partial session and Rust aborts the token; the lease follows the same
  `releasing -> session_closed -> empty` rule, or returns directly to empty
  when no session was created.
- If Rust commit fails, Swift closes the session and marks the Swift snapshot
  aborted through the same idempotency key.
- Expiration marks the Rust token expired and moves its global run lease to
  `releasing`. If no Swift session exists, Rust releases it atomically;
  otherwise Swift closes the prepared session and `session_closed` releases the
  lease.
- Repeating renewal with an already rotated token returns the previously issued
  replacement only for the same idempotency key; otherwise the old token is
  stale.
- Repeating abort is a no-op.
- A consumed or expired token cannot start a run.
- Startup reconciliation cleans pending records on both sides before the UI
  allows a new run.

### Prepared LLM Session

Swift materializes the Phase B result as:

```swift
struct PreparedLLMSession: Sendable {
    let handle: LLMSessionHandle
    let capabilityAttestation: AgentLLMCapabilities
    let hostBindingID: String
    let hostBindingRevision: UInt64
    let hostBindingHash: String
    let egressAttestationDigest: String
    let sanitizedSnapshot: LLMRunSnapshot
}
```

`LLMSessionHandle` is opaque to Rust. It never encodes a model path, Provider
Profile, API key, Base URL, engine ID, or adapter kind. Swift creates it from at
least 128 bits of cryptographically secure randomness and never reuses it within
a host epoch. The Swift session registry binds the handle to preparation ID,
run ID, host epoch, binding hash, and pinned credential generation when remote;
Rust persists the provider-neutral preparation/run/epoch binding. Closed or
expired handles remain tombstoned for the rest of the epoch, preventing ABA.

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
start_generation(session_handle, agent_llm_input, generation_disclosure)
resume_generation(session_handle, normalized_tool_results, generation_disclosure)
cancel_generation(session_handle)
close_session(session_handle)
capacity_available(session_handle)
```

Rust computes a fresh `GenerationDisclosure` for every generation turn. The
start disclosure is bound to the frozen initial input. A resume disclosure is
bound to the complete canonical semantic request for that turn: all prior
content the adapter will resend, the full tool-result batch, and every context,
memory, or attachment revision newly included. Swift must validate the
disclosure before it lets an adapter encode or transmit the corresponding
remote request.

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
  `llm.event.turn_terminal` and are ignored. A `tool_calls_ready` terminal keeps
  the session open for a later acknowledged resume turn.
- After `generation_completed(outcome: final_response)`, `cancelled`, or
  `failed`, further generation events return `llm.event.generation_terminal`;
  the matching `session_closed` event remains admissible.
- After `session_closed`, every later event returns `llm.event.session_closed`
  and is ignored.
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
  `session + sequence -> eventID + eventDigest` until `session_closed`, so a
  duplicate remains verifiable after the inbound queue has drained.

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
session_closed
sequence_gap
sequence_conflict
identity_conflict
```

`backpressure` does not consume the rejected event's sequence number. Swift
suspends consumption of the URLSession byte stream or local token queue and
retries the same sequence after capacity notification. When the Rust queue
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
  stale and ignored; the matching `cancelled` and eventual `session_closed`
  remain admissible.
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
}

struct ProviderProfileState: Codable, Sendable {
    let profileID: String
    let profileRevision: UInt64
    var currentCredentialGeneration: UInt64
    var validationState: ProviderValidationState
    var approvedEgressOrigin: EgressOrigin?
    var catalogRevision: UInt64?
}
```

Non-secret Provider Profile configuration is immutable by revision. Changing
the preset or Base URL creates a new revision. A cloud `LLMTargetRevision` pins
the Provider Profile revision it was validated against. Key replacement does
not rewrite that target revision, but it always advances the credential slot's
non-secret `credentialGeneration` and invalidates generation-scoped readiness.

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
  preparation, or live session references the CredentialRef. A credential slot
  shared by another logical profile is retained until its final reference is
  removed.
- Key deletion uses an idempotent persisted tombstone: record deletion intent,
  delete the Keychain item, then mark completion. Startup reconciliation safely
  repeats an incomplete deletion without exposing the old credential.
- Credential resolution happens only after egress and approval checks pass.
- Credential values never enter logs, SQLite, FFI DTOs, diagnostics, exports, or
  provider error messages.

### Credential Generation and Rotation

`credentialGeneration` is a monotonically increasing `UInt64` owned by the
Swift credential slot. It is not a secret. Phase B pins the current generation
into provider validation, the scope grant, per-turn authorization, private
egress subject, `LLMSessionHandle` registry entry, provider session, and
sanitized Swift run snapshot. Every remote request verifies that the session is
still using its pinned generation before resolving the generation-specific
Keychain item.

Because the private egress subject feeds `EgressAttestationDigest`, the host
attestation is generation-bound without exposing generation semantics to Rust.

Publishing a new key generation is forbidden while any pending preparation or
live/closing session references that CredentialRef. The UI may wait, or ask the
user to cancel the run and wait for `session_closed`; it cannot silently rotate
under an active run.

Rotation is an idempotent Swift saga:

```text
1. persist rotation intent and next generation
2. write the new key to a generation-specific Keychain item
3. in one SQLite transaction, CAS currentCredentialGeneration from old to next
   and invalidate validation, availability, scope grants, and readiness bound
   to the old generation
4. tombstone and delete the old generation-specific Keychain item
```

Startup reconciliation completes or rolls back an interrupted saga without
ever labeling old key material as the new generation. When several logical
profiles intentionally share one credential slot, rotation invalidates all of
their generation-scoped state and the UI discloses that shared impact before
the CAS.

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

The session retains provider-private response IDs, reasoning content needed for
continuation, thinking blocks, and signatures. When Rust returns a normalized
tool result, Swift reconstructs the correct provider-specific request. This
state is memory-only and is dropped when the session closes.

Cloud inference uses process-bound, non-background URLSession tasks. Only model
downloads use background URLSession; a generation cannot outlive the host epoch
as a resumable app operation.

Reasoning summaries may cross the LLM client port only when the provider
explicitly returns a user-displayable summary. Raw private reasoning and opaque
continuation state do not cross the port.

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
free-form approval text.

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
cloud routes it is also bound to the pinned credential generation. For every
turn, Swift creates a derived `GenerationEgressAuthorization` bound to that
grant ID, credential generation, generation turn ID, content/source digests,
and exact request scope. Changed content within the approved scope receives a
new derived authorization without another prompt; a scope expansion requires a
new user grant. No authorization can be reused for a later changed payload or
credential generation.

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
- No private, loopback, link-local, or reserved targets.
- Redirects may not change origin.
- DNS rebinding protections are applied by the transport policy.
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

`subject` records every identifier that scopes the observation. Fields may be
absent only when the observation is genuinely broader: for example, an adapter
encoding observation has an adapter ID but no model, while provider-list
availability has an exact Provider Profile revision and Model ID but may precede
creation of an LLM target. An observation can contribute to a run attestation
only when its populated subject fields match the selected route exactly.
Authenticated availability/validation observations must include the exact
credential generation; static catalog or adapter observations leave it absent.

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
the lease to `releasing`. V2 releases it only after `session_closed` (or
old-epoch recovery); legacy releases it only after its Rust-owned backend/worker
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
quarantined -> idle, only after session_closed or a new host epoch
```

Invariants:

- There is at most one active agent/LLM session globally, enforced by the Rust
  lease rather than actor state alone.
- A new preparation/run is rejected while the durable lease is preparing,
  active, or releasing.
- `idle` requires both `session_closed`/legacy cleanup and an empty Rust global
  run lease. A quarantined same-epoch session keeps the coordinator non-idle and
  blocks new runs.
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

SQLite stores:

```text
Provider Profile metadata
LLM Target revisions
AgentHostConfiguration revisions
capability catalog revision and provenance
parameter defaults and overrides
local installation records
download task and resume metadata
egress grants and validation state
private non-secret egress subjects and attestation digests
append-only generation disclosure/grant audit rows
credential generations, rotation intents, and deletion tombstones
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
     -> HostBindingStagingReceipt bound to publish-token digest, slot, and
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
     -> HostBindingStagingReceipt

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
private egress subject, credential generation when remote, and
EgressAttestationDigest
stable preparation ID and final consumed token digest
LLM target and sanitized runtime configuration
```

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
run snapshot cross-links
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
credential generation when remote
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
Likewise, `llm.command.*`, `llm.event.*`, `llm.turn.*`, `llm.cancel.*`, and
`llm.session.*` describe Rust bridge protocol violations/timeouts. They
interrupt or fail the run deterministically and are not remapped to a provider
error.

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

Affected states include:

```text
preparing
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
- Grant-neutral source summaries and Swift-only grant-delta summaries contain
  only manifest-controlled enums/keys, counts/buckets, and new classes; raw
  values cannot enter approval UI/logs.
- Provider/origin/credential/grant semantics remain inside the private egress
  subject while the public opaque attestation binds the required generic fields.
- Credential rotation is blocked by pending/live/closing sessions; successful
  rotation increments generation and invalidates old validation/grants.
- Archiving one Provider Profile revision retains a CredentialRef still used by
  another revision; logical-profile deletion reconciles Keychain tombstones.
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
- usage normalization;
- unknown event forward compatibility;
- rate-limit and authentication errors;
- cancellation command acceptance;
- command-acknowledged versus generation-started/cancelled/session-closed
  lifecycle signals; and
- terminal event enforcement.

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

- Rust passes the same `CanonicalDigestV1` golden fixtures as Swift; ordinary
  serde JSON byte order never affects a digest.
- The agent kernel depends only on the abstract LLM client port.
- Rust product code does not construct or resolve Provider Profiles, model
  installations, Base URLs, credentials, model paths, or backend adapters.
- The resumable worker persists and yields before host generation.
- Worker state and each `HostCommandEnvelope` outbox row commit atomically;
  crash injection between commit, copy receipt, and command acknowledgement
  cannot strand a run or duplicate execution.
- No Swift host vtable callback occurs while the Rust runtime mutex is held.
- Event sequence duplication, gaps, terminal events, stale handles, and bounded
  backpressure follow the bridge contract.
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
- Start/resume command acknowledgement timeout and deduplication use the same
  command ID, sequence, and full command-envelope digest, including disclosure.
- Rust waits for `generation_completed`, rejects malformed tool batches, and
  executes a valid multi-call batch sequentially before one batched resume.
- Normalized text and tool-call events drive the resumable agent worker.
- Swift-side cancellation terminates the Rust run.
- A host LLM failure maps to the limited agent-facing failure taxonomy.
- During migration, architecture lint rejects growth of the checked-in legacy
  allowlist; after Phase 5 it rejects all provider or engine concepts in the
  Rust agent path.

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
- Rotating a key during a prepared/live session is rejected; after
  `session_closed`, rotation advances credential generation and requires fresh
  validation/grant before another request.
- Crash injection after Rust outbox commit and before Swift acknowledgement
  redispatches the same command identity without a duplicate provider request.
- Conflicting duplicate event envelopes and an old-handle ABA attempt are
  rejected without advancing the worker.
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
the legacy route for unmigrated V1 records. Phase 5 migrates or archives every
remaining V1 profile and then removes the legacy reader, writer, resolver, and
route.

Architecture lint uses a checked-in temporary allowlist containing each
pre-existing legacy occurrence as `path + owning item + forbidden symbol`, plus
a non-increasing total count. It rejects a new `ModelBinding`, Provider Registry,
or Rust inference-router dependency even inside an already listed file. The
allowlist must shrink when code moves and is deleted entirely in Phase 5.

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
  `abort_preparation` contracts without switching the production worker yet.
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
- Add digest-bound initial and incremental `GenerationDisclosure` grants,
  safe display summaries, opaque egress attestations, conservative tool-result
  labeling, credential generations, rotation sagas, and tombstones.
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
- Migrate each retained `legacy_v1` profile to `host_slot_v2` only after its
  Swift host binding has been staged and verified; failed migrations leave the
  V1 record and route intact.
- Remove the production use of Rust `ModelBinding`, Provider Registry, local LLM
  provider, and Rust `InferenceRouter` after parity tests pass.
- Retain only the provider-neutral agent model-client trait and test mocks in
  Rust.
- Delete the old product route after migration; do not maintain indefinite
  dual execution.

Legacy stored provider selection may be imported only through a one-time,
read-only, redacted importer. No legacy plaintext secret is migrated. Development
environment providers remain debug-only and are not treated as user profiles.

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

## Acceptance Criteria

Unless explicitly labeled as a migration invariant, these criteria describe
the Phase 5 end state. Earlier phases must satisfy the transitional schema and
lint rules above without pretending the legacy route is already gone.

- [ ] Rust production code does not own LLM targets, Provider Profiles, model
      installations, credentials, Base URLs, model paths, or backend selection.
- [ ] Rust never parses Provider Profile, origin, CredentialRef/generation,
      scope grant, or per-turn authorization; it validates only the generic
      public binding of a versioned opaque egress attestation.
- [ ] Every Swift-Rust digest uses registered `CanonicalDigestV1` schemas and
      both languages pass identical RFC 8785 golden fixtures.
- [ ] Rust Agent/Profile/Package contracts retain only portable LLM slots,
      requirements, and optional hints; they contain no device-local binding.
- [ ] Swift is the sole product owner of local/cloud LLM selection and runtime
      configuration.
- [ ] C++ performs only local inference execution.
- [ ] C++ renders engine/model-format-specific chat templates; Swift owns
      template selection, canonical messages/tools, and tool-call parsing.
- [ ] Run start uses preview, Swift host preparation, and Rust commit with a
      rotating digest-preserving preparation lease and a short-lived ready
      attestation.
- [ ] Rust never invokes the Swift host vtable while holding its runtime mutex.
- [ ] The Rust worker is resumable and receives Swift stream events through an
      independent FFI entry with defined ownership, sequencing, and backpressure.
- [ ] Session handles contain at least 128 random bits, are bound to
      preparation/run/epoch, remain tombstoned, and are never reused in an
      epoch.
- [ ] Event envelopes bind event ID, handle, epoch, run, turn, sequence, and
      payload digest; a conflicting duplicate interrupts instead of becoming a
      no-op.
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
- [ ] Validation, grants, sessions, private egress attestations, and Swift
      snapshots pin credential generation; key rotation cannot cross a
      pending/live/closing session.
- [ ] Archiving a Provider Profile revision cannot delete a CredentialRef still
      used by another revision, preparation, or live session.
- [ ] Egress approval is bound to exact provider origin.
- [ ] Every remote start/resume request carries a disclosure bound to its exact
      content and source revisions; expanded sensitive tool data requires
      incremental approval before the affected request.
- [ ] Every approval uses a digest-bound grant-neutral source summary plus a
      Swift-only grant-delta summary of source enums, counts, size bucket,
      manifest tool keys, and new classes, with no raw user data.
- [ ] OpenAI, Claude, Gemini, Grok, DeepSeek, MiniMax, and GLM have explicit
      Swift adapter semantics.
- [ ] Capability unknowns fail conservatively.
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
- [ ] Migration keeps tagged `legacy_v1` and `host_slot_v2` records separate,
      preserves the legacy resolver until Phase 4, and forbids growth of the
      temporary architecture-lint allowlist.
- [ ] The legacy Rust provider product path is removed after migration parity.

## Official API References

The adapter design was checked against official provider documentation on
2026-07-10. Provider presets and capability catalogs must be versioned because
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
  <https://platform.claude.com/docs/en/docs/build-with-claude/extended-thinking>
- Gemini thinking:
  <https://ai.google.dev/gemini-api/docs/thinking>
- Gemini function calling:
  <https://ai.google.dev/gemini-api/docs/function-calling>
- Gemini thought signatures:
  <https://ai.google.dev/gemini-api/docs/generate-content/thought-signatures>
- xAI reasoning:
  <https://docs.x.ai/developers/model-capabilities/text/reasoning>
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
