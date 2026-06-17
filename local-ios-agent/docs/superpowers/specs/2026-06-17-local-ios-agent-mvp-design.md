# Local iOS Agent MVP Design

Date: 2026-06-17
Status: Draft for user review
Project path: `/Users/alexandercou/Projects/Alex-agent/local-ios-agent`

## 1. Purpose

This project builds a local-first iOS AI assistant inspired by Pi's minimal,
decoupled agent design. The first milestone is not a full production assistant.
The MVP proves that the system can support a Pi-like agent runtime on iOS while
keeping model inference, agent state, native device capabilities, and UI
separate.

The project uses four primary layers:

```text
C++ / Metal / llama.cpp = model inference
Rust Core Runtime      = agent loop, state, context, tools, policy, events
Swift Native Toolkit   = iOS APIs, permissions, App Intents, Shortcuts bridge
SwiftUI Frontend       = presentation and interaction
```

The MVP starts with a mock model provider, then adds a desktop MiniCPM-V-4.6
provider for simulator testing. True on-device model inference is designed as a
future provider behind the same runtime boundary.

## 2. MVP Scope

The MVP must prove three things.

First, the Rust runtime must be structurally capable of growing into a real
agent runtime. It must include an agent loop, event stream, session tree,
context assembly, tool-call orchestration, security policy hooks, provider
abstraction, and persistent event storage.

Second, model access must be replaceable. The first implementation supports:

- `MockStreamingProvider`, for stable runtime and UI tests.
- `DesktopMiniCPMProvider`, for iOS Simulator calls to a Mac-local
  MiniCPM-V-4.6 service through an OpenAI-compatible HTTP endpoint.
- `OnDeviceMiniCPMProvider`, as an interface boundary only in the MVP.

Third, Swift must remain the native capability layer, not the agent brain.
Swift owns iOS APIs, permissions, App Intents, Shortcuts, voice shortcut
bridging, and native tool executors. Rust owns the runtime semantics and decides
how tool results enter future model context.

## 3. Non-Goals

The MVP does not include:

- Built-in multi-agent collaboration.
- Built-in plan mode.
- Background always-on assistant behavior.
- Arbitrary cross-app control.
- Model self-download or dynamic executable code updates.
- True on-device MiniCPM inference on iPhone or iPad.
- A general plugin marketplace.
- Autonomous JS self-evolution as a default capability.

## 4. MVP Acceptance Criteria

The MVP is accepted when:

- The iOS Simulator can launch a SwiftUI app and send a text message.
- SwiftUI can subscribe to Rust runtime events and render streamed assistant
  output.
- Rust can create a session, append events, maintain an active leaf, and persist
  the session tree.
- The app can switch between `MockStreamingProvider` and
  `DesktopMiniCPMProvider`.
- The simulator can complete at least one real MiniCPM-V-4.6 text call through a
  Mac-local HTTP endpoint.
- At least one Swift native read tool and one confirmation-required write tool
  can be registered and invoked through the Rust runtime.
- A tool call completes the full lifecycle:
  model tool request, Rust parse and validate, Swift execution, Rust event
  persistence, tool result injection, model continuation, UI rendering.
- Tool calls are written to an audit log.
- A debug view or export can show the `PromptFrame` sent to the provider.

## 5. Overall Architecture

The system has four layers.

```text
SwiftUI Frontend
  -> Swift Native Toolkit
  -> Rust Core Runtime
  -> C++ / Metal / llama.cpp inference backend
```

During the MVP, the true inference backend is represented by two Rust model
providers:

```text
MockStreamingProvider
DesktopMiniCPMProvider -> Mac-local OpenAI-compatible HTTP endpoint
```

The future on-device provider will use:

```text
Rust OnDeviceMiniCPMProvider
  -> stable C ABI
  -> C++ / llama.cpp / GGUF / Metal
```

The C++ layer only exposes inference operations. It does not know about
sessions, tools, user permissions, memory, policy, SwiftUI, or iOS APIs.

## 6. Layer Responsibilities

### 6.1 C++ Inference Layer

Responsibilities:

- Load model artifacts.
- Accept prompt and multimodal input in the backend format.
- Produce streamed tokens or structured model events.
- Support cancellation and resource release.
- Manage inference memory, KV cache, Metal resources, and model lifecycle.

Non-responsibilities:

- Agent loop.
- Session tree.
- Tool schemas.
- iOS permissions.
- Long-term memory.
- UI state.

The future C ABI should remain minimal:

```text
backend_init
backend_load_model
backend_stream_chat
backend_cancel
backend_release
```

### 6.2 Rust Core Runtime

Responsibilities:

- Run the agent loop.
- Maintain event-sourced session state.
- Maintain the session tree and active branch.
- Assemble each model `PromptFrame`.
- Manage model provider abstraction.
- Parse and route tool calls.
- Apply security and approval policy.
- Persist tool lifecycle and audit events.
- Stream typed runtime events to Swift.

Rust does not call iOS APIs directly. It orchestrates Swift tools.

### 6.3 Swift Native Toolkit

Responsibilities:

- Implement native iOS tools.
- Request and check system permissions.
- Call EventKit, Reminders, Photos, Files, App Intents, Shortcuts, and
  `INVoiceShortcutCenter`.
- Present native approval UI when Rust requests user confirmation.
- Return structured `ToolResult` objects to Rust.

Swift Native Toolkit does not assemble LLM prompts and does not own the session
tree.

### 6.4 SwiftUI Frontend

Responsibilities:

- Chat UI.
- Provider selector.
- Session list.
- Basic branch indicator.
- Tool approval sheets.
- Tool and audit expandable rows.
- Debug `PromptFrame` viewer.
- Settings for endpoint, provider, model id, and runtime configuration.

SwiftUI is a projection of runtime state. It should not be the source of truth
for agent state.

## 7. Rust Runtime Module Layout

The Rust runtime is organized into six top-level modules.

```text
rust-core/
  src/
    core/
    memory/
    context/
    security/
    tool/
    utils/
```

### 7.1 `core`

The `core` module is the runtime kernel.

Responsibilities:

- `AgentRuntime`
- Agent loop
- Run lifecycle
- Session state machine
- Event stream
- Session tree
- Stream management
- Run suspension and resumption
- Cancellation
- Provider selection
- Runtime errors

Representative types:

```text
AgentRuntime
RunManager
RunId
EventBus
RuntimeEvent
StreamBatcher
SuspendedRun
ApprovalWaiter
SessionTree
SessionId
EntryId
BranchCursor
ProviderRegistry
AgentError
```

The `core` module may call `context`, `tool`, `security`, and `memory`, but those
modules should not own the agent loop.

### 7.2 `memory`

The `memory` module owns persistence and long-term memory expansion points.

MVP responsibilities:

- SQLite event store.
- Blob metadata store.
- Audit log persistence.
- Session metadata persistence.
- Provider settings persistence.

Future responsibilities:

- Long-term user memory.
- Memory extraction candidates.
- User-confirmed memory writes.
- Vector or hybrid retrieval.
- SQLCipher or encrypted stores.

Representative types:

```text
EventStore
SQLiteStore
BlobStore
AuditStore
MemoryCandidate
MemoryRetention
```

In the MVP, long-term memory is mostly a reserved boundary. The important part
is that persistence is not mixed into `core` logic.

### 7.3 `context`

The `context` module owns all prompt and model-context construction.

Responsibilities:

- Build each `PromptFrame`.
- Select the active branch path.
- Inject system prompt, runtime policy, tool schemas, recent messages,
  attachments, and pending tool results.
- Estimate context size through the active provider tokenizer contract.
- Apply token budget rules.
- Cache reusable prompt fragments.
- Prepare provider-specific message formats.
- Preserve debug visibility into the final provider request.

Representative types:

```text
PromptFrame
PromptBuilder
ContextController
ContextBudget
ContextCache
ContextInjectionPolicy
TokenizerAdapter
ProviderPromptAdapter
```

The `context` module decides what the model sees. It does not execute tools and
does not mutate native iOS state.

### 7.4 `security`

The `security` module owns authorization, policy, and privacy boundaries.

Responsibilities:

- Tool risk classification.
- Approval requirements.
- Permission state modeling.
- Capability lease tracking.
- Sensitivity classification.
- Prompt-injection guardrails for tool results.
- Retention rules for private data.

Representative types:

```text
PolicyEngine
ApprovalRequest
ApprovalDecision
CapabilityLease
RiskLevel
Sensitivity
RetentionPolicy
SecurityDecision
```

The `security` module does not show UI. If user confirmation is needed, Rust
emits an approval request and SwiftUI presents the sheet.

### 7.5 `tool`

The `tool` module owns tool registration and tool-call orchestration.

Responsibilities:

- Tool schema registry.
- Tool-call parser.
- JSON schema validation.
- Tool routing.
- Tool lifecycle event generation.
- Tool result normalization.
- Swift native executor bridge.

Representative types:

```text
ToolRegistry
ToolSchema
ToolCall
ToolCallParser
ToolRouter
ToolExecutorBridge
ToolResult
ToolResultNormalizer
```

The actual iOS tool implementation lives in Swift. Rust only orchestrates and
records the call.

### 7.6 `utils`

The `utils` module contains reusable helpers that are not domain owners.

Examples:

- IDs.
- Time.
- JSON helpers.
- Small serialization helpers.
- Bounded stream helpers.
- Test fixtures.

No major runtime state should live in `utils`.

## 8. Runtime Event Model

All meaningful state changes are represented as append-only events.

Core event kinds:

```text
SessionCreated
ProviderChanged
ToolRegistered
UserMessage
AssistantMessageStarted
AssistantTextDelta
AssistantMessageCompleted
ToolCallRequested
ToolCallApproved
ToolCallRejected
ToolExecutionStarted
ToolExecutionUpdate
ToolExecutionCompleted
ToolExecutionFailed
ToolResultMessage
RunSuspended
RunResumed
CompactionCreated
BranchSummaryCreated
RunCancelled
RunFailed
```

Every persisted event includes:

```text
id
session_id
parent_id
run_id optional
timestamp
kind
payload_json
blob_refs
```

The `parent_id` field forms the tree. The runtime can continue from any prior
entry by appending a new child entry instead of rewriting history.

### 8.1 Stream Batching

Runtime events are persisted at semantic boundaries, but UI streaming events
must not cross the Rust-Swift FFI boundary one token at a time.

The `core` stream manager batches assistant deltas before sending them to Swift.
The default MVP batching policy is:

```text
flush when accumulated text reaches a small byte threshold
or when 16 ms have elapsed
or when the provider finishes the message
or when a tool call boundary is detected
```

This keeps SwiftUI updates close to display refresh cadence and avoids turning
token streaming into thousands of tiny FFI calls. The event store may persist
coarser `AssistantTextDelta` chunks; it does not need one row per model token.

## 9. Session Tree

The MVP session tree supports:

- Create session.
- Append child event.
- Maintain active leaf.
- Continue from any prior event.
- Create a new branch by sending a message from an older event.
- Basic branch list.
- Entry labels.

The UI can remain simple in the MVP, but the storage and runtime model must
already be tree-shaped.

## 10. Agent Loop

The `core` agent loop executes one user turn as:

```text
1. Append UserMessage.
2. Ask context module to build PromptFrame from active branch.
3. Call selected ModelProvider.
4. Emit AssistantMessageStarted.
5. Stream AssistantTextDelta events.
6. If a tool call appears:
   6.1 Append ToolCallRequested.
   6.2 Ask tool module to parse and validate.
   6.3 Ask security module for policy decision.
   6.4 Ask Swift for user confirmation if needed.
   6.5 Route execution to Swift Native Toolkit.
   6.6 Append ToolResultMessage.
   6.7 Ask context module to build follow-up PromptFrame.
   6.8 Continue model call.
7. Append AssistantMessageCompleted.
8. Update active leaf.
```

MVP constraints:

- Tool calls run sequentially.
- Only one active model stream per session.
- Cancellation writes `RunCancelled`; it does not delete prior deltas.
- Provider failure writes `RunFailed`.

### 10.1 Cross-Language Suspension

When Rust needs Swift user confirmation, permission mediation, Face ID, or a
native approval sheet, the agent loop must suspend asynchronously instead of
blocking an executor thread.

The lifecycle is:

```text
1. Rust creates an ApprovalRequest with run_id, tool_call_id, and approval_id.
2. Rust writes RunSuspended and emits the request to Swift.
3. Rust stores a SuspendedRun waiter and awaits a one-shot resume signal.
4. Swift presents the native UI.
5. Swift calls submit_approval_decision(approval_id, decision).
6. Rust validates that the approval belongs to the suspended run.
7. Rust writes RunResumed or ToolCallRejected.
8. The original run continues or terminates cleanly.
```

Required properties:

- No blocking waits across UniFFI or C ABI.
- Every suspended run has a timeout or cancellation path.
- Approval IDs are single-use.
- Runtime restart can recover the suspended state as "needs user decision" or
  "cancelled", but must not silently execute the tool.
- Swift UI may disappear while a run is suspended; Rust must treat that as
  cancellation or unresolved approval, not implicit approval.

## 11. Per-Call LLM Context

Every model call receives a `PromptFrame` built by Rust `context`.

```text
PromptFrame
  1. System Prompt
  2. Runtime Policy
  3. Tool Schemas
  4. Active Branch Context
  5. Current User Input
  6. Current Attachments
  7. Pending Tool Results
```

### 11.1 System Prompt

Defines the assistant identity and baseline behavior.

Example:

```text
You are a local-first personal assistant running on an iOS device.
You must use tools for system actions.
You must not claim that a system action succeeded unless a tool result confirms it.
```

### 11.2 Runtime Policy

Injected by Rust. It tells the model how to behave under local runtime rules:

```text
- iOS system actions must use tools.
- Sensitive actions may require user confirmation.
- Tool results may be summarized or redacted.
- Missing permissions must be surfaced to the user.
```

### 11.3 Tool Schemas

Swift Native Toolkit registers tool schemas with Rust. Rust decides which schemas
enter each model call.

MVP can inject all registered schemas because the tool set is small. Later
versions can retrieve only relevant tools.

Candidate MVP tools:

```text
calendar.search_events
reminders.create_reminder
shortcuts.list_voice_shortcuts
shortcuts.donate_voice_shortcut
```

### 11.4 Active Branch Context

Rust selects the path from root to the current active leaf and projects it into a
model-readable history:

```text
compaction summary, if any
recent user messages
recent assistant messages
recent tool call summaries
recent permitted tool results
```

The database contains the complete event log. The model receives only the active
branch projection.

### 11.5 Current User Input

The current user input always enters the next `PromptFrame`. Editing from an
older entry creates a new branch.

### 11.6 Current Attachments

Images, selected files, and selected text are stored as blob references. The
context module adapts them by provider:

```text
MockStreamingProvider:
  attachment metadata only

DesktopMiniCPMProvider:
  OpenAI-compatible image_url/base64 payload, when supported

OnDeviceMiniCPMProvider:
  future local tensor or llama.cpp multimodal input
```

### 11.7 Pending Tool Results

When a tool call has completed, the next model call must include:

```text
assistant tool_call
tool_result
```

Swift returns structured results. Rust chooses what becomes model-visible.

```text
ToolResult
  display_text
  model_text
  structured_json
  audit_text
  sensitivity
  retention
  is_error
```

Retention rules:

```text
run_only:
  Include only in the immediate tool follow-up call.

session:
  May appear in later session context.

memory_candidate:
  Requires user confirmation before becoming long-term memory.

audit_only:
  Never enters model context; persist only for audit.

secret:
  Minimize injection and never include in compaction by default.
```

### 11.8 Tokenizer Contract

Context truncation must use the tokenizer semantics of the active provider.
Rust must not rely on one global approximation such as tiktoken for every model.

Each provider exposes a tokenizer contract:

```text
TokenizerAdapter
  provider_id
  model_id
  count_prompt_frame(frame)
  count_messages(messages)
  max_context_tokens
  safety_margin_tokens
```

Provider-specific behavior:

```text
MockStreamingProvider:
  deterministic approximate counts for tests

DesktopMiniCPMProvider:
  endpoint-specific estimate if available, otherwise conservative local estimate
  with a safety margin

OnDeviceMiniCPMProvider:
  exact count from the same tokenizer used by the C++ backend, exposed through
  the provider boundary
```

The `context` module must truncate only at message, tool result, attachment, or
summary boundaries. It must not split JSON tool calls or structured tool
results in the middle of a syntactic unit.

## 12. Tool Calling Flow

Tool execution uses this fixed chain:

```text
LLM outputs tool_call
  -> Rust parses, validates, records, and applies policy
  -> Swift Native Toolkit executes iOS API or Shortcut bridge
  -> Swift returns structured ToolResult
  -> Rust persists result and builds next context
  -> Model continues
  -> SwiftUI renders events
```

Rust is the orchestrator. Swift is the real native capability layer.

## 13. Swift Native Toolkit

The Swift toolkit provides native tool implementations and shortcuts bridging.

MVP candidate tool areas:

- Calendar / EventKit read.
- Reminders write.
- Shortcuts and voice shortcuts through App Intents and
  `INVoiceShortcutCenter`.

Each tool provides:

```text
name
description
parameters JSON schema
risk level
permission requirements
executor
ToolResult encoder
```

The Swift toolkit may request system permissions and may surface native dialogs,
but it must return through the Rust runtime for persistence and model
continuation.

## 14. Model Providers

The Rust provider abstraction must support:

```text
id
profile
stream_chat
estimate_tokens
cancel
```

MVP providers:

- `MockStreamingProvider`: deterministic token stream and deterministic tool-call
  simulation.
- `DesktopMiniCPMProvider`: HTTP provider for Mac-local MiniCPM-V-4.6 endpoint
  from iOS Simulator.
- `OnDeviceMiniCPMProvider`: interface boundary for later C++ integration.

The desktop provider is for development realism. It is not the final pure
offline architecture.

## 15. Storage

MVP uses SQLite.

Tables:

```text
sessions
events
event_paths
blobs
tool_registry
provider_settings
audit_log
```

Rules:

- Event log is append-only.
- Blob metadata is stored separately from large payloads.
- Tool audit data is persisted even if it is not model-visible.
- SwiftUI state is not authoritative.
- Sensitive settings should eventually move to Keychain or encrypted storage.

### 15.1 Session Tree Indexing

The session tree cannot rely only on an adjacency list if every context build
must repeatedly walk from leaf to root.

The MVP stores `parent_id` as the canonical relationship and adds a query
accelerator:

```text
events:
  id
  session_id
  parent_id
  depth
  sequence
  kind
  payload_json

event_paths:
  session_id
  ancestor_id
  descendant_id
  depth_delta
```

This closure table allows efficient active-branch reconstruction:

```text
select e.*
from event_paths p
join events e on e.id = p.ancestor_id
where p.session_id = ?
  and p.descendant_id = ?
order by e.depth, e.sequence;
```

The `parent_id` column remains the source of truth for append operations. The
closure table is maintained transactionally when a new event is appended.

Materialized path is an acceptable later simplification for prototypes, but its
query must be used carefully: prefix matching a leaf path finds descendants of
that path, not the ancestors needed to construct the active branch. For MVP
correctness, closure table is the default design.

## 16. Cross-Language Interfaces

Swift and Rust use UniFFI or an equivalent generated FFI boundary.

Minimal interface:

```text
create_runtime(config)
create_session()
send_message(session_id, parent_event_id, input)
cancel(run_id)
register_tool(schema)
submit_approval_decision(approval_id, decision)
submit_tool_result(tool_call_id, result)
subscribe_events(session_id)
set_provider(provider_config)
```

FFI rules:

- Pass DTOs, not language-native internal objects.
- Pass large blobs by file URL or blob id.
- Events include `event_id` and `run_id`.
- Swift callbacks should not do heavy work inside the FFI callback.

## 17. Error Handling

Unified error categories:

```text
storage
provider
tool_parse
tool_validation
tool_permission
tool_execution
policy_denied
cancelled
ffi
unknown
```

Rules:

- Provider errors write `RunFailed`.
- User cancellation writes `RunCancelled`.
- Tool execution errors are represented as failed tool events or model-visible
  error tool results.
- Permission denial must be model-visible when it affects the user request.
- Rust panic must not cross FFI.
- C++ crashes cannot be caught by Rust; the later on-device provider must rely on
  stable C ABI boundaries, conservative resource management, and stress tests.

## 18. Testing Strategy

Rust unit tests:

- `SessionTree`
- Closure-table active branch reconstruction
- `ContextController`
- Provider tokenizer contract and truncation boundaries
- `ToolRouter`
- `PolicyEngine`
- `SuspendedRun` approval lifecycle
- `StreamBatcher`
- `MockStreamingProvider`

Rust integration tests:

- `send_message` with mock stream.
- Tool-call lifecycle.
- Tool-call approval suspension and resumption.
- Branch continuation.
- Cancellation.
- Provider error path.
- Batched assistant delta delivery.

Swift tests:

- `ToolResult` encoding.
- Native tool permission handling.
- UniFFI DTO roundtrip.
- Approval decision roundtrip.
- UI event rendering smoke test.

Development test matrix:

```text
Simulator + MockStreamingProvider
Simulator + DesktopMiniCPMProvider
```

Future true-device test matrix:

```text
On-device model loading
Memory pressure
Thermal behavior
Background / foreground lifecycle
```

## 19. Milestones

### Milestone 1: Project Skeleton

Create:

```text
local-ios-agent/
  docs/
  rust-core/
  ios-app/
  inference/
```

### Milestone 2: Rust Runtime With Mock Provider

Implement:

- `core` module.
- `memory` event store.
- `context` prompt builder.
- `tool` schema registry and mock tool-call flow.
- `security` policy stubs.
- `MockStreamingProvider`.

### Milestone 3: SwiftUI Shell

Implement:

- Chat UI.
- Runtime bridge.
- Provider selector.
- Debug `PromptFrame` viewer.

### Milestone 4: Swift Native Toolkit

Implement:

- Tool schema registration.
- One read tool.
- One confirmation-required write tool.
- Tool/audit event rendering.

### Milestone 5: Desktop MiniCPM Provider

Implement:

- Local endpoint configuration.
- Streaming HTTP client.
- Real model smoke test.
- Image input path if endpoint supports it.

### Milestone 6: MVP Hardening

Implement:

- Cancellation.
- Error states.
- Persistence verification.
- Runbook and developer docs.

## 20. Open Implementation Decisions

These are intentionally deferred to the implementation plan:

- Whether to initialize `local-ios-agent` as its own git repository.
- Exact iOS project generator: Xcode project, Swift Package, or mixed setup.
- Exact Rust SQLite library.
- Exact UniFFI version and generated binding layout.
- Exact local MiniCPM-V-4.6 serving command.
- Exact first read and write native tools.

## 21. Final Architecture Commitment

The project architecture is:

```text
C++ = model inference
Rust = core runtime
Swift = native toolkit and Shortcuts bridge
SwiftUI = frontend
```

The MVP implementation order is:

```text
Mock provider
Rust Pi-like runtime
SwiftUI shell
Swift native tools
Desktop MiniCPM provider
Hardening
```

This keeps the core small, observable, recoverable, and replaceable while
leaving room for true on-device inference after the runtime proves itself.
