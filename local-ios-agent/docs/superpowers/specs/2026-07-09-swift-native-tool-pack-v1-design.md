# Swift Native Tool Pack v1.5 Design

## Purpose

This document defines the next native tool expansion after the current Builder, Toolkit, and App Frontend MVP work.

The current `LocalNativeToolkit` already has the important plumbing:

- `NativeToolManifest` as the source of truth for schema, card, risk, permission, approval, and audit metadata.
- `NativeToolExecutor` and `ToolResultEnvelopeV1`.
- `NativePermissionGateway`.
- `NativeAttachmentStore` and `NativeAttachmentByteStore`.
- `PendingUserInteractionStore`.
- existing first tools: `native.list_tools`, `native.permission_status`, `calendar.search_events`, `reminders.create_reminder`, `files.pick_document`, `photos.pick_images`, attachment read/describe tools, `web.fetch_url_text`, and `shortcuts.list_voice_shortcuts`.

The missing product value is not more raw API coverage. The missing value is a small set of composable tools that let users build agents that can capture information, extract meaning, and take safe actions.

This tool pack is therefore organized around:

```text
Capture
  Bring user-selected material into the app.

Extract
  Turn captured material into bounded, labelled context.

Act
  Create or update user-visible system state with clear permission and approval.
```

The goal is to make Builder tool cards feel real, make Conversation Workspace tool use understandable, and preserve the platform boundary:

```text
Apple APIs and system UI
  -> Swift Native Toolkit
  -> ToolResultEnvelopeV1
  -> Rust execution/tool context
```

## Product Principle

The agent should feel like it has useful hands, but not invisible hands.

Swift owns all platform interaction, permission prompts, foreground UI, attachment access, and system handoff. Rust owns tool routing semantics and execution context. The model only sees tool schemas and structured, labelled results.

The most useful tools are not standalone. They form safe chains:

```text
share.capture_input
  -> attachment_id
  -> web.extract_readable_article or files.read_attachment
  -> context pipeline
```

```text
photos.pick_images
  -> attachment_id
  -> vision.extract_text_from_attachment
  -> reminders.create_reminder
```

```text
files.pick_document
  -> files.read_attachment
  -> agent extracts tasks
  -> calendar.create_event_user_confirmed
```

Every chain must preserve:

- attachment identity
- provenance
- trust level
- sensitivity
- retention policy
- user approval boundary

## Scope

This design owns:

- the next useful native tool families
- tool names and boundaries
- manifest requirements
- attachment and trust propagation
- user-mediated flows
- App Intent and Share Extension role in the tool system
- recommended implementation order

This design does not own:

- final visual UI styling
- Rust context assembly internals
- C++ inference backend changes
- arbitrary user Shortcut execution
- background daemon behavior outside iOS constraints
- full onboarding, account, or model download UX

## Apple Platform Rules

The toolkit should follow Apple platform behavior instead of abstracting it away.

### System UI Is A Boundary

Files, Photos, document scanning, audio recording, camera, microphone, and visible web or maps handoff are user-mediated capabilities. They should not be shaped as silent background functions.

### App Intents Are System Action Adapters

App Intents, App Shortcuts, Siri, Spotlight, widgets, and controls expose selected app-owned actions to the system. They are not a general model tool execution layer and should not run arbitrary user Shortcuts.

When system action adapters are implemented, the first surface should stay narrow:

```text
agent.capture_text
agent.start_chat
agent.continue_conversation
agent.open_builder
```

### Permissions Stay Narrow

Use the smallest useful permission scope:

- Calendar read/search requires full calendar event access.
- Calendar write-only creation should not request full read access.
- User-confirmed event creation can use a visible event editor flow instead of silent write access.
- Photos and Files should prefer selected-item access.
- Device location should be separate from coordinate geocoding.

### Region And Device Differences Are Availability States

Do not delete a tool family only because one API may be unavailable on a region, OS version, device, or entitlement. Encode availability and fallback in `NativeToolManifest`.

## Current Baseline

The current toolkit already gives us enough to build on:

| Family | Current tools | Product gap |
| --- | --- | --- |
| Meta | `native.list_tools`, `native.permission_status` | Good base. Should power Builder and Context Inspector. |
| Calendar | `calendar.search_events` | Add safe create paths and event detail later. |
| Reminders | `reminders.create_reminder` | Add search and completion to make reminders useful in loops. |
| Files | `files.pick_document`, `files.describe_attachment`, `files.read_attachment` | Add attachment listing and richer extraction. |
| Photos | `photos.pick_images`, `photos.describe_attachment` | Add OCR and image metadata extraction. |
| Web | `web.fetch_url_text` | Add readable article extraction and source labelling. |
| Shortcuts | `shortcuts.list_voice_shortcuts` | Keep as introspection. Do not execute arbitrary shortcuts. |
| Pending interaction | persisted interaction records | Needs more user-mediated tool coverage. |

This document adds the next layer, not a replacement.

## Tool Pack v1.5

### Tool Pack v1.5 Required Set

These tools define the required v1.5 set because they make existing Builder and Chat flows feel useful without expanding risk too much.

They do not all need to land in one implementation slice. The implementation order below splits this required set into smaller deliverable slices:

```text
Slice 1
  attachments.list
  web.extract_readable_article
  vision.extract_text_from_attachment

Slice 2
  reminders.search_reminders
  calendar.find_free_time
  calendar.create_event_user_confirmed
```

#### `attachments.list`

Mode: background.

Purpose: list attachment records available to the current conversation or run.

Inputs:

```json
{
  "conversation_id": "optional",
  "run_id": "optional",
  "source_family": "optional"
}
```

Output:

```json
{
  "attachments": [
    {
      "attachment_id": "att_...",
      "display_name": "Receipt.png",
      "content_type": "image/png",
      "source_family": "photos",
      "size_bytes": 12345,
      "trust_level": "untrusted_external_content",
      "sensitivity": "private",
      "access_state": "available"
    }
  ]
}
```

Rules:

- Do not return raw file paths.
- Do not return security-scoped bookmark data.
- Sort by newest first, then display name.
- Runtime may only list attachments already authorized for the current active run or conversation frame.
- `conversation_id` and `run_id` from model arguments are hints only. Swift and Rust must verify them against the current execution context or ignore them.
- A model-provided id must never widen attachment scope or enumerate attachments from old conversations that were not bound to the current run.
- Tool Center may list broader app-level attachments only through app-owned UI, not through a model-callable runtime tool.

Why first: it makes attachments inspectable and gives the model a safe way to reference captured material.

#### `web.extract_readable_article`

Mode: background with approval.

Purpose: fetch a public HTTPS URL and return a bounded readable article representation.

Inputs:

```json
{
  "url": "https://example.com/article",
  "max_characters": 12000
}
```

Output:

```json
{
  "url": "https://example.com/article",
  "final_url": "https://example.com/article",
  "title": "Article title",
  "site_name": "Example",
  "excerpt": "Bounded readable text...",
  "content_truncated": false,
  "trust_level": "untrusted_external_content"
}
```

Rules:

- Use the same `WebFetchPolicyV1` family as `web.fetch_url_text`.
- Only public HTTPS in the first implementation.
- No cookies, no auth headers, no file URLs, no custom schemes.
- Background extraction does not execute JavaScript.
- Background extraction does not use `WKWebView` or hidden browser automation.
- Background extraction should use `URLSession` plus bounded HTML bytes and a readability parser.
- Do not follow meta refresh as navigation. HTTP redirects must be bounded and re-validated by policy.
- Pages that require JavaScript or login must use a visible browser handoff such as `web.open_url_visible`.
- Treat all returned page content as untrusted external content.
- Return source labels suitable for Context Preview and Conversation source disclosure.

Known limitation:

- If resolved-address private-network protection is not implemented yet, the manifest and docs must describe this as best-effort public HTTPS policy, not complete network isolation.

Why first: web reading is a core agent workflow and gives immediate value in Builder context experiments.

#### `vision.extract_text_from_attachment`

Mode: background or user-mediated repair, depending on attachment access.

Purpose: OCR an existing image or scan attachment.

Inputs:

```json
{
  "attachment_id": "att_...",
  "max_characters": 12000,
  "language_hint": "optional"
}
```

Output:

```json
{
  "attachment_id": "att_...",
  "text": "Recognized text...",
  "content_truncated": false,
  "confidence_summary": "medium",
  "trust_level": "untrusted_external_content"
}
```

Rules:

- Input must be an attachment id.
- Do not read Photos or Files directly.
- If attachment access expired, return a repairable error.
- OCR output is external material. It is not instruction text.
- Implementation should keep scanner UI and text recognition separate: `VisionKitDocumentScannerAdapter` for scanning, `VisionTextRecognitionAdapter` for OCR.

Why first: it turns existing `photos.pick_images` and future scan flows into useful context.

#### `reminders.search_reminders`

Mode: background after permission.

Purpose: search reminders by title, status, due date range, or list.

Inputs:

```json
{
  "query": "optional",
  "include_completed": false,
  "due_from": "optional ISO-8601",
  "due_to": "optional ISO-8601",
  "limit": 20
}
```

Output:

```json
{
  "reminders": [
    {
      "reminder_id": "opaque",
      "title": "Buy milk",
      "due_date": "optional ISO-8601",
      "is_completed": false,
      "list_title": "Personal"
    }
  ]
}
```

Rules:

- Return opaque reminder ids, not EventKit internals.
- Bound result count.
- Private sensitivity by default.

Why first: create-only reminders are useful, but search makes the agent able to avoid duplicates and reason about existing tasks.

#### `calendar.create_event_user_confirmed`

Mode: user-mediated.

Purpose: prepare a calendar event and show a system-confirmed event editor.

Inputs:

```json
{
  "title": "Dentist",
  "start_date": "ISO-8601",
  "end_date": "ISO-8601",
  "notes": "optional",
  "location": "optional"
}
```

Output:

```json
{
  "status": "created | cancelled_by_user",
  "event_id": "optional opaque",
  "title": "Dentist"
}
```

Rules:

- Must persist `pending_user_interaction` before presenting the editor.
- User cancellation is a normal result, not a crash or generic error.
- This tool should not request full calendar read access.
- `event_id` is best-effort trace metadata only in the user-confirmed path.
- Later tool calls must not depend on `event_id` as a reliable handle unless the app has the EventKit access needed to resolve it.

Why first: it proves the difference between silent background tools and user-confirmed system actions.

### Strong Second Slice

These tools become valuable once the first slice works.

#### `share.capture_input`

Mode: system action adapter.

Purpose: receive text, URLs, images, and files from the iOS Share Sheet and store them as capture records or attachments.

Stored capture record shape:

```json
{
  "capture_id": "capture_...",
  "attachments": ["att_..."],
  "text_excerpt": "optional",
  "source_app": "optional",
  "target": "inbox | conversation | agent"
}
```

Rules:

- The Share Extension should not run heavy inference.
- Store captured content and hand off to the main app.
- User chooses target agent/conversation when needed.
- Shared content is untrusted external content unless it is user-authored text explicitly marked by the UI.
- This is a system input capability, not a Rust-exported runtime tool schema.
- Builder may display it as an input capability, but Rust should not receive `share.capture_input` as a model-callable tool.

Why second: it is extremely useful, but it touches app extension storage, routing, and handoff.

#### `vision.scan_document`

Mode: user-mediated.

Purpose: present a document scanner and store scans as attachments.

Rules:

- Scanner UI is app-owned.
- Each page becomes an attachment or an attachment group.
- OCR is a separate tool, not implicit.
- Implementation should use a scanner-facing adapter such as `VisionKitDocumentScannerAdapter`, separate from OCR/text recognition.

Why second: scanning is high value, but it depends on attachment UX and pending interaction recovery.

#### `notifications.schedule_local`

Mode: user-mediated or background after explicit approval.

Purpose: schedule a local notification for a user-confirmed reminder-like event.

Rules:

- Approval policy is per-call by default.
- Requires notification authorization.
- Never schedule silently from untrusted external content.
- Must include visible summary before scheduling.
- Scheduled notifications must be visible in the app and cancellable by the user.

Why second: it gives agents a lightweight follow-up ability without broader automation risk.

#### `calendar.find_free_time`

Mode: background after permission.

Purpose: find candidate free slots from existing calendar events.

Inputs:

```json
{
  "duration_minutes": 60,
  "search_from": "ISO-8601",
  "search_to": "ISO-8601",
  "working_hours_only": true,
  "limit": 5
}
```

Output:

```json
{
  "candidates": [
    {
      "start_date": "ISO-8601",
      "end_date": "ISO-8601",
      "confidence": "high"
    }
  ]
}
```

Rules:

- Builds on `calendar.search_events`.
- Does not create or modify calendar events.
- Should be paired with `calendar.create_event_user_confirmed` when the user wants to schedule one candidate.

Why second: it matches real scheduling workflows better than jumping directly from search to event creation.

#### `maps.geocode_address`

Mode: background.

Purpose: convert a user-provided address string into candidate coordinates.

Rules:

- Does not use device current location.
- Returns candidates, not a forced choice.
- Region availability should be manifest-driven.

#### `maps.reverse_geocode_coordinate`

Mode: background.

Purpose: convert provided coordinates into address candidates.

Rules:

- Does not request location permission.
- Must stay distinct from `location.current_place`.

#### `maps.open_route`

Mode: user-mediated visible handoff.

Purpose: open Apple Maps with a route or destination.

Rules:

- Visible system handoff only.
- No silent location tracking.

### Deferred Tools

These are useful, but should not block the required first slice. Some are included in later slices below; others should become separate issues.

```text
calendar.get_event
calendar.create_event_write_only
mail.create_draft
speech.record_audio
speech.transcribe_audio_attachment
files.extract_pdf_text
attachments.pin_to_conversation
```

Late-stage or high-risk capabilities:

```text
contacts.search
health.*
home.*
shortcuts.run_user_shortcut
messages.send
mail.send
location.current_place
clipboard.read_silent
camera.capture_silent
microphone.record_silent
```

These require stronger privacy UX, audit, and recovery before becoming model-callable.

## Naming Rules

Tool names must encode capability and risk clearly.

Use:

```text
maps.reverse_geocode_coordinate
location.current_place
calendar.create_event_user_confirmed
calendar.create_event_write_only
web.extract_readable_article
vision.extract_text_from_attachment
```

Avoid:

```text
maps.reverse_geocode
location.reverse_geocode
calendar.create_event
web.read
vision.ocr
```

Reason:

- `maps.reverse_geocode_coordinate` consumes provided coordinates and does not need current location.
- `location.current_place` reads device location and needs location permission.
- `calendar.create_event_user_confirmed` makes the approval mode explicit.
- `web.extract_readable_article` is different from raw fetch.

## Manifest Requirements

Every new tool must have a manifest before it is exported or executable in product mode.

Required manifest fields:

```text
manifest_id
tool_name
tool_mode
capability_id
permission_scope
approval_policy
risk_level
sensitivity
default_trust_level
retention
availability
fallback
audit
```

The manifest must drive:

- Builder Tool Belt card.
- Tool Center row.
- Rust `ToolSchemaDTO.metadata_json`.
- runtime approval policy.
- permission readiness.
- result audit behavior.

Missing manifest in product mode is fail-closed:

```text
not exported
not listed by native.list_tools
not executable by NativeToolExecutor
```

## Result Envelope Rules

Every tool result must use `ToolResultEnvelopeV1`.

### Trust Level

External content is not instruction text.

Use `untrusted_external_content` for:

- web page content
- OCR output
- file text read from attachment
- text from shared URLs or files
- transcripts from external audio/video

Use user-provided material only when the app UI can clearly mark the content as authored or selected by the user for this conversation.

### Provenance

Every result should include:

```text
tool_name
tool_call_id
source_family
attachment_id or source_url when applicable
created_at
```

### Bounded Output

All text outputs need:

```text
max_characters
content_truncated
source_count or page_count when applicable
```

The model should receive excerpts and structured metadata, not unlimited raw contents.

## Attachment Store Rules

The attachment store is the central crossing point for user-mediated content.

Allowed model-visible output:

```text
attachment_id
display_name
content_type
size_bytes
source_family
trust_level
sensitivity
access_state
```

Forbidden model-visible output:

```text
raw file path
Photos asset URL
security-scoped bookmark data
temporary sandbox path
full filesystem hierarchy
```

Attachment access states:

```text
available
needs_user_reselection
expired
deleted
unavailable_on_device
```

If a tool cannot access bytes, it should return a repairable error that Conversation Workspace can render as a pending interaction or repair card.

## Runtime Flows

### Background Tool

```text
Rust requests tool
  -> Swift NativeToolExecutor validates manifest
  -> permission gateway checks readiness
  -> adapter runs
  -> ToolResultEnvelopeV1 returns to Rust
```

### User-Mediated Tool

```text
Rust requests tool
  -> Swift creates pending_user_interaction
  -> store persists record before UI
  -> app presents picker/scanner/editor
  -> selection creates attachment or confirmed action
  -> Swift submits tool result
  -> Rust resumes execution
```

### System Action Adapter

```text
Share Sheet / App Intent / Shortcut / Spotlight
  -> thin adapter validates input
  -> stores capture or routes app destination
  -> main app decides target conversation/agent
```

System action adapters are not generic native tools. They can create inputs for agents or open app workflows, but should not bypass the toolkit manifest and attachment rules.

## Builder Integration

Builder should group capabilities by user meaning, not by Apple framework.

Builder must distinguish runtime tools from system input capabilities:

```text
Runtime Tools
  Exported to Rust as model-callable schemas.

System Input Capabilities
  Displayed as ways to bring material into the app, but not exported as model-callable runtime schemas.
```

Suggested groups:

```text
Available Runtime Tools
  Capture
  files.pick_document
  photos.pick_images
  vision.scan_document

  Read And Extract
  files.read_attachment
  web.extract_readable_article
  vision.extract_text_from_attachment

  Organize
  reminders.create_reminder
  reminders.search_reminders
  calendar.search_events
  calendar.find_free_time
  calendar.create_event_user_confirmed

  Open And Navigate
  maps.geocode_address
  maps.reverse_geocode_coordinate
  maps.open_route
  web.open_url_visible

  System
  native.list_tools
  native.permission_status
  notifications.schedule_local

Available System Input Capabilities
  share.capture_input
  agent.capture_text
  agent.start_chat
  agent.continue_conversation

Future Disabled Cards
  speech.transcribe_audio_attachment
  files.extract_pdf_text
  mail.create_draft
```

Tool cards should show:

- mode: background, user-mediated, or system action
- permission state
- approval policy
- output trust level
- whether outputs can enter context
- availability/fallback

The Builder should prefer useful combinations:

```text
photos.pick_images + vision.extract_text_from_attachment
web.extract_readable_article + context preview
reminders.search_reminders + reminders.create_reminder
calendar.search_events + calendar.create_event_user_confirmed
```

## Conversation Integration

Tool use should be visible in chat.

Conversation Workspace needs cards for:

- approval request
- pending user interaction
- permission repair
- external content used
- attachment created
- action completed
- user cancelled system UI

For this tool pack, the most important runtime UX is:

```text
agent asks for photos or file
  -> Chat shows pending picker card
  -> user continues or cancels
  -> result appears as attachment chip
  -> later extraction tool references the attachment id
```

and:

```text
agent reads a web page
  -> Chat shows source disclosure
  -> context inspector labels content untrusted_external_content
```

## Security And Privacy

### Indirect Prompt Injection

Tools that ingest external content must label it as external material at result creation time. The label should travel through:

```text
ToolResultEnvelopeV1
  -> Rust tool result event
  -> ContextAssembler segments
  -> ContextPreviewService
  -> Conversation source disclosure
```

The model should see source framing that makes clear that external content is not a higher-priority instruction.

### No Silent Broad Access

Do not add tools that silently read:

- all files
- all photos
- clipboard
- contacts
- messages
- current location
- microphone
- camera

Those can become later user-mediated or confirmed workflows, but not background tools.

### Audit

Every tool call should produce audit text suitable for Debug/Trace:

```text
tool name
permission scope
approval decision
attachment ids
source URL or system surface
result size
trust level
retention
```

## Implementation Order

### Slice 1: Make Current Attachments And Web Useful

Tools:

- `attachments.list`
- `web.extract_readable_article`
- `vision.extract_text_from_attachment`

Why:

- Uses the existing attachment and web foundations.
- Makes Context Pipeline preview much more meaningful.
- Does not require new write permissions.

Acceptance signal:

```text
pick photo
  -> attachment appears in attachments.list
  -> vision.extract_text_from_attachment returns OCR result
  -> context preview shows OCR as untrusted external content
```

### Slice 2: Make Organizing Tools Useful

Tools:

- `reminders.search_reminders`
- `calendar.find_free_time`
- `calendar.create_event_user_confirmed`

Why:

- Complements existing reminders create and calendar search.
- Lets the agent propose free slots before asking the user to create an event.
- Demonstrates safe action tools with user confirmation.

Acceptance signal:

```text
agent checks existing reminders
  -> creates missing reminder
  -> finds candidate free time
  -> proposes calendar event
  -> user confirms event editor
```

### Slice 3: Add Capture From Outside The App

Tools/system adapters:

- `share.capture_input`
- `agent.capture_text`
- `agent.continue_conversation`

Why:

- Turns the app into something users can invoke from Safari, Files, Photos, and system surfaces.
- Should follow after the attachment store and routing are stable.

Acceptance signal:

```text
share URL from Safari
  -> capture record created
  -> app opens selected agent/conversation
  -> article extraction can run
```

### Slice 4: Add Visible Handoff And Follow-Up

Tools:

- `notifications.schedule_local`
- `maps.geocode_address`
- `maps.reverse_geocode_coordinate`
- `maps.open_route`
- `web.open_url_visible`

Why:

- Adds everyday utility while preserving visible user control.

## Testing Strategy

Default tests should not require real Apple services.

Unit tests:

- manifest export for every new tool
- fail-closed missing manifest behavior
- result envelope trust/provenance/retention
- attachment list filtering
- web readable extraction parsing fallback
- OCR fake adapter result
- reminders search fake adapter result
- calendar user-confirmed pending interaction lifecycle
- system input capabilities are not exported by `NativeToolSchemaExport`
- `native.list_tools` does not list `share.capture_input`, `agent.capture_text`, or `agent.continue_conversation`

Integration tests with fakes:

- photo attachment -> OCR -> context preview
- web URL -> readable article -> source disclosure
- reminders search -> create reminder
- calendar create -> pending interaction -> user cancel

Optional simulator/device smoke:

- real Photos picker presentation
- real document scanner presentation
- real Share Extension handoff
- real EventKit editor presentation

No test should require private user data by default.

## Documentation And User-Facing Copy

Tool cards should use user language:

```text
Read webpages
Extract text from images
Find reminders
Create calendar events with confirmation
Capture shared content
```

Avoid framework language in primary UI:

```text
VisionKit OCR
EventKit write-only access
URLSession fetch
App Intent action
```

Framework names belong in debug details or developer docs.

## Open Follow-Ups

These should become later issues or implementation plans, not part of the first tool pack:

- resolved-address private-network blocking for web fetch
- security-scoped bookmark repair and renewal
- PDF text extraction
- mail draft creation
- speech transcription
- map search ranking and region policy
- device current-location permission UX
- arbitrary user Shortcut execution policy
- contacts access policy
- HealthKit and HomeKit exclusion policy

## Acceptance Criteria

This design is complete when:

- The first tool pack is bounded to Capture, Extract, and Act.
- Each new tool has a clear mode, permission, input, output, trust level, and fallback.
- User-mediated tools persist pending interaction before system UI.
- Attachment ids remain the only model-visible handle for selected files/photos/scans/audio.
- External content carries trust labels into context preview and conversation source disclosure.
- App Intents and Share Extension are treated as system action adapters, not arbitrary tool execution.
- The implementation order does not block on high-risk or high-permission APIs.

## Official Apple Reference Surface

The relevant Apple framework families for this design are:

- App Intents: https://developer.apple.com/documentation/appintents
- EventKit: https://developer.apple.com/documentation/eventkit
- PhotosUI: https://developer.apple.com/documentation/photosui
- UIDocumentPickerViewController: https://developer.apple.com/documentation/uikit/uidocumentpickerviewcontroller
- VisionKit: https://developer.apple.com/documentation/visionkit
- Vision: https://developer.apple.com/documentation/vision
- Speech: https://developer.apple.com/documentation/speech/sfspeechrecognizer
- UserNotifications: https://developer.apple.com/documentation/usernotifications
- MapKit: https://developer.apple.com/documentation/mapkit
- SafariServices: https://developer.apple.com/documentation/safariservices/sfsafariviewcontroller
- URLSession: https://developer.apple.com/documentation/foundation/urlsession
