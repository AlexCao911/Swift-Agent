# Swift Conversation Workspace Runtime Interaction Design

## Purpose

This document defines the Conversation Workspace side of the Swift app.

The companion document, `2026-07-06-swift-card-agent-builder-design.md`, focuses on Agent Builder and Native Toolkit. This document covers the runtime product surface where those builder choices become visible during real conversation:

- chat timeline
- session list, forks, edit and regenerate
- tool approval
- user-mediated tool interactions
- run state and recovery
- source/trust disclosure
- agent profile revision binding
- navigation between Chat, Builder, and Model Center

The goal is not to redesign the whole chat product from scratch. The current `ChatView`, `AgentViewModel`, `ConversationViewModel`, `AgentRunViewModel`, and `ChatInteractionCoordinator` already form the first working shell. This design specifies the missing interaction contract that makes Phase 2 native tools usable in real conversations.

## Product Principle

Conversation Workspace is the runtime surface of the agent. It must make interruptions feel like part of the conversation, not like random app state.

```text
User message
  -> assistant thinking / streaming
  -> tool approval card if needed
  -> pending interaction card if user input is needed
  -> tool progress / result card
  -> assistant answer
  -> source and trust disclosure
```

The central product object is a conversation timeline containing both messages and run cards. Messages are durable conversation facts. Run cards are transient or resumable runtime facts tied to `run_id`, `tool_call_id`, `approval_id`, or `pending_interaction_id`.

## Scope

This document owns:

- how Conversation Workspace displays and resolves tool approval
- how user-mediated tools appear in the chat timeline
- how trust/source labels appear during real chat
- how conversations bind to published agent profile revisions
- how Chat navigates to Agent Builder and Model Center
- the Swift MVVM boundaries for those interactions

This document does not own:

- NativeToolManifest field definitions
- final Rust context assembly policy
- full Agent Builder UI
- full Model Center model download/provider design
- C++ local inference engine internals

## Architecture

```text
Conversation Workspace
  ConversationListView
    conversation rows
    revision/status metadata

  ChatView
    message timeline
    run inline cards
    composer
    agent header
    source/trust disclosure

  ConversationWorkspaceViewModel
    combines conversation state, run state, cards, and navigation

  ConversationViewModel
    conversation list projection

  AgentRunViewModel
    run state, runtime events, pending approvals, pending tools

  ChatInteractionCoordinator
    prepare user turn
    start/observe execution
    submit approval/tool/user-interaction results
    commit final assistant result

  LocalNativeToolkit
    executes approved native tools
    provides manifests, permission readiness, and user-mediated broker flows
```

`ConversationWorkspaceViewModel` can be introduced gradually. In the first implementation it may be a set of helpers around the existing `AgentViewModel`; the architectural target is that `ChatView` renders projections and does not execute tools, assemble context, or inspect raw Rust payloads directly.

## Timeline Model

The chat timeline should support two item families:

```text
ConversationTimelineItem
  message(AgentMessageViewState)
  runCard(RunInlineCardViewState)
```

`AgentMessageViewState` remains the model for user, assistant, and tool-result messages.

`RunInlineCardViewState` is the model for runtime interaction:

```text
RunInlineCardViewState
  id
  run_id
  kind
  state
  anchor_message_id
  created_at
  updated_at
```

Initial card kinds:

```text
tool_approval
  The model wants to run a tool and needs user approval.

pending_interaction
  The tool needs foreground user action such as picking files or photos.

tool_progress
  A tool is running or has returned a structured status.

model_setup_required
  The selected local/cloud model is not ready.

revision_notice
  The conversation is pinned to an older/newer agent revision than the current builder draft.

source_disclosure
  A completed assistant answer used external, attachment, OCR, web, memory, or tool sources.
```

The design intentionally avoids making approval or picker requests into normal assistant text. They are interaction cards because they have buttons, lifecycle, recovery state, audit metadata, and run identity.

## Tool Approval In Chat

`NativeToolManifest.approval_policy` is only useful if Conversation Workspace can render and resolve it.

### Card Shape

```text
ToolApprovalCard
  approval_id
  run_id
  tool_call_id
  tool_name
  manifest_title
  risk_level
  approval_policy
  permission_scope
  argument_summary
  sensitivity
  reason
  actions
```

The card should show:

- tool title and short purpose
- why the tool is being requested
- risk level and permission scope
- redacted argument summary
- whether the approval is one-time or session-scoped
- links to inspect full schema/arguments when safe

Primary actions:

- `Allow once`
- `Allow for this chat` when policy permits session scope
- `Deny`

Secondary actions:

- `View details`
- `Open tool settings`

The card must be generated from the same manifest that Builder uses. Chat must not maintain separate display names, risk labels, or approval descriptions.

### State Machine

```text
requested
  -> approving
  -> approved
  -> denied
  -> cancelled
  -> expired
  -> failed
```

Rules:

- A card is keyed by `approval_id` and `tool_call_id`.
- Duplicate replayed events should update the same card, not create another prompt.
- `Allow once` submits an approval scoped to that tool call.
- `Allow for this chat` submits a session/run-scoped grant only if Rust and the manifest both permit it.
- `Deny` submits rejection and leaves a visible audit row in the timeline.
- Approval cards should be disabled while the decision is in flight.
- If the app is relaunched while approval is pending, replay/refresh should restore the card before the run resumes.

### Runtime Mapping

Current Swift already has `AgentRunViewModel.approval`, `ExecutionDomain.approveTool`, and `ChatInteractionCoordinator.approveTool`. The UI contract is:

```text
Rust / ExecutionDomain emits suspended or approval-required boundary
  -> AgentRunViewModel records approval request
  -> Conversation Workspace renders ToolApprovalCard
  -> user chooses action
  -> ChatInteractionCoordinator.approveTool(...)
  -> execution resumes or finalizes the denied path
```

If a tool requires iOS permission and permission is denied, approval is not enough. The approval card should turn into a permission repair card or route to the relevant settings/tool card.

## Pending User Interaction In Chat

Some tools are not approvable background actions. They require the user to choose, capture, scan, or confirm through iOS UI.

Examples:

- `files.pick_document`
- `photos.pick_images`
- `vision.scan_document`
- `speech.record_and_transcribe`
- `calendar.events.user_confirmed_create`

### Card Shape

```text
PendingInteractionCard
  pending_interaction_id
  run_id
  tool_call_id
  interaction_kind
  manifest_title
  instruction
  state
  resumable_payload_summary
  selected_attachment_summary
  expiration
  actions
```

Primary actions:

- `Choose File`
- `Choose Photos`
- `Scan Document`
- `Open System UI`
- `Resume`
- `Cancel`

The card appears inline at the point where the run needs human input. It should not immediately throw the user into a picker without context. The user sees what the agent is asking for, then taps the action.

### State Machine

```text
requested
  -> awaiting_user_action
  -> presenting_system_ui
  -> completed
  -> cancelled_by_user
  -> interrupted
  -> needs_repair
  -> expired
  -> failed
```

Rules:

- System pickers are launched only from user action on the card.
- The picker result is persisted through `NativeAttachmentStore` before returning a tool result to Rust.
- The card changes from requested to completed with a compact selected-item summary.
- If the app is killed or backgrounded while the picker is open, the card is restored from `pending_user_interaction`.
- If restoration cannot continue the picker, the card shows `Resume` when possible or `Cancel` with an interrupted reason.
- The run remains suspended until Swift submits a structured result, cancellation, or failure.

### Example

```text
Assistant is preparing a response
  -> RunInlineCard.photos.pick_images requested
  -> user taps Choose Photos
  -> PhotosPicker opens
  -> NativeAttachmentStore stores 3 selected images
  -> card shows "3 images selected"
  -> Swift submits tool result with attachment ids
  -> Rust resumes execution
  -> assistant answer continues
```

This preserves the feeling of one conversation: the user is not leaving the chat to manage files; the chat asks for exactly the missing human action.

## Trust And Source Disclosure In Chat

Trust levels should not exist only in Builder preview. When a real answer uses external or attachment-derived content, Conversation Workspace should show that fact.

### Disclosure Shape

```text
SourceDisclosure
  assistant_message_id
  run_id
  sources[]
  highest_risk_trust_level
  warnings[]
```

Each source item:

```text
SourceItem
  source_kind: web | file | photo | ocr | share | memory | tool | user | system
  source_id
  display_name
  trust_level
  sensitivity
  attachment_id?
  url?
  excerpt?
```

UI treatment:

- Assistant messages may show compact chips such as `Web`, `File`, `OCR`, `Tool`, `Memory`.
- Expanding the chip shows source names, trust levels, and privacy warnings.
- `untrusted_external_content` should display a calm warning: "External content was used as material, not as instructions."
- Source chips should be attached to the assistant message they influenced, not buried in a debug panel.

The warning should inform without making the product feel broken. The tone is: "This answer used outside material; check the source when it matters."

### Runtime Mapping

Rust remains the authority for final context assembly and trace. Swift should display trust/source data from runtime events, context trace, or debug archive projections. Swift should not infer source usage by scraping assistant text.

Minimum acceptable first version:

- show source/trust disclosure when a tool result or context trace includes explicit source links
- show `untrusted_external_content` warning for web/file/OCR/share-derived sources
- allow a debug/details expansion for exact source metadata

## Conversation Revision Binding

Runs must bind to immutable published agent revisions.

### New Conversation

When the user starts a new conversation:

```text
new chat
  -> resolve selected agent
  -> use latest published profile_revision_id
  -> store conversation revision binding
  -> prepare user turn with that profile_revision_id
```

If the agent has unpublished local changes, the app should show a choice:

- `Use published version`
- `Publish changes first`
- `Continue editing`

The first version can default to latest published revision and show a non-blocking draft indicator.

### Existing Conversation

Existing conversations stay pinned:

```text
conversation_id
  agent_profile_id
  profile_revision_id
  revision_display_name
  revision_created_at
```

Conversation List should eventually show:

- agent name
- revision badge when useful
- stale revision notice if the current published revision is newer

Chat Header should show:

- active agent name
- profile revision label
- model readiness
- quick actions: edit agent, start with latest, open run details

Editing an agent from a conversation opens Builder at the referenced revision. Publishing creates a new revision and does not mutate active or historical conversations. To use the new revision, the user starts a new chat or forks the current conversation onto the new revision.

## Builder And Chat Navigation

The relationship should be explicit:

```text
Chat Header
  -> Edit Agent
     opens Builder for the current profile revision

Builder Publish
  -> creates new profile_revision_id
  -> returns to Builder or starts a new chat with that revision

Chat Revision Notice
  -> Start new chat with latest revision
  -> Fork this conversation using latest revision
```

Rules:

- Chat must not hot-swap the agent revision during an active run.
- Returning from Builder should not change the current conversation unless the user explicitly starts/forks with the new revision.
- A user should always be able to answer: "Which agent version is this conversation using?"

## Model Center Integration

Model Center is a separate product area, but Conversation Workspace needs a small runtime contract.

Chat should display model readiness when it blocks conversation:

```text
ModelReadinessCard
  active_provider_or_model
  readiness_state
  reason
  actions
```

Readiness states:

```text
ready
  selected local or cloud inference path can run

missing_local_model
  local engine is available but weights are not downloaded

missing_cloud_credentials
  cloud provider needs API key or account setup

engine_unavailable
  selected local engine is not compiled/available on this device

unsupported_region_or_policy
  provider or tool is unavailable in the current region/policy context
```

Actions:

- `Open Model Center`
- `Choose another model`
- `Use cloud/local alternative` when configured

Conversation Workspace does not download models directly. It routes to Model Center and retries once readiness changes.

## MVVM Boundaries

```text
ConversationWorkspaceViewModel
  Owns timeline projection, inline run cards, header metadata, and navigation intents.

ConversationViewModel
  Owns session list projection and grouping.

AgentRunViewModel
  Owns run phase, event replay, pending approval/tool/interaction summaries.

RunInlineCardReducer
  Converts runtime events and pending interaction records into card state.

ToolApprovalCardViewModel
  Formats approval request from NativeToolManifest + runtime approval DTO.

PendingInteractionCardViewModel
  Formats and drives user-mediated interaction cards through NativeInteractionBroker.

TrustDisclosureViewModel
  Formats source/trust data for assistant messages.

ConversationRevisionViewModel
  Formats profile revision badge, stale revision notices, and revision navigation actions.

ModelReadinessViewModel
  Formats selected provider/model readiness and Model Center navigation actions.
```

View rules:

- `ChatView` renders timeline items and sends user actions to view models.
- `ChatView` does not call iOS pickers directly except through `NativeInteractionBroker`.
- `ChatView` does not decide approval policy.
- `ChatView` does not assemble context or infer source trust from message text.
- Runtime events and recovered pending interactions must be replayable into the same visible state.

## Data Flows

### Send Message

```text
User sends message
  -> ConversationWorkspaceViewModel checks model readiness
  -> ChatInteractionCoordinator.prepareUserTurn
  -> user message appears
  -> ChatInteractionCoordinator.startRun(profile_revision_id)
  -> observeEvents replay + live tail
  -> MessageTimelineReducer updates messages
  -> RunInlineCardReducer updates cards
```

### Approval

```text
Rust run suspends for approval
  -> observeEvents / pending approval refresh
  -> ToolApprovalCard appears
  -> user chooses Allow/Deny
  -> ChatInteractionCoordinator.approveTool
  -> run resumes or records denial
  -> card becomes approved/denied
```

### User-Mediated Interaction

```text
Rust run waits for a user-mediated tool
  -> PendingInteractionCard appears
  -> user taps card action
  -> NativeInteractionBroker opens system UI
  -> NativeAttachmentStore persists selected result
  -> Swift submits tool result or cancellation
  -> run resumes
```

### Recovery

```text
App launch / foreground
  -> load active conversation
  -> replay run events from durable sequence
  -> load pending approvals/interactions
  -> restore inline cards
  -> user can resume/cancel without losing run identity
```

## Phasing

### Phase 1: Runtime Inline Card Foundation

- Add timeline support for `message` and `runCard`.
- Add RunInlineCard projection from runtime events.
- Add basic run status card for waiting tool, suspended, failed, cancelled.
- Keep current message streaming behavior.

### Phase 2: Tool Approval UI

- Render ToolApprovalCard from approval DTO + NativeToolManifest.
- Support allow once, allow for chat when permitted, deny.
- Ensure replayed pending approvals restore the same card.
- Add audit/status row after approval or denial.

### Phase 3: Pending Interaction UI

- Render PendingInteractionCard for files/photos first.
- Route user action through NativeInteractionBroker.
- Persist selected attachments through NativeAttachmentStore.
- Recover interrupted cards after app relaunch.

### Phase 4: Trust And Source Disclosure

- Attach source/trust chips to assistant messages.
- Show `untrusted_external_content` warnings for web/file/OCR/share-derived content.
- Add expandable source details.

### Phase 5: Revision And Navigation

- Bind new conversations to latest published `profile_revision_id`.
- Show profile revision metadata in Chat Header and Conversation List.
- Add Chat -> Builder edit navigation.
- Add start/fork with latest revision flow.

### Phase 6: Model Readiness Integration

- Add ModelReadinessCard when provider/model setup blocks send or run.
- Route to Model Center.
- Retry or revalidate when model readiness changes.

## Acceptance Criteria

- Conversation Workspace can show runtime interaction cards inline with messages.
- Tool approval is visible, actionable, replayable, and derived from `NativeToolManifest`.
- User-mediated tools such as Files and Photos appear as pending interaction cards before opening system UI.
- Pending interactions can be recovered, resumed, cancelled, or failed cleanly after app interruption.
- Assistant messages can display source/trust disclosure when external or attachment-derived content was used.
- `untrusted_external_content` is visible in real chat, not only in Builder preview.
- New conversations bind to a specific `profile_revision_id`.
- Existing conversations keep their original revision binding.
- Conversation List and Chat Header can show agent revision metadata and stale revision notices.
- Chat can navigate to Builder without mutating the current conversation revision.
- Chat can route model setup problems to Model Center without owning model download/provider setup.
- Views render projected state and route actions; they do not execute tools, assemble context, or infer security policy locally.
