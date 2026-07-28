# OpenMinis Product Reuse and Minimal Rust ReAct Core Design

**Status:** Revised after second written-spec review; pending final approval

**Date:** 2026-07-28

**Target:** iPhone and iPad, with a platform-neutral Rust core

## Summary

The product keeps three implementation layers, but OpenMinis becomes the
primary Swift application trunk:

```text
OpenMinis Swift App trunk
  keeps its app shell, UI, tools, iSH, Skills, and product facilities
  integrates the existing Rust bridge, LocalAgentLLMCloud, and C++ adapter
  yields agent-loop control to Rust

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

The migration starts from OpenMinis and integrates the existing project
components into it. It does not copy OpenMinis features one by one into the
current Swift app. OpenMinis keeps its coupled UI, `ChatStore`, tool, and iSH
facilities; only `AIChatViewModel.runAgentLoop` loses control ownership.

The current reliable Rust/Swift transport and Swift cloud security
implementation remain the execution foundations. Logical interfaces named in
this document are mapped onto the existing wire envelopes rather than creating
a second bridge protocol.

This document supersedes the earlier untracked
`docs/openminis-reuse-architecture.md` draft. It also supersedes the custom
Rust Skill Package direction in
`docs/superpowers/specs/2026-07-05-minimal-agent-capability-contract.md`.

## Goals

- Make Rust the sole owner of the ReAct model/tool loop.
- Make OpenMinis the Swift app and product trunk, then integrate the current
  Rust bridge, cloud runtime, security layer, and C++ adapter into that trunk.
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
- Reuse the existing sequenced, digested, backpressured, epoch-bound
  Rust/Swift wire transport.
- Keep Prompt and Context assembly exclusively in Rust.
- Prevent `ChatStore` cross-device data from bypassing the canonical Rust
  transcript.

## Non-Goals

- Reimplementing OpenMinis as a second Rust application framework.
- Transplanting OpenMinis product features piecemeal into the current Swift app.
- Creating a second Rust/Swift request, event, or tool transport.
- Porting Pi's TypeScript extension framework or its full hook surface.
- Building a dynamic native plugin loader.
- Implementing an m_flow, Memori, Graphify, vector, or graph-memory backend now.
- Loading every Skill body into the system prompt.
- Sending API keys or OAuth tokens through Rust FFI.
- Preserving redundant legacy execution abstractions for compatibility.
- Resuming an in-flight provider stream or tool process after process death.
- Adding a general Rust approval workflow for normal tools.
- Adding reverse `ChatStore -> Rust` transcript import.
- Adding a global projection cursor or second projection bus.
- Claiming phase-one iSH guest networking has destination-level sandboxing.

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
13. OpenMinis is the Swift app trunk, not a donor library for the current app.
14. `ModelRequest`, `ModelEvent`, `ToolBatch`, and `ToolBatchResult` are logical
    interfaces, not new wire protocols.
15. Swift exposes one batch tool entry point; Rust never schedules individual
    tools.
16. `LocalAgentLLMCloud` is the only cloud HTTP execution stack.
17. Rust is the only writer of the canonical agent transcript.
18. Rust is the only Prompt, Context, and tool-schema assembler.
19. Agent-loop state is removed; necessary transport lifecycle state remains
    isolated in the host adapter.
20. Phase one disables cross-device conversation synchronization.
21. Phase-one iSH guest networking is an independent high-privilege capability,
    not a protected `LocalAgentLLMCloud` egress path.

## Architecture

```text
OpenMinis Swift App trunk
  - chat and settings UI
  - Prompt and Skill file management
  - provider/model/API key/OAuth configuration
  - existing LocalAgentLLMCloud execution and security
  - C++ local model adapter
  - OpenMinis tools, iSH, browser, native iOS integrations
                    |
                    | existing HostCommandEnvelope / LLMEventEnvelope
                    | existing receipts, sequencing, digest, backpressure,
                    | and host-process epoch
                    | ordered PromptDocument and SkillDescriptor snapshots
                    v
Rust host_adapter
  - existing envelopes, receipts, epoch, digest, backpressure
  - necessary transport delivery and resource lifecycle
                    |
                    | ModelRuntime / ToolRuntime logical interfaces
                    v
Rust agent_loop
  - direct ReAct loop
  - Prompt Markdown composition
  - Context assembly and budgeting
  - Skills progressive disclosure
  - MemoryBackend interface
  - conversation/session data
  - completed-turn persistence and per-stream events
```

### Logical Core Boundary and Existing Wire Transport

The generic Rust loop is written against these logical contracts:

```text
ModelRequest  <-> ModelEvent
ToolBatch     <-> ToolBatchResult
PromptDocument[] -> compiled prompt
SkillDescriptor[] -> ContextContribution
MemoryBackend -> MemoryContribution[]
```

These names describe responsibilities inside the core; they do not authorize a
parallel FFI or serialization protocol. The Swift bridge continues using the
existing:

- `HostCommandEnvelope` command path;
- `LLMEventEnvelope` event path;
- stable command/event IDs and sequence numbers;
- canonical payload and envelope digests;
- event receipts and duplicate detection;
- backpressure and capacity notifications;
- session handles and host-process epochs.

Where the existing envelope does not yet carry a whole tool batch, evolve its
versioned command/payload schema and reuse the same delivery machinery. Do not
add a second callback channel, queue, receipt scheme, or transport abstraction.
The migration removes business-state-machine meaning from Agent Core while
preserving the reliable communication layer.

The Rust module boundary is:

```text
agent_loop/
  depends only on ModelRuntime, ToolRuntime, Prompt, Context, Skills, Memory,
  conversation, and persistence interfaces

host_adapter/
  implements ModelRuntime and ToolRuntime over the existing envelopes
  retains receipts, sequence checks, epoch checks, backpressure,
  delivery acknowledgements, and required resource lifecycle
```

`agent_loop/` must not import `HostExecutionPhase`, `ResourceLifecycle`, event
receipts, prepared host sessions, or host epochs. Those types may remain inside
`host_adapter/` where required for reliable transport. The "no state machine"
rule does not authorize deleting transport acknowledgements or lifecycle
tracking.

Agent-only states and transitions are still retired: `RunMachine`, generic
approval flow, suspended-for-approval behavior, and any
`HostExecutionPhase` variants that have no remaining transport purpose after
the batch migration.

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
prepared host sessions
Swift callback lifecycles
```

iOS-specific delivery reliability remains in the Swift/Rust bridge adapter,
but it does not define agent-loop semantics. A future desktop or server host
may implement the same logical interfaces with a different transport.

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

Swift `ModelRuntime` owns retry and fallback because it owns model
configuration, OAuth, provider compatibility, and model-group ordering. Rust
issues one logical generation request and never receives or stores a candidate
list.

The minimum safe replay rule is:

- before the first text, reasoning, or tool-call event, Swift may automatically
  retry or advance to the next configured fallback candidate;
- after any such output-bearing event, Swift must not automatically replay the
  generation;
- a post-output failure is returned to Rust as a terminal normalized failure
  and requires an explicit user retry.

This avoids duplicate billing, duplicate visible output, and repeated tool
calls. API keys, OAuth tokens, provider request construction, retry counts, and
fallback ordering all stay in Swift.

### Cancellation

- Rust stops issuing new model and tool requests.
- Swift cancels the active provider task, C++ generation, iSH processes, and
  native tool tasks.
- The Swift batch executor owns a per-call cancellation registry keyed by call
  ID. Each entry retains the task handle and every iSH PID created for that
  call.
- Every started tool call receives a terminal success, error, or cancelled
  result.
- A cancelled batch remains correctly paired as assistant tool calls followed
  by tool results.

OpenMinis's current `runningCommandPids` computed property is not sufficient:
it maps back to one `runningCommandPid`. It must not be treated as proof that a
concurrent batch is fully cancellable. Fixing per-call cancellation is a
localized Swift batch-executor change and adds no Rust state.

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

Rust is the sole assembler of the complete system prompt, messages, Context,
and model-visible tool definitions. On the new runtime path, Swift receives
that completed input and only encodes it for the selected local or cloud
backend.

The new OpenMinis `ModelRuntime` path must not call or append:

- `SystemPromptBuilder`;
- `baseSystemPrompt`;
- `SkillStore.skillPromptFragment`;
- OpenMinis global or daily memory injection;
- `MCPStore.systemPromptSnippet`;
- a separately rebuilt `makeAgentTools()` schema.

Any model capability fragment or product prompt that remains useful must enter
Rust first as a `PromptDocument`, `ContextContribution`, or registered tool
definition. Swift must not mutate the already-budgeted input.

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

### Existing Memory Code Migration

The current Rust `memory` module contains SQLite, HTTP, long-term-memory, and
other concrete implementations. The implementation plan must audit their
production callers rather than assuming the codebase is already interface
only.

The target surface contains only:

- `MemoryBackend`;
- the contribution and scope data needed by Context;
- a test fake.

Concrete memory implementations without production callers are deleted, not
extended. Storage primitives that are still required for the canonical
conversation or event log are moved to a neutral storage namespace if needed;
they are not preserved as an accidental concrete memory backend.

## Tool Runtime

### Registration

Swift/OpenMinis publishes runtime tool definitions containing:

```text
name
description
JSON argument schema
```

Rust maintains the active tool table for model input and validates that every
model call references a registered name. Concurrency and serialization rules
are private Swift executor policy and are not exposed across the Rust boundary.

### Batch Contract

Rust has exactly one tool execution interface:

```text
execute_batch(ordered_calls) -> ordered_results
```

The logical batch contains:

```text
batch_id
run_id
ordered_calls[]
```

Each call contains its source index, call ID, tool name, and arguments.

Swift/OpenMinis:

- reuses existing argument repair and tool-specific preflight;
- chooses its internal parallel or sequential execution policy;
- executes concurrent calls with at most ten in flight;
- reuses iSH, file, browser, memory-tool, and native offload implementations;
- owns every per-call task handle and iSH PID;
- returns progress for UI when available;
- returns exactly one terminal result per call in source order.

Rust verifies batch identity, unique call IDs, result count, and result order.
Individual tool failures become `is_error = true` tool results and normally
return to the model instead of failing the whole run.

The existing `HostToolBatchExecutor::execute_tool` plus Rust-side sequential
loop is replaced, not wrapped. Batch commands and results travel over the
existing command/event envelope machinery.

### Approval Policy

- ordinary iSH guest operations do not enter a Rust approval queue;
- iOS system permissions use native system prompts;
- irreversible host-side operations may request confirmation inside Swift;
- a security-policy denial returns an error tool result;
- Rust does not model approval as an agent-loop state.

### iSH Security Boundary

Removing generic Rust approvals does not weaken the host boundary:

- API keys and OAuth tokens never enter the iSH filesystem, process
  environment, command input, logs, or tool results;
- Skill directories, shared directories, and user mounts declare explicit
  read-only or read-write access;
- path traversal, symbolic-link escape, and native-offload permission checks
  remain enforced in Swift before host access;
- OpenMinis `ToolLoopDetector` remains in the Swift tool executor;
- Rust enforces one simple configurable maximum number of model/tool turns.

The maximum-turn counter is a loop budget, not a state machine.

OpenMinis currently gives the iSH guest its own DNS configuration, including
public-DNS fallback, and guest processes can open sockets independently.
Therefore phase one treats raw iSH networking as a separate high-privilege
capability:

- it is not protected by `LocalAgentLLMCloud` HTTPS, SSRF, DNS, redirect, or
  egress policy;
- `curl`, `wget`, package managers, and other guest processes may use that
  independent network path;
- shell-command string inspection is not a network security boundary and must
  not be presented as one;
- product UI and security documentation must disclose this boundary wherever
  raw guest networking is enabled;
- API keys and OAuth tokens remain excluded from the guest even though the
  guest has independent network access.

Destination filtering, private-address denial, and DNS policy require a future
implementation at the iSH socket/connect boundary. They are not claimed or
scheduled in phase one.

## Model Runtime

Rust sends one logical provider-neutral generation request at a time over the
existing command envelope. Swift resolves the configured local model or cloud
model group internally.

### Local

Swift continues using the current C++ adapter for:

- model lifecycle;
- message/template rendering at the appropriate existing boundary;
- streaming;
- cancellation;
- usage where available.

### Cloud

`LocalAgentLLMCloud` is the only executable cloud HTTP stack. It remains the
cloud execution and security base because it already provides:

- provider-semantic codecs and validation;
- HTTPS, redirect, DNS, and SSRF restrictions;
- credential generation/lease behavior;
- immutable provider-profile revisions;
- egress and retention policy;
- response limits, timeouts, and ephemeral sessions;
- capability discovery and validation;
- OpenAI Responses, Anthropic Messages, Gemini, xAI, DeepSeek, MiniMax, and
  GLM adapters.

OpenMinis remains responsible for the product surface:

- richer provider and model configuration UI;
- custom Base URL and `/v1` behavior;
- Chat Completions versus Responses selection;
- model refresh, custom models, and quick tests;
- OAuth login and refresh flows;
- OpenRouter and Kimi Code support;
- import/export without secrets by default;
- forward-compatible unsupported-provider preservation;
- model groups and ordered fallback configuration;
- model selection, testing, and user-visible errors.

Missing provider codecs and compatibility behavior discovered in OpenMinis are
ported into `LocalAgentLLMCloud` and exercised through its existing transport
and security policy. OpenMinis provider HTTP adapters are not retained as a
second executable route. The same provider must never be reachable through two
HTTP stacks.

OAuth login may originate in OpenMinis UI, but token storage, refresh use, and
authenticated provider requests flow through the existing credential and
transport boundaries. API keys and OAuth tokens remain Swift-only and are
never passed into Rust or iSH.

Model retry and fallback are internal `ModelRuntime` behavior and obey the
pre-output-only replay rule above.

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

Subject to the license gate, OpenMinis is the primary Swift application source
tree and product trunk. The migration integrates the current Rust bridge,
`LocalAgentLLMCloud`, security layer, and C++ local-model adapter into
OpenMinis. It does not progressively copy OpenMinis screens and tools into the
current `LocalAgentApp`.

Keep OpenMinis ownership of:

- iPhone/iPad app shell, navigation, and adaptive layouts;
- chat/message UI, Markdown, attachments, voice, share, widgets, and intents;
- provider/model settings and OAuth screens;
- Skills import, storage, editing, enablement, and sync;
- iSH build, Alpine rootfs, shell execution, PID cancellation, and mounts;
- file, browser, image, media, MCP, and native iOS tools;
- concurrent tool execution and result ordering;
- relevant onboarding and diagnostics.

Replace only the control ownership of
`AIChatViewModel.runAgentLoop`: user actions enter the Rust ReAct loop, which
requests model generations and complete tool batches from Swift. Existing
OpenMinis tool code may remain colocated with `AIChatViewModel`; it does not
need to become a standalone library before migration.

The current tool code mutates `AIChatViewModel.messages`, `ChatStore`, and UI
state directly. Preserve transient progress and presentation behavior, but
route durable transcript changes through the Rust event projection described
below. Localized suppression or extraction of direct `ChatStore` transcript
writes is permitted; wholesale tool rewrites are not.

## Persistence Ownership

- Rust is the only writer of the canonical provider-neutral agent transcript
  and completed ReAct turns.
- OpenMinis `ChatStore` remains only a local UI/search read model for
  conversation data.
- Projection reuses the existing per-stream event position:
  `(stream_id or run_id, sequence)`.
- Swift records the last applied sequence separately for each stream and
  ignores events at or below that sequence.
- Projection is one-way: Rust to `ChatStore`. There is no bidirectional
  transcript synchronization and no independent Swift transcript append.
- Transient UI progress may update `AIChatViewModel.messages`, but it cannot
  become canonical history or independently drive the agent loop.
- On restart, Swift resumes each stream after its saved sequence; it never
  infers missing canonical messages from `ChatStore`.
- No global projection cursor, global event number, or separate projection bus
  is introduced.
- Swift owns provider profiles, credentials, model installations, Skill files,
  iSH filesystem data, and iOS UI preferences.
- C++ owns no product persistence.

### Phase-One Cross-Device Sync

OpenMinis currently uploads and downloads `Session`, `Message`,
`CompactMarker`, and `SessionFile` records. Remote records would mutate the
local `ChatStore` without entering Rust, so this path is incompatible with a
Rust-canonical transcript.

Phase one disables upload, download, merge, deletion propagation, and restore
for those conversation record types. Cloud sync may remain enabled for product
data such as Skills and provider configuration, subject to their existing
secret-handling rules.

Do not add a `ChatStore -> Rust` import or reverse-projection protocol to retain
the current conversation sync. Cross-device conversations are deferred until
the sync format directly carries Rust canonical event streams.

## Legacy Simplification

After production callers move to the direct loop, remove or retire:

- `ExecutionReactWorker`;
- `RunMachine`;
- old `ToolLoopService`;
- generic tool-approval queue and approval FFI;
- unused `PluginModule` / `RuntimePluginRegistry`;
- custom Rust Skill Package types;
- concrete memory implementations with no production callers;
- `agent_loop/` dependencies on iOS host lifecycle contracts.

Deletion occurs only after caller searches and replacement tests confirm that
the production path no longer depends on each item.

Existing archived plans and older design documents remain historical records;
they are not compatibility requirements.

## Error Handling

- malformed model events fail the current generation without corrupting the
  last completed turn;
- a generation failure after any output-bearing event is terminal and is not
  automatically replayed;
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
2. The shipping Swift app is based on the OpenMinis app trunk; the migration
   does not recreate its product features inside the current app shell.
3. Existing `HostCommandEnvelope`, `LLMEventEnvelope`, receipt, sequence,
   digest, backpressure, and epoch machinery carries the new loop traffic;
   there is no second wire protocol. Necessary lifecycle state remains inside
   `host_adapter/` and is absent from `agent_loop/`.
4. Multiple tool calls cross the boundary through one
   `execute_batch(ordered_calls)` request and return in source order.
5. Rust exposes no tool execution-mode field and performs no per-call
   scheduling.
6. Cancelling a batch cancels every per-call task and every recorded iSH PID;
   no started call lacks a terminal result.
7. A failure before model output may retry/fallback inside Swift; a failure
   after text, reasoning, or tool output does not automatically replay.
8. Rust never receives a model candidate list or provider secret.
9. `ChatStore` projection is one-way and idempotent using
   `(stream_id or run_id, sequence)`; no global projection cursor exists.
10. No API key or OAuth token appears in iSH files, environment, logs, or tool
    results.
11. Phase-one cloud sync excludes `Session`, `Message`, `CompactMarker`, and
    `SessionFile` upload, download, merge, deletion, and restore.
12. OpenMinis `ToolLoopDetector` and a simple Rust maximum-turn budget both
    stop runaway loops.
13. Exactly one cloud HTTP execution stack exists:
    `LocalAgentLLMCloud`.
14. Rust deterministically assembles the complete Prompt, Context, messages,
    and tool schema. The Swift runtime performs no second base-prompt, Skill,
    Memory, MCP, or tool-schema injection.
15. Uploaded OpenMinis Skills appear as Rust-generated metadata and their
    `SKILL.md` files are read on demand through ordinary tools.
16. A fake `MemoryBackend` can be swapped without changing the ReAct loop, and
    unused concrete memory implementations have been removed.
17. Cloud and C++ local generation satisfy the same Rust model contract.
18. Existing cloud transport, credential, egress, and retention security tests
    continue to pass.
19. The platform-neutral loop imports no Apple, Swift, Keychain, URLSession,
    iSH, `HostExecutionPhase`, `ResourceLifecycle`, receipt, or epoch types.
20. Mount permissions, path traversal, symbolic links, and native offload have
    explicit security tests. Tests and product disclosure also demonstrate
    that raw iSH networking is independent of cloud egress protection.
21. Legacy loop/state/plugin/approval paths have no production callers before
    they are removed.
22. One small end-to-end contract test covers the core loop; focused bridge,
    security, projection, cancellation, and parser tests cover trust
    boundaries.

## License Gate

OpenMinis is licensed under GPLv3. Its iSH dependency is also GPL-licensed and
documents an App Store distribution exception. Direct source reuse must not
begin until the product owner confirms the intended distribution/license model
and legal review confirms the obligations for the combined app.

If direct GPL reuse is not acceptable, this OpenMinis-trunk design is blocked
and requires a separate clean-room product plan. It must not silently degrade
into piecemeal source copying.

## Implementation Planning Boundary

The implementation plan may sequence migration, but it must not expand this
design with:

- another agent-loop abstraction;
- a new business state machine;
- a second Rust/Swift transport;
- a second provider stack;
- a second Skill store;
- a concrete memory backend;
- a dynamic plugin framework;
- a reverse `ChatStore` transcript-import path;
- a global projection cursor or projection bus;
- a claimed iSH network sandbox without socket/connect enforcement;
- speculative compatibility layers.

The shortest safe path is to adopt OpenMinis as the Swift trunk, connect its
model and whole-batch tool facilities to the existing reliable bridge, make
the direct Rust loop authoritative, disable ChatStore conversation sync and
Swift-side Prompt injection, then delete superseded Rust paths and unused
concrete memory implementations.
