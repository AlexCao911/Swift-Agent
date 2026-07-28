# OpenMinis Product Reuse and Minimal Rust ReAct Core Design

**Status:** User-approved design; pending written-spec review

**Date:** 2026-07-28

**Target:** iPhone and iPad, with a platform-neutral Rust core

## Summary

The product keeps its three existing implementation layers:

```text
Swift
  owns the app, OpenMinis product features, model configuration,
  cloud execution, iSH, tools, Skills files, and iOS permissions

Rust
  owns a small provider-neutral ReAct agent loop plus reusable
  Prompt, Context, Skills, Memory, conversation, and persistence components

C++
  owns local model inference and is reached through the Swift model runtime
```

The Rust agent loop follows the OpenMinis/Pi behavior but is not implemented as
a business state machine. It repeatedly assembles model input, requests one
generation, executes an ordered tool-call batch when present, appends the
results, and continues until the model returns no tool calls.

OpenMinis is reused most heavily in the Swift product and tool layers. The
current Swift cloud security implementation remains the execution foundation;
OpenMinis fills product, provider, OAuth, model-management, Skills, and iSH
gaps.

This document supersedes the earlier untracked
`docs/openminis-reuse-architecture.md` draft. It also supersedes the custom
Rust Skill Package direction in
`docs/superpowers/specs/2026-07-05-minimal-agent-capability-contract.md`.

## Goals

- Make Rust the sole owner of the ReAct model/tool loop.
- Keep the loop small enough to understand as one ordinary control flow.
- Preserve useful Rust Prompt, Context, Memory, conversation, and persistence
  work without making those components control the loop.
- Reuse OpenMinis Swift UI, provider configuration, OAuth, Skills, tool
  execution, iSH/Alpine, browser, and native iOS integrations.
- Preserve the current Swift cloud transport, credential, validation, egress,
  retention, and provider-profile security boundaries.
- Execute all tool calls from one model turn as one ordered batch.
- Adopt standard `SKILL.md` progressive disclosure.
- Allow future model, tool, skill, prompt, and memory implementations without
  changing the ReAct loop.
- Remove iOS-specific lifecycle concepts from the platform-neutral Rust loop.

## Non-Goals

- Reimplementing OpenMinis as a second Rust application framework.
- Porting Pi's TypeScript extension framework or its full hook surface.
- Building a dynamic native plugin loader.
- Implementing an m_flow, Memori, Graphify, vector, or graph-memory backend now.
- Loading every Skill body into the system prompt.
- Sending API keys or OAuth tokens through Rust FFI.
- Preserving redundant legacy execution abstractions for compatibility.
- Resuming an in-flight provider stream or tool process after process death.
- Adding a general Rust approval workflow for normal tools.

## Confirmed Decisions

1. Rust owns the complete agent loop.
2. The loop uses a direct ReAct loop, not a business state machine.
3. Swift executes one model generation or one tool batch when Rust asks.
4. C++ local inference and Swift cloud inference share one model-runtime
   contract from Rust's perspective.
5. Swift/OpenMinis executes a tool batch concurrently with a maximum of ten
   in-flight calls, then returns results in source order.
6. Normal iSH guest tools run without a generic Rust approval.
7. iOS permissions and confirmations for irreversible host operations remain
   in Swift at the execution point.
8. Prompt, Context, Skills, and Memory remain independently testable
   components.
9. Skills use uploaded/imported `SKILL.md` directories and progressive
   disclosure.
10. Memory is an interface only in this work.
11. Runtime data contracts, not a plugin framework, provide extensibility.
12. Existing Swift cloud security remains authoritative.

## Architecture

```text
Swift App / OpenMinis product layer
  - chat and settings UI
  - Prompt and Skill file management
  - provider/model/API key/OAuth configuration
  - secure cloud model execution
  - C++ local model adapter
  - OpenMinis tools, iSH, browser, native iOS integrations
                    |
                    | ModelRequest / ModelEvent
                    | ToolBatch / ToolBatchResult
                    | ordered PromptDocument and SkillDescriptor snapshots
                    v
Rust Core
  - direct ReAct loop
  - Prompt Markdown composition
  - Context assembly and budgeting
  - Skills progressive disclosure
  - MemoryBackend interface
  - conversation/session data
  - completed-turn persistence and events
                    |
                    v
C++ local inference
  - model loading
  - generation
  - streaming
  - cancellation
```

### Platform-Neutral Core Boundary

The generic Rust loop knows only these contracts:

```text
ModelRequest  <-> ModelEvent
ToolBatch     <-> ToolBatchResult
PromptDocument[] -> compiled prompt
SkillDescriptor[] -> ContextContribution
MemoryBackend -> MemoryContribution[]
```

It does not know about:

```text
UIKit
Keychain
URLSession
iSH paths or PIDs
OpenMinis database types
provider wire formats
API key bytes
OAuth token bytes
host process epochs
prepared host sessions
Swift callback lifecycles
```

iOS-specific delivery reliability may remain in the Swift/Rust bridge adapter,
but it must not define agent-loop semantics. A future desktop or server host
can implement the same data contracts without Swift.

## Minimal Rust ReAct Loop

The authoritative behavior is:

```text
append the new user message

repeat until cancelled or the run budget is exhausted:
  build Prompt + Context + conversation + available tool definitions
  ask ModelRuntime for one streamed assistant generation
  append the completed assistant message

  if the assistant produced no tool calls:
    commit the completed turn and return

  validate tool names, call IDs, arguments, and batch ordering
  ask ToolRuntime to execute the complete ordered batch
  append exactly one result for every tool call
  commit the assistant tool calls and tool results together
```

The loop is an ordinary function. It does not require `RunState`,
`HostExecutionPhase`, `AwaitingTool`, or approval-state transitions.

### Streaming

`ModelEvent` supports:

- generation start;
- text start/delta/end;
- reasoning start/delta/end;
- tool-call start/argument delta/end;
- usage;
- completion;
- normalized failure;
- cancellation.

Rust emits provider-neutral run events for persistence and Swift UI projection.
Event persistence observes the loop; it does not control it.

### Retry and Model Fallback

The retry policy is deliberately small:

- a retryable model failure receives at most three total attempts on the
  current candidate;
- a permanent candidate failure advances immediately;
- after the current candidate is exhausted, Rust tries each remaining frozen
  route candidate once in order;
- when no candidate remains, the run fails with the last normalized error.

Swift freezes an ordered, secret-free route candidate list at run start.
API keys and provider-specific request construction stay in Swift.

### Cancellation

- Rust stops issuing new model and tool requests.
- Swift cancels the active provider task, C++ generation, iSH processes, and
  native tool tasks.
- Every started tool call receives a terminal success, error, or cancelled
  result.
- A cancelled batch remains correctly paired as assistant tool calls followed
  by tool results.

### Process Loss and Recovery

Recovery is turn-based rather than a replay state machine:

- completed user, assistant, tool-call, and tool-result messages persist;
- an in-flight generation or tool batch is marked interrupted;
- the user may resume from the last complete turn;
- the core does not replay an unknown external side effect automatically.

## Prompt Markdown Documents

Prompt composition remains a Rust component.

Swift or another host supplies an ordered list:

```text
PromptDocument
  id
  source
  markdown
```

Supported sources include:

- bundled base prompt;
- Agent/Profile prompt;
- project prompt;
- session prompt;
- user-imported prompt.

Rust validates unique IDs and concatenates the list in the exact supplied
order using stable separators and source metadata. There is no new Prompt DSL
and no hidden platform-specific precedence.

Swift owns Prompt file import, upload, editing, selection, and display. The
Rust Prompt compiler owns the final deterministic text sent into Context.

## Context

The existing `ContextContribution` and `ContextAssembler` concepts remain.

Prompt, Memory, Skills, conversation, attachments, and tool results contribute
segments. Context remains responsible for:

- deterministic ordering;
- token budgeting;
- required-segment validation;
- sensitivity filtering;
- context preview and trace output;
- compaction or truncation before each model request.

The ReAct loop calls Context once before each generation. Context does not
introduce loop states.

## Skills

### Format

Skills use the common Agent Skills directory format:

```text
skill-name/
  SKILL.md
  scripts/       optional
  references/    optional
  assets/        optional
```

`SKILL.md` must contain `name` and `description` frontmatter. Other standard
fields may be preserved, but the first implementation does not add a Rust
executable-Skill sandbox or capability language.

### Swift/OpenMinis Ownership

Reuse OpenMinis `SkillStore` and related UI for:

- bundled Skills;
- file and URL import;
- directory/archive upload;
- editing;
- enable/disable;
- per-session enable overrides;
- local storage and optional sync;
- exposing files inside the iSH filesystem.

Swift provides Rust with an ordered enabled-Skill snapshot:

```text
SkillDescriptor
  name
  description
  location
```

`location` is host supplied. Rust never constructs
`/var/minis/skills/...` or another platform path.

### Progressive Disclosure

Rust injects metadata for at most twenty enabled Skills into
`<available_skills>`. If additional Skills exist, the prompt reports the
remaining count and instructs the model to use ordinary file/list tools to
discover them.

The model reads the full `SKILL.md` through the normal file tool only after a
Skill is relevant. Relative scripts, references, and assets remain in the tool
execution environment.

There is no special Skill execution state. A Skill supplies instructions; its
actions use normal tools.

### Removed Custom Direction

The following custom Rust concepts are retired:

- `SkillPackageManifest`;
- `SkillSandboxPolicy`;
- `SkillActivation`;
- `InMemorySkillRepository` as the product store.

The existing Context contribution type remains the Rust integration point.

## Memory

This work defines only a replaceable boundary:

```text
MemoryBackend
  recall(query, scope, limit) -> MemoryContribution[]
  remember(events) -> result
  forget(scope or memory_id) -> result
```

The interface must support asynchronous local or remote implementations.
Memory scopes include at least user, agent, and session identifiers without
assuming a particular database schema.

`recall` results enter the existing Context budgeting and sensitivity policy.
`remember` receives completed-turn events after they have been persisted.
Memory failure does not corrupt or block the main conversation transcript.

No concrete backend is included in this design. Future adapters may target:

- m_flow for episodic/procedural graph memory;
- Memori for managed or bring-your-own-database memory;
- Graphify for queryable code/document knowledge graphs;
- another local, remote, MCP, graph, or vector service.

The ReAct loop does not change when a backend is added or replaced.

## Tool Runtime

### Registration

Swift/OpenMinis publishes runtime tool definitions containing:

```text
name
description
JSON argument schema
execution mode
```

Execution mode is `parallel` by default and may be `sequential` for a tool that
cannot safely share a batch.

Rust maintains the active tool table for model input and validates that every
model call references a registered name.

### Batch Contract

`ToolBatch` contains:

```text
batch_id
run_id
ordered_calls[]
```

Each call contains its source index, call ID, tool name, and arguments.

Swift/OpenMinis:

- reuses existing argument repair and tool-specific preflight;
- executes permitted parallel calls with at most ten in flight;
- respects sequential tools;
- reuses iSH, file, browser, memory-tool, and native offload implementations;
- returns progress for UI when available;
- returns exactly one terminal result per call in source order.

Rust verifies batch identity, unique call IDs, result count, and result order.
Individual tool failures become `is_error = true` tool results and normally
return to the model instead of failing the whole run.

### Approval Policy

- ordinary iSH guest operations do not enter a Rust approval queue;
- iOS system permissions use native system prompts;
- irreversible host-side operations may request confirmation inside Swift;
- a security-policy denial returns an error tool result;
- Rust does not model approval as an agent-loop state.

## Model Runtime

Rust sends one provider-neutral `ModelRequest` at a time. Swift selects the
concrete target using an opaque route candidate ID.

### Local

Swift continues using the current C++ adapter for:

- model lifecycle;
- message/template rendering at the appropriate existing boundary;
- streaming;
- cancellation;
- usage where available.

### Cloud

The current `LocalAgentLLMCloud` layer remains the cloud execution and security
base because it already provides:

- provider-semantic codecs and validation;
- HTTPS, redirect, DNS, and SSRF restrictions;
- credential generation/lease behavior;
- immutable provider-profile revisions;
- egress and retention policy;
- response limits, timeouts, and ephemeral sessions;
- capability discovery and validation;
- OpenAI Responses, Anthropic Messages, Gemini, xAI, DeepSeek, MiniMax, and
  GLM adapters.

OpenMinis product/provider code fills missing capabilities:

- richer provider and model configuration UI;
- custom Base URL and `/v1` behavior;
- Chat Completions versus Responses selection;
- model refresh, custom models, and quick tests;
- OAuth login and refresh flows;
- OpenRouter and Kimi Code support;
- import/export without secrets by default;
- forward-compatible unsupported-provider preservation;
- model groups and ordered fallback configuration;
- additional provider-specific compatibility behavior.

The OpenMinis credential store and general HTTP transport do not replace the
current security implementations. API keys and OAuth tokens remain Swift-only.

## Extensibility

The project adopts Pi's useful boundary shape, not its complete extension
system:

- one small ReAct loop;
- runtime model and tool registration;
- provider-neutral events;
- Prompt, Context, Skills, and Memory as replaceable inputs.

The unused compile-time `PluginModule` and `RuntimePluginRegistry` direction is
retired. A new native plugin loader, event-hook framework, marketplace, or
extension SDK is added only when a concrete second implementation needs it.

## Swift Product Reuse

Subject to license review, reuse OpenMinis Swift code wherever it can remain
the product or execution owner:

- iPhone/iPad app shell, navigation, and adaptive layouts;
- chat/message UI, Markdown, attachments, voice, share, widgets, and intents;
- provider/model settings and OAuth screens;
- Skills import, storage, editing, enablement, and sync;
- iSH build, Alpine rootfs, shell execution, PID cancellation, and mounts;
- file, browser, image, media, MCP, and native iOS tools;
- concurrent tool execution and result ordering;
- relevant onboarding and diagnostics.

Do not reuse OpenMinis `AIChatViewModel.runAgentLoop` as the control owner.
Provider and tool functions are extracted behind the minimal Rust contracts,
while its existing UI becomes a projection of Rust run events.

## Persistence Ownership

- Rust owns the canonical provider-neutral conversation and completed ReAct
  turns.
- Swift may keep OpenMinis `ChatStore` as the UI/search/sync read model.
- Swift UI data is projected from Rust events and must not independently drive
  the loop.
- Swift owns provider profiles, credentials, model installations, Skill files,
  iSH filesystem data, and iOS UI preferences.
- C++ owns no product persistence.

## Legacy Simplification

After production callers move to the direct loop, remove or retire:

- `ExecutionReactWorker`;
- `RunMachine`;
- old `ToolLoopService`;
- generic tool-approval queue and approval FFI;
- unused `PluginModule` / `RuntimePluginRegistry`;
- custom Rust Skill Package types;
- core dependencies on iOS host lifecycle contracts.

Deletion occurs only after caller searches and replacement tests confirm that
the production path no longer depends on each item.

Existing archived plans and older design documents remain historical records;
they are not compatibility requirements.

## Error Handling

- malformed model events fail the current generation without corrupting the
  last completed turn;
- unknown tools and invalid arguments become ordered error tool results;
- missing or duplicate batch results reject the whole submitted batch before
  transcript commit;
- memory and Skill catalog failures omit that optional contribution and emit a
  diagnostic;
- Prompt or required Context validation failures stop before a model request;
- cloud security failures remain explicit and are never downgraded to retries;
- cancellation always produces a terminal run event.

## Validation and Acceptance

The implementation is acceptable when:

1. A Rust test drives `user -> model tool calls -> ordered tool results ->
   model final response` without a business state machine.
2. Multiple tool calls execute through one Swift batch and return in source
   order.
3. Cancellation leaves no orphaned tool call.
4. Prompt Markdown composition is deterministic and source traceable.
5. Uploaded OpenMinis Skills appear as Rust-generated metadata and their
   `SKILL.md` files are read on demand through ordinary tools.
6. A fake `MemoryBackend` can be swapped without changing the ReAct loop.
7. Cloud and C++ local generation satisfy the same Rust model contract.
8. Existing cloud transport, credential, egress, and retention security tests
   continue to pass.
9. The platform-neutral loop imports no Apple, Swift, Keychain, URLSession, or
   iSH-specific types.
10. Legacy loop/state/plugin/approval paths have no production callers before
    they are removed.
11. One small end-to-end contract test covers the core loop; focused bridge,
    security, and parser tests cover trust boundaries.

## License Gate

OpenMinis is licensed under GPLv3. Its iSH dependency is also GPL-licensed and
documents an App Store distribution exception. Direct source reuse must not
begin until the product owner confirms the intended distribution/license model
and legal review confirms the obligations for the combined app.

If direct GPL reuse is not acceptable, this architecture still applies, but
OpenMinis behavior must be independently reimplemented behind the same Swift
contracts instead of copied.

## Implementation Planning Boundary

The implementation plan may sequence migration, but it must not expand this
design with:

- another agent-loop abstraction;
- a new business state machine;
- a second provider stack;
- a second Skill store;
- a concrete memory backend;
- a dynamic plugin framework;
- speculative compatibility layers.

The shortest safe path is to introduce the direct loop and batch contracts,
reuse the existing Swift/OpenMinis product facilities, then delete superseded
Rust paths.
