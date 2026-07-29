# LocalAgent App with Migrated OpenMinis Capabilities and Rust ReAct Core

**Status:** Approved for implementation planning

**Date:** 2026-07-29

**Target:** iPhone and iPad, with one shipping LocalAgent App, a
platform-neutral Rust core, and the existing C++ local-inference backend

## Summary

`LocalAgentApp` remains the product. OpenMinis is a third-party source donor,
not the application trunk:

```text
LocalAgentApp (the only shipping App)
  owns the App target, identity, navigation, Agent Builder, local-model UI,
  App Intents, and product composition
  includes selected migrated OpenMinis product code
    - complete first-pass chat/core UI and UX
    - iSH, Alpine rootfs, terminal, mounts, and file browser
    - tool execution, browser, MCP, media, and native integrations
    - Skills management and filesystem exposure
    - provider settings, OAuth, API Key, Base URL, and model-group UI
    - optional, explicitly selected voice/alarm/widget/extension/backup/sync
      slices
    - the minimal DEBUG measurement helpers required for core validation
  connects those capabilities to the existing Rust/Swift bridge

Rust
  owns the complete provider-neutral Agent Core
    - direct ReAct loop
    - Prompt and Context assembly
    - tool and Skill discovery contracts
    - canonical transcript and projection
    - run cancellation and recovery boundaries

C++
  remains the local model inference backend
```

OpenMinis source is migrated selectively into the current repository and
`LocalAgentApp.xcodeproj`. The final tree does not retain the complete
`OpenMinis/` checkout, `Minis.xcodeproj`, `MinisApp`, or code that has no
caller in the migrated product.

The first migrated core chat UI should preserve OpenMinis appearance and
interaction behavior. Visual redesign and UX refinement are later work.

## Goals

- Keep `local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj` as the only
  shipping App.
- Migrate OpenMinis's mature Swift product capabilities instead of mounting
  the LocalAgent runtime inside the Minis App.
- Preserve the current LocalAgent App identity, Rust bridge, security layer,
  Agent Builder, local-model management, and C++ inference.
- Make Rust the sole owner of a small, standard ReAct agent loop.
- Make Rust Tools and Skills contracts directly compatible with the migrated
  OpenMinis tool definitions, batch executor, and file-based Skills.
- Preserve the existing sequenced, digested, backpressured, epoch-bound
  Rust/Swift transport rather than building a second protocol.
- Keep `LocalAgentLLMCloud` as the only executable cloud HTTP stack.
- Keep the complete first-pass OpenMinis visual behavior for the migrated core
  chat path. Treat peripheral product facilities as exact-file optional
  slices rather than an open-ended “remaining UI” migration.
- Remove unused donor code and duplicate business logic once each migrated
  capability is connected.

## Non-Goals

- Shipping or modifying the Minis App as the product.
- Retaining the full OpenMinis repository as a linked source tree.
- Tracking an upstream OpenMinis commit inside the product.
- Creating an `OpenMinisProductKit` package before a concrete second consumer
  exists.
- Preserving OpenMinis's Swift agent loop, Prompt assembly, canonical
  `ChatStore` writes, concrete Memory implementation, or provider HTTP
  execution as parallel systems.
- Adding a second Rust/Swift transport, projection bus, global cursor, native
  plugin loader, marketplace, or Pi-style hook framework.
- Implementing a concrete m_flow, Memori, Graphify, graph, or vector Memory
  backend in this work.
- Rebuilding OpenMinis UI before the migrated product path is working.
- Claiming iSH guest networking is protected by the cloud-model egress layer.

## Confirmed Product Decisions

1. `LocalAgentApp` is the only shipping App and Xcode application target.
2. OpenMinis is migrated as selected third-party source, resources, tests, and
   native build inputs under the LocalAgent project.
3. Required GPLv3 copyright and license notices are retained; an upstream
   commit record is not required.
4. The first product pass keeps the complete OpenMinis visual design and
   interaction behavior.
5. Existing Agent Builder, local-model download/management/selection, debug,
   and App Intent features remain.
6. OpenMinis voice, alarms/background, App Intents, widgets, Share Extension,
   FileProvider Extension, backup, and eligible sync are independent optional
   slices. None is selected by default or required for core completion.
7. Debug and performance facilities compile only in Debug/Test paths when
   appropriate; they remain available for migration and performance
   validation.
8. Rust owns the complete Agent Core and a direct ReAct loop.
9. Swift performs one complete model request or one complete tool batch when
   Rust asks.
10. C++ local inference and Swift cloud inference implement the same logical
    Rust model-runtime contract.
11. `LocalAgentLLMCloud` is the only executable cloud HTTP transport.
12. OpenMinis provider UI and OAuth flows remain Swift product facilities.
13. Rust is the only assembler of the complete Prompt, Context, conversation,
    Skill metadata, and model-visible tool definitions.
14. Rust is the only writer of the canonical transcript.
15. A trimmed OpenMinis `ChatStore` may remain only as a disposable,
    one-way-projected UI read model.
16. All transcript mutations enter Rust before Swift persistence or
    projection.
17. Tools cross the boundary as one ordered batch and execute concurrently in
    Swift with at most ten in flight.
18. Skills follow Claude-style progressive disclosure.
19. The hard runaway ceiling is `MAX_MODEL_TURNS = 200`.
20. Agent business state machines and generic approval machinery are not
    restored.
21. Necessary transport lifecycle, receipt, epoch, and backpressure state
    remains isolated in `host_adapter`.
22. Raw iSH networking remains enabled by default and is explicitly disclosed
    as an independent high-privilege network path.

## Source and Target Ownership

### Shipping Targets

Keep:

- `LocalAgentApp`;
- `LocalAgentAppTests`;
- existing LocalAgent App Intents and targets;
- migrated OpenMinis widget, share, and file-provider targets renamed and
  configured as LocalAgent targets.

Remove from the final tree:

- `Minis.xcodeproj`;
- `MinisApp`;
- Minis bundle identifiers and shipping schemes;
- the complete donor checkout after required files have moved;
- generated OpenMinis binaries, extracted third-party trees, and rootfs
  artifacts.

Removing generated outputs does not remove their inputs. The LocalAgent tree
retains every required iSH source file, patch, build script, source lock,
license notice, and Xcode reference needed to reproduce those outputs from a
clean checkout.

### Migrated Source Layout

Use the existing App project rather than a new Swift package:

```text
local-ios-agent/apps/LocalAgentApp/
  LocalAgentApp/
    App/
    Composition/
    Presentation/
    Runtime/
    ThirdParty/OpenMinis/
      UI/
      ChatUI/
      ISH/
      Tools/
      Skills/
      Providers/
      Voice/       # only when the optional Voice slice is selected
      Product/     # only for explicitly selected optional slices
      Resources/
    Debug/         # two core validation helpers only
  ThirdParty/OpenMinisNative/
    iSH/
    Patches/
    Licenses/
  scripts/
    native/
    prepare-ios-native.sh
```

The exact subdirectories may be collapsed where OpenMinis files already form
a coherent unit. The boundary is functional: only files with a shipping,
debug, test, build, or resource caller remain.

Do not rename every migrated type merely to erase the donor origin. Rename
only App identity, public product copy, URL schemes, bundle identifiers, and
types whose old name would leak into the LocalAgent product.

### License

Copying GPLv3 OpenMinis and iSH code requires a GPLv3-compatible distribution.
The user has approved that distribution direction. Preserve required
copyright headers, license text, and third-party notices. No donor Git history
or commit identifier is required in the product tree.

## Architecture

```text
LocalAgentApp Swift product
  OpenMinis-derived UI + product facilities
  LocalAgent Agent Builder + local-model UI
  Swift ModelRuntime
    LocalAgentLLMCloud
    C++ local inference adapter
  Swift ToolRuntime
    OpenMinis batch executor
    iSH/file/browser/MCP/media/native tools
  Swift SkillStore + provider/OAuth product stores
                    |
                    | existing HostCommandEnvelope / LLMEventEnvelope
                    | existing receipt, digest, sequence, epoch, backpressure
                    v
Rust host_adapter
  transports complete model requests and tool batches
  owns only transport lifecycle
                    |
                    v
Rust Agent Core
  direct ReAct loop
  Prompt + Context
  tool registry from Swift snapshots
  Skill progressive disclosure
  optional MemoryProvider interface
  canonical transcript + projection
                    |
                    v
Rust canonical storage
```

`RustAgentCoordinator` is a thin Swift connection point. It translates
product actions into existing bridge commands, maintains transient UI
subscriptions, and routes Rust model/tool requests to Swift executors. It
does not own an agent loop, Prompt assembly, transcript truth, or another
business state machine.

## Migrated Swift Product Facilities

### Product Shell and UI

Migrate OpenMinis:

- adaptive iPhone/iPad navigation;
- session list and chat workspace;
- message list, Markdown, code, math, attachments, media, and previews;
- input bar, mentions, slash-command presentation, tool cards, live tool
  sheets, usage, and resumable-run presentation;
- Provider, Skills, MCP, iSH, rootfs, terminal, file browser, mounts, and
  relevant Settings screens;
- onboarding, alerts, product diagnostics, and accessibility behavior.

Integrate LocalAgent:

- Agent Builder as a first-class navigation destination;
- local-model download, installation, selection, and configuration;
- provider/model selection that can choose either a cloud target or the C++
  local runtime;
- existing debug trace views and App Intents.

Keep OpenMinis View code where practical. Reduce `AIChatViewModel` to a Swift
UI facade that:

- submits Rust transcript commands;
- observes canonical projections;
- observes ephemeral run progress;
- owns presentation-only state;
- contains no model/tool loop or final Prompt builder.

### iSH and Filesystem

Migrate the source and resources required for:

- iSH kernel and emulator linkage;
- Alpine rootfs lifecycle;
- shell execution and per-process PID cancellation;
- session filesystem routing;
- terminal emulator and keyboard;
- file read/write/edit and binary/image access;
- static, shared, Skill, attachment, and user-mounted directories;
- native offload integration;
- rootfs and mounted-folder UI.

Native LAME, FFmpeg, iSH, Rust, and C++ artifacts remain platform-isolated for
`iphoneos` and `iphonesimulator`. Device remains the native-script default;
Xcode selects the current platform. Generated artifacts remain ignored.

File tools keep two path domains:

- ordinary absolute guest paths such as `/tmp`, `/root`, and `/usr` resolve
  through the iSH rootfs/fakefs and retain normal guest Unix semantics;
- `/var/localagent/skills`, `/var/localagent/shared`,
  `/var/localagent/attachments`, and `/var/localagent/mounts` are
  Swift-managed host mounts.

Both domains normalize paths and check symbolic links. A guest symlink may
resolve anywhere inside the guest filesystem but not escape it. A host-mount
symlink must remain inside its declared mount and obey that mount's read/write
policy. Rust and tool results never receive the underlying iOS host path.

#### Clean-checkout native build contract

The donor repository must not be required after migration. Retain under
LocalAgent ownership:

- the iSH source snapshot, including source that the donor currently obtains
  through nested submodules;
- the LAME, FFmpeg, iSH, fakefs/rootfs, and platform-selection build scripts;
- OpenMinis/iSH integration sources, local patches, headers, resource
  templates, and license notices;
- a data-only `native-sources.lock` containing the exact version, canonical
  download URL, archive filename, and SHA-256 for every downloaded source.

Do not commit generated frameworks, static libraries, extracted LAME/FFmpeg
trees, fakefs data, `RootfsPatch.bundle`, or `alpine-rootfs.zip`. LAME and
FFmpeg release archives and the Alpine minirootfs are downloaded only through
the locked URLs, verified before extraction, and rejected on a digest
mismatch. The lock is initialized with these verified inputs:

| Dependency | Version/architecture | Canonical URL | SHA-256 |
| --- | --- | --- | --- |
| Alpine minirootfs | `3.21.0`, `aarch64` | `https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/alpine-minirootfs-3.21.0-aarch64.tar.gz` | `f31202c4070c4ef7de9e157e1bd01cb4da3a2150035d74ea5372c5e86f1efac1` |
| LAME | `3.100` | `https://sourceforge.net/projects/lame/files/lame/3.100/lame-3.100.tar.gz/download` | `ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e` |
| FFmpeg | `6.1.2` | `https://ffmpeg.org/releases/ffmpeg-6.1.2.tar.xz` | `3b624649725ecdc565c903ca6643d41f33bd49239922e45c9b1442c63dca4e38` |

One committed entry point runs the migrated scripts in dependency order:

```sh
./local-ios-agent/scripts/prepare-ios-native.sh --platform iphonesimulator
# Or use: --platform iphoneos
```

The order is LAME, FFmpeg, iSH, then Alpine fakefs/rootfs. The command may
reuse a valid local cache, but it must apply the same digest checks. It emits
platform-specific native outputs and the platform-neutral
`alpine-rootfs.zip`, then verifies:

- each library/framework matches the requested Apple platform;
- the matching `RootfsPatch.bundle` exists;
- `alpine-rootfs.zip` exists and contains the expected fakefs data and
  metadata;
- `LocalAgentApp.xcodeproj` places both `alpine-rootfs.zip` and the selected
  `RootfsPatch.bundle` in the App target's Copy Bundle Resources phase.

The documented and CI-supported clean-checkout sequence is therefore:

```sh
./local-ios-agent/scripts/prepare-ios-native.sh --platform iphonesimulator
xcodebuild -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp -sdk iphonesimulator build
```

The same sequence with `iphoneos` must build with signing disabled in CI.
Skipping preparation must fail early with the exact preparation command
rather than producing an App that fails later when `RootfsManager` cannot find
`alpine-rootfs.zip`.

### Tools

Migrate OpenMinis tool definitions, argument repair, preflight, concurrent
execution, progress, result ordering, loop detection, and cancellation for:

- `shell_execute`;
- `file_read`;
- `file_write`;
- `file_edit`;
- `read_image`;
- `browser_use`;
- MCP-discovered tools;
- media and native iOS tools used by the migrated product.

OpenMinis tool code may be reorganized out of `AIChatViewModel` only where
required to expose one batch executor. Do not rewrite working executors for
architectural appearance.

### Skills

Migrate OpenMinis Skills:

- bundled, file, URL, directory, and archive import;
- `SKILL.md` parsing and validation;
- enable/disable and session overrides;
- filesystem storage and iSH visibility;
- management UI;
- eligible non-secret sync.

The migrated Swift store remains the product store. Rust receives a frozen
ordered descriptor snapshot; it does not create a second Skill database.
Every descriptor `location` is a stable tool-visible virtual path such as
`/var/localagent/skills/<skill-id>/SKILL.md`. It is never an iOS container,
App Group, security-scoped bookmark, or other host absolute path.

### Providers and Models

Migrate OpenMinis:

- provider-instance and model-group UI;
- API Key, OAuth, custom Base URL, `/v1`, and protocol-mode product settings;
- OAuth login, refresh, logout, and Keychain product behavior;
- model discovery, custom models, quick tests, and fallback ordering;
- provider-specific product metadata and unsupported-config preservation.

Integrate:

- existing LocalAgent local-model management and C++ selection;
- the current credential boundary;
- `LocalAgentLLMCloud` provider codecs and network security.

Do not retain OpenMinis provider request execution as a second HTTP route.
Missing codecs or provider semantics are ported into
`LocalAgentLLMCloud` only after a compatibility table proves the existing
OpenAI-compatible or other installed codec is insufficient.

### Optional Product Facilities

After the core path works, select and retarget only explicitly approved
vertical slices:

- voice input/output and correction;
- alarms and background behavior;
- donor App Intent behavior reused inside existing LocalAgent intents;
- backup and restore UI;
- widgets;
- Share Extension;
- FileProvider Extension;
- eligible non-conversation sync.

Each slice has an exact source allowlist, focused test, Xcode/resource
membership, migration-manifest rows, and independent commit. Unselected
slices add no source or target and do not affect core acceptance. Broad
“remaining settings,” WebApp, diagnostics UI, or polish migration is not
implied.

When selected, conversation backup/restore uses Rust canonical events and
eligible sync excludes conversation records. Extensions never import
canonical events or write transcript storage.

## Rust Agent Core

### Direct ReAct Loop

The loop is an ordinary function:

```text
persist user command

for model_turn in 1...200:
  stop if cancelled
  build the complete Prompt, Context, conversation, and active tool schemas
  request one model generation from Swift
  stop if cancelled

  if there are no tool calls:
    commit the final assistant turn
    finish

  validate the complete ordered tool batch
  stop if cancelled
  execute the batch through Swift
  validate the complete ordered result
  atomically commit assistant tool calls plus all tool results

finish as resumable if the 200-turn hard ceiling is exhausted
```

One model invocation is one turn. A parallel tool batch does not consume
additional turns. OpenMinis `ToolLoopDetector` stops repeated, unknown,
no-progress, and pathological tool use earlier. The fixed 200-turn constant
is a final runaway backstop and is not exposed as phase-one configuration.

Cancel, retry, error, max-turn, and final-output paths are ordinary branches,
not business states.

### Prompt and Context

Rust is the only final assembler. A run freezes:

```text
RunStartSnapshot
  ordered_prompt_documents[]
  skill_descriptors[]       max 20 visible descriptors
  ordered_tool_definitions[]
  model_context_window      context + reserved output tokens
  snapshot_digest
```

Rust verifies the digest, unique document and tool IDs, JSON object schemas,
and the Skill limit. Swift must not append another:

- base prompt;
- system prompt;
- Skill body;
- Memory fragment;
- MCP prompt fragment;
- tool schema.

Existing Rust Context concepts remain responsible for deterministic ordering,
budgeting, sensitivity filtering, required-segment validation, preview, and
compaction before every model request.

#### Context-window policy and compaction

Compaction belongs only to Rust `context`. It is not a Memory operation:

- canonical conversation events remain the complete durable transcript;
- Context decides which canonical material is visible to a particular model
  turn;
- `MemoryProvider` remains an optional interface for durable factual recall
  and completed-turn fact extraction only.

The frozen run input includes a non-secret model Context snapshot:

```rust
pub struct ModelContextWindow {
    pub context_window_tokens: usize,
    pub max_output_tokens: usize,
}
```

Swift derives the values from the selected model and freezes the smallest
compatible window across the run's fallback candidates. Rust rejects zero or
inverted values before the first model call. The values contain
no model credential, provider session, or HTTP configuration.

`ContextWindowPolicy::for_model(window)` computes all model-visible budgets in one
place. Its default automatic compaction ratio is 70%, but the policy accepts an
injected ratio for tests and future product configuration. The hard input limit
also reserves the selected model's maximum output tokens. No agent-loop code
contains a fixed 32,000-token budget, provider-specific context constant, or
per-tool byte constant.

Rust uses a centralized conservative model-visible estimate. Exact
provider/local tokenizers may replace that counter without changing Context or
the ReAct loop.

Before every ordinary model request, Context applies the cheapest reversible
steps first:

1. preserve the canonical transcript unchanged;
2. keep the latest complete tool-call/result batch model-visible;
3. replace older tool-result bodies with a short stable placeholder while
   retaining call/result pairing;
4. bound the latest batch with a Context-derived shared token budget using a
   head-and-tail preview;
5. assemble and estimate the complete model-visible input;
6. if the estimate reaches the policy threshold, request one text-only summary
   from the current run's frozen model.

The compaction request carries no tools and uses the existing model runtime and
reliable transport. It does not consume one of the 200 ordinary ReAct model
turns. A tool call, empty summary, cancellation, or malformed response fails
the compaction without committing a checkpoint.

On success Rust appends one `BranchSummaryCreated` canonical event containing
the summary and the highest covered conversation sequence. Projection of a
compacted branch produces:

- the model-generated summary;
- the latest exact user instruction;
- the latest complete tool-call/result batch;
- any canonical events after the covered sequence.

This preserves the current task boundary and tool pairing while removing older
ephemeral output from subsequent model requests. It does not delete or rewrite
the covered canonical events. Context then rebuilds the current request from
the checkpoint before normal generation continues.

Only one automatic compaction may run at a given conversation sequence.
Cancellation never commits a checkpoint or starts the ordinary model request.

### Tool Compatibility

Swift supplies the OpenMinis runtime tools as:

```text
ToolDefinitionSnapshot
  name
  description
  input_schema
```

Rust has no duplicate static OpenMinis tool catalog. Its single logical
interface is:

```text
execute_batch(
  batch_id,
  run_id,
  ordered_calls
) -> ToolBatchResult {
  batch_id,
  run_id,
  ordered_results
}
```

Rust validates batch and run identity, unique call IDs, tool names, result
count, call/result pairing, and original order. Concurrency, preflight,
argument repair, PID/task ownership, and per-tool execution strategy remain
private Swift concerns.

Swift keys cancellation entries by `(batch_id, call_id)`. It may run at most
ten calls concurrently. It records loop-detector history per `run_id`, checks
before execution, and records results in original call order after concurrent
tasks have rejoined.

### Skills Progressive Disclosure

Use the Claude-style filesystem model:

```text
skill-name/
  SKILL.md
  scripts/       optional
  references/    optional
  assets/        optional
```

1. At run start Rust exposes only ordered descriptors containing ID, name,
   description, location, and enabled state.
2. When a Skill becomes relevant, the Agent reads its `SKILL.md` through the
   ordinary file tool.
3. Referenced scripts, references, and assets are read or executed only when
   needed.

Do not proactively inject `SKILL.md`, recurse through a Skill directory, or
add a special Skill execution state. `SKILL.md` supplies instructions; normal
tools perform actions.

Rust treats descriptor locations as opaque virtual paths. Swift `ToolRuntime`
resolves Skill paths under `/var/localagent/skills` into the current App
container or App Group only when a file tool executes. Ordinary guest paths
continue through iSH rootfs/fakefs. Every resolution reapplies the relevant
domain's permissions, path-normalization, traversal, and symbolic-link escape
checks. Rust never receives or infers the host path.

### Memory

Evolve the existing unwired `MemoryProvider` into the minimum optional
interface needed by Context. Keep:

- query/recall contribution types;
- completed-turn remember hook;
- a test fake.

Do not add a wire flag until a production Memory provider exists. Concrete
SQLite, HTTP, long-term-memory, graph, or vector implementations with no
production caller are removal candidates, not parallel interfaces.

## Existing Transport, Not a Second Protocol

Logical `ModelRuntime` and `ToolRuntime` calls travel over the existing:

- `HostCommandEnvelope`;
- `LLMEventEnvelope`;
- event and command IDs;
- sequence and digest validation;
- receipts and duplicate detection;
- host-process epoch;
- backpressure and resource lifecycle.

Extend versioned payloads only where whole-model or whole-batch data is
missing. Do not add another callback family except the required canonical
conversation projection observation and its explicit cancellation endpoint.

`agent_loop` imports only model/tool traits, Prompt, Context, conversation,
Skills, optional Memory, and storage. `host_adapter` alone may import
transport lifecycle, receipts, epochs, backpressure, and FFI callback
lifecycle.

## Canonical Transcript and Swift Projection

### Commands

Every model-visible mutation first enters Rust:

- send;
- retry;
- edit;
- delete;
- clear;
- branch;
- archive;
- conversation deletion.

Each command carries `conversation_stream_id` and `request_id`.

Idempotency is keyed by `(conversation_stream_id, request_id)`:

- same canonical payload returns the first stored result;
- a different payload returns `conversation.idempotency_conflict`;
- duplicates never append a second message or start a second run.

One conversation may have at most one active Agent run. A second run-producing
or transcript-mutating command returns stored `conversation_busy` without
executing external effects.

Title, pinned state, selected model, and presentation preferences remain
Swift-owned metadata because they do not change model-visible history.

### Atomic ReAct Persistence

- A final assistant turn commits directly after complete generation.
- A tool round commits assistant tool calls and all validated tool results in
  one transaction.
- Streaming text, reasoning, tool arguments, and progress remain temporary UI
  state until the round is complete.
- A provider, process, validation, or tool failure cannot leave canonical
  assistant calls without paired tool results.

### Projection

Projection uses the existing per-stream event position:

```text
(conversation_stream_id, sequence)
```

There is no global cursor or second projection bus.

`observeTranscriptProjections(conversationStreamId, afterSequence)`:

1. registers a cancellable subscription before querying;
2. replays every stored event after the cursor in strict sequence;
3. switches to live notifications;
4. treats live notification payloads only as wake-ups and re-queries canonical
   storage;
5. detects a gap and re-fetches instead of skipping;
6. unregisters and wakes an idle blocking receiver on cancellation.

Archive and delete projections require no `run_id`. Swift applies projections
idempotently by stream and sequence. Command responses are acknowledgements
only; projection events have one delivery path.

Persistent feeds cover:

```text
running conversations union current conversation
```

With five concurrent runs this is at most six persistent feeds. A dormant
conversation command may create a seventh temporary feed, apply its terminal
projection, and close it. No LRU or arbitrary product-command rejection is
introduced.

### ChatStore

Retain only the OpenMinis `ChatStore` surface needed by the migrated UI as a
rebuildable read model:

- no independent agent-loop drive;
- no direct send/retry/edit/delete/clear/branch persistence;
- no reverse import into Rust;
- no independent canonical cursor;
- no Session/Message/CompactMarker cross-device merge.

On launch or conversation open, Swift catches up from Rust after its durable
per-stream cursor before consuming live events.

## Model Runtime

### Run Plan

The first Swift model call for a `run_id` freezes a non-secret
`ProviderRunPlan` for the entire ReAct run:

- logical selected model;
- provider kind;
- Base URL and protocol mode;
- fallback candidate order.

Changing product settings during a tool round affects the next run, not the
current one. API Keys and OAuth tokens remain late-bound from Swift secure
storage immediately before each request. The run plan is removed on final,
cancel, or error.

### Retry and Fallback

- Before the first text, reasoning, or tool event, Swift may retry or advance
  to the next frozen candidate.
- After any output-bearing event, Swift does not automatically replay.
- User cancellation, Swift task cancellation, and Rust run cancellation never
  retry or trigger fallback.
- Fallback state is local to one `generate(run_id:)` call and the frozen run
  plan; it is never an executor-global boolean or duplicate handler registry.

### Local

Use the existing C++ runtime for model lifecycle, streaming, cancellation, and
usage. The migrated model selection UI exposes local targets alongside cloud
providers and model groups.

### Cloud

Use only `LocalAgentLLMCloud` for executable HTTP. Preserve its HTTPS, redirect,
DNS, SSRF, credential, immutable-profile, retention, response-size, timeout,
and egress behavior.

Build a compatibility table before adding an adapter. OpenRouter and similar
providers should reuse an existing OpenAI-compatible codec plus
endpoint/header presets unless protocol, OAuth, or event semantics prove a
special adapter is required.

## Cancellation

Rust keeps one run-scoped record:

```text
run_id
cancellation_token
optional active_batch_id
```

Cancellation:

1. sets the token and copies the active batch ID inside a short lock;
2. releases the lock;
3. calls Swift model cancellation or batch cancellation;
4. prevents tool start at the model/tool boundary;
5. prevents final or tool-round commit after cancellation.

No mutex is held across Swift, FFI, model, or tool calls. Required race tests
cover cancellation during model generation, between model and tools, and
during tool execution.

## Sync, Backup, and Extensions

- Only the Rust runtime hosted by the main App may open the canonical
  transcript store for writing.
- Share, FileProvider, Widget, App Intent, and other extension processes must
  not open the Rust event store, write `ChatStore`, import canonical events, or
  instantiate another canonical writer.
- Global Skill files/descriptors/enabled state, non-secret provider
  configuration, and eligible product settings may use migrated OpenMinis
  sync. Conversation-scoped Skill overrides remain local while canonical
  conversations do not sync.
- API Keys and OAuth tokens do not sync through ordinary product records.
- Session, Message, CompactMarker, and SessionFile records do not upload,
  download, merge, delete, or restore through OpenMinis ChatStore sync.
- Cross-device conversation sync is deferred until it directly transports
  Rust canonical events.
- Backup and restore are initiated by the main App and use the main App Rust
  runtime to export or import canonical events.
- Import first performs idempotency lookup, blocks new run admission, and
  requires zero active runs. It validates the complete archive before
  writing, rejects the whole import when an incoming conversation stream ID
  already exists, and never merges, overwrites, or silently remaps streams.
  Events and the import receipt commit in one transaction; any failure writes
  nothing. After commit, Rust wakes projection observers for every imported
  stream.
- In this phase, Share Extension writes only a pending draft and attachment
  references to the App Group. FileProvider writes only approved shared,
  Skill, and mounted files. The main App turns a user-confirmed draft into a
  Rust transcript command.
- Do not build a command inbox until an extension has a concrete requirement
  to mutate transcript history. When that requirement exists, the extension
  may only append a command containing a stable `request_id` to an App Group
  inbox; the main App Rust runtime consumes it idempotently. The extension
  still never writes canonical events itself.

## iSH and Security

- Ordinary iSH tools do not enter a general Rust approval queue.
- Native iOS permissions and confirmations remain at the Swift execution
  boundary.
- API Keys and OAuth tokens never enter iSH files, environment, command input,
  logs, tool results, Skills, or mounted shared directories.
- Skill, shared, attachment, and user-mounted directories declare explicit
  read/write access.
- Path traversal, symbolic-link escape, mount visibility, and native-offload
  permissions remain checked before host access.
- Raw guest networking remains enabled by default to match the migrated
  product behavior.
- Settings and first use disclose that guest `curl`, `wget`, package managers,
  and sockets are independent of `LocalAgentLLMCloud` egress controls.
- Shell-command string matching is not represented as a network sandbox.
- Destination filtering requires future enforcement at the iSH
  socket/connect boundary.

## Process Loss and Recovery

- Completed canonical turns survive relaunch.
- A fresh accepted request with no `run_started` may be claimed once.
- A `run_started` record without a terminal event is marked interrupted on
  restart.
- Unknown external tool effects are never automatically replayed.
- The UI can resume from the last complete turn with a new request ID.
- Projection subscriptions always reconnect from their durable per-stream
  cursor.

## Migration Strategy

Do not implement the revised architecture on top of the branch that imported
the complete OpenMinis tree. That history contains roughly 1.48 million donor
lines even if later deleted.

At implementation time:

1. preserve the old branch as a reference;
2. start a clean feature branch from the pre-import LocalAgent baseline;
3. migrate vertical product capabilities into `LocalAgentApp`;
4. transplant only verified native-platform scripts and reusable Rust work;
5. connect and test each migrated capability before retaining its dependencies;
6. remove the donor checkout and any zero-caller source before final product
   verification.

Maintain one lightweight Markdown migration manifest at
`local-ios-agent/docs/openminis-migration-manifest.md`. Each vertical slice
gets one short table with these columns:

| OpenMinis source | LocalAgent target | Xcode target/resource/build phase | License |
| --- | --- | --- | --- |
| donor file or directory | final owned path | concrete target and ownership | required license/notice |

An entry is added when a file or resource is retained and removed when its
production, debug, test, build, or resource caller is removed. This is a
review checklist, not a dependency database or generated inventory. The
implementation plan must name the table updated by each migration task.

Recommended vertical order:

1. LocalAgent App composition, product shell, and the chat UI required to run
   one conversation;
2. iSH/rootfs/filesystem plus file, shell, browser, image, MCP, media, native
   tools, and Skills;
3. provider/OAuth/model UI plus local-model integration;
4. Rust transcript commands and one-way projection;
5. Rust direct ReAct loop, existing envelope extensions, and Swift model/tool
   handlers;
6. one complete LocalAgent Agent product path through the migrated UI;
7. legacy and zero-caller donor removal followed by final core product
   verification;
8. explicitly selected optional product slices, each independently testable
   and committable after the core path exists.

The ordering may group adjacent compile dependencies, but it must not recreate
Minis as a shipping target or introduce temporary production ownership by a
second agent loop. The required implementation chain is core Tasks 1–12,
cleanup Task 15, and validation Task 16. Optional product slices never block
validation of the Rust transcript, ReAct, model, or tool architecture.

## Error Handling

- Prompt, snapshot, or required Context validation stops before a model call.
- Invalid event-kind/payload combinations are rejected on both Swift output
  and Rust input before delivery or lifecycle changes.
- Unknown tools and invalid arguments become ordered error tool results when
  safe; batch identity, count, pairing, or order mismatch rejects the batch
  before canonical commit.
- Provider failure after output is terminal and never auto-replayed.
- Cancellation is terminal and never fallback-eligible.
- Optional Skill catalog or Memory contribution failure emits diagnostics but
  cannot corrupt the transcript.
- Projection overflow or closure ends the feed with an error; Swift reconnects
  from the durable cursor.
- The 200-turn ceiling produces a resumable terminal presentation.

## Validation

Focused tests cover:

- snapshot digest and schema validation;
- transcript command idempotency and busy-stream exclusion;
- atomic tool-round persistence;
- projection replay, gaps, runless events, and idle subscription cancellation;
- model/tool cancellation races;
- tool-batch identity and ordered results;
- per-run tool-loop detection;
- provider-run-plan freezing and cancellation without fallback;
- model-derived Context budgets, 70% automatic compaction, one reactive
  pre-output recovery, and no repeated compaction at the same sequence;
- older tool-result elision, bounded latest-batch previews, preserved
  call/result pairing, and unchanged canonical tool-result events;
- Skill descriptor-only startup and on-demand file reads;
- virtual Skill-path resolution without host-path disclosure;
- source-lock digest rejection and clean-checkout native preparation/build
  for both `iphonesimulator` and `iphoneos`;
- built-App resource inspection proving that `alpine-rootfs.zip` and the
  platform-matching `RootfsPatch.bundle` are present;
- credential isolation, mount traversal, symlinks, native offload, and guest
  network disclosure;
- when an extension slice is selected, its target cannot open or write
  canonical transcript storage;
- migration of Swift UI actions so no direct canonical `ChatStore` write
  remains;
- local and cloud model selection through the same Rust model contract.

Product-level integration is intentionally small:

1. one complete ReAct path covering cloud or local model, multiple concurrent
   tools, final response, and migrated UI projection;
2. one relaunch and canonical projection replay path;
3. one core diagnostic comparison using only the measurement primitives
   ported from OpenMinis `Debug/PerfTrace.swift` and
   `Debug/AgentRequestTrace.swift`, covering streaming order, tool
   concurrency, projection, cancellation cleanup, and process/listener leaks.

Do not repeat every focused error and race scenario in one product-path test.

## Acceptance Criteria

1. `LocalAgentApp.xcodeproj` is the only shipping App project.
2. No `MinisApp`, Minis bundle ID, Minis shipping scheme, or complete
   `OpenMinis/` donor checkout remains.
3. OpenMinis-derived UI provides the first complete chat and product
   experience inside LocalAgentApp.
4. Agent Builder and local-model management remain available in the migrated
   navigation and model picker.
5. Rust exclusively controls the direct ReAct loop and complete Prompt/Context.
6. The loop has a 200-model-turn hard ceiling and no business state machine.
7. Tools use one Swift-executed ordered batch and remain compatible with
   OpenMinis definitions and executors.
8. Skills preload descriptors only, expose tool-visible virtual locations
   without host paths, and read `SKILL.md` plus referenced files progressively
   through ordinary tools; file tools also retain normal `/tmp`, `/root`,
   `/usr`, and other iSH guest paths.
9. Rust is the only canonical transcript writer; migrated ChatStore is a
   one-way read model.
10. Existing envelope reliability remains; no second transport exists.
11. Local C++ and cloud models satisfy one Rust logical model contract.
12. `LocalAgentLLMCloud` is the only executable cloud HTTP stack.
13. API Keys/OAuth tokens remain Swift-only and never enter Rust or iSH.
14. iSH networking risk is disclosed and no false sandbox claim is made.
15. Each explicitly selected optional slice satisfies its exact allowlist,
    focused test, Xcode/resource ownership, manifest, and safety boundary;
    unselected slices do not block core completion.
16. When sync, backup, or extension slices are selected, only the main App
    Rust runtime can write canonical transcript storage and those processes
    cannot bypass it.
17. Context uses the selected model's frozen window, automatically compacts at
    the default 70% policy threshold with the same model, retains only the
    latest complete tool batch at full fidelity, and never treats compaction as
    Memory or destructive transcript rewriting.
18. Zero-caller donor and legacy code is absent from the final tree.
19. A clean checkout can regenerate device and Simulator native/rootfs
    artifacts from digest-locked inputs, and both required rootfs resources
    are present in the built App bundle.
20. Every retained donor file or resource appears in its vertical slice's
    lightweight migration manifest.
21. Focused suites and the three product-level paths pass.

## Implementation Planning Boundary

The implementation plan must rewrite the previous OpenMinis-trunk plan. It
must not preserve these obsolete assumptions:

- importing the complete OpenMinis repository as Task 1;
- using `Minis.xcodeproj` as the shipping App;
- linking the LocalAgent runtime into Minis;
- demoting `LocalAgentApp` to a legacy fixture;
- testing the Minis target as the product path.

Each migration task in the rewritten plan must update its vertical slice's
migration-manifest table. The iSH/native task implements the pinned build
contract and validates the current-worktree Simulator path. Final validation,
after the implementation is committed, exercises one clean-worktree
Simulator/device regeneration before the donor tree is eligible for removal.

The plan may not add:

- another agent-loop abstraction;
- a business state machine;
- a second transport or provider stack;
- a second canonical conversation store;
- a second Skill database;
- a concrete Memory backend;
- a speculative plugin framework;
- reverse ChatStore transcript import;
- a global projection cursor;
- a claimed iSH network sandbox without socket enforcement.

The shortest safe implementation is selective capability migration into the
existing LocalAgent App, followed by direct Rust ReAct ownership and deletion
of donor code with no connected caller.
