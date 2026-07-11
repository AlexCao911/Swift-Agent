# Plan 10: LLM Provider Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the replaceable LLM provider management layer, then connect
Desktop MiniCPM as a desktop-only validation provider behind that layer.

**Architecture:** Plan 10 has two intentionally separate parts. The provider
management layer is platform-neutral: provider profiles, registry, provider
selection, provider/tokenizer bundle switching, tokenizer-aware context
fitting, cancellation, prompt debug capture, provider-setting persistence, and
the Swift `ProviderControllingRuntimeClient` capability. Desktop MiniCPM is a
desktop-only adapter behind that contract for development and validation. It
must not define the mobile runtime path. The mobile production path is a
separate `OnDeviceMiniCPMProvider` that reuses the Plan 10 provider contract
and connects to the Plan 11 C ABI / C++ / Metal / Core ML / llama.cpp backend.

**Tech Stack:** Rust 2021, existing `ModelProvider`, existing
`TokenizerAdapter`, existing `PromptFrame`, `serde_json`, cargo tests, Swift
tests, TDD. Localhost HTTP transport is desktop-adapter-only and must stay out
of the platform-neutral provider management layer.

---

## Current Code Audit

Existing provider state:

- `ModelProvider` has `id()` and synchronous `stream_chat(&PromptFrame)`.
- `AgentRuntimeConfig` owns one provider and one tokenizer.
- `MockStreamingProvider` is the only implemented provider.
- `ProviderChanged` exists as an event kind but provider switching does not yet
  exist.
- `ProviderSetting` exists as a key/value record, but `EventStore` has no
  provider-setting persistence methods.
- `TokenizerAdapter` has `count_prompt_frame`, but not per-text
  `count_text`.
- `ContextBudget` currently needs tokenizer-aware message counting before real
  provider token limits can be trusted.

## Ownership Boundary

Plan 10A owns the platform-neutral provider management layer:

- provider profile DTOs and runtime provider registry;
- provider-generation cancellation semantics;
- provider selection in Rust runtime;
- tokenizer swap with provider swap;
- runtime prompt snapshot capture around provider calls;
- provider list and `setProvider` bridge capability.

Plan 10B owns only the desktop development adapter:

- `DesktopMiniCPMProvider`;
- OpenAI-compatible local endpoint adapter;
- deadlock-safe localhost HTTP transport;
- desktop endpoint settings, ports, paths, and model service assumptions.

Plan 10 does not own the mobile inference backend:

- C++/Metal/llama.cpp inference internals;
- `OnDeviceMiniCPMProvider` backend execution beyond the provider contract
  shape; Plan 11 supplies the C ABI/backend primitive;
- Swift native tools;
- SwiftUI provider picker layout;
- app bootstrap composition.

Final provider shape:

```text
Rust Runtime
  -> ProviderRegistry
      -> MockProvider
      -> DesktopMiniCPMProvider        // desktop/dev validation only
      -> OnDeviceMiniCPMProvider       // mobile production path
            -> Plan 11 C ABI
            -> C++ / Metal / Core ML / llama.cpp backend
```

## Integration Points

- Plan 8 supplies the base bridge client. Plan 10 adds a separate
  `ProviderControllingRuntimeClient` capability rather than changing the base
  `RuntimeClient` contract.
- Plan 11 supplies an on-device inference backend primitive that sits behind the
  provider abstraction and uses Plan 10 cancellation semantics.
- Plan 12 renders provider choices and depends on
  `ProviderControllingRuntimeClient`; it does not mutate provider state locally.

## Provider Control Contract

Plan 10 adds this capability protocol on the Swift side:

```swift
public protocol ProviderControllingRuntimeClient: Sendable {
    func providerProfiles() async throws -> [ProviderProfileDTO]
    func activeProvider() async throws -> ProviderProfileDTO
    func setProvider(sessionId: String, providerId: String) async throws -> RuntimeEventDTO
}
```

`RustRuntimeClient` should conform to both `RuntimeClient` and
`ProviderControllingRuntimeClient`. `MockRuntimeClient` may conform for tests,
but UI code must require this capability explicitly.

`setProvider(sessionId, providerId)` must reject provider changes while the
session has an active or suspended run that may continue generation. The Rust
bridge should return a structured error such as
`provider_switch_blocked(active_run_id)` instead of swapping the provider under
an in-flight turn. Plan 12 can disable the selector during active runs, but the
runtime owns the safety check.

## Tokenizer Contract

Plan 10 extends the tokenizer contract explicitly:

```rust
pub trait TokenizerAdapter: Send + Sync {
    fn provider_id(&self) -> &str;
    fn max_context_tokens(&self) -> usize;
    fn safety_margin_tokens(&self) -> usize;
    fn count_text(&self, text: &str) -> usize;
    fn count_prompt_frame(&self, frame: &PromptFrame) -> usize;
    fn boxed_clone(&self) -> Box<dyn TokenizerAdapter>;
}
```

`ContextBudget` should call `count_text` when fitting individual messages and
`count_prompt_frame` when validating the assembled prompt. `MockTokenizer`
should keep its current whitespace behavior by implementing `count_text` with
`split_whitespace().count()`.

## Provider Settings Persistence Contract

Plan 10 must add provider settings to the store trait rather than treating
persistence as optional:

```rust
pub trait EventStore {
    fn save_provider_setting(&mut self, setting: ProviderSetting) -> Result<(), AgentError>;
    fn load_provider_setting(&self, key: &str) -> Result<Option<ProviderSetting>, AgentError>;
}
```

The active provider key should be deterministic:

```text
active_provider:<session_id>
```

`InMemoryEventStore` and `SqliteEventStore` must both implement these methods.
`AgentRuntime::set_provider` writes the setting after a successful provider swap,
and runtime startup/restore should load the setting before defaulting to the
mock provider.

## Cancellation Contract

Plan 10 must make cancellation a provider-layer concept. The current
`ModelProvider::stream_chat` shape is synchronous; that is acceptable for the
mock provider, but real providers need a cancel path.

Provider hardening must use a `CancellationToken` backed by `Arc<AtomicBool>`:

```rust
#[derive(Clone, Default)]
pub struct CancellationToken {
    inner: Arc<AtomicBool>,
}

impl CancellationToken {
    pub fn cancel(&self) {
        self.inner.store(true, Ordering::SeqCst);
    }

    pub fn is_cancelled(&self) -> bool {
        self.inner.load(Ordering::SeqCst)
    }
}

pub trait ModelProvider: Send + Sync {
    fn id(&self) -> &str;
    fn stream_chat(
        &self,
        frame: &PromptFrame,
        cancellation: CancellationToken,
    ) -> Result<Vec<ModelProviderOutput>, AgentError>;
}
```

Required behavior:

- `AgentRuntime::cancel(run_id)` records `RunCancelled` and signals the active
  provider generation for that run.
- The runtime owns a `run_id -> CancellationToken` map for in-flight provider
  calls and removes tokens when a run completes, suspends, fails, or is
  cancelled.
- Desktop MiniCPM checks cancellation between transport reads and before
  returning provider outputs.
- Plan 11 C++ backend cancel is only a backend primitive until connected through
  this provider cancellation path.

## Prompt Debug Ownership

Prompt debug snapshots are runtime/provider observability, not bridge behavior.
Plan 10 owns capturing the latest `PromptDebugSnapshot` whenever the runtime
builds a frame for a provider call. Plan 8 only transports the DTO/API, and
Plan 12 only renders the snapshot if one exists.

## File Structure

Create:

```text
local-ios-agent/rust-core/src/core/provider_profile.rs
local-ios-agent/rust-core/src/core/provider_registry.rs
local-ios-agent/rust-core/src/core/openai_chat.rs
local-ios-agent/rust-core/src/core/desktop_minicpm.rs
local-ios-agent/rust-core/tests/provider_registry.rs
local-ios-agent/rust-core/tests/runtime_provider_selection.rs
local-ios-agent/rust-core/tests/openai_chat_adapter.rs
local-ios-agent/rust-core/tests/desktop_minicpm_provider.rs
local-ios-agent/docs/model-providers/desktop-minicpm.md
```

Modify:

```text
local-ios-agent/rust-core/src/context/budget.rs
local-ios-agent/rust-core/src/context/tokenizer.rs
local-ios-agent/rust-core/src/context/prompt_frame.rs
local-ios-agent/rust-core/src/core/mod.rs
local-ios-agent/rust-core/src/core/runtime.rs
local-ios-agent/rust-core/src/memory/event_store.rs
local-ios-agent/rust-core/src/memory/sqlite.rs
local-ios-agent/rust-core/src/ffi_bridge.rs
local-ios-agent/ios-app/Sources/LocalAgentBridge/RuntimeClient.swift
local-ios-agent/ios-app/Sources/LocalAgentBridge/RustRuntimeClient.swift
```

## Milestone 10A: Provider Contract Hardening

### Task 1: Make Context Budget Provider-Tokenizer Aware

- [ ] Add `count_text(&self, text: &str) -> usize` to `TokenizerAdapter`.
- [ ] Make `ContextBudget` accept a token-counting function.
- [ ] Keep existing mock-token behavior stable.
- [ ] Add regression tests proving message fitting uses tokenizer counts rather
  than plain word counts.

### Task 2: Add Provider Profiles and Registry

- [ ] Add `ProviderKind`, `ProviderProfile`, and `ProviderBundle`.
- [ ] Add provider factories so selection can construct a provider and tokenizer
  together.
- [ ] Add duplicate-profile rejection and sorted profile listing tests.

### Task 3: Add Provider Cancellation Contract

- [ ] Add `CancellationToken` backed by `Arc<AtomicBool>` to runtime/provider
  calls.
- [ ] Make runtime cancellation signal the provider generation for the matching
  run.
- [ ] Keep mock provider behavior deterministic.
- [ ] Add tests proving `cancel(run_id)` signals provider cancellation before or
  while appending `RunCancelled`.

### Task 4: Capture Prompt Debug Snapshots

- [ ] Capture the latest prompt frame snapshot at provider-call boundaries.
- [ ] Expose the captured snapshot through the bridge API defined in Plan 8.
- [ ] Return `nil` when no provider call has occurred.
- [ ] Add tests proving a sent message produces a readable prompt debug
  snapshot.

### Task 5: Wire Provider Selection Into Runtime

- [ ] Add runtime APIs for provider profiles, active provider, and set provider.
- [ ] Replace provider and tokenizer atomically.
- [ ] Add `save_provider_setting` and `load_provider_setting` to `EventStore`.
- [ ] Persist active provider through `ProviderSetting` using the
  `active_provider:<session_id>` key.
- [ ] Reject `set_provider` when the target session has an active or suspended
  run.
- [ ] Append `ProviderChanged` when selection changes.
- [ ] Expose provider methods through `ProviderControllingRuntimeClient`.

### Milestone 10A Verification Checkpoint

Run this checkpoint before starting any desktop-only provider adapter work in
Milestone 10B:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo test --test provider_registry
cargo test --test runtime_provider_selection
cargo test
```

Expected coverage:

- tokenizer-aware message fitting uses `TokenizerAdapter::count_text`;
- mock provider calls receive a `CancellationToken`;
- `cancel(run_id)` flips the matching token and records `RunCancelled`;
- prompt debug snapshot is captured after a mock provider call;
- active provider persists through `EventStore` provider-setting methods;
- `set_provider` rejects active/suspended runs and emits `ProviderChanged` only
  after a successful swap.

## Milestone 10B: Desktop MiniCPM Provider (Desktop-Only Adapter)

Milestone 10B must stay isolated from the platform-neutral provider management
layer. It may depend on localhost HTTP, an OpenAI-compatible desktop server, a
desktop model process, desktop paths/ports, and `Content-Length` socket
transport. None of those assumptions may be required by `ModelProvider`,
`ProviderRegistry`, `ProviderControllingRuntimeClient`, or
`OnDeviceMiniCPMProvider`.

### Task 6: Add Desktop MiniCPM Provider

- [ ] Add OpenAI-compatible chat request adapter.
- [ ] Add response parser for text completion.
- [ ] Add `DesktopMiniCPMProvider`.
- [ ] Keep this provider text-first for MVP.
- [ ] Leave image/multimodal payload adaptation for later provider evolution.

### Task 7: Add Safe Localhost HTTP Transport

- [ ] Accept only localhost HTTP endpoints.
- [ ] Parse request and response headers using `Content-Length`.
- [ ] Avoid socket deadlock by not waiting for EOF on both sides.
- [ ] Add a local server test that would hang with naive `read_to_string`.
- [ ] Add Desktop MiniCPM runbook.

## Verification

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo test
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/ios-app
swift test
```

## Self-Review

- Plan 10 is about LLM providers, not UI.
- Plan 10A provider management is platform-neutral and reusable by both desktop
  and mobile providers.
- Plan 10B Desktop MiniCPM is a desktop/dev validation adapter only; it must
  not become the phone runtime path.
- The phone runtime path is `OnDeviceMiniCPMProvider` behind the same provider
  contract, connected through Plan 11's C ABI/backend boundary.
- Provider selection is included only because provider choice must affect Rust
  runtime provider/tokenizer state.
- Provider cancellation is included because real provider generation must be
  interruptible from runtime cancel.
- Prompt debug capture is included because it is observed at provider-call
  boundaries.
- C++ inference backend remains Plan 11.
