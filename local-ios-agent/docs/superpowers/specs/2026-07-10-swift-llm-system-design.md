# Swift-Owned LLM System Design

**Status:** Approved design

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
  model bindings, or inference backend selection.
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

## Architectural Boundary

```text
Swift App / Agent Host
  |
  |-- AgentHostConfiguration
  |-- LLMTargetRepository
  |-- CapabilityMatrix
  |-- LLMParameterSystem
  |-- LocalModelManager
  |-- CloudProviderManager
  |-- LLMRuntimeCoordinator
  |
  | prepares an opaque LLMSessionHandle
  v
Rust Agent Kernel
  |
  |-- agent loop
  |-- context assembly
  |-- memory
  |-- tool orchestration
  |-- run lifecycle
  |-- provider-neutral LLMClient port
  |
  | calls through the opaque session handle
  v
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
- Agent LLM requirements such as required tool calling, required input
  modalities, minimum context size, and streaming requirement.
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
    LLMTarget.swift
    CapabilityMatrix.swift
    LLMParameterSystem.swift
    LLMRuntimeCoordinator.swift
    LLMSessionRegistry.swift
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

The Rust Agent Profile stays model-neutral. Swift composes it with an LLM target.

```swift
struct AgentHostConfiguration: Codable, Sendable {
    let agentProfileID: String
    let agentProfileRevision: UInt64
    let llmTargetID: LLMTargetID
    let llmTargetRevision: UInt64
    let parameterOverrides: GenerationConfiguration
}
```

The UI may present this composition as part of Agent Profile editing, but the
record belongs to the Swift host layer and is not stored in the Rust agent
definition.

### Prepared LLM Session

Before Rust starts a run, Swift resolves and validates the host configuration.

```swift
struct PreparedLLMSession: Sendable {
    let handle: LLMSessionHandle
    let agentCapabilities: AgentLLMCapabilities
    let sanitizedSnapshot: LLMRunSnapshot
}
```

`LLMSessionHandle` is opaque to Rust. It never encodes a model path, Provider
Profile, API key, Base URL, engine ID, or adapter kind.

## Rust-Swift LLM Client Port

The product path should keep the existing agent-facing model-client abstraction
but replace provider-owned Rust implementations with a host-backed client.

Conceptual operations:

```text
start_generation(session_handle, agent_llm_input)
submit_tool_results(session_handle, normalized_tool_results)
cancel_generation(session_handle)
close_session(session_handle)
```

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
- Events after a terminal event are rejected.
- Provider-specific unknown events are handled in Swift and do not cross FFI.
- Provider reasoning signatures and raw thinking blocks never cross FFI.
- Tool calls cross FFI only in the normalized agent tool-call shape.
- Secrets and local paths never appear in port DTOs.
- The bridge must support cancellation while a generation callback is blocked.

The initial bridge may use the project's existing JSON envelope conventions
over the C ABI. The implementation plan must define buffer ownership, callback
threading, terminal-event rules, and release behavior explicitly.

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
prompt template ID
tool-call codec ID
```

Artifacts may include model weights, tokenizer data, multimodal projection
files, and chat templates. The manifest, not the user, determines which files
are required for a format. The prompt template and tool-call codec are
implemented in the Swift local adapter; C++ remains unaware of agent tool-call
semantics.

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

Every material capability has provenance:

```text
official_model_catalog
cloud_capability_catalog
provider_model_list
swift_adapter
cpp_engine
validation_probe
```

The effective capability is the conservative intersection of catalog claims
and adapter/engine implementation support. Numeric limits use the lowest
verified bound. Conflicts become `unknown` rather than optimistic support.
Readiness is evaluated separately from capability and may block an otherwise
capable target because an installation, credential, approval, or validation is
missing.

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

## Sanitized Run Snapshot

Swift records a run-level LLM snapshot containing:

```text
agent profile ID and revision
LLM target ID and revision
route class: local or cloud
model ID
capability snapshot hash
resolved non-secret generation parameters
egress disclosure ID when remote
adapter or engine version
```

The snapshot does not contain the API key, absolute local path, full request,
provider-private continuation state, or raw provider failure body.

Rust may receive a small opaque snapshot identifier for cross-linking a run,
but Swift remains the owner and resolver of the snapshot.

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

## Testing Strategy

### Swift Contract Tests

- Capability intersection and provenance.
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
- One real smoke model per release engine in the appropriate release gate.

### Rust Boundary Tests

- The agent kernel depends only on the abstract LLM client port.
- Rust product code does not construct or resolve Provider Profiles, model
  installations, Base URLs, credentials, model paths, or backend adapters.
- Normalized text and tool-call events drive the existing agent loop.
- Swift-side cancellation terminates the Rust run.
- A host LLM failure maps to the limited agent-facing failure taxonomy.
- Architecture lint rejects reintroduction of provider or engine concepts into
  the Rust agent path.

### End-to-End Tests

- Agent Profile -> Swift AgentHostConfiguration -> local fake engine -> Rust
  tool loop -> final response.
- Agent Profile -> Swift Provider fixture adapter -> Rust tool loop -> final
  response.
- Local/cloud switch affects only the next run.
- Missing download, credential, capability, or egress approval blocks before
  Rust starts the agent run.

## Migration from the Current Codebase

The current repository contains Rust provider/model/inference product paths and
a Swift Model Center that projects Rust provider profiles. Migration must avoid
a permanent dual architecture.

### Phase 1: Swift LLM Foundation

- Add Swift LLM contract, core, storage, capability, and parameter targets.
- Add `AgentHostConfiguration` and immutable `LLMTarget` revisions.
- Do not change the active runtime path yet.

### Phase 2: Local Product Path

- Add official catalog, downloader, installer, disk policy, and local runtime.
- Connect Swift directly to the existing C++ v2 engine boundary.
- Extend the C++ boundary only for capabilities, parameters, and explicit
  unload behavior required by this design.

### Phase 3: Cloud Product Path

- Add Provider Profiles, Keychain storage, egress, validation, and provider
  adapters.
- Complete fixture coverage before exposing a provider preset in release UI.

### Phase 4: Host LLM Session Bridge

- Add opaque Swift-owned LLM session handles to the Rust-Swift boundary.
- Replace the production `BridgeExecutionModelClient` provider path with a
  host-backed LLM client.
- Keep Rust agent loop behavior unchanged.

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

1. Swift LLM contracts, storage, capabilities, and parameters.
2. Local model catalog, download, disk management, and C++ runtime.
3. Cloud Provider Profiles, Keychain, egress, and adapters.
4. Swift-Rust LLM session bridge and Agent Host Configuration.
5. Model Center UI, migration, and legacy cleanup.

The plans are sequential. Later plans must not redefine the ownership boundary
established here.

## Acceptance Criteria

- [ ] Rust production code does not own LLM targets, Provider Profiles, model
      installations, credentials, Base URLs, model paths, or backend selection.
- [ ] Swift is the sole product owner of local/cloud LLM selection and runtime
      configuration.
- [ ] C++ performs only local inference execution.
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
- [ ] Parameter controls are capability-driven and adapter-validated.
- [ ] Provider-private thinking/signature state remains inside Swift sessions.
- [ ] Local and cloud sessions emit the same normalized agent event contract.
- [ ] Cancellation is idempotent and reaches Rust plus the active backend.
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
