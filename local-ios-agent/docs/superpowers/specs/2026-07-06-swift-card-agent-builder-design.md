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
- MapKit / Core Location / Apple Maps handoff: place search, geocoding, routing handoff, and map display.
- SafariServices / WebKit / URLSession: user-visible web opening, in-app web viewing, and bounded URL fetching.
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
- MapKit: https://developer.apple.com/documentation/mapkit
- MKLocalSearch: https://developer.apple.com/documentation/mapkit/mklocalsearch
- MKMapItem `openInMaps`: https://developer.apple.com/documentation/mapkit/mkmapitem/openinmaps(launchoptions:)
- SafariServices / SFSafariViewController: https://developer.apple.com/documentation/safariservices/sfsafariviewcontroller
- WebKit / WKWebView: https://developer.apple.com/documentation/webkit/wkwebview
- URLSession: https://developer.apple.com/documentation/foundation/urlsession

Verified Apple DocC details that affect tool design:

- `MKLocalSearch` is for map-based address and point-of-interest searches and is available across iOS, iPadOS, macOS, Mac Catalyst, tvOS, visionOS, and watchOS.
- `MKMapItem.openInMaps(launchOptions:)` opens the Maps app to display a map item.
- `SFSafariViewController` provides a visible standard web-browsing interface.
- `WKWebView` displays interactive web content for an in-app browser.
- `URLSession` coordinates network data transfer tasks.
- `AppIntent`, `AppEntity`, and `AppShortcutsProvider` are available from iOS 16 era platforms and are the right surface for app-owned actions discoverable by Shortcuts/Siri/system experiences.
- EventKit calendar access is not one permission: full event access, write-only event access, and user-confirmed event editing have different privacy and UX implications.

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

### Tool Design Doctrine

The toolkit should be designed scientifically: every tool should have a clear source capability, one manifest, one execution path, one permission model, one audit story, and one fallback story.

The design principles are:

```text
Most basic tools
  Prove the agent can safely inspect and act on local system information.
  Examples: native.list_tools, native.permission_status, calendar.search_events, reminders.create.

Most important tools
  Support Tool Belt and Context Pipeline directly.
  Examples: files.pick_document -> files.read_attachment, photos.pick_images -> attachment metadata.

Most clever tools
  Compose multiple safe capabilities through attachments instead of giving the model raw platform access.
  Example: share.capture_input -> attachment_id -> vision.extract_text_from_attachment -> context preview.

Most interesting tools
  Make agents touchable outside the main app through app-owned system actions.
  Examples: agent.capture_text, agent.start_chat, agent.continue_conversation.
```

The important distinction is composition, not API count. A tool family becomes powerful when its output is a clean input to another family:

```text
User-mediated capture
  -> NativeAttachmentStore
  -> attachment-consuming analysis tool
  -> structured result
  -> ContextPreviewService
  -> Context Pipeline injection decision
```

Tool design rules:

- Prefer explicit user-mediated capture over silent data access.
- Prefer attachment references over raw file paths, photo-library paths, or security-scoped URLs in model-visible output.
- Label tool results by trust level at creation time. External web pages, OCR output, file contents, and shared input are untrusted material, not instructions.
- Prefer app-owned App Intents and Shortcuts over arbitrary execution of user-created Shortcuts.
- Prefer visible Safari/Maps handoff for navigation-style actions; allow background URL or map search only when bounded, approved, and auditable.
- Prefer narrow permission scopes that match Apple's privacy prompts.
- Prefer runtime availability and fallback over deleting a capability because one region, device, or OS version may not support it.
- Keep tool cards, schema export, runtime approval, permission readiness, and audit metadata derived from the same manifest.

The toolkit should be decomposed into small, testable roles:

```text
NativeToolManifest
  Describes capability, schema, permission, risk, approval, availability, fallback, and audit policy.

NativeToolExecutor
  Runs background tools and dispatches user-mediated tools through the interaction broker.

NativeInteractionBroker
  Owns foreground UI flows such as pickers, scanners, camera, microphone, permission repair, and app handoff.

NativeAttachmentStore
  Owns selected files, photos, scans, audio, shared input, metadata, retention, and byte access.

NativePermissionGateway
  Maps high-level scopes to Apple authorization APIs and Info.plist requirements.

SystemActionAdapter
  Owns app-provided App Intents, App Shortcuts, entities, widgets, and system-facing actions.

ContextPreviewService
  Shows what tool schemas, tool results, memory, skill, and attachment-derived content would contribute to model context.
```

No layer should bypass another layer. Views render cards; they do not execute tools. Tools execute through the toolkit; they do not present random UI. Rust assembles final context; Swift previews and explains it.

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
- OS/platform availability
- region/service availability policy
- fallback behavior when the service is unavailable or restricted
- risk level: read-only, confirmation required, destructive
- approval policy: never, per-call, per-session, or always-deny-until-configured
- sensitivity of returned data
- context trust level of returned data
- retention policy for results
- availability on current platform/device
- audit label and result summary policy

`NativeToolSchema` can remain as the bridge-facing projection, but Swift code should not hand-maintain separate card, schema, and approval definitions.

Manifest fields are not UI decoration. They are contract inputs for Builder rendering, Rust bridge schema export, runtime approval, permission readiness, test fixtures, and audit output.

### NativeToolSchema Metadata Contract

`ToolSchemaDTO` can keep `metadata_json` as the bridge extension point, but the content must be a stable schema, not a free-form dumping ground. Swift should project `NativeToolManifest` into `metadata_json` using this v1 envelope:

```json
{
  "schema_version": 1,
  "manifest_id": "native.calendar.search_events.v1",
  "capability_id": "calendar.events.search",
  "tool_mode": "background",
  "permission_scope": "calendar.events.read_full",
  "approval_policy": "per_call",
  "risk_level": "read_only",
  "context_trust_level": "trusted_tool_result",
  "availability": {
    "state": "available",
    "os_minimum": "iOS 17.0",
    "region_policy": "available_with_service_fallback"
  },
  "fallback": {
    "kind": "open_settings",
    "message": "Calendar access is required to search events."
  },
  "audit": {
    "label": "Calendar Search",
    "result_summary_policy": "metadata_only"
  }
}
```

Stable fields:

- `schema_version`: metadata envelope version.
- `manifest_id`: stable manifest identity used by Builder, runtime approval, tests, and audit.
- `capability_id`: semantic capability, used to match skill/tool requirements.
- `tool_mode`: `background`, `user_mediated`, or `system_action_adapter`.
- `permission_scope`: the `NativePermissionGateway` scope.
- `approval_policy`: `never`, `per_call`, `per_session`, or `always_deny_until_configured`.
- `risk_level`: same value as `ToolSchemaDTO.riskLevel`, duplicated here so metadata is self-describing.
- `context_trust_level`: default trust level for successful model-visible result content.
- `availability`: current platform/device/service availability projection.
- `fallback`: what Swift should do when unavailable or restricted.
- `audit`: how UI/runtime should summarize use without leaking sensitive payload.

Rules:

- `NativeToolSchemaExport` is the only code path that converts manifest to Rust schema metadata.
- Builder cards, runtime approval cards, and Rust tool schema export must all consume the same manifest values.
- Rust should ignore unknown metadata keys from newer Swift clients, but malformed known keys should make the tool unavailable rather than silently widening permissions.
- A tool without valid metadata may still appear in debug builds, but product builds should not expose it as an agent-selectable native tool.

`context trust level` is required because some tools import hostile or untrusted text into the agent context. Initial values:

```text
trusted_app_policy
  App-owned system prompts, app policy, and manifest-generated tool schemas.

user_instruction
  Current user message or explicit user-authored agent instructions.

trusted_tool_result
  Structured result from an app-owned deterministic tool, such as native.permission_status.

untrusted_external_content
  Web fetches, OCR text, file text, shared page text, email-like content, and any content produced by a third-party source.
```

The model may use `untrusted_external_content` as material to summarize, compare, or extract from, but the context pipeline must mark it as content whose embedded instructions are not to be followed. This label should be attached when a tool result is created and carried through attachment storage, preview, Rust context assembly, and execution trace.

### NativeTool

A native tool is a model-callable host action.

Each `NativeTool` must expose its manifest and implement execution:

```text
NativeTool
  manifest: NativeToolManifest
  execute(argumentsJson) -> ToolResultDTO
```

The model never calls iOS frameworks directly. Rust requests a tool call; Swift receives the tool request; `LocalNativeToolkit` executes the platform adapter; the result returns to Rust as a structured tool result.

### ToolResult Envelope Contract

`ToolResultDTO` currently has top-level `displayText`, `modelText`, `structuredJson`, `auditText`, `sensitivity`, `retention`, and `isError`. For v1, `structuredJson` must carry a stable envelope so trust/provenance cannot be accidentally dropped.

```json
{
  "schema_version": 1,
  "manifest_id": "native.web.fetch_url_text.v1",
  "tool_name": "web.fetch_url_text",
  "tool_call_id": "call_123",
  "result": {
    "kind": "web_text",
    "title": "Example",
    "text_excerpt": "..."
  },
  "provenance": {
    "source_kind": "web",
    "source_id": "https://example.com/article",
    "display_name": "example.com",
    "attachment_ids": [],
    "trust_level": "untrusted_external_content",
    "sensitivity": "public"
  },
  "context_policy": {
    "model_text_policy": "summarize_or_quote_only",
    "trust_level": "untrusted_external_content",
    "source_label": "Web"
  },
  "audit": {
    "summary": "Fetched text from example.com",
    "redaction": "excerpt_only"
  }
}
```

Rules:

- `structuredJson` is the authoritative source for `trust_level`, `source_kind`, provenance, attachment ids, and context policy.
- `modelText` is a model-visible rendering, not a place to hide policy. It must be consistent with `structuredJson.context_policy`.
- External-content tools such as Web, OCR, Files, Photos, Share, Speech, and Vision must mark successful imported text as `untrusted_external_content`.
- If an external-content tool returns a success result without the v1 envelope, Rust/Swift should treat it as `untrusted_external_content` and surface a warning rather than trusting it by default.
- Deterministic app-local status tools such as `native.permission_status` may return `trusted_tool_result` when their manifest declares it.
- Future DTOs may lift `trustLevel`, `sourceKind`, and provenance to top-level fields, but v1 must work through this envelope so current bridge shape can still be used.

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

User-mediated tools may outlive the immediate Swift call stack. The broker must represent them as durable pending interactions, aligned with the execution/run snapshot boundary:

```text
pending_user_interaction
  pending interaction id
  run id
  tool call id
  interaction kind
  requested manifest id
  created at
  resumable payload summary
  expiration policy
  resume action
  cancel action
```

If the app is backgrounded, killed while a picker is open, or relaunched from a share extension, Swift should be able to recover the pending interaction, either resume it or fail it with a structured user-cancelled/system-interrupted result, then let Rust continue from the run snapshot.

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
- trust level for context injection
- bookmark status for file-backed attachments
- recovery status when original access can no longer be resolved

The model receives metadata and a stable attachment id. Swift and Rust resolve the actual bytes only through approved tool paths.

File-backed attachments should use explicit recovery states:

```text
available
  Bytes can be resolved through app storage or a valid security-scoped bookmark.

needs_user_reselection
  The bookmark is stale, revoked, missing, or no longer resolves.
  NativeInteractionBroker must ask the user to reselect the file before the tool can read bytes.

unavailable
  The user declined repair, the source no longer exists, or the app cannot legally access it.
```

Files and Photos tools must not return raw paths or opaque file errors when access fails. They should return attachment state and, when possible, route repair through `NativeInteractionBroker`.

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
| App Actions / Shortcuts | `agent.start_chat`, `agent.capture_text`, `agent.continue_conversation`, `agent.open_builder` | App Intents / AppEntity / AppShortcutsProvider | System action adapter | Compatibility-priority. Build as app-owned outward adapters, not arbitrary shortcut execution. |
| Maps | `maps.search_places`, `maps.geocode_address`, `maps.reverse_geocode_coordinate`, `maps.open_place_in_maps`, `maps.open_route_in_maps` | MapKit / `MKLocalSearch` / `CLGeocoder` / `MKMapItem.openInMaps` | Background for provided query/coordinate; user-visible system action for open-in-Maps | Compatibility-priority with service availability fallback. Coordinate reverse geocode uses caller-provided coordinates and does not request device location. |
| Web | `web.open_url`, `web.fetch_url_text`, `web.summarize_attachment_or_url_metadata` | SFSafariViewController / WKWebView / URLSession | User-visible for open/browse; background only for bounded fetch with approval | Compatibility-priority with network policy, content limits, and regional fallback. |
| Notifications | `notifications.schedule_local`, `notifications.cancel_scheduled` | UserNotifications | Background after permission and confirmation | Later, because side effects need clear approval UX. |
| Contacts | `contacts.search`, `contacts.get_contact` | Contacts / `CNContactStore` | Background after permission | Later; high privacy sensitivity. |
| Location | `location.current_coordinate`, `location.current_place` | CoreLocation + optional geocoding | User-mediated or background with strict permission | Later; high sensitivity because it touches device location. `location.current_place` may combine current device location with reverse geocoding, so it is not the same tool as coordinate-only Maps geocoding. |
| Speech | `speech.transcribe_audio_attachment`, `speech.record_and_transcribe` | Speech / AVFoundation | User-mediated | Later; recording requires foreground UX. |
| Vision | `vision.scan_document`, `vision.extract_text_from_image` | VisionKit / Vision | User-mediated for scan; background for existing image attachment | Later, useful for document workflows. |
| Clipboard | `clipboard.import_text`, `clipboard.copy_text` | UIPasteboard | User-mediated | Later; only through explicit user action. |
| App Meta | `native.list_tools`, `native.permission_status` | App-local services | Background | Keep. Existing tools are useful for debug and builder readiness. |

Later privacy-sensitive families:

- Contacts.
- Location.
- Camera / microphone.
- Speech transcription.
- Vision document scan.
- HealthKit or HomeKit only if the product has a clear user-facing need.

Hidden or unsafe variants that must not enter the first-stage catalog:

- arbitrary file-system browsing
- silent clipboard reads
- silent camera or microphone capture
- health or home automation controls
- hidden execution of user-created Shortcuts without a visible user action
- hidden URL opening or navigation as a model side effect

These are different from the compatible tool families above. They may become explicit user-mediated actions later, but they should not enter the initial agent tool catalog as hidden model side effects.

Compatibility-first families:

- App-owned Shortcuts/App Intents are first-class system action adapters.
- Maps tools are first-class as long as they expose service availability and fallback clearly.
- Web tools are first-class when split into user-visible open/browse actions and bounded, approved fetch/read actions.

### Permission Gateway

Tools should not own permission UX directly. They call a shared permission gateway:

```text
NativePermissionGateway
  status(scope)
  request(scope)
  openSettings(scope)
```

The gateway translates high-level scopes into Apple authorization APIs and Info.plist requirements. These scopes should be specific enough to match Apple's privacy prompts instead of collapsing a whole framework into one bucket.

Initial scopes:

```text
calendar.events.read_full
  EventKit full access, for search/read tools.
  Requires NSCalendarsFullAccessUsageDescription.

calendar.events.write_only
  EventKit write-only access, for direct create/update tools that do not read existing events.
  Requires NSCalendarsWriteOnlyAccessUsageDescription.

calendar.events.user_confirmed_create
  Uses EventKitUI edit flow where the user confirms saving in system UI.
  Prefer for low-friction event creation when the app does not need to inspect existing calendars.

reminders.full
  EventKit reminders full access, for search/read/write reminder tools.
  Requires NSRemindersFullAccessUsageDescription.

files.user_selected
  User-mediated document picker; returns attachment references.

photos.user_selected
  User-mediated PhotosPicker selection; returns attachment references.

web.fetch.approved
  Bounded network fetch with user/agent policy approval and content-size limits.
  Returned text is untrusted_external_content.

maps.search
  MapKit search/geocode capability with service-availability fallback.

location.current
  CoreLocation device-location capability.
  Only for tools that read the user's current location. Separate from coordinate-only Maps tools.
```

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
- Maps search/geocode/open-in-Maps through MapKit.
- Web open/browse/fetch through SafariServices/WebKit/URLSession.
- App-owned Shortcut/App Intent actions for agent capture, start chat, and continue conversation.
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
    trust levels
    token estimate
    sensitivity labels
    privacy warnings
    omitted segment reasons
    assembly trace id
```

The preview is allowed to be approximate, but the ordering, source labels, trust levels, and policy warnings must come from the same Rust context assembly policy used during execution.

Each segment should carry enough identity to explain how it entered the context:

```text
ContextSegmentPreview
  segment_id
  source_kind: user_message | system_policy | tool_schema | tool_result | memory | skill | attachment | web
  source_id
  trust_level
  sensitivity
  token_estimate
  warnings
```

External material must be visibly different from instructions. For example, `web.fetch_url_text`, `vision.extract_text_from_attachment`, `files.read_attachment`, and share-extension captures should preview as `untrusted_external_content`, even when the user explicitly selected the source. This is the Builder-facing defense against indirect prompt injection.

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
  -> dirty
  -> invalid
  -> readyToPublish

invalid
  -> dirty
  -> editing

readyToPublish
  -> dirty
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

Transition rules:

- Any card edit from `editing`, `invalid`, or `readyToPublish` moves the draft to `dirty`.
- If the user edits while `validating`, the validation request is cancelled or ignored by draft version token, then the state returns to `dirty`.
- While `publishing`, the published payload is an immutable draft revision snapshot. The simplest first-stage UX should lock card editing until publish succeeds or fails. If later we allow editing during publish, those edits must create a new local draft version and must not alter the in-flight publish payload.
- A run must bind to a specific `profile_revision_id`, not a mutable profile id resolved to "latest".

### Agent Profile Revision Contract

The product contract must distinguish mutable profile identity from immutable runnable revision identity.

| Operation | Input identity | Output identity | Rule |
|---|---|---|---|
| List agents | `profile_id` | latest published `profile_revision_id` plus draft status | Lists may show mutable profiles. |
| Open Builder | `profile_id`, optional `profile_revision_id` | local draft id | Builder may edit from a selected revision. |
| Validate draft | local draft id | validation report | Does not create a runnable revision. |
| Publish agent | `profile_id`, local draft snapshot | new `profile_revision_id` | Publish freezes a runnable revision. |
| Start run | `profile_revision_id`, `conversation_run_frame_ref`, user intent, execution options | `run_id` | Execution must not resolve `profile_id` to latest at run time. |
| Conversation summary | conversation id | pinned `profile_revision_id` | Existing conversations remain pinned. |

ABI/DTO mapping:

```text
profile_id
  Mutable product identity for listing, editing, draft lookup, and display grouping.

profile_revision_id
  Immutable execution identity for published agent configuration.
  Required for startRun/start_execution_run/start_run_json.

agent_profile_id
  Legacy compatibility field when present in current bridge DTOs.
  It may be kept for display or lookup during migration, but it is not the trusted execution selector.
```

Required Rust migration:

- `StartRunRequest` / start-run JSON should accept `profile_revision_id`.
- `RunSnapshotResolver` should resolve the exact revision, not `AgentProfileReference::latest(...)`, when a revision id is provided.
- `ResolvedRunSnapshot` should record both `profile_id` and `profile_revision_id` for audit/debug, with `profile_revision_id` as the execution pin.
- A missing or stale revision id should fail before model/tool execution starts.

Required Swift migration:

- Agent Builder publish returns and stores `profile_revision_id`.
- Conversation Workspace starts runs with `profile_revision_id`, not only `selectedAgentProfileId`.
- `selectedAgentProfileId` remains useful for Builder navigation and grouping, but the run path must carry the pinned revision id.

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
  -> Publish AgentProfileRevision
  -> Conversation Workspace can start run with profile_revision_id
```

### Run Agent

```text
Conversation Workspace
  -> Rust prepare user turn with profile_revision_id
  -> Rust start execution with profile_revision_id + conversation_run_frame_ref
  -> Rust requests tool call
  -> Swift LocalNativeToolkit inspects NativeToolManifest.tool_mode
       background:
         execute tool -> submit ToolResultEnvelopeV1 -> Rust resumes execution
       user_mediated:
         persist pending_user_interaction -> show/present system UI -> persist attachment/result
         submit ToolResultEnvelopeV1 or structured cancellation/failure -> Rust resumes execution
       system_action_adapter:
         route app/system action when explicitly user-triggered -> return structured result or app route
  -> Rust commits final assistant result
```

For user-mediated tools, the run flow is not linear. The execution boundary must represent the run as suspended for `pending_user_interaction` before Swift opens the picker or system UI:

```text
Rust tool request / run boundary
  -> Swift creates PendingUserInteraction record
  -> record persisted before presenting system UI
  -> app may be killed/backgrounded
  -> app relaunch rehydrates pending interaction from local store + Rust pending run/tool state
  -> user resumes or cancels
  -> Swift submits ToolResultDTO:
       success: attachment ids / selected values / context trust envelope
       cancel: is_error=true, reason=user_cancelled
       interrupted: is_error=true, reason=system_interrupted
  -> Rust resumes or finalizes according to tool policy
```

The first bridge may encode this as `run.suspended` with a `pending_user_interaction` payload. A dedicated `run.pending_user_interaction` event is cleaner long-term, but the durable contract is the pending id, run id, tool call id, manifest id, resumable payload summary, expiration, and resume/cancel actions.

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
- Add `NativeToolSchemaMetadataV1` projection through `ToolSchemaDTO.metadata_json`.
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
- Maps search/geocode and open-in-Maps handoff.
- Web open URL and bounded fetch/read path.
- App-owned Shortcuts/App Intents for agent capture/start/continue actions.
- App meta tools for tool listing and permission status.
- Context trust levels for web/file/OCR/share content.
- ToolResultEnvelopeV1 in `ToolResultDTO.structuredJson` for provenance and trust.

### Phase 3: Agent Builder Cards

- Build card-based Agent Builder screen.
- Render Tool Belt and Context Pipeline as the main canvas.
- Add inspector for selected card.
- Add draft lifecycle states: empty, editing, dirty, validating, invalid, readyToPublish, publishing, published, publishFailed.
- Enforce draft version tokens so validation and publish cannot apply stale card edits.
- Save draft locally and validate through Rust bridge.
- Publish returns an immutable `profile_revision_id`.

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
- Tool architecture keeps manifest, executor, interaction broker, attachment store, permission gateway, system action adapter, and context preview as separate roles.
- Tool cards show permission, risk, and availability.
- Tool cards show whether a tool is background, user-mediated, or a system action adapter.
- Tool cards, Rust schema export, and runtime approval policy derive from the same `NativeToolManifest`.
- `ToolSchemaDTO.metadata_json` uses a stable metadata schema, not ad hoc keys.
- Tool cards show OS, region/service availability, and fallback behavior.
- EventKit calendar tools use distinct read-full, write-only, and user-confirmed-create permission scopes.
- Maps coordinate geocoding and device-location tools use distinct names and permission scopes.
- Files and Photos tools return attachment references, not arbitrary raw paths.
- User-mediated tools route through one interaction broker instead of presenting UI from random tool code.
- User-mediated tools can recover or fail cleanly from pending interaction state after app interruption.
- Attachment-producing tools and attachment-consuming tools compose through `NativeAttachmentStore`.
- Attachment and external-content results carry trust levels through `ToolResultEnvelopeV1` into Context Preview and Rust context assembly.
- Files/Photos attachment storage has explicit `available`, `needs_user_reselection`, and `unavailable` states for security-scoped bookmark failure and repair.
- Shortcuts/App Intents, Maps, and Web are treated as compatibility-priority tool families, not blanket-deferred capabilities.
- Context cards can be reordered/configured through presets.
- Context Pipeline has a Rust-backed preview with ordered segments, trust levels, token estimates, and privacy warnings.
- Agent Builder exposes a clear draft lifecycle from editing to published.
- Published runs bind to an immutable profile revision id.
- startRun/start_execution_run/start_run_json use `profile_revision_id` as the trusted execution selector; `profile_id` is for listing/draft/navigation.
- User-mediated tools suspend through a durable `pending_user_interaction` record and resume via structured success/cancel/interruption tool results.
- Swift can validate an agent draft before publishing.
- Rust remains final authority for agent profile validation and execution context assembly.
- iOS system APIs are wrapped as toolkit capabilities rather than scattered through views.
- ViewModels do not execute system tools directly or assemble final model context.
