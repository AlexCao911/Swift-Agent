# Cloud Provider Adapter Architecture

## Ownership

The cloud product path is Swift-owned. Rust owns Agent planning, tool policy,
memory/context selection, the authoritative semantic input, and the future
provider-neutral host command protocol. Swift owns Provider Profiles, exact
origins, credential slots and Keychain access, signed model capabilities,
semantic parameter mapping, egress approval, provider sessions, and network
transport. C++ has no cloud role and remains a local inference backend only.

The seven shipped presets are OpenAI, Anthropic, Gemini, xAI, DeepSeek,
MiniMax, and GLM. Each preset selects one explicit semantic adapter. Shared SSE
and JSON codecs may normalize framing, but they do not merge provider-specific
request schemas, continuation rules, thinking state, parameter support, tool
assembly, terminal semantics, or error classification.

## Request boundary

```text
authoritative AgentLLMInput + tool schema + source revisions
  + attachment identities + complete tool-result batch + semantic history
        │
        ▼
CloudSemanticTurnValidator
  recompute agent-input:v1 and source-revisions:v1
  verify GenerationDisclosure
        │
        ▼
ProviderEgressPolicy
  exact origin + retention + credential generation/use lease
  incremental scope grant and per-turn authorization
        │
        ▼
CloudProviderAdapter
  encode provider-specific CloudWireRequest (no credential, unsendable)
        │
        ▼
ProviderEgressPolicy.sealGenerationRequest
        │
        ▼
CloudHTTPTransport(AuthorizedCloudHTTPRequest only)
  revalidate lease → resolve Keychain → enforce origin/path → URLSession
```

`ValidatedCloudGenerationTurn` and `AuthorizedCloudHTTPRequest` cannot be
constructed by adapters or callers. Direct `URLSession` use is confined to
`CloudHTTPTransport.swift`; direct Security framework item operations are
confined to `SecurityCredentialVault.swift`. A wire request cannot carry an
Authorization header, API-key query, or credential value.

## Prepared session

Preparation requires an immutable cloud `LLMTargetRevision`, an exact active
`AgentHostConfiguration`, an active Provider Profile revision, an installed
matching adapter, a current credential-generation validation, and
retention-bound capabilities. A catalog route additionally requires the exact
current, non-revoked catalog entry. A probe-only manual route has explicit
`manual(adapterID, modelID)` identity, requires stateless retention, and keeps
both catalog and model revision nil. Catalog parameter resolution is:

```text
signed model defaults → target defaults → host overrides
```

Manual routes reject non-empty target defaults or host overrides and resolve
an empty semantic/provider configuration whose digest binds the adapter,
model, and manual source. A later catalog entry with the same model ID does not
promote existing manual evidence.

Swift authorizes the initial disclosure under a preparation credential lease,
persists a sanitized session and capability/configuration snapshot, waits for
the injected local route to unload, creates the provider-private session, then
binds the lease. A failure before binding atomically removes the snapshot,
prepared row, and acquired lease. Restart closes non-terminal old-epoch rows
and removes their leases before the subsystem is exposed.

Only one cloud session and one generation can be active. A turn terminal is
either a final response or one complete ordered tool-call batch. Multiple calls
may execute sequentially in the Agent layer, but the provider resumes once with
the whole normalized result batch. Mixed text before tool calls is visible; no
provider-private response ID, encrypted reasoning, or signature crosses the
normalized backend event boundary.

## Runtime event handoff

The outer generation stream is bounded. Every yield is checked: `.enqueued`
allows progress, `.dropped` fails as
`runtime.cloud_consumer_backpressure`, and `.terminated` enters cancellation.
A terminal lifecycle transition is persisted only after its terminal event is
enqueued. Explicit cancel, consumer abandonment, and their race share one
actor-isolated cancel-once decision; normal completion does not cancel the
provider.

This boundary detects in-process loss but is not a durable Rust/Swift delivery
protocol. Phase 4 still supplies command IDs and acknowledgements, durable
outbox rows, event sequence receipts, watchdogs, and restart recovery.

## Continuation and terminal rules

OpenAI Responses and xAI sessions can resume only the exact complete ordered
tool batch decoded by that session. Missing, duplicate, reordered, extra,
unrelated, or consumed result batches fail before request construction with
`cloud_adapter.tool_result_batch_mismatch`. Stateless requests replay the
required provider-private function-call continuation items; approved
provider-state requests use the exact prior response identity.

DeepSeek and GLM share framing but not weakened terminal semantics. A final
finish reason cannot coexist with accumulated tool fragments
(`cloud_adapter.terminal_conflict`), and `tool_calls` requires a non-empty,
complete ordered batch (`cloud_adapter.tool_call_incomplete`).

## Probe wire and capability gates

Every semantic adapter constructs its own discovery, account-validation, and
model-validation `CloudWireRequest`. Policy services seal those requests but
do not infer provider endpoints or headers. In particular, all Anthropic probe
requests carry `anthropic-version: 2023-06-01`; MiniMax selects its own headers.

Manual probe evidence proves only routine text generation and streaming.
Catalog acceptance deletes all validation rows whose decoded subject has a
catalog revision while preserving nil-revision manual rows. Runtime preparation
requires both text generation and streaming. Tool schemas accept only an array,
an empty object, or an object whose sole member is an array-valued `tools`;
malformed shapes fail with `runtime.cloud_tool_schema_invalid`, and only a
non-empty array requires tool-calling capability.

## Failure and retry rules

- A changed message, tool schema, source revision, attachment identity, tool
  result, or provider-required semantic history fails before the affected
  outbound request.
- Attachment-bearing cloud turns are rejected in Phase 3 because upload,
  retention, deletion, and byte-transport policy are not yet implemented.
- Credential rotation/deletion state, generation change, Profile archival,
  retention change, catalog change, adapter mismatch, or expired capability
  evidence fails closed.
- Outer handoff overflow fails as `runtime.cloud_consumer_backpressure`; it is
  never converted into a successful terminal state.
- Manual route parameters fail as
  `cloud_parameters.manual_parameter_unsupported`; manual provider-state
  retention is not runnable.
- At most one retry is allowed before any normalized output. Once reasoning
  summary, text, tool, or usage output exists, interruption is terminal.
- Cancellation and close are idempotent. Provider cancel and close each have a
  single owner. Close transitions the lease to closing, writes the tombstone,
  and removes the lease atomically.
- No automatic model/provider fallback is permitted.

## Verification

`scripts/run-llm-phase-3-contracts.sh` is the deterministic, credential-free
gate. It includes all earlier local/Rust/C++ gates, Phase 3 architecture lint,
all seven provider fixture suites, direct runtime and subsystem integration,
and the iOS `ThisDeviceOnly`/non-synchronizable Keychain contract. The live
smoke runner is manual and reference-only; it never accepts an API key value.

Phase 4 now connects this path to the Rust Agent worker through the
provider-neutral host target. Rust owns exact-revision route selection,
authoritative frozen input, public registration/attestation recomputation,
durable command outbox and receipts, ordered tool batches, lifecycle
watchdogs, formal output, global admission, and restart recovery. Swift keeps
the provider session, credential, egress, network, and continuation details.
The App installs one local/cloud host under the same Rust-owned execution
route and App-owned epoch; stale or mismatched routes fail without fallback.

`scripts/run-llm-phase-4-contracts.sh` is the release gate. It runs this Phase
3 gate first, clears all seven supported provider-key variables, then verifies
the Rust host contracts and integration, the complete Swift package, and the
App composition on explicit available iPhone and iPad Simulator UDIDs without
live network traffic.

Phase 5 still owns product UI, binding migration, and legacy-path removal.
