# Task 5 OAuth and Rebind Fix Round 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore the exact donor OAuth protocols and make active-model rebinds, credential lifecycle changes, browser login, and startup projection recoverable and truthful.

**Architecture:** `LocalAgentLLMCloud` remains the only provider/network/credential owner, but dispatches through explicit provider protocol descriptors instead of flattening every OAuth provider into a generic exchange. Rust is the authoritative active cross-link owner, while `LLMStore` persists a rebind saga before Rust mutation and reconciles the Swift group from the Rust-confirmed operation after relaunch. Shipping bootstrap derives the active-model label from durable model state; the signed LocalAgent catalog remains canonical.

**Tech Stack:** Swift 6, Swift Testing/XCTest, Security Keychain, Network.framework, SQLite, Rust, C FFI, Xcode iOS Simulator.

## Global Constraints

- Strict test-first red/green/refactor for every behavior change.
- Preserve all existing valid API-key, OAuth refresh, model picker, and host-run behavior.
- OAuth tokens may only be injected into exact provider-owned origins.
- No provider networking may move into migrated OpenMinis presentation code.
- No staging or commits.

---

### Task 1: Exact provider OAuth protocols and runtime routes

**Files:**
- Modify: `toolkit/Sources/LocalAgentLLMCloud/OAuthHTTPClient.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCloud/ProviderPreset.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCloud/ProviderProductMapping.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCloud/CloudHTTPTransport.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCloud/ProviderValidationService.swift`
- Test: `toolkit/Tests/LocalAgentLLMCloudTests/OAuthHTTPClientTests.swift`
- Test: `toolkit/Tests/LocalAgentLLMCloudTests/CloudHTTPTransportTests.swift`
- Test: `toolkit/Tests/LocalAgentLLMCloudTests/CloudProductPathIntegrationTests.swift`
- Test: `toolkit/Tests/LocalAgentLLMCloudTests/OpenMinisProviderProductMappingTests.swift`

**Interfaces:**
- Produces: provider-specific authorization and token request descriptors, preserved `id_token`/account identity, and executable runtime routing for each supported OAuth preset.
- Consumes: existing allowlisted `CloudHTTPTransport`, credential vault, validation lease, and single-flight refresh coordinator.

- [ ] Add literal request-shape tests for Anthropic state, xAI discovery/nonce/plan/referrer, OpenAI JSON exchange and Codex identity headers/route, Google, Kimi, and Antigravity.
- [ ] Run focused tests and verify failures identify the flattened protocol behavior.
- [ ] Add the minimum provider-specific protocol descriptors and one shared internal token-request primitive.
- [ ] Route OpenAI Responses OAuth to `chatgpt.com/backend-api/codex/responses`; retain API-key routing for `api.openai.com`.
- [ ] Remove OAuth capability from OpenAI Chat Completions.
- [ ] Run provider protocol, transport, mapping, validation, and generation tests green.

### Task 2: OAuth origin binding, credential transitions, and browser lifecycle

**Files:**
- Modify: `toolkit/Sources/LocalAgentLLMCloud/CloudLLMSubsystem.swift`
- Modify: `toolkit/Sources/LocalAgentLLMCloud/CloudHTTPTransport.swift`
- Modify: `apps/LocalAgentApp/LocalAgentApp/Presentation/Models/ProviderProfileEditorView.swift`
- Test: `toolkit/Tests/LocalAgentLLMCloudTests/CloudProductPathIntegrationTests.swift`
- Test: `apps/LocalAgentApp/LocalAgentAppTests/Presentation/Models/ProviderProfileEditorTests.swift`

**Interfaces:**
- Produces: exact-origin OAuth publication/execution guard, transition-time credential requirement, and a retained cancellable browser-login session.
- Consumes: provider OAuth protocol descriptors from Task 1.

- [ ] Add publish- and execution-layer tests that substituted OAuth origins fail before credential access while API-key custom origins remain supported.
- [ ] Add all preset/mode transition tests proving a newly supplied/authenticated credential is mandatory.
- [ ] Add callback-before-wait, duplicate-key, Safari dismissal, timeout, cancellation, and retry tests.
- [ ] Run focused tests red.
- [ ] Implement exact-origin guards, transition validation, callback buffering, duplicate-key rejection, and retained session/delegate cancellation.
- [ ] Run focused tests green.

### Task 3: Recoverable Rust/Swift rebind saga

**Files:**
- Modify: `rust-core/src/storage/agent_os_state/in_memory.rs`
- Modify: `rust-core/src/storage/agent_os_state/sqlite.rs`
- Modify: `rust-core/src/llm_contracts/host_binding_service.rs`
- Modify: `toolkit/Sources/LocalAgentLLMCore/LLMStore.swift`
- Modify: `apps/LocalAgentApp/LocalAgentApp/Runtime/AppLLMHostRouting.swift`
- Modify: `apps/LocalAgentApp/LocalAgentApp/Composition/AppBootstrapper.swift`
- Test: `rust-core/tests/contract/host_binding_saga.rs`
- Test: `rust-core/tests/integration/agent_os_state_sqlite.rs`
- Test: `toolkit/Tests/LocalAgentLLMCoreTests/LLMStoreTests.swift`
- Test: `apps/LocalAgentApp/LocalAgentAppTests/Integration/LLMProductBootstrapTests.swift`

**Interfaces:**
- Produces: durable `ModelRebindOperation` records with prepared, Rust-confirmed, Swift-swapped, and completed phases; relaunch reconciliation; one active Rust cross-link per profile/slot.
- Consumes: exact Swift binding group, Rust `profile_rebind` operation identity, and atomic Swift group swap.

- [ ] Add Rust tests proving replacement activation atomically supersedes the previous active link in memory and SQLite.
- [ ] Add Swift failure/crash/reopen tests before Rust commit, after Rust confirmation, after Swift swap, and after registry installation.
- [ ] Add an integration test using the real Rust gateway through rebind and run prepare/register/commit.
- [ ] Run focused tests red.
- [ ] Persist the intended replacement group and phase before Rust commit; make each phase idempotent.
- [ ] Reconcile Rust-confirmed/Swift-old state during bootstrap and finish registry installation from durable state.
- [ ] Run Rust, Swift store, and Xcode integration tests green.

### Task 4: Durable disconnect, startup projection, truthful resources, and secret boundary

**Files:**
- Modify: `toolkit/Sources/LocalAgentLLMCloud/ProviderCredentialStore.swift`
- Modify: `apps/LocalAgentApp/LocalAgentApp/Composition/AppContainer.swift`
- Modify: `apps/LocalAgentApp/LocalAgentApp/App/AppShellView.swift`
- Modify: `apps/LocalAgentApp/LocalAgentApp/ThirdParty/OpenMinis/Product/OpenMinisContentView.swift`
- Modify: `apps/LocalAgentApp/LocalAgentApp.xcodeproj/project.pbxproj`
- Delete: `apps/LocalAgentApp/LocalAgentApp/Resources/models-dev-api.json`
- Modify: `docs/openminis-migration-manifest.md`
- Test: `toolkit/Tests/LocalAgentLLMCloudTests/CloudProductPathIntegrationTests.swift`
- Test: `apps/LocalAgentApp/LocalAgentAppTests/Integration/LLMProductBootstrapTests.swift`
- Test: `apps/LocalAgentApp/LocalAgentAppTests/Integration/CloudCredentialKeychainTests.swift`
- Test: `apps/LocalAgentApp/LocalAgentAppTests/Architecture/ShippingTargetOwnershipTests.swift`

**Interfaces:**
- Produces: reconciled disconnect deletion while retaining profiles, bootstrap/active-agent label projection, signed-catalog-only shipping resources, and an actual credential-to-host-command secret boundary test.
- Consumes: existing credential deletion operations, Model Center snapshot, active Agent selection, and real host preparation composition.

- [ ] Add disconnect deletion failure/relaunch tests using durable deleting operations.
- [ ] Add bootstrap and active-Agent-change tests for active label restoration.
- [ ] Replace the miniature-resource membership test with a production behavior assertion that the signed LocalAgent catalog is canonical.
- [ ] Add an integration test storing a sentinel Keychain credential and exercising provider reservation through host command composition.
- [ ] Run focused tests red.
- [ ] Reuse the deletion reconciliation saga for disconnect, wire startup projection, remove the inert resource/membership/claim, and expose no secret-bearing DTO.
- [ ] Run focused tests green.

### Task 5: Regression verification and report

**Files:**
- Modify: `.superpowers/sdd/2026-07-29-localagent-openminis-capability-migration-rust-react-core-implementation/task-5-report.md`

**Interfaces:**
- Consumes: all completed behavior and tests from Tasks 1–4.
- Produces: exact round-2 RED/GREEN evidence and external-only limitations.

- [ ] Run all focused SwiftPM provider/core suites.
- [ ] Run Rust host-binding, preparation, and SQLite suites.
- [ ] Run focused Xcode provider/editor/bootstrap/runtime/resource/security suites.
- [ ] Run `git diff --check`.
- [ ] Append exact commands, counts, results, and external-only notes to the task report.
