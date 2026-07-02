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

Swift should adapt to these Rust boundaries instead of mirroring Rust internals
or keeping one broad `AgentOSRuntime` protocol.

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

Current Rust code has the right primitives, but they are still mixed through
runtime-facing APIs:

- `core/session_tree.rs`, `core/event.rs`, and event-store branch APIs represent
  conversation history.
- `core/runtime.rs` still combines session operations, provider calls, context
  construction, tool continuation, and run state.
- `context/`, `run_snapshot/`, `execution/`, and `runtime/` already point toward
  execution ownership, but conversation-frame preparation is not yet a first
  class Rust boundary.

### 8.1 Target Rust Paths

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

### 8.2 Rust Conversation Path

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
Rust domain object with a DTO mapping for Swift:

```rust
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

### 8.3 Rust Execution Path

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
`user_intent`. The execution boundary should evolve to either include
`ConversationRunFrameId`/`ConversationRunFrame` or wrap it in a new
`StartExecutionRequest`.

The trust rule remains unchanged:

```text
Swift may provide conversation facts and selected agent profile id.
Swift must not provide trusted permission state, local binding state, or
credential availability.
Rust execution captures trusted host state before resolving the snapshot.
```

### 8.4 Rust Event Ownership

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

### 8.5 Rust Migration Path

1. Introduce `conversation/` with re-exported wrappers around the existing
   session/event-store primitives. Do not move storage tables first.
2. Add `ConversationRunFrame` and DTO mapping.
3. Move branch-to-visible-history projection out of `context/BranchProjector`
   into conversation, leaving context to consume frame messages as inputs.
4. Add `ConversationService.prepare_user_turn` and
   `commit_assistant_result`.
5. Add `execution/ExecutionService` as the Rust app-service entry point for
   `StartExecutionRequest`.
6. Update `run_snapshot::StartRunRequest` or add a wrapper so snapshot
   resolution receives conversation frame identity/content plus agent profile.
7. Move provider/model/tool-loop orchestration out of `core/runtime.rs` into
   execution services while keeping `runtime/RunMachine` as the lower-level
   state machine.
8. Keep compatibility bridge APIs until Swift finishes moving from
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

1. Add Rust `conversation/` and `execution/` module shells around existing
   primitives without changing behavior.
2. Add DTOs and protocols without changing behavior:
   `ConversationDomain`, `ExecutionDomain`, `ConversationRunFrameDTO`,
   `StartExecutionRequestDTO`, and initial bridge client shells.
3. Add Rust `ConversationRunFrame` and map it to
   `ConversationRunFrameDTO`.
4. Extract conversation projection and session operations from
   `AgentRuntimeService` into `ConversationCommandService` and
   `ConversationProjectionStore`.
5. Extract run event reduction from `AgentViewState`/`RuntimeEventReducer` into
   `AgentRunViewModel` and `RuntimeEventStore`.
6. Add `ChatInteractionCoordinator` and route send/cancel/regenerate/edit flows
   through it while preserving existing runtime calls.
7. Move provider/model/agent build APIs under execution services.
8. Replace Swift prompt-text attachment concatenation with attachment refs in
   conversation frames and Rust-side context policy.
9. Add context preview/debug DTOs once execution archive APIs are stable.
10. Delete or shrink `AgentRuntimeService` into bridge adapters after the split.

## 13. Acceptance Criteria

- Swift has separate `ConversationDomain` and `ExecutionDomain` protocols.
- Rust has clear `conversation/` and `execution/` module boundaries or module
  facades, even if storage migration remains incremental.
- Agent configuration APIs are not exposed from conversation APIs.
- Rust conversation APIs produce `ConversationRunFrame`; Rust execution APIs
  consume it.
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
- Swift cannot forge trusted permission/local binding state.
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
