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
`AgentHostConfiguration`, an active Provider Profile revision, a trusted
catalog entry, an installed matching adapter, a current credential-generation
validation, and retention-bound capabilities. Parameter resolution is:

```text
signed model defaults → target defaults → host overrides
```

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

## Failure and retry rules

- A changed message, tool schema, source revision, attachment identity, tool
  result, or provider-required semantic history fails before the affected
  outbound request.
- Attachment-bearing cloud turns are rejected in Phase 3 because upload,
  retention, deletion, and byte-transport policy are not yet implemented.
- Credential rotation/deletion state, generation change, Profile archival,
  retention change, catalog change, adapter mismatch, or expired capability
  evidence fails closed.
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

Phase 4 still owns the Rust host-command bridge and canonical public
registration recomputation. Phase 5 still owns product UI, migration, and
legacy-path removal.
