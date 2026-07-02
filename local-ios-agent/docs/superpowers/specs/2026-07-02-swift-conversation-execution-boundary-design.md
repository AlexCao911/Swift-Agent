# Swift Conversation and Execution Boundary Design

Date: 2026-07-02
Status: Draft for review
Project path: `/Users/alexandercou/Projects/Alex-agent/local-ios-agent`

## 1. Purpose

This design splits the current Swift agent surface into two large domains:

- `conversation/`: owns conversation facts, sessions, branch/edit lineage, and
  user-visible message history.
- `execution/`: owns agent configuration, run lifecycle, context assembly
  decisions, ReAct/tool loop execution, inference settings, and debug archives.

The main goal is to retire the single large Swift runtime object shape without
creating another large object under a different name. Swift should expose two
domain protocols and a thin coordinator for cross-domain chat use cases.

The central rule is:

```text
Conversation owns history facts.
Execution owns context assembly decisions.
```

## 2. Current State

The current Swift app has useful pieces, but the responsibilities are bundled:

- `AgentRuntimeService` handles session management, send/edit/regenerate,
  provider options, stream consumption, host tool continuation, and conversation
  replay.
- `AgentViewModel` owns draft state, conversation actions, run actions,
  attachments, and runtime error handling.
- `ConversationService` currently projects and groups conversations and replays
  runtime events into `AgentViewState`.
- Runtime events are used both as durable conversation history and transient run
  projection.

The Rust side already points toward cleaner boundaries:

- `run_snapshot/` resolves agent profile and trusted host state into an
  immutable `ResolvedRunSnapshot`.
- `context/` owns `ContextAssembler`, `ContextPolicy`, `ContextBudget`, and
  model input assembly.
- `runtime/` owns execution state, effects, checkpoints, and runtime events.
- `core/session_tree` and event-store APIs already represent branch history.

These are foundational modules, not a landed boundary. The current production
chat path still runs through `core::AgentRuntime`, which mixes conversation
history, context construction, provider calls, tool continuation, and run state.
The newer AgentOS start-run path resolves snapshots and executes a plan, but it
does not yet include a conversation frame and currently behaves more like a
synchronous debug runner than the future streamed run lifecycle.

Swift should adapt to the intended Rust boundaries instead of mirroring Rust
internals or keeping one broad `AgentOSRuntime` protocol. Rust must also be
tightened so the intended boundaries are real.

## 3. Non-Goals

This design does not define the final chat UI layout.

It does not implement the split. It only defines the target boundaries,
protocols, DTO direction, coordinator role, and migration order.

It does not move context assembly into Swift. Swift may request previews and
debug archives, but Rust remains the only owner of model-input assembly.

It does not require every execution runtime event to become a durable
conversation message.

## 4. Top-Level Shape

```text
Swift MVVM Layer
  ConversationViewModel        AgentRunViewModel
          \                         /
           \                       /
            ChatInteractionCoordinator
             /                    \
            /                      \
  ConversationDomain protocol    ExecutionDomain protocol
            \                      /
             JSON over C ABI bridge
                    |
                 Rust core
```

`ConversationViewModel` works with `ConversationDomain`.
`AgentRunViewModel` works with run projection and receives execution events.
Agent builder, inference settings, and run debug view models work with
`ExecutionDomain`.

`ChatInteractionCoordinator` is not a third domain. It is a thin app-layer
orchestrator for use cases that must cross both domains, such as send,
regenerate, edit-and-resend, approve tool, and cancel run.

## 5. Conversation Domain

The conversation domain manages conversation facts and branch structure.

It owns:

- session list and metadata
- active session and active branch head
- session rename/archive/delete
- fork tree and edit lineage
- visible user/assistant message history
- current draft text and attachment references
- preparation of a stable user turn for execution
- commit of final assistant output as durable conversation fact

It does not own:

- system prompt compilation
- token budget decisions
- memory injection
- tool schemas
- ReAct scratchpad
- tool loop state
- model input messages
- inference provider request formatting
- context archives

### 5.1 Conversation Internal Services

```text
ConversationDomain
  ConversationCommandService
  ConversationHistoryService
  ConversationProjectionStore
  TurnPreparationService
  BranchingService
  ConversationRepository
  DraftAttachmentStore
```

`ConversationCommandService` is the domain facade. It exposes conversation use
cases and delegates detailed work to the smaller services.

`ConversationHistoryService` resolves a session and leaf into a canonical branch
path. It understands fork/edit lineage and message ordering. It does not choose
which messages fit in the model context.

`TurnPreparationService` turns the current draft into a durable user turn and a
`ConversationRunFrameDTO`.

`BranchingService` owns fork, edit, regenerate, and parent-target semantics.

`ConversationProjectionStore` produces Swift UI projections for session lists,
grouped sections, active branch messages, draft target state, and search.

`ConversationRepository` is the bridge-facing adapter for conversation APIs.
It handles DTOs only.

`DraftAttachmentStore` manages temporary draft attachment previews and
attachment references. It does not decide whether file contents enter the model
input.

### 5.2 Conversation Protocol

```swift
protocol ConversationDomain {
    func listSessions() async throws -> [ConversationSummaryDTO]
    func createSession() async throws -> SessionDTO
    func loadSession(
        _ id: SessionID,
        leafId: EventID?
    ) async throws -> ConversationProjectionDTO

    func prepareUserTurn(
        _ request: PrepareUserTurnRequestDTO
    ) async throws -> ConversationRunFrameDTO

    func forkSession(_ request: ForkSessionRequestDTO) async throws -> SessionDTO
    func editTurn(_ request: EditTurnRequestDTO) async throws -> ConversationRunFrameDTO

    func commitAssistantResult(
        _ request: CommitAssistantResultDTO
    ) async throws -> ConversationProjectionDTO

    func renameSession(_ id: SessionID, title: String) async throws
    func archiveSession(_ id: SessionID) async throws
    func deleteSession(_ id: SessionID) async throws
}
```

`prepareUserTurn` creates or selects the session, applies the intended parent
or edit/fork semantics, stores the user turn, and returns a stable frame for
execution.

`commitAssistantResult` is called only when execution reaches final assistant
output. Streaming deltas, transient tool calls, and debug events remain
execution projection unless a later policy explicitly promotes them.
The commit payload should contain the user-visible assistant message, run link,
and searchable metadata. It should not copy the full execution event tree,
context archive, or model-call trace into conversation history.

### 5.3 ConversationRunFrameDTO

`ConversationRunFrameDTO` is the clean conversation skeleton for a run.

```text
ConversationRunFrameDTO
  frameId
  sessionId
  branchId
  branchHeadId
  userTurnId
  parentEventId
  conversationMessages
  attachmentRefs
  lineage
```

It may include visible message roles and attachment references. It must not
include:

- system/developer prompt
- agent instructions
- tool schema
- memory injection
- hidden scratchpad
- accumulated ReAct tool call transcript
- provider-specific message format
- token trimming decisions

## 6. Execution Domain

The execution domain manages agent setup and agent execution.

It owns:

- agent profiles and published profile versions
- component slots and agent composition
- model/provider settings
- run start/cancel/resume
- context preview and context archives
- per-LLM-call context assembly decisions
- ReAct/tool loop state
- host-side tool continuation and approval coordination
- transient execution event projection
- run debug snapshots

It does not own:

- session list
- fork tree
- edit lineage
- durable conversation message history
- conversation title/search projection

### 6.1 Execution Internal Services

```text
ExecutionDomain
  ExecutionCommandService
  AgentProfileService
  AgentCompositionService
  RunLifecycleService
  ContextAssemblyService
  ToolLoopService
  RuntimeEventStore
  RunDebugStore
  InferenceSettingsService
  ExecutionRepository
```

`ExecutionCommandService` is the domain facade. It exposes agent and run use
cases without storing all domain state itself.

`AgentProfileService` owns active profile, published profile, readiness, and
version information.

`AgentCompositionService` owns prompt/persona/instruction/model/tool/memory
component slots, validation, and agent build/publish flows.

`RunLifecycleService` owns duplicate-run guards, active run handle, cancellation,
resume, and terminal run state.

`ContextAssemblyService` calls Rust for context preview and archive/debug data.
It does not assemble the context in Swift.

`ToolLoopService` coordinates pending tool requests, approval decisions,
native-tool execution, and submission of tool results.

`RuntimeEventStore` reduces execution events into run UI projection:
streaming output, tool calls, approvals, run phase, and errors.

`RunDebugStore` loads runtime events, prompt archives, context archives, tool
records, and model-call traces for debugging.

`InferenceSettingsService` owns provider/model selection and generation options.

`ExecutionRepository` is the bridge-facing adapter for execution APIs. It
handles DTOs only.

### 6.2 Execution Protocol

```swift
protocol ExecutionDomain {
    func listModels() async throws -> [ModelDescriptorDTO]
    func listComponents() async throws -> [ComponentDTO]
    func buildAgent(_ draft: AgentDraftDTO) async throws -> AgentProfileDTO

    func startRun(_ request: StartExecutionRequestDTO) async throws -> RunHandleDTO
    func observeEvents(
        runId: RunID
    ) -> AsyncThrowingStream<ExecutionEventDTO, Error>

    func approveTool(_ decision: ToolApprovalDecisionDTO) async throws
    func submitToolResult(_ result: ToolResultDTO) async throws
    func cancelRun(_ runId: RunID) async throws

    func previewContext(
        _ request: ContextPreviewRequestDTO
    ) async throws -> ContextPreviewDTO

    func getRunDebugSnapshot(
        _ runId: RunID
    ) async throws -> RunDebugSnapshotDTO
}
```

Agent configuration APIs such as `listModels`, `listComponents`, and
`buildAgent` belong to execution, not conversation.

### 6.3 StartExecutionRequestDTO

```text
StartExecutionRequestDTO
  conversationRunFrame
  agentProfileId
  executionOptions
```

Rust execution/app-service then resolves:

```text
ConversationRunFrame
  + AgentProfile
  + PromptCompiler
  + ToolRegistry
  + MemoryResolver
  + ContextPolicy
  + ContextBudget
  -> ModelInputMessages
```

The bridge may pass conversation facts and user intent. It must not pass trusted
permission state, local binding state, or provider internals from Swift.

## 7. Context Assembly Boundary

Context construction happens in two stages.

Stage 1: `conversation/` prepares conversation context.

```text
SessionTree active branch
  + edit/fork lineage
  + current user turn
  + attachment refs
  -> ConversationRunFrameDTO
```

This stage produces a clean skeleton. It does not assemble prompt text.

Stage 2: `execution/` assembles model input before every LLM call.

```text
ConversationRunFrameDTO
  + compiled prompt
  + tool schemas
  + memory contributions
  + accumulated tool calls/results for this run
  + context policy
  + context budget
  -> ContextAssembler
  -> ModelInputMessages
  -> InferenceRouter
  -> C++ backend/provider
```

Within a tool loop, execution rebuilds model input from structured run state
before every LLM call:

```text
call 1:
  conversation frame + prompt + tools + memory

model -> tool_call
tool -> tool_result

call 2:
  conversation frame + prompt + tools + memory
  + prior assistant tool_call
  + tool_result

model -> final_response
```

The implementation should not mutate or reuse a single prompt string as the
source of truth. It should rebuild each call from structured state and archive
the resulting context trace.

## 8. Rust Boundary Adjustment

The same two-domain split should be reflected in Rust. This is the missing
counterpart to the Swift protocol split.

Current Rust code has the right primitives, but the boundary has not landed.
The main path is still a mixed runtime object.

- `core/session_tree.rs`, `core/event.rs`, and event-store branch APIs represent
  conversation history.
- `core/runtime.rs` still combines session operations, provider calls, context
  construction, tool continuation, and run state.
- `context/`, `run_snapshot/`, `execution/`, and `runtime/` already point toward
  execution ownership, but conversation-frame preparation is not yet a first
  class Rust boundary.
- `app_service.rs` resolves and persists a `ResolvedRunSnapshot`, but the input
  is only `StartRunRequest { agent_profile_id, user_intent }`.
- `ffi_bridge.rs` exposes both the legacy streaming chat path and the newer
  AgentOS run path. They are parallel paths today, not a single coherent
  conversation -> execution pipeline.

### 8.1 Current Rust Findings

The current implementation should be treated as partially prepared, not
architecturally complete.

1. `core::AgentRuntime` is still a mixed large object. It stores config,
   `ContextController`, event store, provider registry, session cursors, run
   records, cancellation registry, debug snapshots, and pending tool requests.
   Its impl contains both conversation APIs such as create/list/fork sessions
   and execution APIs such as send, provider call, tool continuation, and
   cancellation.
2. The new AgentOS `StartRunRequest` has no conversation frame. Snapshot
   resolution captures profile and trusted host state, but not the session,
   branch, user turn, or attachment references that define the conversation
   input for a run.
3. Legacy `send_message_streaming` bypasses `ResolvedRunSnapshot` and
   `ExecutionPlan`. It appends the user message, loads the branch, asks
   `ContextController` to build a prompt frame, and calls the provider directly.
   `submit_tool_result_streaming` repeats the same direct branch -> prompt frame
   -> provider pattern for tool continuation.
4. `context` currently consumes raw `RuntimeEvent` values through
   `ContextController.build_prompt_frame_from_context_assembly`, with
   `BranchProjector` turning branch events into `PromptMessage` and deciding
   whether tool results inject into context. That mixes conversation replay and
   model-input policy.
5. The newer `start_agent_os_run` path resolves snapshot -> plan -> run machine
   and stores debug output in one synchronous call. It is useful as a scaffold,
   but it is not yet the future lifecycle API of start, observe, approve tool,
   submit result, and cancel.

### 8.2 Target Rust Paths

```text
rust-core/src/conversation/
  mod.rs
  session.rs
  session_tree.rs
  event.rs
  branch.rs
  turn.rs
  frame.rs
  projection.rs
  repository.rs
  conversation_service.rs

rust-core/src/execution/
  mod.rs
  execution_service.rs
  execution_plan.rs
  execution_planner.rs
  run_lifecycle.rs
  context_bridge.rs
  tool_loop.rs
  trace.rs
  budgets.rs
```

`conversation/` is the renamed and clarified home for what was previously
described as the interaction runtime. It is not an agent runtime. It is the
conversation history and interaction domain.

`execution/` is the clarified home for what was previously described as app
service plus runtime execution. It owns agent execution and calls into
`run_snapshot/`, `context/`, `runtime/`, `tool/`, `memory/`, and `inference/`.

The existing `runtime/` module can remain the lower-level run machine/effect
layer. The higher-level start-run application service belongs under
`execution/`.

### 8.3 Rust Conversation Path

The Rust conversation path owns durable conversation facts:

```text
ConversationService
  list_sessions()
  create_session()
  load_session(session_id, leaf_id)
  prepare_user_turn(request)
  fork_session(request)
  edit_turn(request)
  commit_assistant_result(request)
  rename/archive/delete
```

It uses:

```text
SessionTree
EventStore
BranchProjector or successor
ConversationProjection
ConversationRunFrame
```

`ConversationRunFrame` is produced here and passed to execution. It should be a
Rust domain object with a persisted reference and DTO mapping for Swift:

```rust
pub struct ConversationRunFrameRef {
    pub frame_id: ConversationFrameId,
    pub session_id: SessionId,
    pub branch_head_id: EntryId,
    pub user_turn_id: EntryId,
}

pub struct ConversationRunFrame {
    pub frame_id: ConversationFrameId,
    pub session_id: SessionId,
    pub branch_id: BranchId,
    pub branch_head_id: EntryId,
    pub user_turn_id: EntryId,
    pub parent_event_id: Option<EntryId>,
    pub conversation_messages: Vec<ConversationFrameMessage>,
    pub attachment_refs: Vec<AttachmentRef>,
    pub lineage: ConversationLineage,
}
```

The conversation path may normalize visible message history into frame
messages. It must not inject system prompts, memories, tool schemas, context
budget decisions, or provider-specific message roles.

`BranchProjector` currently lives in `context/` and turns branch runtime events
into `PromptMessage`. That coupling should be split:

- conversation projection should produce `ConversationFrameMessage`
- execution context assembly should map those frame messages into
  `ContextSegment` or model-input roles

This keeps branch replay in conversation and model-input selection in
execution/context.

### 8.4 Rust Execution Path

The Rust execution path owns agent execution:

```text
ExecutionService
  start_run(StartExecutionRequest)
  observe_events(run_id)
  approve_tool(decision)
  submit_tool_result(result)
  cancel_run(run_id)
  preview_context(request)
  get_run_debug_snapshot(run_id)
```

It orchestrates:

```text
ConversationRunFrame
  + AgentProfileId
  + trusted host state captured inside Rust
  -> RunSnapshotService.resolve()
  -> ExecutionPlanner.plan()
  -> RuntimeExecutionService / RunMachine
  -> ContextAssembler before every LLM call
  -> InferenceRouter
  -> ToolLoop
  -> ExecutionEvent stream
```

`StartRunRequest` in `run_snapshot/` currently contains `agent_profile_id` and
`user_intent`. This is insufficient for the target boundary. The next hard
Rust change is to introduce `ConversationRunFrameRef` into either
`StartRunRequest` or a new `StartExecutionRequest`, and to persist that
reference in `ResolvedRunSnapshot`.

The target snapshot relationship is:

```text
StartExecutionRequest
  agent_profile_id
  conversation_frame_ref
  user_intent / execution_options

ResolvedRunSnapshot
  agent profile/version bindings
  trusted host state
  conversation_frame_ref
  created_at
```

The full frame content can be loaded by execution through a trusted
conversation repository. The snapshot must at least pin the frame identity so
debug archives can explain which branch and user turn the run used.

The trust rule remains unchanged:

```text
Swift may provide conversation facts and selected agent profile id.
Swift must not provide trusted permission state, local binding state, or
credential availability.
Rust execution captures trusted host state before resolving the snapshot.
```

### 8.5 Rust Event Ownership

Rust should distinguish event ownership:

```text
ConversationEvent
  durable session facts:
  session created, user turn committed, assistant final committed,
  branch/fork/edit metadata, title/archive/delete metadata

ExecutionEvent
  transient or debug execution facts:
  run started, model call started/completed, assistant delta,
  tool call requested, approval requested, tool result observed,
  context archive created, run completed/failed/cancelled
```

Some execution events may reference conversation ids or message ids. That does
not make them conversation events.

The final assistant result crosses the boundary through
`ConversationService.commit_assistant_result`, which stores a durable visible
assistant message plus run/debug references. The complete execution event tree,
context archives, and model-call traces stay in execution storage/debug
archives.

### 8.6 Legacy Runtime Classification

The legacy runtime path should be explicitly classified, not treated as already
compliant.

```text
Legacy compatibility path:
  AgentRuntime.send_message_streaming
  AgentRuntime.submit_tool_result_streaming
  ffi_bridge send_message_streaming APIs

Target execution path:
  ConversationService.prepare_user_turn
  ExecutionService.start_run
  ExecutionService.observe_events
  ExecutionService.approve_tool / submit_tool_result
  ExecutionService.cancel_run
```

During migration, the legacy path may remain for app compatibility and test
coverage. It should be named and tested as a migration object because it
bypasses snapshot resolution, execution planning, and the future
conversation-frame contract.

### 8.7 Rust Migration Path

1. Introduce `ConversationRunFrame` and `ConversationRunFrameRef` around the
   existing session tree and event-store branch APIs.
2. Extend `StartRunRequest` or add `StartExecutionRequest` so every new
   execution run includes a conversation frame reference.
3. Persist `conversation_frame_ref` in `ResolvedRunSnapshot` and add a fixture
   proving snapshot debug output identifies session, branch head, and user turn.
4. Mark `AgentRuntime.send_message_streaming` and
   `submit_tool_result_streaming` as legacy compatibility paths in docs/tests.
5. Introduce `conversation/` with re-exported wrappers around the existing
   session/event-store primitives. Do not move storage tables first.
6. Move branch-to-visible-history projection out of `context/BranchProjector`
   into conversation, leaving context to consume frame messages as inputs.
7. Add `ConversationService.prepare_user_turn` and
   `commit_assistant_result`.
8. Add `execution/ExecutionService` as the Rust app-service entry point for
   `StartExecutionRequest`.
9. Move provider/model/tool-loop orchestration out of `core/runtime.rs` into
   execution services while keeping `runtime/RunMachine` as the lower-level
   state machine.
10. Keep compatibility bridge APIs until Swift finishes moving from
   `AgentRuntimeService` to the two-domain coordinator.

## 9. ChatInteractionCoordinator

The coordinator is an app-layer use-case orchestrator.

It may hold short-lived task handles, such as an observation task for the active
run. It must not become a stateful domain object.

```swift
@MainActor
final class ChatInteractionCoordinator {
    private let conversationVM: ConversationViewModel
    private let runVM: AgentRunViewModel
    private let conversation: ConversationDomain
    private let execution: ExecutionDomain
    private var observeTask: Task<Void, Never>?

    func sendMessage() async
    func regenerate(from messageId: String) async
    func editAndResend(messageId: String, text: String) async
    func approveTool(_ decision: ToolApprovalDecisionDTO) async
    func cancelRun() async
}
```

`sendMessage` flow:

```text
1. Read draft from ConversationViewModel.
2. conversation.prepareUserTurn(...)
3. runVM.resetForNewRun(...)
4. execution.startRun(conversationRunFrame + activeAgentProfileId)
5. execution.observeEvents(runId)
6. runVM.apply(event)
7. On final assistant response:
     conversation.commitAssistantResult(...)
8. conversationVM refreshes active session projection.
```

Swift may pass a frame DTO or frame reference depending on bridge maturity.
Rust execution must persist the frame reference in the snapshot either way.

`approveTool` flow:

```text
1. Read pending approval from AgentRunViewModel.
2. execution.approveTool(...)
3. Continue observing execution events.
```

`cancelRun` flow:

```text
1. execution.cancelRun(runId)
2. Stop observation task when terminal event arrives or cancellation confirms.
3. Keep partial run projection in AgentRunViewModel.
```

The coordinator may call both domains. Individual view models should not call
across domains directly.

## 10. View Models

### 10.1 ConversationViewModel

Owns conversation UI state:

```swift
@Observable
final class ConversationViewModel {
    var sessions: [ConversationSummaryViewState]
    var sections: [ConversationSectionViewState]
    var activeSessionId: String?
    var activeBranchHeadId: String?
    var messages: [ConversationMessageViewState]
    var draft: UserDraftViewState
    var searchQuery: String
    var errorMessage: String?
}
```

It calls `ConversationDomain` only. It does not know tool approval or run loop
rules.

### 10.2 AgentRunViewModel

Owns active run UI state:

```swift
@Observable
final class AgentRunViewModel {
    var phase: RunPhaseViewState
    var runId: String?
    var streamBuffer: String
    var events: [ExecutionEventViewState]
    var toolCalls: [ToolCallViewState]
    var pendingApproval: ApprovalViewState?
    var terminalReason: RunTerminalReason?
    var errorMessage: String?

    func apply(_ event: ExecutionEventDTO)
    func resetForNewRun(...)
}
```

It reduces execution events. It does not own sessions, fork tree, or durable
conversation history.

### 10.3 AgentBuilderViewModel

Owns agent editing:

```swift
var draft: AgentDraftViewState
var components: [ComponentSlotViewState]
var readiness: ReadinessViewState
var activeProfile: AgentProfileViewState?
```

It calls execution agent-composition APIs.

### 10.4 InferenceSettingsViewModel

Owns provider/model/generation option UI state:

```swift
var providers: [ProviderProfileViewState]
var activeProvider: ProviderProfileViewState?
var models: [ModelDescriptorViewState]
var temperature: Double
var topP: Double
```

It belongs to execution configuration.

### 10.5 RunDebugViewModel

Owns run debug archive projection:

```swift
var runId: String?
var timeline: [RunDebugEventViewState]
var contextArchives: [ContextArchiveViewState]
var promptArchives: [PromptArchiveViewState]
var modelCalls: [ModelCallTraceViewState]
```

It calls execution debug APIs.

## 11. Bridge Split

The Swift bridge should avoid one broad runtime protocol. Split it into two
capability groups:

```text
ConversationBridgeClient
  listSessions
  createSession
  loadSession
  prepareUserTurn
  forkSession
  editTurn
  commitAssistantResult
  rename/archive/delete

ExecutionBridgeClient
  listModels
  listComponents
  buildAgent
  startRun
  observeEvents
  approveTool
  submitToolResult
  cancelRun
  previewContext
  getRunDebugSnapshot
```

Both clients can still use JSON over the same C ABI handle. The split is a
Swift/Rust boundary contract, not necessarily two separate native libraries.

## 12. Migration Order

1. Add Rust `ConversationRunFrame` / `ConversationRunFrameRef` and wire the
   reference into `StartRunRequest` or `StartExecutionRequest`.
2. Persist the frame reference in `ResolvedRunSnapshot`.
3. Mark the legacy Rust `send_message_streaming` path as a compatibility path
   and keep tests that show it bypasses snapshot/execution planning.
4. Add Rust `conversation/` and `execution/` module shells around existing
   primitives without changing behavior.
5. Add DTOs and protocols without changing behavior:
   `ConversationDomain`, `ExecutionDomain`, `ConversationRunFrameDTO`,
   `StartExecutionRequestDTO`, and initial bridge client shells.
6. Map Rust `ConversationRunFrame` to `ConversationRunFrameDTO`.
7. Extract conversation projection and session operations from
   `AgentRuntimeService` into `ConversationCommandService` and
   `ConversationProjectionStore`.
8. Extract run event reduction from `AgentViewState`/`RuntimeEventReducer` into
   `AgentRunViewModel` and `RuntimeEventStore`.
9. Add `ChatInteractionCoordinator` and route send/cancel/regenerate/edit flows
   through it while preserving existing runtime calls.
10. Move provider/model/agent build APIs under execution services.
11. Replace Swift prompt-text attachment concatenation with attachment refs in
   conversation frames and Rust-side context policy.
12. Add context preview/debug DTOs once execution archive APIs are stable.
13. Delete or shrink `AgentRuntimeService` into bridge adapters after the split.

## 13. Acceptance Criteria

- Swift has separate `ConversationDomain` and `ExecutionDomain` protocols.
- Rust has clear `conversation/` and `execution/` module boundaries or module
  facades, even if storage migration remains incremental.
- Agent configuration APIs are not exposed from conversation APIs.
- Rust conversation APIs produce `ConversationRunFrame`; Rust execution APIs
  consume it.
- `StartRunRequest` or `StartExecutionRequest` carries a
  `ConversationRunFrameRef`.
- `ResolvedRunSnapshot` pins the conversation frame reference used by the run.
- `ConversationRunFrameDTO` contains conversation skeleton data only.
- Swift does not assemble `ModelInputMessages`.
- Every LLM call context is assembled in Rust execution/context code.
- `ChatInteractionCoordinator` has no long-lived domain state beyond task/run
  coordination.
- `ConversationViewModel` does not know tool loop details.
- `AgentRunViewModel` does not own session list or fork tree.
- Final assistant output is committed to conversation through an explicit
  conversation API.
- Run debug/context preview is read through execution APIs.
- `BranchProjector` no longer makes conversation history depend on prompt/model
  input types.
- Legacy `send_message_streaming` is documented and tested as a compatibility
  path until it is removed or routed through execution.

## 14. Test Boundary

Swift tests:

- Conversation projection from branch DTOs.
- `prepareUserTurn` maps draft, parent target, and attachment refs into
  `ConversationRunFrameDTO`.
- `ConversationViewModel` does not require execution mocks.
- `AgentRunViewModel` reduces execution events without conversation mocks.
- `ChatInteractionCoordinator.sendMessage` calls prepare -> start -> observe ->
  commit in order.
- Tool approval routes to execution only.
- Cancel does not mutate conversation projection directly.

Rust/bridge tests:

- Rust conversation frame fixture from a branched session tree.
- Start execution request accepts conversation frame plus profile id.
- Snapshot fixture records `conversation_frame_ref`.
- Swift cannot forge trusted permission/local binding state.
- Legacy `send_message_streaming` fixture documents that it bypasses snapshot
  resolution until migration is complete.
- Context preview and actual context archive use the same assembler.
- Tool-loop second LLM call includes prior tool call/result through execution
  run state, not conversation history mutation.
- Conversation frame replay is deterministic for the same session leaf.
- Execution final response commits only visible assistant result and run links
  into conversation storage.

## 15. Review Gate

Any future API that tries to pass prompt strings, tool schemas, memory
contributions, or provider-specific messages through `ConversationDomain` should
be rejected and moved to execution/context.

Any future API that tries to mutate session branch history from
`ExecutionDomain` should be rejected and routed through conversation commit
APIs.
