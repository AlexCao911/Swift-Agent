# Swift Card-Based Agent Builder and Native Tool Architecture

## Purpose

This document defines the next Swift app stage for Local Agent.

The app should become a product-level agent workspace, not a thin Rust debug shell. The two primary product surfaces are:

1. Conversation Workspace: chat, sessions, forks, editing, streaming runs, tool approval, and run state.
2. Agent Builder: a card-based workspace where users compose agents from tool cards and context pipeline cards.

The center of gravity is agent engineering:

```text
Agent = Tool Belt + Context Pipeline
```

Prompt, memory, skills, model settings, and runtime options matter, but they are supporting pieces around those two core surfaces.

## Research Notes

### Apple System Surfaces

The app should use App Intents and Shortcuts as system entry points, not as the internal tool runtime. Apple positions App Intents as the way to expose app actions and content to Shortcuts, Siri, Spotlight, widgets, and controls. The first pass should expose a small set of useful verbs and narrow entities, not mirror every app screen.

Useful system surfaces:

- App Intents: start chat, open an agent, open Agent Builder, continue a conversation, capture text into an agent.
- App Shortcuts: discoverable user-facing shortcuts for the above actions.
- Siri and Spotlight: route into high-value app actions and app entities.
- Widgets and controls: later reuse the same intent/entity layer for quick entry points.
- Share Extension: later feed selected text/files/URLs into an agent.
- Document Picker / Files integration: allow user-selected files to become tool inputs.
- PhotosUI / PhotoKit: user-selected images as tool or context inputs.
- EventKit / Reminders: calendar and reminder tools.
- Contacts, CoreLocation, AVFoundation, Speech, VisionKit, UserNotifications: optional native tool families gated by permissions.
- App Clips: future public mini-app/acquisition surface, not the first implementation path for the local agent product.

Important boundary:

```text
System Intent Surface != Agent Tool Runtime
```

System intents let the user or OS invoke app actions. Agent tools are actions the model may request during a run and must pass app permission, approval, and audit rules.

References:

- Apple App Intents: https://developer.apple.com/documentation/appintents
- Making actions and content discoverable: https://developer.apple.com/documentation/appintents/making-actions-and-content-discoverable-and-widely-available
- App Clips: https://developer.apple.com/documentation/appclip
- EventKit: https://developer.apple.com/documentation/eventkit
- PhotosUI: https://developer.apple.com/documentation/photosui
- File Provider: https://developer.apple.com/documentation/fileprovider

## Architecture

```text
Swift App
  Conversation Workspace
    ChatView / ConversationViewModel / AgentRunViewModel
    ChatInteractionCoordinator
    Rust ConversationDomain + ExecutionDomain

  Agent Builder
    Card-based canvas
    Tool Belt
    Context Pipeline
    Inspector
    Validation

  Model Center
    Local model selection/download
    Cloud provider settings
    Swift HostInference routing
    C++ local inference engines

  Native Tool Center
    LocalNativeToolkit
    Permission gateway
    Tool catalog
    Tool executor
    Rust tool schema export

  System Intent Surface
    App Intents
    App Shortcuts
    AppEntity / EntityQuery
    one app routing handoff
```

Rust remains the agent kernel. It owns conversation frames, execution snapshots, final context assembly, tool routing semantics, security metadata, and durable run behavior.

C++ remains the local inference backend. It owns compiled local engine adapters such as llama.cpp and LiteRT.

Swift owns product composition, user choices, permissions UX, native tool adapters, model download/settings UX, and the visible builder experience.

## Native Toolkit Layer

The existing `LocalNativeToolkit` is the right home for platform tools. It should grow carefully into a host-tool runtime:

```text
LocalNativeToolkit
  NativeTool
  NativeToolSchema
  NativeToolCatalog
  NativeToolExecutor
  NativePermissionGateway
  NativeToolSchemaExport
  NativeToolTestHarness
```

### NativeTool

A native tool is a model-callable host action.

Each tool must declare:

- stable tool name
- user-facing title and description
- JSON input schema
- output shape
- capability id
- permission scope
- risk level: read-only, confirmation required, destructive
- sensitivity of returned data
- retention policy for results
- availability on current platform/device

The model never calls iOS frameworks directly. Rust requests a tool call; Swift receives the tool request; `LocalNativeToolkit` executes the platform adapter; the result returns to Rust as a structured tool result.

### Tool Families

First implementation families:

- Calendar: search events, inspect event details.
- Reminders: create reminder, search reminders.
- Files: import/read user-selected files, summarize file metadata.
- Photos: import user-selected images.
- Share Input: receive text/URL/file from share sheet into a conversation or agent.
- Notifications: schedule local reminder-style notification after explicit approval.
- Clipboard: read/write only through explicit user action or visible confirmation.
- App Meta: list enabled native tools, permission status, runtime availability.

Later families:

- Contacts.
- Location.
- Camera / microphone.
- Speech transcription.
- Vision document scan.
- HealthKit or HomeKit only if the product has a clear user-facing need.

### Permission Gateway

Tools should not own permission UX directly. They call a shared permission gateway:

```text
NativePermissionGateway
  status(scope)
  request(scope)
  openSettings(scope)
```

The gateway translates high-level scopes such as `calendar.events`, `reminders`, `photos.selected`, or `files.user_selected` into Apple authorization APIs and Info.plist requirements.

Agent Builder uses the same gateway to show readiness badges before a user publishes an agent.

### System Intent Surface

App Intents should stay thin and call app/domain services. They should not become a second tool runtime.

First App Intents:

- Open Agent Builder.
- Start Chat with Agent.
- Continue Conversation.
- Capture Text to Agent.
- Open Model Center.

First App Entities:

- `AgentEntity`: id, display name, short description.
- `ConversationEntity`: id, title, last updated.

Guidance:

- Long-running local inference should open the app rather than try to complete inline.
- Inline intents should be limited to lightweight capture/routing actions.
- Use one `AppIntentRouter` handoff path into the main scene.
- Do not expose every screen as an intent.

App Clips are deferred. They may eventually support a lightweight public agent preview or shared-agent launch path, but they are not suitable for the local-first full builder, local model downloads, or native tool execution surface.

## Agent Builder Product Model

Agent Builder should feel like a canvas of cards, not a settings form.

```text
Left: Component Library
  Tools
  Context Blocks
  Skills
  Memory Blocks
  Prompt Blocks

Center: Agent Canvas
  Tool Belt
  Context Pipeline
  Basic Agent Identity

Right: Inspector
  Selected card configuration
  Permission state
  Schema preview
  Context preview
  Validation issues
```

### Primary Cards

Tool cards:

- describe what the agent can do
- show required permission
- show risk level
- expose configuration such as confirmation policy
- preview input/output schema
- support a test action

Context cards:

- define what enters each LLM call
- are ordered visually in a pipeline
- show token budget and privacy impact
- can be previewed before publish

### Context Pipeline v1

Initial context cards:

```text
System Prompt
Agent Instructions
Conversation History
Memory Retrieval
Skill Instructions
Tool Schemas
Tool Results
User Message
```

Swift lets the user configure the pipeline. Rust remains responsible for final assembly, budgeting, filtering, and trace output.

The first version should ship with presets:

- Focused: recent history, compact tool schemas, conservative memory.
- Full Context: more history, richer tool schemas, memory enabled.
- Private: memory off, minimal persisted context, stricter tool result retention.

Custom freeform context pipelines can come later.

### Supporting Cards

Supporting cards include:

- Skill card: reusable workflow/instruction bundle plus required capabilities.
- Memory card: extraction, selection, and injection policy at a user-understandable level.
- Prompt card: identity, rules, output style.
- Model/runtime card: default model, local/cloud preference, temperature, max tokens.

These cards should not compete visually with Tool Belt and Context Pipeline.

## MVVM Boundaries

```text
AgentBuilderViewModel
  owns screen state and card selection
  coordinates draft loading/saving/validation

AgentDraftStore
  persists local unsaved builder draft
  syncs published draft through Rust bridge

ToolCatalogViewModel
  maps NativeToolCatalog + Rust capability metadata into Tool Cards

ContextPipelineViewModel
  manages context card order and user-facing options
  asks Rust for validation/preview, does not assemble final model input

CardInspectorViewModel
  owns selected-card editor state
  validates local fields before draft save

AgentValidationService
  combines Rust draft validation, native permission readiness, model readiness
```

The existing `AgentBuilderViewModel` can evolve from readiness-only into the screen coordinator, but it should not absorb tool execution, permission implementation, or context assembly.

## Data Flow

### Publish Agent

```text
User edits cards
  -> AgentDraftStore
  -> AgentValidationService
       Rust validateDraft
       Native permission readiness
       Model/runtime readiness
  -> Publish AgentProfile
  -> Conversation Workspace can start run with profile id
```

### Run Agent

```text
Conversation Workspace
  -> Rust prepare user turn
  -> Rust start execution
  -> Rust requests tool call
  -> Swift LocalNativeToolkit executes native tool
  -> Rust resumes execution
  -> Rust commits final assistant result
```

### System Shortcut

```text
Shortcut / Siri / Spotlight
  -> AppIntent
  -> AppIntentRouter
  -> Main app route
  -> Conversation Workspace or Agent Builder
```

## What Not To Build Now

- A full marketplace.
- Executable user-downloaded skill code.
- Arbitrary user-defined native tools.
- Arbitrary shortcut introspection or execution as a model tool.
- App Clip product flow.
- Full visual node graph editor.
- Swift-side final model context assembly.
- Rust-side model download/provider management.

## Phasing

### Phase 1: Native Toolkit Catalog

- Extend tool schema metadata for card rendering.
- Add permission gateway abstraction.
- Add platform availability and readiness reporting.
- Keep existing calendar/reminder/meta tools as first real examples.

### Phase 2: Agent Builder Cards

- Build card-based Agent Builder screen.
- Render Tool Belt and Context Pipeline as the main canvas.
- Add inspector for selected card.
- Save draft locally and validate through Rust bridge.

### Phase 3: Context Preview

- Add Rust-backed context preview/trace endpoint if needed.
- Show pipeline preview in Swift without letting Swift assemble final model input.
- Add presets: Focused, Full Context, Private.

### Phase 4: System Intents Refresh

- Replace page-heavy shortcuts with action-first intents.
- Add `AgentEntity` and `ConversationEntity`.
- Add Open Agent Builder, Start Chat with Agent, Continue Conversation, Capture Text to Agent.

### Phase 5: Tool Expansion

- Add Files and Photos tools with user-selected inputs.
- Add Share Extension capture path.
- Add notification/clipboard tools only with explicit user confirmation.

## Acceptance Criteria

- User can create or edit an agent from cards.
- Tool Belt and Context Pipeline are the visual center of the builder.
- Native tools are listed from `LocalNativeToolkit`, not hardcoded in views.
- Tool cards show permission, risk, and availability.
- Context cards can be reordered/configured through presets.
- Swift can validate an agent draft before publishing.
- Rust remains final authority for agent profile validation and execution context assembly.
- App Intents expose useful actions, not a mirror of every screen.
