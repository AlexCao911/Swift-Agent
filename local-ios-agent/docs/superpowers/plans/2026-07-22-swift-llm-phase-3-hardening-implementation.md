# Swift LLM Phase 3.1 Reliability and Continuation Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Phase 3 Swift cloud path loss-detecting, cancel-once, continuation-exact, provider-correct during validation, and capable of running a conservatively validated manual model without granting unproven capabilities.

**Architecture:** Keep the existing direct Swift cloud runtime and bounded streams, but fail closed when the outer handoff cannot enqueue an event. Provider sessions retain the exact private continuation required to validate tool-result batches, provider adapters own discovery/validation wire semantics, and validation/runtime represent catalog-backed and manual routes explicitly. Rust stays provider-neutral, C++ stays local-inference-only, and Phase 4 durable command/event receipts remain deferred.

**Tech Stack:** Swift 6, SwiftPM, Foundation `AsyncThrowingStream`, `URLSession`, Security/Keychain Services, Apple SQLite3, canonical JSON digests, SSE fixtures, Swift Testing, Rust architecture lint, and shell contract runners.

**Design authority:** `docs/superpowers/specs/2026-07-10-swift-llm-system-design.md` plus `docs/superpowers/specs/2026-07-22-swift-llm-phase-3-hardening-design.md`.

## Global Constraints

- Work only in `/Users/alexandercou/Projects/Alex-agent/.worktrees/llm-runtime-provider-design/local-ios-agent` on `codex/llm-runtime-provider-design`.
- Execute sequentially with one Agent; do not dispatch subagents.
- Use strict RED/GREEN/REFACTOR for every behavior change. No production edit is allowed before its focused test fails for the intended reason.
- Preserve the seven explicit provider semantic adapters and four shared codec families.
- Rust remains the provider-neutral Agent kernel. Do not add provider/profile/base-URL/credential/model-wire semantics to Rust.
- C++ remains local-inference-only and is unchanged.
- Keep the outer runtime event buffer bounded at 32; do not replace protocol correctness with an unbounded buffer.
- Keep provider-private continuation in memory only. Do not persist response IDs, encrypted reasoning, function-call items, or signatures.
- Manual models support only exact routine-probe text generation and streaming. Unknown capability remains unsupported.
- A later catalog entry never silently upgrades existing manual evidence.
- Preserve exact-origin sealing, credential-use leases, disclosure validation, egress approval, and attachment fail-closed behavior.
- Each task ends with focused tests, the relevant cloud regression suite, `git diff --check`, and one reviewable commit.

## File Structure

The implementation modifies focused existing files and adds one provider-probe helper:

```text
toolkit/Sources/LocalAgentLLMCloud/
  CloudLLMRuntime.swift                   outer event handoff, cancel arbiter, capability gate, route source
  OpenAIResponsesAdapter.swift            exact tool continuation and OpenAI probe selection
  OpenAIChatCompletionsCodec.swift         final/tool terminal coherence
  CloudProviderAdapter.swift              adapter-owned probe-wire requirements
  ProviderProbeWireEncoder.swift           shared body construction selected by each adapter
  XAIAdapter.swift                         xAI probe selection
  AnthropicMessagesAdapter.swift           Anthropic versioned probe selection
  MiniMaxAdapter.swift                     MiniMax probe selection
  GeminiInteractionsAdapter.swift          Gemini probe selection
  DeepSeekAdapter.swift                    DeepSeek probe selection
  GLMAdapter.swift                         GLM probe selection
  CloudModelDiscoveryService.swift         decode/merge only; no request guessing
  ProviderValidationService.swift          optional catalog evidence and two validation branches
  ProviderProfile.swift                    optional evidence catalog revision
  CloudCapabilityCatalog.swift             selective catalog-backed invalidation
  CloudGenerationConfigurationResolver.swift deterministic parameter-free manual resolution

toolkit/Tests/LocalAgentLLMCloudTests/
  CloudLLMRuntimeTests.swift
  OpenAIResponsesAdapterTests.swift
  XAIAdapterTests.swift
  DeepSeekAdapterTests.swift
  GLMAdapterTests.swift
  ProviderValidationServiceTests.swift
  CloudCapabilityCatalogTests.swift
  CloudModelDiscoveryTests.swift
  CloudGenerationConfigurationResolverTests.swift
  CloudProductPathIntegrationTests.swift
  Fixtures/openai/responses-encrypted-tool.sse
  Fixtures/deepseek/deepseek-tool-stop-conflict.sse
  Fixtures/deepseek/deepseek-empty-tool-terminal.sse
  Fixtures/deepseek/deepseek-incomplete-tool-terminal.sse
```

No SQLite migration file is added: `provider_profile_state.catalog_revision` is already nullable and existing numeric JSON values decode into `UInt64?`.

---

### Task 1: Fail Closed on Runtime Backpressure and Unify Cancellation

**Files:**
- Modify: `toolkit/Tests/LocalAgentLLMCloudTests/CloudLLMRuntimeTests.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCloud/CloudLLMRuntime.swift`

**Interfaces:**
- Produces `yieldRuntimeEvent(_:to:)`, which maps `.dropped` to `runtime.cloud_consumer_backpressure` and `.terminated` to cancellation.
- Produces one actor-isolated `cancelGenerationOnce(sessionID:generationID:cancelPump:)` path used by explicit cancel, consumer termination, and pump cancellation.
- Preserves public `cancel(sessionID:)`, `startGeneration`, and `resumeGeneration` signatures.

- [x] **Step 1: Write failing overflow and consumer-cancellation tests**

Add a burst mode to `RuntimeSpyProviderSession` that synchronously emits 40 text deltas followed by `generationCompleted`. Start generation without consuming until the provider has finished producing, then drain the outer stream and require the stable failure rather than clean EOF:

```swift
@Test
func outerBufferOverflowFailsInsteadOfDroppingTerminal() async throws {
    let harness = try await RuntimeHarness.make(providerEvents: (0..<40).map {
        .textDelta("chunk-\($0)")
    } + [.generationCompleted(.init(
        outcome: .finalResponse,
        orderedCallIDs: [],
        finishReason: .stop
    ))])
    defer { harness.cleanup() }

    let stream = try await harness.runtime.startGeneration(
        sessionID: harness.prepared.sessionID,
        turn: harness.initialTurn
    )
    await harness.providerSession.waitUntilDecodeFinished()

    await expectStreamFailure("runtime.cloud_consumer_backpressure", stream: stream)
    #expect(await harness.runtime.state == .terminal)
}
```

Add tests that cancel by abandoning an active iterator, race abandonment with `runtime.cancel`, and finish normally. Assert `cancelCount == 1` for both cancellation cases and `cancelCount == 0` for normal completion; `closeCount` remains exactly one after `closeSession`.

- [x] **Step 2: Run RED**

```bash
swift test --package-path toolkit --filter CloudLLMRuntimeTests.outerBufferOverflowFailsInsteadOfDroppingTerminal
swift test --package-path toolkit --filter CloudLLMRuntimeTests.consumerTerminationAndExplicitCancelShareOneProviderCancel
```

Expected: overflow reaches clean EOF or misses the terminal error, and consumer termination leaves `cancelCount == 0`.

- [x] **Step 3: Implement loss-detecting yield and cancel-once arbitration**

Move terminal lifecycle commits after successful enqueue and handle every yield result:

```swift
private func yieldRuntimeEvent(
    _ event: LLMBackendEvent,
    to continuation: LLMBackendEventStream.Continuation
) throws {
    switch continuation.yield(event) {
    case .enqueued:
        return
    case .dropped:
        throw cloudRuntimeFailure(
            "runtime.cloud_consumer_backpressure",
            "cloud generation consumer exceeded its bounded event buffer"
        )
    case .terminated:
        throw CancellationError()
    @unknown default:
        throw cloudRuntimeFailure(
            "runtime.cloud_consumer_backpressure",
            "cloud generation consumer state is unknown"
        )
    }
}
```

In `pumpGeneration`, call `yieldRuntimeEvent` before `finishGeneration` for normalized terminal events. On a dropped terminal, the ordinary error path calls `failGeneration` and finishes the stream with the backpressure failure. Install an `onTermination` closure that reacts only to `.cancelled` and sends the exact session/generation identity back to the runtime actor.

The arbiter sets `cancelRequested` before awaiting `providerSession.cancel()`. Explicit cancel cancels and awaits the pump task; a pump that observes termination claims provider cancellation without awaiting itself. Repeated claimants do not call the provider again.

- [x] **Step 4: Run GREEN and regressions**

```bash
swift test --package-path toolkit --filter CloudLLMRuntimeTests
swift test --package-path toolkit --filter CloudProductPathIntegrationTests
git diff --check
```

Expected: all runtime/integration tests pass; overflow surfaces `runtime.cloud_consumer_backpressure`; cancellation counts are exact.

- [x] **Step 5: Commit**

```bash
git add toolkit/Sources/LocalAgentLLMCloud/CloudLLMRuntime.swift \
  toolkit/Tests/LocalAgentLLMCloudTests/CloudLLMRuntimeTests.swift
git commit -m "fix: make cloud runtime event handoff loss detecting"
```

---

### Task 2: Bind Responses and xAI Resume to the Exact Tool Batch

**Files:**
- Create: `toolkit/Tests/LocalAgentLLMCloudTests/Fixtures/openai/responses-encrypted-tool.sse`
- Modify: `toolkit/Tests/LocalAgentLLMCloudTests/OpenAIResponsesAdapterTests.swift`
- Modify: `toolkit/Tests/LocalAgentLLMCloudTests/XAIAdapterTests.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCloud/OpenAIResponsesAdapter.swift`

**Interfaces:**
- Produces private `ResponsesToolContinuation` and `ContinuationState.pendingToolCalls`.
- `encodeResume(_:)` requires and consumes an exact ordered pending batch.
- `encodeStart(_:)` rejects non-empty tool results.
- xAI inherits the same exact continuation behavior through `OpenAIResponsesSession`.

- [x] **Step 1: Write failing exact-batch and stateless-continuation tests**

Decode `responses-two-tools.sse`, then try resume batches with missing, duplicate, reversed, extra, and unrelated IDs. Every invalid batch must fail before request creation:

```swift
for results in [missing, duplicate, reversed, extra, unrelated] {
    expectAdapterFailure("cloud_adapter.tool_result_batch_mismatch") {
        _ = try session.encodeResume(
            authorizedTurn(toolResults: results)
        )
    }
}
```

For the valid ordered batch, inspect stateless wire input and require this relative order:

```text
saved function_call(call_weather)
saved function_call(call_calendar)
function_call_output(call_weather)
function_call_output(call_calendar)
```

Assert each saved function call preserves its provider item ID, name, and complete arguments. Call `encodeResume` a second time without another decode and expect `cloud_adapter.continuation_missing`. Add the same reordered-batch assertion to the xAI suite.

- [x] **Step 2: Run RED**

```bash
swift test --package-path toolkit --filter OpenAIResponsesAdapterTests.resumeRequiresExactOrderedDecodedToolBatch
swift test --package-path toolkit --filter OpenAIResponsesAdapterTests.statelessResumeResendsPrivateFunctionCallItemsBeforeOutputs
swift test --package-path toolkit --filter XAIAdapterTests.resumeRejectsReorderedToolResults
```

Expected: a fresh session accepts resume, mismatched batches encode, and stateless input lacks saved function-call items.

- [x] **Step 3: Store and consume the complete private continuation**

Extend session state:

```swift
private struct ResponsesToolContinuation: Sendable {
    let itemID: String
    let callID: String
    let name: String
    let arguments: String
}

private struct ContinuationState: Sendable {
    var responseID: String?
    var encryptedReasoning: [String] = []
    var pendingToolCalls: [ResponsesToolContinuation] = []
}
```

The decoder exposes an ordered private continuation only after it emits a valid `toolCallsReady` terminal. `recordContinuation` stores it atomically with response ID and encrypted reasoning. `encodeResume` compares arrays, not sets:

```swift
let expected = state.pendingToolCalls.map(\.callID)
let supplied = toolResults.map(\.callID)
guard !expected.isEmpty, supplied == expected,
      Set(supplied).count == supplied.count else {
    throw responsesFailure(
        "cloud_adapter.tool_result_batch_mismatch",
        "tool-result batch does not match the preceding ordered tool calls"
    )
}
```

For stateless mode, append saved `function_call` objects before matching `function_call_output` objects. Consume `pendingToolCalls` under the lock when the resume request is successfully encoded. Preserve response ID/encrypted reasoning needed for that encoded request, and clear all private state on close.

- [x] **Step 4: Run GREEN and shared regressions**

```bash
swift test --package-path toolkit --filter OpenAIResponsesAdapterTests
swift test --package-path toolkit --filter XAIAdapterTests
swift test --package-path toolkit --filter CloudProductPathIntegrationTests
git diff --check
```

Expected: OpenAI, xAI, and the end-to-end tool loop pass with exact ordered continuation.

- [x] **Step 5: Commit**

```bash
git add toolkit/Sources/LocalAgentLLMCloud/OpenAIResponsesAdapter.swift \
  toolkit/Tests/LocalAgentLLMCloudTests/OpenAIResponsesAdapterTests.swift \
  toolkit/Tests/LocalAgentLLMCloudTests/XAIAdapterTests.swift
git commit -m "fix: bind responses resume to decoded tool calls"
```

---

### Task 3: Reject Conflicting Chat Terminals

**Files:**
- Create: `toolkit/Tests/LocalAgentLLMCloudTests/Fixtures/deepseek/deepseek-tool-stop-conflict.sse`
- Create: `toolkit/Tests/LocalAgentLLMCloudTests/Fixtures/deepseek/deepseek-empty-tool-terminal.sse`
- Create: `toolkit/Tests/LocalAgentLLMCloudTests/Fixtures/deepseek/deepseek-incomplete-tool-terminal.sse`
- Modify: `toolkit/Tests/LocalAgentLLMCloudTests/DeepSeekAdapterTests.swift`
- Modify: `toolkit/Tests/LocalAgentLLMCloudTests/GLMAdapterTests.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCloud/OpenAIChatCompletionsCodec.swift`

**Interfaces:**
- Produces decoder validation that separates `terminal_conflict` from `tool_call_incomplete`.
- Preserves the normalized event contract and shared DeepSeek/GLM codec.

- [x] **Step 1: Add failing terminal-coherence fixtures and tests**

`deepseek-tool-stop-conflict.sse` starts one complete tool call, reports `finish_reason: "stop"`, then `[DONE]`. `deepseek-empty-tool-terminal.sse` reports `finish_reason: "tool_calls"` without any tool delta, then `[DONE]`.

```swift
@Test
func toolFragmentsCannotEndAsFinalResponse() async throws {
    await expectDeepSeekFailure(
        "cloud_adapter.terminal_conflict",
        fixture: "deepseek-tool-stop-conflict"
    )
}

@Test
func toolTerminalRequiresANonemptyCompleteBatch() async throws {
    await expectDeepSeekFailure(
        "cloud_adapter.tool_call_incomplete",
        fixture: "deepseek-empty-tool-terminal"
    )
}
```

Add the equivalent synthetic-event conflict assertion to GLM to prove both adapters inherit the shared rule.

- [x] **Step 2: Run RED**

```bash
swift test --package-path toolkit --filter DeepSeekAdapterTests.toolFragmentsCannotEndAsFinalResponse
swift test --package-path toolkit --filter DeepSeekAdapterTests.toolTerminalRequiresANonemptyCompleteBatch
swift test --package-path toolkit --filter GLMAdapterTests.toolFragmentsCannotEndAsFinalResponse
```

Expected: the conflict fixture emits `generationCompleted(.finalResponse)` and the empty tool terminal reaches `[DONE]` without the required stable failure.

- [x] **Step 3: Validate terminal coherence before completion**

When a finish reason arrives, reject any final reason if `tools` is non-empty. For `.toolCalls`, call `completeTools()` and require the complete batch. At `[DONE]`, revalidate the invariant before building `LLMBackendCompletion`:

```swift
if finishReason != .toolCalls, !tools.isEmpty {
    throw chatFailure(
        "cloud_adapter.terminal_conflict",
        "Chat stream accumulated tool calls but ended as a final response"
    )
}
let ordered = finishReason == .toolCalls ? try completeToolValues() : []
```

Keep JSON completeness checking in one helper used both when tool-call completion events are emitted and when the terminal batch is formed.

- [x] **Step 4: Run GREEN and shared codec regressions**

```bash
swift test --package-path toolkit --filter DeepSeekAdapterTests
swift test --package-path toolkit --filter GLMAdapterTests
git diff --check
```

Expected: both adapter suites pass; no conflicting stream publishes `generationCompleted`.

- [x] **Step 5: Commit**

```bash
git add toolkit/Sources/LocalAgentLLMCloud/OpenAIChatCompletionsCodec.swift \
  toolkit/Tests/LocalAgentLLMCloudTests/DeepSeekAdapterTests.swift \
  toolkit/Tests/LocalAgentLLMCloudTests/GLMAdapterTests.swift \
  toolkit/Tests/LocalAgentLLMCloudTests/Fixtures/deepseek
git commit -m "fix: reject conflicting chat terminal states"
```

---

### Task 4: Move Discovery and Validation Wire Semantics to Adapters

**Files:**
- Create: `toolkit/Sources/LocalAgentLLMCloud/ProviderProbeWireEncoder.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCloud/CloudProviderAdapter.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCloud/OpenAIResponsesAdapter.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCloud/XAIAdapter.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCloud/AnthropicMessagesAdapter.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCloud/MiniMaxAdapter.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCloud/GeminiInteractionsAdapter.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCloud/DeepSeekAdapter.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCloud/GLMAdapter.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCloud/CloudModelDiscoveryService.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCloud/ProviderValidationService.swift`
- Modify: `toolkit/Tests/LocalAgentLLMCloudTests/ProviderValidationServiceTests.swift`
- Modify: `toolkit/Tests/LocalAgentLLMCloudTests/CloudModelDiscoveryTests.swift`

**Interfaces:**
- Adds three requirements to `CloudProviderAdapter`: `makeDiscoveryRequest()`, `makeAccountValidationRequest()`, and `makeModelValidationRequest(modelID:)`.
- `ProviderProbeWireEncoder` only builds fixed synthetic bodies; adapters explicitly select their exact family and headers.
- Removes `CloudModelDiscoveryService.discoveryWire(preset:)` and `ProviderValidationWireFactory`.

- [x] **Step 1: Write failing provider-owned-wire tests**

For all seven shipped adapters, require three no-user-data wires, no credential headers, and the expected request class. Add explicit Anthropic checks:

```swift
let adapter = AnthropicMessagesAdapter()
for wire in [
    try adapter.makeDiscoveryRequest(),
    try adapter.makeAccountValidationRequest(),
    try adapter.makeModelValidationRequest(modelID: "claude-fixture"),
] {
    #expect(wire.headers["anthropic-version"] == "2023-06-01")
    #expect(wire.headers["x-api-key"] == nil)
}
#expect(try MiniMaxAdapter().makeDiscoveryRequest()
    .headers["anthropic-version"] == nil)
```

Update the service integration assertion to inspect the actual three sealed requests and verify the version header survives egress sealing.

- [x] **Step 2: Run RED**

```bash
swift test --package-path toolkit --filter ProviderValidationServiceTests.everyShippedAdapterOwnsItsProbeWire
swift test --package-path toolkit --filter ProviderValidationServiceTests.anthropicValidationCarriesRequiredVersionHeader
swift test --package-path toolkit --filter CloudModelDiscoveryTests.anthropicDiscoveryCarriesRequiredVersionHeader
```

Expected: adapter methods do not exist and current Anthropic discovery/validation headers lack `anthropic-version`.

- [x] **Step 3: Add adapter-owned probe methods and remove generic guessing**

Extend the protocol:

```swift
package protocol CloudProviderAdapter: Sendable {
    var adapterID: String { get }
    var adapterVersion: String { get }
    var presetID: ProviderPresetID { get }
    func makeDiscoveryRequest() throws -> CloudWireRequest
    func makeAccountValidationRequest() throws -> CloudWireRequest
    func makeModelValidationRequest(modelID: String) throws -> CloudWireRequest
    func makeSession(_ context: CloudProviderSessionContext) throws -> any CloudProviderSession
}
```

`ProviderProbeWireEncoder` has distinct functions for Responses, Anthropic, MiniMax, Gemini, and Chat families. Every adapter implements all three protocol methods and chooses one exact helper. The Anthropic helper always adds `anthropic-version: 2023-06-01`; the MiniMax helper does not.

`ProviderValidationService.performValidation` calls the selected adapter for all request construction. `CloudModelDiscoveryService` retains only response decoding/merge logic. Delete `ProviderValidationWireFactory` after all call sites move.

- [x] **Step 4: Run GREEN and provider regressions**

```bash
swift test --package-path toolkit --filter ProviderValidationServiceTests
swift test --package-path toolkit --filter CloudModelDiscoveryTests
swift test --package-path toolkit --filter CloudProviderBoundaryTests
git diff --check
```

Expected: all seven adapters provide exact probe wires; Anthropic requests carry the version header; boundary lint sees no credential material.

- [x] **Step 5: Commit**

```bash
git add toolkit/Sources/LocalAgentLLMCloud toolkit/Tests/LocalAgentLLMCloudTests/ProviderValidationServiceTests.swift \
  toolkit/Tests/LocalAgentLLMCloudTests/CloudModelDiscoveryTests.swift
git commit -m "refactor: let cloud adapters own validation wire"
```

---

### Task 5: Make Manual Validation Evidence First-Class

**Files:**
- Modify: `toolkit/Sources/LocalAgentLLMCloud/ProviderProfile.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCloud/ProviderValidationService.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCloud/CloudCapabilityCatalog.swift`
- Modify: `toolkit/Tests/LocalAgentLLMCloudTests/ProviderValidationServiceTests.swift`
- Modify: `toolkit/Tests/LocalAgentLLMCloudTests/CloudCapabilityCatalogTests.swift`

**Interfaces:**
- Changes `ProviderValidationEvidenceIdentity.catalogRevision` to `UInt64?`.
- `currentValidation` accepts either exact catalog-backed evidence or exact conservative manual evidence.
- Catalog acceptance invalidates only catalog-backed validation rows.

- [x] **Step 1: Write failing manual evidence and selective invalidation tests**

Validate `manual-openai-model`, which is absent from the signed fixture catalog. Require:

```swift
#expect(result.subject.catalogRevision == nil)
#expect(result.subject.modelRevision == nil)
#expect(result.snapshot.support(for: "text_generation") == .supported)
#expect(result.snapshot.support(for: "streaming") == .supported)
#expect(result.snapshot.support(for: "tool_calling") == .unknown)
```

Call `currentValidation` for an exact target and require success. Accept catalog revision 2 and require the manual evidence still succeeds with the same evidence identity, while the existing catalog-backed test still becomes `cloud_catalog.revision_changed` and loses its rows.

- [x] **Step 2: Run RED**

```bash
swift test --package-path toolkit --filter ProviderValidationServiceTests.manualModelValidationIsCurrentAndConservative
swift test --package-path toolkit --filter ProviderValidationServiceTests.catalogAdvancePreservesManualEvidenceWithoutPromotion
swift test --package-path toolkit --filter ProviderValidationServiceTests.catalogAdvanceAtomicallyInvalidatesPublishedEvidence
```

Expected: manual evidence is stored with catalog revision `1` or `0`, `currentValidation` rejects it, or catalog advance deletes its rows.

- [x] **Step 3: Implement optional evidence identity and two current-validation branches**

Use the actual source when constructing the subject:

```swift
catalogRevision: entry == nil ? nil : catalog.catalogRevision
```

Publish the optional revision without a sentinel. In `currentValidation`, validate common profile/origin/credential/adapter/model/retention/expiry fields first, then branch:

```swift
if let revision = evidence.catalogRevision {
    guard let catalog = try await catalogStore.current(),
          catalog.catalogRevision == revision,
          let entry = catalog.entry(presetID: profile.revision.presetID, modelID: modelID),
          !catalog.isRevoked(entry.identity),
          entry.supports(adapterVersion: adapterVersion),
          entry.adapterID == evidence.adapterID else { throw currentUnavailable() }
} else {
    guard validation.subject.catalogRevision == nil,
          validation.subject.modelRevision == nil else { throw currentUnavailable() }
}
```

Build the target-bound exact subject from the persisted validation subject, not the current catalog. During catalog acceptance, select only states with non-null catalog revision, invalidate each by CAS, and delete observations/validation rows for that exact profile revision and evidence model ID inside the same transaction. Remove the global table-wide deletes.

- [x] **Step 4: Run GREEN and persistence regressions**

```bash
swift test --package-path toolkit --filter ProviderValidationServiceTests
swift test --package-path toolkit --filter CloudCapabilityCatalogTests
swift test --package-path toolkit --filter LLMStoreSchemaV2Tests
git diff --check
```

Expected: manual evidence stays conservative/current across catalog advance; catalog-backed evidence remains atomically invalidated; old numeric JSON remains decodable.

- [x] **Step 5: Commit**

```bash
git add toolkit/Sources/LocalAgentLLMCloud/ProviderProfile.swift \
  toolkit/Sources/LocalAgentLLMCloud/ProviderValidationService.swift \
  toolkit/Sources/LocalAgentLLMCloud/CloudCapabilityCatalog.swift \
  toolkit/Tests/LocalAgentLLMCloudTests/ProviderValidationServiceTests.swift \
  toolkit/Tests/LocalAgentLLMCloudTests/CloudCapabilityCatalogTests.swift
git commit -m "fix: preserve conservative manual model validation"
```

---

### Task 6: Route Manual Models Without Catalog Parameters

**Files:**
- Modify: `toolkit/Sources/LocalAgentLLMCloud/CloudGenerationConfigurationResolver.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCloud/CloudLLMRuntime.swift`
- Modify: `toolkit/Tests/LocalAgentLLMCloudTests/CloudGenerationConfigurationResolverTests.swift`
- Modify: `toolkit/Tests/LocalAgentLLMCloudTests/CloudLLMRuntimeTests.swift`
- Modify: `toolkit/Tests/LocalAgentLLMCloudTests/CloudProductPathIntegrationTests.swift`

**Interfaces:**
- Produces `CloudModelRouteSource.catalog(CloudModelCatalogEntry)` and `.manual(adapterID:modelID:)` inside the cloud target.
- Produces `CloudGenerationConfigurationResolver.resolveManual(adapterID:modelID:targetDefaults:hostOverrides:)`.
- Manual runtime routes require stateless retention and empty target/host parameter configuration.

- [x] **Step 1: Write failing manual resolver and runtime tests**

Resolver tests require an empty manual resolution with a stable digest and reject each non-empty parameter source with `cloud_parameters.manual_parameter_unsupported`.

Runtime integration validates an unknown OpenAI model, creates an exact target with empty parameters, prepares it with the already-supported canonical empty tool array, streams final text, and closes normally. Separate tests require preparation failure for a real tool schema, non-empty target defaults, non-empty host overrides, and provider-state-approved retention. Task 7 owns the distinct `{ "tools": [] }` object-shape regression so Task 6 does not pre-implement its parser change.

- [x] **Step 2: Run RED**

```bash
swift test --package-path toolkit --filter CloudGenerationConfigurationResolverTests.manualRouteAllowsOnlyEmptyParameters
swift test --package-path toolkit --filter CloudLLMRuntimeTests.probedManualModelRunsOnlyConservativeStatelessText
swift test --package-path toolkit --filter CloudProductPathIntegrationTests.manualModelCompletesRoutineTextPath
```

Expected: `requireRoute` rejects the model because it has no catalog entry and the resolver has no manual source.

- [x] **Step 3: Add explicit route source and manual resolution**

Represent source identity explicitly:

```swift
package enum CloudModelRouteSource: Equatable, Sendable {
    case catalog(CloudModelCatalogEntry)
    case manual(adapterID: String, modelID: String)
}
```

`requireRoute` chooses `.catalog` only when evidence contains the exact current catalog revision and entry; nil catalog evidence chooses `.manual` only when retention is `.statelessRequired` and model revision is nil. It never looks up a later catalog entry to promote manual evidence.

Manual resolution requires both configurations to be empty and hashes this canonical document in `resolved-parameters:v1`:

```swift
try .object(entries: [
    .init(name: "schema_version", value: .string("1")),
    .init(name: "adapter_id", value: .string(adapterID)),
    .init(name: "model_id", value: .string(modelID)),
    .init(name: "model_revision", value: .null),
    .init(name: "route_source", value: .string("manual")),
    .init(name: "semantic", value: try .object(entries: [])),
    .init(name: "provider_fields", value: try .object(entries: [])),
])
```

Use the route source consistently during preparation, post-approval route recheck, start/resume recheck, and resolved-parameter comparison.

- [x] **Step 4: Run GREEN and runtime regressions**

```bash
swift test --package-path toolkit --filter CloudGenerationConfigurationResolverTests
swift test --package-path toolkit --filter CloudLLMRuntimeTests
swift test --package-path toolkit --filter CloudProductPathIntegrationTests
git diff --check
```

Expected: manual routine text runs; tools, parameters, stateful retention, and silent catalog promotion remain rejected.

- [x] **Step 5: Commit**

```bash
git add toolkit/Sources/LocalAgentLLMCloud/CloudGenerationConfigurationResolver.swift \
  toolkit/Sources/LocalAgentLLMCloud/CloudLLMRuntime.swift \
  toolkit/Tests/LocalAgentLLMCloudTests/CloudGenerationConfigurationResolverTests.swift \
  toolkit/Tests/LocalAgentLLMCloudTests/CloudLLMRuntimeTests.swift \
  toolkit/Tests/LocalAgentLLMCloudTests/CloudProductPathIntegrationTests.swift
git commit -m "feat: run conservative manual cloud models"
```

---

### Task 7: Require Streaming and Parse Tool Schemas Exactly

**Files:**
- Modify: `toolkit/Tests/LocalAgentLLMCloudTests/CloudLLMRuntimeTests.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCloud/CloudLLMRuntime.swift`

**Interfaces:**
- Produces `CloudRuntimeCapabilityGate.requestedToolCount(in:) throws -> Int`.
- `requireCapabilities` requires text generation plus streaming for every route.

- [x] **Step 1: Write failing capability-gate matrix tests**

Exercise these schemas against a snapshot with text/streaming supported and tool calling unknown:

```swift
[
    .array([]),
    try .object(entries: []),
    try .object(entries: [.init(name: "tools", value: .array([]))]),
]
```

All three must pass. Non-empty array and non-empty `tools` array must require tool calling. A string-valued `tools` member and an unrelated non-empty object must fail with `runtime.cloud_tool_schema_invalid`. A snapshot with text supported but streaming unknown must fail with `runtime.cloud_capability_unsatisfied`.

- [x] **Step 2: Run RED**

```bash
swift test --package-path toolkit --filter CloudLLMRuntimeTests.emptyToolsObjectDoesNotRequireToolCalling
swift test --package-path toolkit --filter CloudLLMRuntimeTests.malformedToolSchemaFailsClosed
swift test --package-path toolkit --filter CloudLLMRuntimeTests.streamingIsRequiredForEveryCloudGeneration
```

Expected: `{ "tools": [] }` is treated as a tool request, malformed objects are guessed rather than rejected, and missing streaming support passes.

- [x] **Step 3: Implement exact provider-neutral parsing**

```swift
package static func requestedToolCount(in schema: CanonicalJSONValue) throws -> Int {
    switch schema {
    case let .array(values):
        return values.count
    case .object:
        let keys = schema.objectKeys ?? []
        if keys.isEmpty { return 0 }
        guard keys == Set(["tools"]),
              case let .array(values)? = schema.objectValue(forKey: "tools") else {
            throw cloudRuntimeFailure(
                "runtime.cloud_tool_schema_invalid",
                "canonical tool schema has an unsupported shape"
            )
        }
        return values.count
    default:
        throw cloudRuntimeFailure(
            "runtime.cloud_tool_schema_invalid",
            "canonical tool schema has an unsupported shape"
        )
    }
}
```

Check `snapshot.support(for: "streaming") == .supported` beside text generation, then require tool calling only when the returned count is greater than zero.

- [x] **Step 4: Run GREEN**

```bash
swift test --package-path toolkit --filter CloudLLMRuntimeTests
git diff --check
```

Expected: the complete capability-gate matrix passes.

- [x] **Step 5: Commit**

```bash
git add toolkit/Sources/LocalAgentLLMCloud/CloudLLMRuntime.swift \
  toolkit/Tests/LocalAgentLLMCloudTests/CloudLLMRuntimeTests.swift
git commit -m "fix: enforce cloud streaming and exact tool schemas"
```

---

### Task 8: Lock the Hardening Contract and Run the Unified Gate

**Files:**
- Modify: `docs/superpowers/specs/2026-07-10-swift-llm-system-design.md`
- Modify: `docs/model-providers/cloud-provider-adapter-architecture.md`
- Modify: `docs/superpowers/plans/2026-07-22-swift-llm-phase-3-hardening-implementation.md`
- Test: `scripts/run-llm-phase-3-contracts.sh`

**Interfaces:**
- Records the Phase 3.1 evidence and preserves the Phase 4 durable event/command handoff boundary.
- Produces one clean unified verification result from the existing runner.

- [x] **Step 1: Add the dated hardening evidence to maintained design docs**

Document the stable errors, exact Responses continuation, adapter-owned probe wire, optional manual catalog identity, selective invalidation, stateless manual route, streaming gate, and remaining Phase 4 delivery-ack limitation. Do not claim durable delivery from `AsyncThrowingStream`.

- [x] **Step 2: Self-review the implementation plan and mark completed checkboxes**

Run:

```bash
rg -n "T[B]D|T[O]DO|implement l[a]ter|fill [i]n|similar to T[a]sk|appropriate error handl[i]ng" \
  docs/superpowers/plans/2026-07-22-swift-llm-phase-3-hardening-implementation.md
git diff --check
```

Expected: no placeholder phrase and no whitespace error. Confirm every approved design requirement maps to Tasks 1–7 and all named interfaces match the implementation.

- [x] **Step 3: Run the unified verification gate**

```bash
scripts/run-llm-phase-3-contracts.sh
git diff --check
git status --short
```

Expected: Phase 1/2 regressions, Rust/C++ architecture lint, all Swift tests, and the Simulator Keychain contract pass without a live provider key or network request.

Recorded 2026-07-22 evidence: the Phase 2 local-product runner passed; all four Phase 3 Rust architecture-lint tests passed; the complete Swift package reported 403 passing tests in 72 suites; and `CloudCredentialKeychainTests/generationAccountHasExactSecurityAttributes()` passed on an iPhone 17 Pro Simulator. The runner exited 0 with `LLM Phase 3 cloud product contracts passed`.

- [x] **Step 4: Commit documentation and final evidence**

```bash
git add docs/superpowers/specs/2026-07-10-swift-llm-system-design.md \
  docs/superpowers/specs/2026-07-22-swift-llm-phase-3-hardening-design.md \
  docs/superpowers/plans/2026-07-22-swift-llm-phase-3-hardening-implementation.md \
  docs/model-providers/cloud-provider-adapter-architecture.md
git commit -m "docs: record phase three cloud hardening"
```

- [x] **Step 5: Re-run after the final commit**

```bash
scripts/run-llm-phase-3-contracts.sh
git status --short
```

Expected: exit code 0 and an empty worktree.

## Completion Gate

Phase 3.1 is complete only when all eight tasks are checked and the unified runner passes from the committed worktree. Completion proves bounded handoff failures are visible, provider cancellation is once-only, tool continuations and terminals are exact, provider validation wire is adapter-owned, manual models remain conservative, and streaming/tool capability gates fail closed. It does not make `host_slot_v2` runnable and does not replace Phase 4 command acknowledgements or event receipts.
