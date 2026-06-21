# Local iOS Agent Chat Experience Design

Date: 2026-06-22
Status: Draft for user review
Project path: `/Users/alexandercou/Projects/Alex-agent/local-ios-agent`

## 1. Purpose

This design upgrades the Local Agent iOS frontend from a minimal streaming chat
view into a stable Claude-like native chat surface. The goal is to support real
local model output, long streaming responses, reasoning blocks, conversation
management, branch and fork workflows, and basic attachments while preserving
the existing MVVM shape and the Rust runtime as the source of agent truth.

The immediate user-visible problems are:

- Model reasoning is rendered as raw `<think>` text inside the answer bubble.
- Long local-model output can appear to stop abruptly or overload the SwiftUI
  update path.
- The app has no first-class conversation list, new chat flow, branch/fork
  controls, edit-resend, regenerate, or continue-generation actions.
- The composer only supports plain text, not photos or links.

## 2. Product Scope

The first product-quality version should support:

- A reasoning block renderer for `<think>...</think>` output.
- Stable streaming for long responses, including partial output retention.
- Clear run states: generating, stopped, reached token limit, failed, and
  cancelled.
- New chat, conversation switching, and a lightweight conversation list.
- Fork from a message, regenerate from the last user turn, and edit-resend.
- Copy message, stop generation, and continue generation actions.
- Photo and link attachments in the composer.
- Provider/model menu remains available but does not dominate the chat UI.

The UI should feel closer to Claude's mobile app than to iMessage. It should
favor readable assistant output, message actions, conversation controls, and
attachment affordances over pure bubble minimalism.

## 3. Non-Goals

This design does not include:

- Cloud sync or account identity.
- Full-text conversation search.
- Cross-device history.
- A plugin marketplace.
- Rich document upload parsing.
- Voice mode.
- Background always-on assistant behavior.
- Perfect Claude feature parity.

## 4. Current State and Constraints

The current SwiftUI state model is intentionally thin:

```swift
struct AgentMessageViewState {
    let id: String
    let role: AgentMessageRole
    var text: String
    var isStreaming: Bool
}
```

This is not expressive enough for reasoning, tool blocks, attachments, message
actions, branch metadata, or partial streaming diagnostics.

The current reducer appends assistant text directly to `message.text` for every
stream event. This makes the UI simple, but it couples runtime token cadence to
SwiftUI invalidation cadence.

The runtime already has useful lower layers:

- `RuntimeEventDTO.parentId`
- `RuntimeEventDTO.blobRefs`
- Rust `SendMessageInput.parent_event_id`
- Rust active branch projection through the event store
- SQLite blob and branch summary tables

However, Swift currently sends user messages with `parentEventId: nil`, so the
frontend does not expose branch or fork workflows yet.

## 5. Architecture

The frontend should remain MVVM, but the current `ChatView` and
`AgentViewModel` should stop carrying all chat behavior directly.

```text
SwiftUI Views
  -> ChatViewModel
  -> ConversationService
  -> RuntimeStreamService
  -> AttachmentService
  -> LocalAgentBridge
  -> Rust Core Runtime
```

### 5.1 SwiftUI Views

Views render state and forward user intents. They do not parse model output,
own runtime rules, or know about Rust details.

Primary views:

- `ChatView`
- `ConversationListView`
- `MessageRowView`
- `MessageContentView`
- `ReasoningBlockView`
- `ComposerView`
- `AttachmentShelfView`
- `MessageActionsMenu`

### 5.2 ChatViewModel

`ChatViewModel` owns page-level state and user intents:

- Bootstrap the app.
- Send a draft.
- Stop generation.
- Continue generation.
- Regenerate a response.
- Edit and resend a message.
- Fork from a message.
- Select a conversation.
- Start a new conversation.
- Add or remove draft attachments.

It delegates runtime calls and local file handling to services.

### 5.3 RuntimeStreamService

`RuntimeStreamService` owns stream consumption and buffering. It converts raw
runtime events into view-state updates at a controlled cadence.

Responsibilities:

- Start a streaming turn.
- Consume `RuntimeEventDTO` values.
- Coalesce assistant text deltas.
- Flush buffered content every 30 to 60 ms.
- Preserve partial output on cancellation or failure.
- Surface structured terminal state to the view model.

### 5.4 ConversationService

`ConversationService` owns conversation and branch operations:

- Create session.
- List sessions.
- Load a session branch.
- Fork from a message by sending with `parentEventId`.
- Regenerate from the previous user message.
- Continue from the active leaf.

It uses RuntimeClient APIs. Where a required runtime API is missing, this design
adds it explicitly rather than hiding session-tree behavior in SwiftUI.

### 5.5 AttachmentService

`AttachmentService` owns attachment preparation:

- Import selected Photos assets into the app container.
- Validate local image size and MIME type.
- Store attachment metadata.
- Normalize pasted URLs.
- Build link attachments.
- Produce draft attachment records for the composer.

The service does not decide how attachments enter model context. That belongs to
the runtime/provider boundary.

## 6. Message Model

Replace the single `text` field with structured content parts.

```swift
struct AgentMessageViewState: Equatable, Identifiable, Sendable {
    let id: String
    let sessionId: String
    let parentId: String?
    let role: AgentMessageRole
    var parts: [MessagePartViewState]
    var attachments: [AttachmentViewState]
    var streaming: MessageStreamingState
    var branch: MessageBranchViewState?
}
```

```swift
enum MessagePartViewState: Equatable, Identifiable, Sendable {
    case text(TextPartViewState)
    case reasoning(ReasoningPartViewState)
    case tool(ToolPartViewState)
    case error(ErrorPartViewState)
}
```

The message model should keep enough event metadata to support fork actions.
Every assistant and user message should be traceable back to its runtime event
id.

## 7. Reasoning Block Rendering

The app should parse model output into reasoning and answer parts. The parser
must be incremental because streaming can split tags across deltas.

Input examples:

```text
<think>
I should inspect the request.
</think>
The answer is...
```

Expected parts:

```text
ReasoningPart("I should inspect the request.")
TextPart("The answer is...")
```

Rendering rules:

- Reasoning is shown in a visually distinct block inside the assistant message.
- The block is collapsed by default after completion.
- While streaming, it can show "Thinking..." and expand automatically only in
  debug mode.
- Empty reasoning tags produce no visible block.
- Unclosed reasoning tags remain in a streaming reasoning block instead of
  leaking raw tags.
- Raw `<think>` and `</think>` should never appear in the normal assistant
  answer.

The parser should be a pure Swift type with unit tests. It should not depend on
SwiftUI.

## 8. Long Output and Stream Stability

Long output stability requires changes at three layers.

### 8.1 Runtime Configuration

The current local model smoke-style configuration often uses
`max_new_tokens: 128`. That is useful for smoke tests but too small for normal
interactive chat. The app should expose or document a debug setting for local
model generation length. For interactive use, a starting value around 512 to
1024 tokens is a safer default.

### 8.2 Stream Buffering

The app should not mutate SwiftUI state for every token. It should buffer text
deltas and flush on a short interval.

Recommended defaults:

```text
flush interval: 50 ms
maximum buffered characters before immediate flush: 512
```

The buffer should flush immediately when receiving:

- Assistant message completed
- Run failed
- Run cancelled
- Tool call requested
- Tool result message

### 8.3 Terminal State

The UI should distinguish:

- Completed
- Cancelled by user
- Failed with error
- Stopped because token limit was likely reached
- Waiting for tool

Partial text should remain visible in all non-completed terminal states.
The composer should offer "Continue" when the last assistant message appears
truncated or when the user explicitly asks to continue.

## 9. Conversation and Branch Design

The Rust runtime is event-sourced, so branch and fork operations should be based
on runtime event ids rather than copying text in Swift.

### 9.1 New Chat

`New Chat` creates a fresh runtime session and clears the active conversation
view. The old session remains in the conversation list.

### 9.2 Conversation List

The first version can show:

- Session title derived from the first user message.
- Last updated ordering.
- Active provider indicator if available.
- Basic empty state.

This requires a Swift-facing DTO beyond plain `sessionIds()`, because the UI
needs display metadata.

### 9.3 Fork From Message

Forking from a message means:

1. User selects "Fork from here" on a message.
2. The app sets the draft target parent to that event id.
3. The next send calls runtime with `parentEventId`.
4. Rust builds context from the selected branch.
5. UI marks the new path as the active branch.

### 9.4 Regenerate

Regenerate uses the parent id of the previous assistant response and resends
from that point. It should not overwrite the old assistant event. It creates a
sibling branch.

### 9.5 Edit and Resend

Edit and resend creates a branch from the edited user message's parent. The
edited text is a new user event, not a mutation of the historical event.

## 10. Attachments

The composer should support text, photos, and links.

```swift
struct UserDraftViewState: Equatable, Sendable {
    var text: String
    var attachments: [AttachmentDraftViewState]
    var targetParentEventId: String?
}
```

### 10.1 Photos

The first version should support one or more images selected from Photos:

- Copy image data into the app container.
- Create attachment metadata with local URL, MIME type, byte count, and kind.
- Render thumbnails above the composer.
- Include image metadata and blob refs in the user message.

For MiniCPM-V multimodal inference, the runtime/provider layer should consume
the image through an explicit multimodal request path. SwiftUI should not call
llama.cpp directly.

### 10.2 Links

The first version should support pasted URLs:

- Normalize and validate URL.
- Render a compact link chip.
- Include URL text in the model-visible message.
- Store link metadata in message attachments.

Network preview fetching is not required in the first version.

## 11. Error Handling

Errors should be actionable and scoped.

Examples:

- Provider not linked: show "Local model backend is not linked for this build."
- Model load failed: show model path and suggest checking the Xcode scheme.
- Token limit reached: show "Response stopped at the generation limit" with a
  Continue action.
- Runtime stream failed: preserve partial content and show a retry action.
- Attachment import failed: show a composer-level error without failing the
  conversation.

The UI should avoid presenting every error as "connection interrupted".

## 12. UI Interaction Model

The primary screen should include:

- Conversation title in the navigation bar.
- New chat button.
- Conversation list button.
- Provider/model menu.
- Stop button while generating.
- Scrollable message list.
- Message action menu on long press or trailing button.
- Composer with text input, attachment button, send button, and stop/continue
  state.

Assistant messages should support:

- Copy
- Regenerate
- Continue
- Fork from here
- Show/hide reasoning
- Show raw event in debug mode

User messages should support:

- Copy
- Edit and resend
- Fork from here

## 13. Testing Strategy

Testing should be layered.

### 13.1 Parser Tests

Unit test the reasoning parser:

- Complete reasoning block.
- Empty reasoning block.
- Reasoning tag split across chunks.
- Unclosed reasoning block.
- Multiple reasoning blocks.
- Normal text before and after reasoning.

### 13.2 Reducer Tests

Test that runtime events produce structured message parts:

- Assistant started.
- Text deltas appended through buffer flush.
- Reasoning parts stay separate from answer text.
- Completion marks message as not streaming.
- Failure preserves partial content.

### 13.3 ViewModel Tests

Test user intents:

- New chat creates and selects a session.
- Send uses active parent event when forking.
- Regenerate sends from the correct parent.
- Edit-resend creates a new user event instead of mutating history.
- Attachment import failure is scoped to the composer.

### 13.4 Runtime Bridge Tests

Add bridge tests only when new runtime APIs are introduced:

- List conversation summaries.
- Load active branch.
- Send with parent event id.
- Return blob refs.

### 13.5 UI Smoke Tests

Add focused UI smoke coverage:

- Long assistant output remains scrollable.
- Reasoning block collapses and expands.
- New chat clears the visible message list.
- Conversation switch restores messages.

## 14. Implementation Phases

### Phase 1: Reasoning and Message Parts

Introduce message content parts and the incremental reasoning parser. Keep the
existing chat screen layout mostly intact.

### Phase 2: Stream Buffer and Terminal States

Add buffered stream updates, better run state labels, partial output retention,
and continue-generation affordance.

### Phase 3: Conversation List and New Chat

Expose the minimum runtime API needed to list, create, and switch sessions.

### Phase 4: Branch, Fork, Regenerate, Edit-Resend

Use runtime parent event ids for branch operations. Do not clone messages in
Swift as a substitute for runtime branches.

### Phase 5: Photos and Links

Add composer attachments, local image import, link chips, and message attachment
rendering. Connect image attachments to the runtime/provider layer through an
explicit multimodal path.

## 15. Acceptance Criteria

This design is accepted when:

- `<think>` output is rendered as a reasoning block and not leaked as raw tags.
- A long local-model response can stream without freezing the UI.
- Partial output remains visible after cancel, failure, or token-limit stop.
- The user can create a new chat and switch between chats.
- The user can fork from a message and regenerate an assistant response.
- The user can edit a previous user message and resend as a new branch.
- The composer can attach photos and links.
- SwiftUI remains decoupled from Rust and llama.cpp implementation details.
- Unit tests cover parser, reducer, stream buffering, and view-model intents.
