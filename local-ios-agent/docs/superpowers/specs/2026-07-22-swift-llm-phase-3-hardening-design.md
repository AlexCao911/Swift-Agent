# Swift LLM Phase 3.1 Reliability and Continuation Hardening Design

**Status:** Approved in conversation on 2026-07-22 (方案 A)

**Parent design:** `docs/superpowers/specs/2026-07-10-swift-llm-system-design.md`

**Phase 3 implementation:** `docs/superpowers/plans/2026-07-15-swift-llm-phase-3-cloud-product-path-implementation.md`

## Purpose

Phase 3 established the Swift-owned cloud product path, but review found seven places where an apparently valid state could be published without proving that the caller received the same event, resumed the exact tool-call batch, or used provider-correct discovery and validation wire semantics. This addendum closes those gaps without making Rust provider-aware, changing the C++ local-inference boundary, or pulling Phase 4's durable Rust/Swift command and event ledger into Phase 3.

The hardening work has four coherent units:

1. loss-detecting runtime event handoff and one cancellation arbiter;
2. exact provider continuation and terminal coherence;
3. provider-owned discovery/validation wire encoding;
4. explicit conservative manual-model routing and exact capability gates.

## Non-goals

- No Rust command outbox, event receipt ledger, or Phase 4 host-backed Agent execution.
- No unbounded event buffer and no claim that `AsyncThrowingStream` is a durable delivery protocol.
- No provider API key, model wire field, or Provider Profile semantic added to Rust or C++.
- No automatic model/provider fallback.
- No capability promotion for a manual model merely because a later signed catalog contains the same model ID.
- No tool calling, reasoning control, structured output, multimodal input, context-window claim, or model parameter control for a manual route unless a future validation protocol proves it explicitly.

## 1. Runtime event handoff and cancellation

`CloudLLMRuntime` keeps its bounded outer `AsyncThrowingStream` because a slow or abandoned UI must not cause unbounded RAM growth. Every `Continuation.yield` result is authoritative:

| Yield result | Runtime action |
| --- | --- |
| `.enqueued` | The event was accepted by the bounded handoff. Processing may continue. |
| `.dropped` | Fail the generation with stable code `runtime.cloud_consumer_backpressure`; do not publish a successful terminal transition. |
| `.terminated` | Treat the consumer as cancelled and enter the shared cancel-once path. |
| unknown future case | Fail closed as `runtime.cloud_consumer_backpressure`. |

For `generationCompleted` and provider `cancelled`, the runtime first obtains `.enqueued` from the outer continuation and only then commits the corresponding terminal or `awaitingToolResult` lifecycle transition. If terminal enqueue drops, the runtime records a failed terminal transition rather than a successful completion. This removes the state/UI contradiction found in Phase 3 while acknowledging that a Phase 4 receipt ledger is still required for durable cross-process delivery.

Explicit `cancel(sessionID:)`, consumer termination, and a `.terminated` yield all call one actor-isolated cancellation arbiter. The first claimant:

- binds the exact `sessionID` and `generationID`;
- flips `cancelRequested` before awaiting provider code;
- invokes `providerSession.cancel()` exactly once;
- cancels the pump task when the claimant is not that pump task.

Losing callers wait for, or observe, the same terminal cleanup and never call the provider again. Normal stream completion does not invoke provider cancellation. `closeSession` continues to close the provider session exactly once after any generation cancellation has converged.

## 2. Exact tool continuation and terminal coherence

### OpenAI Responses and xAI

The Responses session stores a private pending continuation only after it has decoded a complete `toolCallsReady` turn. The continuation contains:

```text
response ID when provider-state retention is approved
encrypted reasoning items required for continuation
ordered tool calls:
  provider output item ID
  normalized call ID
  function name
  complete arguments JSON
```

`encodeResume` is invalid unless such a pending batch exists. The supplied normalized results must match the pending call IDs exactly in order and cardinality. Missing, duplicate, reordered, extra, or unrelated IDs fail before a wire request is created with `cloud_adapter.tool_result_batch_mismatch`.

In provider-state-approved mode the request uses the exact stored `previous_response_id` and ordered function-call outputs. In stateless-required mode it resends the complete provider-required semantic history and the saved provider-private function-call continuation items before the matching function-call output items. Provider-private item IDs, encrypted reasoning, and function-call items stay in the in-memory Swift session and are never persisted or exposed as public backend events.

Encoding a resume consumes the pending batch for that session turn. A second resume without decoding a new `toolCallsReady` terminal fails closed, preventing duplicate submission through the provider session API.

### OpenAI Chat family

The shared Chat decoder used by DeepSeek and GLM validates the complete turn before publishing `generationCompleted`:

- `finalResponse` requires that no tool-call fragment was ever accumulated;
- `toolCallsReady` requires a non-empty, contiguous, fully identified batch whose arguments are complete JSON values;
- a tool fragment followed by `stop`, `length`, `content_filter`, or another final finish reason fails as `cloud_adapter.terminal_conflict`;
- `tool_calls` without a complete non-empty batch fails as `cloud_adapter.tool_call_incomplete`.

Any text emitted before a valid tool batch remains a display preamble. It does not change the terminal outcome and does not become a standalone final assistant turn.

## 3. Provider-owned discovery and validation wire

Provider generation adapters also own the wire details for:

- model discovery;
- account validation;
- minimal streaming model validation.

`CloudModelDiscoveryService` remains responsible for decoding and merging model identities, and `ProviderValidationService` remains responsible for leases, egress seals, evidence, and persistence. Neither service guesses provider headers or endpoint bodies. Each installed `CloudProviderAdapter` returns unsendable `CloudWireRequest` values tagged with the correct no-user-data request class.

Shared family helpers may remove JSON duplication, but every shipped semantic adapter explicitly selects and exposes its probe wire. Registry completeness tests require all seven adapters to provide all three request types.

Anthropic discovery, account validation, and model validation carry `anthropic-version: 2023-06-01`, matching the version used by the generation codec. MiniMax does not inherit that header merely because it uses an Anthropic-compatible Messages body; its semantic adapter owns its exact headers. Probe wires contain no credential header and no user content.

## 4. Manual-model evidence and routing

A model ID absent from the signed catalog may become runnable only after exact discovery/account/model probes succeed. Manual evidence is represented directly rather than with catalog revision `0`:

```swift
ProviderValidationEvidenceIdentity.catalogRevision: UInt64?
CapabilitySubject.catalogRevision == nil
CapabilitySubject.modelRevision == nil
```

`currentValidation` has two branches:

- catalog-backed evidence requires the same current catalog revision, a non-revoked exact entry, compatible adapter version, and allowed retention mode;
- manual evidence requires `catalogRevision == nil`, `modelRevision == nil`, the same profile/origin/credential generation/adapter/model/retention identity, and unexpired recomputable probe evidence.

A catalog advance invalidates and deletes only catalog-backed validation records. Manual evidence remains valid until its own expiry or until profile, origin, credential generation, adapter version, retention identity, or target identity changes. If a later catalog adds the same model ID, the existing evidence stays manual and conservative. The user must revalidate to obtain a catalog-backed route; there is no silent capability promotion.

The runtime represents the model source explicitly as either `catalog(entry)` or `manual(adapterID, modelID)`. Manual routes require `statelessRequired`, reject non-empty target defaults and host overrides, and resolve to an empty semantic parameter set plus a deterministic digest bound to the exact adapter/model/manual source. They receive only capabilities proven by the routine probe: text generation and streaming. Unknown remains unsupported.

## 5. Capability gate

All Phase 3 generations are streaming, so runtime preparation and every generation recheck require both `text_generation` and `streaming` to be supported.

Tool presence is parsed from the canonical schema rather than inferred from object non-emptiness:

- `[]`, `{}`, and `{ "tools": [] }` request no tools;
- a non-empty top-level array or non-empty `{ "tools": [...] }` requests tools;
- a non-array `tools` value or an unrelated non-empty object fails with `runtime.cloud_tool_schema_invalid`;
- a real tool request additionally requires `tool_calling == supported`.

This parsing is provider-neutral and remains in the Swift runtime. Provider adapters continue to validate and encode the actual canonical tool definitions.

## Persistence and compatibility

Changing `ProviderValidationEvidenceIdentity.catalogRevision` from `UInt64` to `UInt64?` is backward-decodable for existing JSON records: existing numeric values remain catalog-backed. SQLite already stores `provider_profile_state.catalog_revision` as nullable, so this hardening requires no schema-version bump or new table.

Catalog-advance cleanup scans every persisted validation record in the catalog-acceptance transaction and uses the record's decoded `CapabilitySubject.catalogRevision`, not merely the Profile's current validation projection, as its source authority. Every catalog-backed validation plus its exact profile-revision/model observations is deleted, including a stale catalog row left behind after the Profile selected another model. Current catalog-backed Profile states are invalidated in the same transaction. Manual rows are not touched.

No provider-private continuation is persisted. Process restart still interrupts all prepared cloud sessions and requires a new generation/session, as defined by the parent design.

## Verification requirements

The implementation is complete only when tests prove:

- outer buffer overflow ends in the stable backpressure failure and never presents a clean successful terminal;
- explicit cancellation, consumer abandonment, and their races call provider cancel once;
- Responses/xAI resume rejects missing, duplicate, reordered, extra, unrelated, or already-consumed result batches;
- stateless Responses resume contains saved function-call continuation items in order;
- Chat final/tool terminal conflicts fail before `generationCompleted`;
- every Anthropic probe request carries the version header, while credential headers remain absent;
- a probed manual model can prepare and run text with streaming, but cannot use tools or parameters;
- manual evidence survives catalog advance without acquiring catalog capabilities;
- catalog-backed evidence is still atomically invalidated on catalog advance;
- `{ "tools": [] }` is accepted without tool capability, malformed schema fails, and missing streaming capability rejects the route;
- the full Phase 3 contract runner and architecture lint remain green.
