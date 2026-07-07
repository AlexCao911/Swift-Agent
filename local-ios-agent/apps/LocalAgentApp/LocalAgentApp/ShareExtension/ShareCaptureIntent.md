# Share Capture Handoff

The Share Extension is a future app target that captures user-selected content and hands it to the main app. It is not a model-callable native tool and it must not execute arbitrary Shortcuts.

## Boundary

The extension owns only the system share sheet boundary:

- Read the user-selected share items granted by the system sheet.
- Normalize text, URL, or file inputs into an app-owned capture payload.
- Store file data as attachments before handing control to the main app.
- Open the main app into Chat or Agent Builder through the app intent routing surface.

The main app owns agent selection, context injection, approvals, and final run execution.

## Payload V1

```json
{
  "text": "optional selected text",
  "url": "optional https URL string",
  "attachment_ids": ["att_1"],
  "target_agent_profile_id": "optional profile id selected by user",
  "source_application": "optional bundle identifier",
  "created_at_millis": 1719999999000
}
```

## Rules

- Do not expose raw file paths or security-scoped bookmark data to the model.
- File inputs must become `attachment_id + metadata` before they enter conversation or execution context.
- External text, web text, OCR text, and file text must carry an untrusted external-content provenance label when injected into context.
- If no target agent is selected, route to Agent Builder so the user can choose or create an agent before using the captured content.
- If a target agent is selected, route to Chat with a capture draft that the user can review before sending.
