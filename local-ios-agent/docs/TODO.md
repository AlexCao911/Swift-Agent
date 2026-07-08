# Local Agent MVP TODO

## Agent Builder UI

Done in the current MVP branch:

- Card-based Builder host is available before the full AppShell.
- Builder can display manifest-backed tool cards.
- Builder can publish a template-backed, Rust-resolvable profile revision.
- Builder can publish a minimal card-backed, Rust-resolvable profile revision with prompt/persona,
  selected tools, and enabled context step ids.
- Builder Identity card can edit the published agent name and description.
- Builder Prompt and Context Pipeline cards can edit prompt/persona/style and enabled context steps.
- Builder can request a Rust-backed context preview for prompt, conversation, and tool-result
  placeholder segments.
- Chat handoff stores both `profile_id` and `profile_revision_id`.

Remaining:

- Tracked below under "Agent Builder Card-Backed Publish".

## Native Toolkit Real Adapters

Done in the current MVP branch:

- Production native catalog is registered through `NativeToolkitClient`.
- Runtime tool calls go through `NativeHostToolDriver` and `NativeToolExecutor`.
- Manifest-less tools fail closed for export and execution.
- `native.list_tools`, `native.permission_status`, and `web.fetch_url_text` use structured tool-result envelopes.
- EventKit calendar search and reminder creation adapters are in place.
- File/photo picker request types and pending-interaction broker contract are in place.
- File/photo picker tools are registered in the production catalog and return pending interaction
  envelopes through `NativeToolkitClient`.
- Attachment read/describe tools return bounded data through opaque attachment ids.
- App-owned App Intents route capture/open actions back into the app.

Remaining:

- Tracked below under "Native Toolkit Additional Adapters" and "Conversation Workspace Polish".

## App Product Frontend

Done in the current MVP branch:

- AppShell owns product routing across Chat, Agents, Tools, Models, and Settings.
- Builder handoff updates Chat with exact `profile_id` and `profile_revision_id`.
- Conversation Workspace shows active agent revision and synchronizes runtime selection before send.
- Coordinator suspends runs on pending-interaction tool envelopes without submitting them as normal
  tool observations.
- Inline run cards project approval, pending interaction, permission repair, missing model, and waiting-tool states.
- Context Inspector shows context sources, trust labels, token estimates, and untrusted external-content warnings.
- Tool Center shows manifest-derived tool rows, permission readiness, approval policy, and mode filters.
- Model Center shows active model, local/cloud readiness, and explicit setup blockers.
- Settings shows privacy summaries for tools, attachments, memory, model/provider, and debug mode.
- Debug/Trace surface is behind the advanced debug toggle.

Remaining:

### Agent Builder Card-Backed Publish

- Expand card-backed publish beyond the MVP prompt/persona/tool/context-step slice.
- Wire full context policy, memory policy, selected tools, and skills into the published profile revision.
- Expand Builder context preview into a full source-map trace with memory, skills, attachments,
  and runtime context policy.
- Add validation copy for unsupported cards, missing permissions, and publish-blocking configuration.

### Native Toolkit Additional Adapters

- Connect real file/photo picker presentation to the pending interaction broker.
- Add Share Extension target once Chat capture review exists.
- Add VisionKit scan, OCR, Speech transcription, Maps/geocoding, and Shortcut metadata adapters.
- Harden `web.fetch_url_text` beyond host-literal checks with resolved-address private-network protection.

### Model Download And Provider Setup

- Add local model catalog, download state, storage management, and engine/model compatibility checks.
- Add cloud provider API-key setup, validation, and per-provider readiness.
- Persist active model/provider selection and connect it to runtime defaults.

### Conversation Workspace Polish

- Add polished approval actions, pending interaction recovery, and user-cancel flows in Chat.
- Finish session/branch/fork/edit affordances for everyday use.
- Surface external-content trust warnings in assistant responses, not only in Context Inspector.
- Add agent selector and visible revision drift indicators for old conversations.

### Release Hardening

- Add onboarding, permissions/privacy review, data export/reset behavior, and debug-safe defaults.
- Run full iOS build/test/manual smoke on a machine with Xcode and simulator.
- Audit accessibility, Dynamic Type, and VoiceOver ordering on all product surfaces.

## Rust Follow-Ups

Track separately from the Swift product path:

- Skill package discovery/activation interface.
- Memory extraction and memory-to-context policy bridge.
- Cross-platform tool capability abstraction.
- Context assembly trace API expansion for Builder memory/skills/attachments.
