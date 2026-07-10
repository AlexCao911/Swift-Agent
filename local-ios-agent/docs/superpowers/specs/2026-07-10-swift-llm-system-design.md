# Swift-Owned LLM System Design

**Status:** Revised after architecture review; pending final approval

**Date:** 2026-07-10

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

The implementation is blocked unless all six review corrections below remain
true:

| Review concern | Required resolution |
| --- | --- |
| Synchronous Rust-Swift call under the runtime mutex | Resumable Rust worker, lock-free outbound host callback, independent event FFI, bounded backpressure, and explicit cancellation races |
| Swift needs resolved requirements before it can prepare | Mandatory preview -> Swift prepare/attest -> Rust commit protocol with single-use expiry-bound tokens |
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
  |-- commits run snapshot and resumable worker state
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
- The global single-run execution lease.

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

Rust uses the existing `RunSnapshotService.preview` path as the starting point,
then previews the execution plan and context requirements without starting the
worker or persisting a run snapshot.

The result contains only agent and host-neutral requirements:

```text
preparation token
proposed Rust run ID
agent profile ID and revision
conversation frame reference and digest
execution plan digest
AgentLLMRequirements
tool schema digest
required input modalities
streaming/tool-calling requirements
requested context budget
egress data classes and highest sensitivity
expiration time
```

The preparation token is random, single-use, bound to the proposed run ID and
all listed digests, and valid for two minutes. Rust persists a pending
preparation record, not a run lifecycle record. The proposed run ID is reserved
for this token and cannot be reused. Restart invalidates every uncommitted
preparation.

Preview does not send prompt content to a provider, resolve a Swift credential,
load a model, or create a Rust run lifecycle record.

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
preparation token
proposed Rust run ID
host binding revision and hash
LLMSessionHandle
Swift LLM snapshot ID
capability attestation and hash
resolved parameter hash
approved egress disclosure ID, when remote
host process epoch
attestation expiration
```

### Phase C: Rust Commit

```text
commit_start(preparation token, host attestation)
  -> RunHandle
```

Rust verifies that:

- the token exists, is unexpired, and has not been consumed;
- the profile, frame, plan, and tool-schema digests are unchanged;
- the generic capability attestation satisfies `AgentLLMRequirements`;
- the host binding and Swift snapshot identifiers are present;
- the host epoch is current; and
- required egress approval metadata is present.

Rust then persists the Rust run snapshot, opaque host-binding cross-link, and
initial resumable worker state under the proposed run ID in one Rust
transaction. The token becomes consumed in that same transaction. The returned
`RunHandle` contains that exact ID. Only after commit does Rust enqueue the first
outbound LLM command.

Rust does not interpret the target, provider, model, parameters, credential, or
route behind the attestation.

### Abort and Expiration

```text
abort_preparation(preparation token, reason)
```

- If Swift preparation fails or the user denies approval, Swift closes any
  partial session and Rust aborts the token.
- If Rust commit fails, Swift closes the session and marks the Swift snapshot
  aborted through the same idempotency key.
- Expiration closes a prepared Swift session, deletes pending host state, and
  marks the Rust token expired.
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
    let hostBindingRevision: UInt64
    let hostBindingHash: String
    let sanitizedSnapshot: LLMRunSnapshot
}
```

`LLMSessionHandle` is opaque to Rust. It never encodes a model path, Provider
Profile, API key, Base URL, engine ID, or adapter kind.

## Rust-Swift LLM Client Port

The current synchronous `ExecutionModelClient::next_turn` contract and
`BridgeExecutionModelClient` mutex path are migration sources, not the target
bridge. Rust must not hold the runtime mutex while Swift performs generation or
while a host callback is running.

The target worker is a resumable state machine:

```text
ready
  -> awaiting_llm
  -> consuming_llm_stream
  -> awaiting_tool
  -> awaiting_llm_resume
  -> consuming_llm_stream
  -> completed | failed | cancelled | interrupted
```

Agent policy, context assembly, tool routing, and completion semantics remain in
Rust. The worker scheduling and model-call implementation do change: a worker
transition persists state, enqueues an outbound host command, and returns
without waiting for Swift.

Outbound commands are:

```text
start_generation(session_handle, agent_llm_input)
resume_generation(session_handle, normalized_tool_results)
cancel_generation(session_handle)
close_session(session_handle)
```

### Host Command Vtable

Swift registers a host command vtable when the runtime bridge is created. Rust
owns a serial outbound command queue and dispatches vtable calls only after all
runtime and repository mutex guards have been released.

The vtable callback receives an immutable byte pointer, length, and opaque
context pointer. Its rules are:

- Rust owns the command buffer for the duration of the callback.
- Swift copies the command before the callback returns.
- The Swift callback only enqueues the copied command onto the dedicated
  `LLMBridgeActor` and returns promptly.
- The callback must not call any Rust FFI entry synchronously or wait for the
  main actor.
- Command delivery is serial per runtime. Different runtimes do not share a
  command-order guarantee.

### Independent Event Submission

Swift delivers model events through a separate FFI entry after the command
callback has returned:

```text
submit_llm_event(runtime, session_handle, event_sequence, event_bytes)
```

Swift owns `event_bytes` for the duration of the FFI call; Rust copies accepted
events before returning. The event entry takes the runtime mutex only long
enough to validate the session/sequence, append the event, advance the worker,
and enqueue any next outbound command. It never calls the Swift vtable while
holding the mutex.

The stream contract is provider-neutral:

```text
started
reasoning_summary_delta
text_delta
tool_call_started
tool_call_arguments_delta
tool_call_completed
usage_updated
completed
cancelled
failed
```

Rules:

- Swift prepares and owns every session handle.
- Rust may retain a handle only for the lifetime of its run.
- Closing is idempotent.
- Each session uses monotonically increasing event sequence numbers.
- A duplicate sequence is an idempotent no-op.
- A sequence gap interrupts the session with `llm.event.sequence_gap`.
- Events after a terminal event return `llm.event.terminal` and are ignored.
- Events for an expired or unknown handle return `llm.event.stale_session` and
  are ignored.
- Provider-specific unknown events are handled in Swift and do not cross FFI.
- Provider reasoning signatures and raw thinking blocks never cross FFI.
- Tool calls cross FFI only in the normalized agent tool-call shape.
- Secrets and local paths never appear in port DTOs.
- Tool completion persists the Rust observation before a resume command is
  enqueued.

### Backpressure

Rust maintains a bounded per-session inbound event queue. V1 limits are 256
events and 2 MiB of copied event payloads. `submit_llm_event` returns one of:

```text
accepted
duplicate
backpressure
stale_session
terminal
sequence_gap
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

- If a terminal model event commits first, a later cancel is an idempotent
  no-op.
- If cancellation commits first, later non-cancellation events are stale and
  ignored.
- Swift cancels the active URLSession task or C++ generation exactly once and
  submits one terminal `cancelled` event.
- If the host does not acknowledge cancellation within ten seconds, Rust marks
  the run interrupted and closes the session handle.

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
    var validationState: ProviderValidationState
    var approvedEgressOrigin: EgressOrigin?
    var catalogRevision: UInt64?
}
```

Non-secret Provider Profile configuration is immutable by revision. Changing
the preset or Base URL creates a new revision. Rotating a key replaces the
secret behind the same credential slot, invalidates validation, and does not
rewrite an Agent or LLM target revision. A cloud `LLMTargetRevision` pins the
Provider Profile revision it was validated against.

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

Changing the Base URL, API key, provider preset, or selected model invalidates
the relevant validation state. A successful probe is evidence of current
availability, not a permanent capability override.

### Keychain

- The API key is stored with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- Persistent stores contain only an opaque CredentialRef.
- The UI cannot read a saved key back as plaintext; it may replace or delete it.
- Deleting a Provider Profile deletes its Keychain item.
- Credential resolution happens only after egress and approval checks pass.
- Credential values never enter logs, SQLite, FFI DTOs, diagnostics, exports, or
  provider error messages.

### Provider Session Continuation

Swift owns an in-memory provider session object for every cloud run:

```text
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

`AgentLLMInput` carries provider-neutral data-class and sensitivity annotations.
Swift evaluates them before credential resolution or network task creation.

High-sensitivity context or sensitive attachments require an additional
per-run approval describing the provider origin and data classes. Denial stops
the run before any outbound request.

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

Tool calling distinguishes unsupported, sequential, and parallel support.
Reasoning capability describes supported control modes without exposing a
provider request field.

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

## Global Runtime Coordinator

`LLMRuntimeCoordinator` is a Swift global actor-backed service.

```text
idle
  -> preparing
  -> awaiting_approval
  -> loading_local | opening_cloud_session
  -> generating
  <-> awaiting_tool_result
  -> completing
  -> closing
  -> idle
```

Every non-terminal state may transition through:

```text
cancelling -> closing -> idle
failed -> closing -> idle
```

Invariants:

- There is at most one active agent/LLM session globally.
- A new run is rejected while another run is active.
- An active run cannot switch target or parameter revision.
- Editing configuration during a run affects only the next run.
- Local preparation verifies installation before loading C++.
- Cloud preparation unloads the local RAM model before opening the provider
  session.
- Tool execution occurs in Rust while the Swift LLM session remains reserved.
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
     -> pending AgentHostConfiguration revision

3. Rust commit_profile_publish(publish token)
     -> visible profile revision

4. Swift activate_host_binding(publish token)
     -> active binding revision
```

Rules:

- Every step is idempotent by the same operation key.
- A Swift staging failure aborts the pending Rust publication.
- A Rust commit failure deletes or expires the pending Swift binding.
- A crash after Rust commit but before Swift activation leaves the profile
  visible but `host_unbound`; it is not runnable.
- Startup reconciliation retries Swift activation when both committed records
  match, otherwise it exposes a repair action.
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
     -> pending AgentHostConfiguration revision

3. Rust attach_host_binding(package binding token, opaque binding hash)
     -> package/profile readiness becomes host_binding_attached

4. Swift activate_host_binding(package binding token)
     -> active binding revision and runnable readiness
```

Each step is idempotent. A failure before Rust attachment removes or expires the
pending Swift binding. A crash after attachment but before activation leaves the
profile visible but not runnable; startup reconciliation activates the matching
record or returns it to `needs_llm_binding` with a repair action. Rust stores
only the opaque binding hash and never the target, provider, model, or path.

Export carries requirements and optional hints, not the device-local binding.

Legacy v1 packages are imported by translating their model manifest into an
optional hint plus a required LLM slot. Their concrete provider/model binding
is not installed into the new product path.

### Run Cross-Link

The two-phase run handshake is also the run saga. The Rust run snapshot stores:

```text
LLM slot ID and requirements hash
opaque host binding revision and hash
opaque Swift LLM snapshot ID
host process epoch
preparation token digest
```

The Swift LLM snapshot stores:

```text
proposed Rust run ID, which becomes the committed run ID
agent profile ID and revision
LLM slot ID
host binding revision and hash
preparation token digest
LLM target and sanitized runtime configuration
```

The shared digests and idempotency key prove that both snapshots describe the
same preparation without making Rust understand the target. A mismatch blocks
the run and enters a repairable `host_binding_conflict` state.

### Provider and Target Deletion

Provider Profile and LLM target revisions referenced by Agent bindings or run
snapshots are archived, not hard-deleted. Archiving:

- deletes the Keychain credential when requested;
- prevents new sessions;
- makes dependent Agent bindings not ready;
- retains immutable, non-secret revision metadata and hashes for explanation
  and audit; and
- permits garbage collection only after no binding, package install record, or
  retained run snapshot references the revision.

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
host binding revision and hash
LLM target ID and revision
route class: local or cloud
model ID
capability snapshot hash
resolved non-secret generation parameters
egress disclosure ID when remote
adapter or engine version
host process epoch
preparation token digest
```

The snapshot does not contain the API key, absolute local path, full request,
provider-private continuation state, or raw provider failure body.

Rust persists the opaque Swift snapshot ID, host binding revision/hash, process
epoch, and preparation-token digest for cross-linking. Swift remains the owner
and resolver of the LLM target and runtime configuration behind that snapshot.

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
rate_limited
generation_failed
stream_interrupted
cancelled
```

`execution.llm_continuation_lost` and
`execution.continuation_expired` are Rust run-recovery errors, not Swift
`AgentLLMFailure` categories, so they remain in the Rust execution namespace.

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

Every prepared LLM session is bound to the Swift host process epoch. A new app
process has an empty LLM session registry and a new epoch. Before pending tools
or approvals are exposed to the UI, startup reconciliation finds every
non-terminal Rust run whose snapshot references an older host epoch.

Runtime bootstrap must be reordered accordingly: Swift supplies the new host
epoch before Rust reconstructs actionable waiting state. Rust opens storage,
invalidates older-epoch continuations transactionally, and only then runs any
remaining replay logic. The current `AgentRuntime::with_store` behavior that
calls `replay_waiting_runs` during construction must be split so LLM-dependent
runs cannot become actionable before invalidation.

Affected states include:

```text
preparing
awaiting_llm
consuming_llm_stream
waiting_tool
suspended_for_approval
awaiting_llm_resume
cancelling
```

Rust performs one recovery transaction per affected run:

1. Append a terminal `run.interrupted` event with
   `execution.llm_continuation_lost`.
2. Mark the run interrupted and remove it from the active-run registry.
3. Invalidate every pending tool request and approval for that run.
4. Mark its preparation/session cross-link expired.
5. Record the host epoch mismatch for diagnostics without persisting provider
   continuation state.

Only after these transactions commit may the app list actionable pending tools
or approvals. A late approval, rejection, or tool result returns the stable
error `execution.continuation_expired`. It does not restart the model request,
recreate a Provider Session, or append the result to another run.

This intentionally replaces the current behavior that replays waiting-tool and
suspended runs after SQLite restart when the continuation depended on a live
Swift LLM session.

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

- Capability authority, dimension, expiry, and invalidation rules.
- Provider-list and generic probes cannot overclaim model semantics.
- Conservative handling of unknown capabilities.
- Parameter range, dependency, and mutual exclusion validation.
- Parameter preservation and pruning on model switch.
- Target and Agent Host Configuration revision pinning.
- Global single-run state-machine invariants.
- Sanitized snapshots and error redaction.

### Provider Adapter Fixture Tests

Each provider adapter has recorded, secret-free fixtures covering:

- request encoding;
- standard and reasoning parameter mapping;
- text streaming;
- tool-call argument deltas;
- tool-result continuation;
- provider-private thinking/signature preservation;
- usage normalization;
- unknown event forward compatibility;
- rate-limit and authentication errors;
- cancellation; and
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

- The agent kernel depends only on the abstract LLM client port.
- Rust product code does not construct or resolve Provider Profiles, model
  installations, Base URLs, credentials, model paths, or backend adapters.
- The resumable worker persists and yields before host generation.
- No Swift host vtable callback occurs while the Rust runtime mutex is held.
- Event sequence duplication, gaps, terminal events, stale handles, and bounded
  backpressure follow the bridge contract.
- Cancellation/final-event races produce one deterministic terminal state.
- Preparation tokens are single-use, expire, abort idempotently, and reject
  stale frame/plan/tool-schema digests.
- Normalized text and tool-call events drive the resumable agent worker.
- Swift-side cancellation terminates the Rust run.
- A host LLM failure maps to the limited agent-facing failure taxonomy.
- Architecture lint rejects reintroduction of provider or engine concepts into
  the Rust agent path.

### End-to-End Tests

- Rust preview -> Swift prepare -> Rust commit starts exactly one run and links
  matching Rust/Swift snapshots.
- Failure injection at every Profile publish and Package binding saga boundary
  converges through compensation or startup reconciliation.
- Agent Profile -> Swift AgentHostConfiguration -> local fake engine -> Rust
  tool loop -> final response.
- Agent Profile -> Swift Provider fixture adapter -> Rust tool loop -> final
  response.
- Local/cloud switch affects only the next run.
- Missing download, credential, capability, or egress approval blocks before
  Rust starts the agent run.
- Restart invalidates LLM-dependent waiting-tool/approval state before it is
  exposed, and late results return `execution.continuation_expired`.
- A committed or outcome-unknown host tool effect is never automatically
  executed twice.

## Migration from the Current Codebase

The current repository contains Rust provider/model/inference product paths and
a Swift Model Center that projects Rust provider profiles. Migration must avoid
a permanent dual architecture.

### Phase 1: Contracts, Slots, and Consistency Foundation

- Add Swift LLM contract, core, storage, capability, and parameter targets.
- Add `AgentHostConfiguration` and immutable `LLMTarget` revisions.
- Replace the concrete Rust model slot contract with portable `LLMSlot` and
  `AgentLLMRequirements`.
- Add Agent Package v2 requirements/hints and the legacy v1 translation rule.
- Add profile publish/install host-binding saga records, idempotency keys, and
  startup reconciliation.
- Add the `preview_run`/`commit_start`/`abort_preparation` contracts without
  switching the production worker yet.
- Do not change the active runtime path yet.

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
- Complete fixture coverage before exposing a provider preset in release UI.

### Phase 4: Host LLM Session Bridge

- Add opaque Swift-owned LLM session handles to the Rust-Swift boundary.
- Replace synchronous `ExecutionModelClient::next_turn` execution with the
  durable resumable worker state machine.
- Add the outbound command vtable and independent inbound event FFI entry.
- Prove that no Swift callback occurs while the Rust runtime mutex is held.
- Implement sequence handling, buffer ownership, bounded backpressure, late
  event behavior, and cancellation races.
- Implement host-process epoch recovery, continuation invalidation, and host
  tool effect idempotency.
- Replace the production `BridgeExecutionModelClient` provider path with a
  host-backed LLM client.
- Keep Rust Agent policy, context assembly, and tool semantics unchanged while
  changing the worker scheduling model.

### Phase 5: Product Adoption and Legacy Removal

- Replace current `ModelRoutingClient` behavior with the Swift LLM system.
- Remove provider construction from `AppBootstrapper` and
  `RustRuntimeConfiguration` product setup.
- Move Agent-to-model composition to Swift `AgentHostConfiguration`.
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

1. Portable LLM slots, Agent Package v2, cross-store saga, Swift LLM contracts,
   storage, capabilities, and parameters.
2. Local model catalog, download, disk management, and C++ runtime.
3. Cloud Provider Profiles, Keychain, egress, and adapters.
4. Async Swift-Rust LLM session bridge, two-phase run commit, and restart
   recovery.
5. Model Center UI, migration, and legacy cleanup.

The plans are sequential. Later plans must not redefine the ownership boundary
established here.

## Acceptance Criteria

- [ ] Rust production code does not own LLM targets, Provider Profiles, model
      installations, credentials, Base URLs, model paths, or backend selection.
- [ ] Rust Agent/Profile/Package contracts retain only portable LLM slots,
      requirements, and optional hints; they contain no device-local binding.
- [ ] Swift is the sole product owner of local/cloud LLM selection and runtime
      configuration.
- [ ] C++ performs only local inference execution.
- [ ] C++ renders engine/model-format-specific chat templates; Swift owns
      template selection, canonical messages/tools, and tool-call parsing.
- [ ] Run start uses preview, Swift host preparation, and Rust commit with a
      single-use expiring preparation token.
- [ ] Rust never invokes the Swift host vtable while holding its runtime mutex.
- [ ] The Rust worker is resumable and receives Swift stream events through an
      independent FFI entry with defined ownership, sequencing, and backpressure.
- [ ] Profile publish, Package binding, and run cross-links use idempotent sagas
      and converge after every injected crash boundary.
- [ ] Agent Package v2 carries LLM requirements/hints and no API key, device
      path, Provider Profile, or concrete host binding.
- [ ] One Agent Profile revision resolves to one explicit LLM target revision.
- [ ] A cloud LLM target revision pins one Provider Profile revision; changing
      its Base URL cannot silently alter an existing Agent configuration.
- [ ] Only one agent run and one generation may be active globally.
- [ ] Installed models remain on disk until the user deletes them.
- [ ] Only the active local model may be loaded in RAM.
- [ ] Local downloads support pause, resume, verification, atomic install, and
      launch reconciliation.
- [ ] Local catalog manifests are signed and arbitrary imports are absent in v1.
- [ ] API keys exist only in Keychain and never cross into Rust.
- [ ] Egress approval is bound to exact provider origin.
- [ ] High-sensitivity remote input requires per-run approval.
- [ ] OpenAI, Claude, Gemini, Grok, DeepSeek, MiniMax, and GLM have explicit
      Swift adapter semantics.
- [ ] Capability unknowns fail conservatively.
- [ ] Capability observations record dimension, authority, model revision,
      observed/expiry time, validation scope, and invalidation triggers.
- [ ] Parameter controls are capability-driven and adapter-validated.
- [ ] Provider-private thinking/signature state remains inside Swift sessions.
- [ ] Local and cloud sessions emit the same normalized agent event contract.
- [ ] Cancellation is idempotent and reaches Rust plus the active backend.
- [ ] Process restart atomically interrupts LLM-dependent non-terminal runs,
      invalidates pending tool/approval state, and rejects late results.
- [ ] Side-effecting host tools use effect IDs and never auto-repeat an
      outcome-unknown effect.
- [ ] No automatic model fallback occurs.
- [ ] Provider adapter CI uses secret-free fixtures rather than live keys.
- [ ] The legacy Rust provider product path is removed after migration parity.

## Official API References

The adapter design was checked against official provider documentation on
2026-07-10. Provider presets and capability catalogs must be versioned because
these APIs and model-level constraints evolve.

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
