# Local Agent MVP TODO

## Agent Builder UI

Done in the current MVP branch:

- Card-based Builder host is available before the full AppShell.
- Builder can display manifest-backed tool cards.
- Builder can publish a template-backed, Rust-resolvable profile revision.
- Chat handoff stores both `profile_id` and `profile_revision_id`.

Remaining:

- Make publish card-backed instead of template-backed.
- Wire prompt/persona, context policy, memory policy, and selected tools into the published revision.
- Add context preview backed by Rust context trace.
- Add validation copy for unsupported cards and missing permissions.

## Native Toolkit Real Adapters

Done in the current MVP branch:

- Production native catalog is registered through `NativeToolkitClient`.
- Runtime tool calls go through `NativeHostToolDriver` and `NativeToolExecutor`.
- Manifest-less tools fail closed for export and execution.
- `native.list_tools`, `native.permission_status`, and `web.fetch_url_text` use structured tool-result envelopes.
- EventKit calendar search and reminder creation adapters are in place.
- File/photo picker request types and pending-interaction broker contract are in place.
- Attachment read/describe tools return bounded data through opaque attachment ids.
- App-owned App Intents route capture/open actions back into the app.

Remaining:

- Add polished tool approval and pending interaction cards in Chat.
- Register file/photo picker tools in the production catalog once Chat can present pending interaction cards.
- Connect real file/photo picker presentation to the pending interaction broker.
- Add Share Extension target once Chat capture review exists.
- Add VisionKit scan, OCR, Speech transcription, Maps/geocoding, and Shortcut metadata adapters.
- Harden `web.fetch_url_text` beyond host-literal checks with resolved-address private-network protection.

## App Product Frontend

Next main line:

- Build the full workspace shell after Builder-first and first toolkit slice are stable.
- Add agent selector, Tool Center, Model Center, Settings, Permissions, Privacy, and Debug/Trace surfaces.
- Polish Chat for approvals, run state, external-content trust labels, context inspector, branch/fork/edit flows, and pending user interaction recovery.
- Add local model download/selection UI and cloud provider API-key setup.

## Rust Follow-Ups

Track separately from the Swift product path:

- Skill package discovery/activation interface.
- Memory extraction and memory-to-context policy bridge.
- Cross-platform tool capability abstraction.
- Context assembly preview/trace API for Builder.
