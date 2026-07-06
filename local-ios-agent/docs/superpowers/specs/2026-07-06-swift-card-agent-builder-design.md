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

### Apple System Capability APIs

The next Swift stage should be understood as two parallel workstreams:

```text
1. Tools Toolkit: wrap iOS system capabilities as safe, permissioned agent tools.
2. App Product: build the visible Conversation Workspace and card-based Agent Builder.
```

App Intents, Shortcuts, Siri, Spotlight, widgets, extensions, and Apple framework APIs are not just "entry points" into the app. In this design, they are system capability surfaces that Swift can wrap into tool families when the platform allows it.

Useful system capability surfaces:

- App Intents / App Shortcuts: expose selected app actions to Shortcuts/Siri and, where useful, model a shortcut-facing action surface.
- Siri / Spotlight / widgets / controls: discover or trigger high-value app actions through the same thin intent layer.
- Share Extension: receive selected text/files/URLs as tool or conversation inputs.
- Document Picker / Files integration: allow user-selected files to become tool inputs.
- PhotosUI / PhotoKit: user-selected images as tool or context inputs.
- EventKit / Reminders: calendar and reminder tools.
- Contacts, CoreLocation, AVFoundation, Speech, VisionKit, UserNotifications: optional native tool families gated by permissions.
- App Clips: future public mini-app/acquisition surface, not the first implementation path for the local agent product.

Important boundary:

```text
System Capability APIs -> Swift Tools Toolkit -> Rust tool result
```

The model does not call Apple APIs directly. Swift wraps allowed system capabilities as tool adapters, applies permission and approval rules, and returns structured results to Rust.

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

  System Capability Toolkit
    App Intents / Shortcuts adapters
    Share / Files / Photos adapters
    Calendar / Reminders adapters
    permission and approval UX
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

### System Capability Toolkit

System capability adapters should stay thin and call app/domain services. They should not become business logic containers.

Some adapters expose app actions outward through App Intents and Shortcuts. Other adapters wrap iOS frameworks inward as model-callable native tools. Both should share permission, schema, availability, and audit metadata through `LocalNativeToolkit`.

First App Intents:

- Open Agent Builder.
- Start Chat with Agent.
- Continue Conversation.
- Capture Text to Agent.
- Open Model Center.

First system-level tool adapters:

- Calendar search through EventKit.
- Reminder creation through EventKit reminders.
- File import/read through user-selected documents.
- Photo import through PhotosUI user selection.
- Share input capture through Share Extension.
- Permission/status inspection through app-local metadata.

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

### System Capability Action

```text
Apple system API
  -> Swift system adapter
  -> LocalNativeToolkit permission/approval
  -> NativeTool result or app route
  -> Rust execution or Swift app workflow
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

### Phase 4: System Capability Adapters

- Replace page-heavy shortcuts with action-first intents where an outward system action is useful.
- Add `AgentEntity` and `ConversationEntity`.
- Add Open Agent Builder, Start Chat with Agent, Continue Conversation, Capture Text to Agent.
- Keep the same toolkit metadata shape for inward native tools and outward App Intent actions.

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
- iOS system APIs are wrapped as toolkit capabilities rather than scattered through views.
