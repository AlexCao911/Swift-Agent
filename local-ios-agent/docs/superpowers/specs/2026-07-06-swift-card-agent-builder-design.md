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
- AppIntent `openAppWhenRun`: https://developer.apple.com/documentation/appintents/appintent/openappwhenrun
- App Clips: https://developer.apple.com/documentation/appclip
- EventKit: https://developer.apple.com/documentation/eventkit
- EKEventStore: https://developer.apple.com/documentation/eventkit/ekeventstore
- PhotosUI: https://developer.apple.com/documentation/photosui
- PhotosPicker: https://developer.apple.com/documentation/photosui/photospicker
- File Provider: https://developer.apple.com/documentation/fileprovider
- UIDocumentPickerViewController: https://developer.apple.com/documentation/uikit/uidocumentpickerviewcontroller
- App extensions: https://developer.apple.com/documentation/technologyoverviews/app-extensions
- Uniform Type Identifiers: https://developer.apple.com/documentation/UniformTypeIdentifiers
- Contacts: https://developer.apple.com/documentation/contacts/cncontactstore
- Core Location: https://developer.apple.com/documentation/corelocation/cllocationmanager
- User Notifications: https://developer.apple.com/documentation/usernotifications/unusernotificationcenter
- AVFoundation capture authorization: https://developer.apple.com/documentation/avfoundation/requesting-authorization-to-capture-and-save-media
- Speech recognition: https://developer.apple.com/documentation/speech/sfspeechrecognizer
- VisionKit: https://developer.apple.com/documentation/visionkit

### Tool Design Principles From Apple APIs

Apple's APIs imply three tool modes. The toolkit should encode this explicitly instead of pretending every tool is a silent background function.

```text
Background tool
  Runs without presenting UI after permission and approval are satisfied.
  Example: calendar.search_events.

User-mediated tool
  Requires foreground UI or a system picker.
  Example: files.pick_document, photos.pick_images, vision.scan_document.

System action adapter
  Exposes or routes a Local Agent action through App Intents, Shortcuts, Siri, Spotlight, widgets, or controls.
  Example: Start Chat with Agent, Capture Text to Agent.
```

This prevents a model tool call from silently crossing iOS privacy or UI boundaries. A user-mediated tool may produce a pending interaction event; the app presents the picker or permission sheet; the selected result is returned to Rust as a normal tool result.

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
  NativeToolManifest
  NativeToolCatalog
  NativeToolExecutor
  NativePermissionGateway
  NativeInteractionBroker
  NativeAttachmentStore
  NativeToolSchemaExport
  NativeToolTestHarness
```

### NativeToolManifest

`NativeToolManifest` is the single source of truth for a tool's product card, Rust schema export, and runtime approval behavior.

```text
NativeToolManifest
  -> Tool Card rendering
  -> Rust tool schema export
  -> Runtime approval policy
  -> Native permission readiness
  -> Audit and retention metadata
```

This avoids a dangerous split where Builder shows one risk or permission policy while runtime execution uses another.

Each manifest must declare:

- stable tool name
- user-facing title and description
- JSON input schema
- output shape
- capability id
- backing Apple framework or app service
- tool mode: background, user-mediated, or system action adapter
- permission scope
- required Info.plist privacy keys or entitlements
- whether foreground UI is required
- risk level: read-only, confirmation required, destructive
- approval policy: never, per-call, per-session, or always-deny-until-configured
- sensitivity of returned data
- retention policy for results
- availability on current platform/device
- audit label and result summary policy

`NativeToolSchema` can remain as the bridge-facing projection, but Swift code should not hand-maintain separate card, schema, and approval definitions.

### NativeTool

A native tool is a model-callable host action.

Each `NativeTool` must expose its manifest and implement execution:

```text
NativeTool
  manifest: NativeToolManifest
  execute(argumentsJson) -> ToolResultDTO
```

The model never calls iOS frameworks directly. Rust requests a tool call; Swift receives the tool request; `LocalNativeToolkit` executes the platform adapter; the result returns to Rust as a structured tool result.

### NativeInteractionBroker

Some Apple APIs require user interaction by design. The toolkit should not hide this behind a fake synchronous call.

```text
Rust tool call
  -> Swift detects user-mediated tool
  -> NativeInteractionBroker creates pending interaction
  -> App presents picker/sheet/camera/document UI
  -> NativeAttachmentStore persists selected input if needed
  -> Swift returns structured ToolResultDTO to Rust
```

The broker is the right home for:

- file pickers
- photo pickers
- document scanners
- camera or microphone capture
- share-extension handoff
- permission repair flows

### NativeAttachmentStore

User-selected files, images, audio, and scanned documents should be represented as app-local attachment references instead of raw paths passed through the model.

Each attachment should record:

- attachment id
- source family: files, photos, share, camera, scanner, audio
- content type / UTI
- original display name
- sandbox location or security-scoped bookmark when applicable
- size and lightweight metadata
- retention policy
- sensitivity

The model receives metadata and a stable attachment id. Swift and Rust resolve the actual bytes only through approved tool paths.

The intended composition pattern is:

```text
user-mediated input tool
  -> attachment_id + metadata
  -> attachment-consuming tool
  -> structured result
  -> optional context pipeline injection
```

Examples:

```text
photos.pick_images
  -> attachment_id
vision.extract_text_from_attachment(attachment_id)
  -> extracted text
Context Pipeline
  -> inject selected extracted content
```

```text
files.pick_document
  -> attachment_id
files.read_attachment(attachment_id)
  -> text or metadata
Context Pipeline
  -> inject selected file excerpt
```

### Tool Families From Apple APIs

First implementation families:

| Family | Candidate tools | Apple APIs | Mode | First-stage status |
|---|---|---|---|---|
| Calendar | `calendar.search_events`, `calendar.get_event` | EventKit / `EKEventStore` | Background after permission | Build first. Existing search tool is the seed. |
| Reminders | `reminders.create`, `reminders.search`, `reminders.complete` | EventKit reminders / `EKEventStore` | Background after permission and approval | Build first. Existing create tool is the seed. |
| Files | `files.pick_document`, `files.read_attachment`, `files.summarize_metadata` | UIDocumentPicker / file importer / UTType | User-mediated | Build first as attachment-based tools. |
| Photos | `photos.pick_images`, `photos.describe_attachment_metadata` | PhotosUI / `PhotosPicker` | User-mediated | Build first as selected-photo attachment tools. |
| Share Input | `share.capture_input`, `share.list_recent_captures` | Share Extension / app groups | User-mediated or extension input | Build after Files/Photos. |
| App Actions | `agent.start_chat`, `agent.capture_text`, `agent.open_builder` | App Intents / AppEntity / AppShortcutsProvider | System action adapter | Build as thin outward adapters, not model-only tools. |
| Notifications | `notifications.schedule_local`, `notifications.cancel_scheduled` | UserNotifications | Background after permission and confirmation | Later, because side effects need clear approval UX. |
| Contacts | `contacts.search`, `contacts.get_contact` | Contacts / `CNContactStore` | Background after permission | Later; high privacy sensitivity. |
| Location | `location.current`, `location.reverse_geocode` | CoreLocation | User-mediated or background with strict permission | Later; high sensitivity and context leakage risk. |
| Speech | `speech.transcribe_audio_attachment`, `speech.record_and_transcribe` | Speech / AVFoundation | User-mediated | Later; recording requires foreground UX. |
| Vision | `vision.scan_document`, `vision.extract_text_from_image` | VisionKit / Vision | User-mediated for scan; background for existing image attachment | Later, useful for document workflows. |
| Clipboard | `clipboard.import_text`, `clipboard.copy_text` | UIPasteboard | User-mediated | Later; only through explicit user action. |
| App Meta | `native.list_tools`, `native.permission_status` | App-local services | Background | Keep. Existing tools are useful for debug and builder readiness. |

Later families:

- Contacts.
- Location.
- Camera / microphone.
- Speech transcription.
- Vision document scan.
- HealthKit or HomeKit only if the product has a clear user-facing need.

Deferred or prohibited first-stage tools:

- arbitrary execution of user Shortcuts
- arbitrary file-system browsing
- silent clipboard reads
- silent camera or microphone capture
- arbitrary URL opening as a model side effect
- health or home automation controls

These may become explicit user-mediated actions later, but they should not enter the initial agent tool catalog.

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
- show approval policy from the same `NativeToolManifest` used at runtime
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

### ContextPreviewService

Context preview is a core Agent Builder capability, not an optional debug add-on. Users need to understand what a configured Context Pipeline will cause the model to see.

Swift should not assemble final model input locally. Instead, it asks Rust for a preview:

```text
ContextPreviewService
  input:
    agent draft
    sample user message
    optional sample conversation id / branch

  output:
    ordered context segments
    source labels
    token estimate
    sensitivity labels
    privacy warnings
    omitted segment reasons
    assembly trace id
```

The preview is allowed to be approximate, but the ordering, source labels, and policy warnings must come from the same Rust context assembly policy used during execution.

Builder uses this service for:

- Context Pipeline preview panel.
- Card-level token and privacy warnings.
- Publish readiness validation.
- Debugging why memory, skill, or tool schema did or did not enter context.

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

ContextPreviewService
  requests Rust-backed preview/trace for a draft and sample user message
```

The existing `AgentBuilderViewModel` can evolve from readiness-only into the screen coordinator, but it should not absorb tool execution, permission implementation, or context assembly.

### Agent Draft Lifecycle

Agent Builder needs a clear draft state machine. Without it, users cannot tell whether they are editing a saved draft, a valid unpublished draft, or an agent already used by an active conversation.

```text
empty
  -> editing

editing
  -> dirty
  -> validating

dirty
  -> validating

validating
  -> invalid
  -> readyToPublish

invalid
  -> editing

readyToPublish
  -> publishing

publishing
  -> published
  -> publishFailed

publishFailed
  -> editing

published
  -> editing
```

State meanings:

- `empty`: no local draft has been loaded or created.
- `editing`: draft is loaded and matches the last local save point.
- `dirty`: user changed one or more cards after the last save/validation.
- `validating`: Rust/profile validation, toolkit permission readiness, and model readiness are running.
- `invalid`: draft has blocking validation issues.
- `readyToPublish`: draft passes validation and can become the active agent profile.
- `publishing`: publish request is in flight.
- `published`: draft has become a published agent profile revision.
- `publishFailed`: publish failed and the user can retry or edit.

Published conversations should reference the published profile revision they started with. Editing an agent should create a new draft/revision instead of mutating the profile under an active run.

## Data Flow

### Publish Agent

```text
User edits cards
  -> AgentDraftStore
  -> AgentValidationService
       Rust validateDraft
       Native permission readiness
       Model/runtime readiness
       ContextPreviewService policy warnings
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

- Introduce `NativeToolManifest` as the single source for card rendering, schema export, approval policy, readiness, and audit metadata.
- Add permission gateway abstraction.
- Add platform availability and readiness reporting.
- Add tool mode metadata: background, user-mediated, system action adapter.
- Add required system API metadata: framework, permission scope, Info.plist keys, entitlements.
- Keep existing calendar/reminder/meta tools as first real examples.

### Phase 2: First System Tool Adapters

- Calendar search and event detail through EventKit.
- Reminder create/search through EventKit reminders.
- Files document picker and attachment read path.
- Photos picker and image attachment path.
- App meta tools for tool listing and permission status.

### Phase 3: Agent Builder Cards

- Build card-based Agent Builder screen.
- Render Tool Belt and Context Pipeline as the main canvas.
- Add inspector for selected card.
- Add draft lifecycle states: empty, editing, dirty, validating, invalid, readyToPublish, publishing, published, publishFailed.
- Save draft locally and validate through Rust bridge.

### Phase 4: Context Preview

- Add Rust-backed `ContextPreviewService` as a first-class Builder service.
- Show pipeline preview in Swift without letting Swift assemble final model input.
- Add presets: Focused, Full Context, Private.

### Phase 5: App Intents and System Action Adapters

- Replace page-heavy shortcuts with action-first intents where an outward system action is useful.
- Add `AgentEntity` and `ConversationEntity`.
- Add Open Agent Builder, Start Chat with Agent, Continue Conversation, Capture Text to Agent.
- Keep the same toolkit metadata shape for inward native tools and outward App Intent actions.

### Phase 6: Tool Expansion

- Add Share Extension capture path.
- Add notification/clipboard tools only with explicit user confirmation.
- Add Contacts, Location, Speech, and Vision only after the permission UX and attachment model are stable.

## Acceptance Criteria

- User can create or edit an agent from cards.
- Tool Belt and Context Pipeline are the visual center of the builder.
- Native tools are listed from `LocalNativeToolkit`, not hardcoded in views.
- Tool cards show permission, risk, and availability.
- Tool cards show whether a tool is background, user-mediated, or a system action adapter.
- Tool cards, Rust schema export, and runtime approval policy derive from the same `NativeToolManifest`.
- Files and Photos tools return attachment references, not arbitrary raw paths.
- User-mediated tools route through one interaction broker instead of presenting UI from random tool code.
- Attachment-producing tools and attachment-consuming tools compose through `NativeAttachmentStore`.
- Context cards can be reordered/configured through presets.
- Context Pipeline has a Rust-backed preview with ordered segments, token estimates, and privacy warnings.
- Agent Builder exposes a clear draft lifecycle from editing to published.
- Swift can validate an agent draft before publishing.
- Rust remains final authority for agent profile validation and execution context assembly.
- iOS system APIs are wrapped as toolkit capabilities rather than scattered through views.
