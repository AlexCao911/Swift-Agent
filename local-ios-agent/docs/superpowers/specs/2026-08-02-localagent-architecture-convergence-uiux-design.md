# LocalAgent Architecture Convergence and Conversation-First Product Design

**Status:** Design approved in conversation; written-spec review pending

**Date:** 2026-08-02

**Product:** `LocalAgentApp` for iPhone and iPad

**Runtime:** Rust Agent Core + Swift product/runtime host + C++ local inference

## 1. Purpose

LocalAgent has passed through several useful but overlapping product phases:

1. a mobile Agent adapted to the restrictions of iOS;
2. a component-oriented system intended to let users assemble Agents;
3. a migration of OpenMinis product capabilities, especially iSH, tools,
   Skills, providers, and chat facilities;
4. a return to a focused mobile Agent with a Rust-owned ReAct core.

Each phase left scaffolding that made sense at the time. The current repository
now contains several parallel concepts for runtime state, package management,
component graphs, bindings, preparation, approval, transcript access, and UI
configuration. The next stage is convergence, not another platform layer.

The product returns to a small and explicit design:

```text
Rust
  owns the Agent, conversation, Context, persistence, and concurrency semantics

Swift
  owns the Apple product experience, credentials, cloud/local model hosting,
  iSH, browser, filesystem, and native tools

C++
  owns llama.cpp-based on-device inference
```

The implementation keeps working code and removes abstractions whose production
callers disappear. It does not start a clean-room rewrite and does not introduce
a second canonical transcript/Agent store, transport, Agent loop, plugin
framework, or package manager.

This specification supersedes the future architecture, Agent Builder, and UI
direction in the 2026-07-29 OpenMinis migration design. It preserves the useful
contracts already established there: one shipping LocalAgent App, one Rust
canonical transcript, the existing reliable host envelopes, one executable
cloud HTTP stack, virtual Skill paths, atomic tool rounds, process-loss recovery,
credential isolation, and the clean-checkout iSH/rootfs build contract.

For normative precedence:

1. this specification governs the target architecture and product behavior;
2. the 2026-07-29 design remains authoritative for retained OpenMinis source,
   license, pinned native/rootfs inputs, and migration-manifest facts not
   replaced here;
3. older Swift-owned Agent-loop/final-commit designs and the 2026-07-28
   OpenMinis-as-product direction are historical only;
4. current README files describe the implementation until convergence, but do
   not override the target decisions in this specification.

## 2. Goals

- Make the current system easier to understand, start, measure, and change.
- Use Rust where ownership, atomicity, concurrency, deterministic projection,
  Context calculation, and durable data are valuable.
- Keep a direct provider-neutral ReAct loop with no Agent business state machine.
- Keep Prompt, Skills, Tools, model choice, and optional Memory independently
  replaceable without recreating a component graph.
- Replace the heavy component/publish/binding Builder with a flat mutable Agent
  configuration and a usable default.
- Make every conversation own an independent Agent configuration after creation.
- Keep OpenMinis-derived iSH, tools, Skills, provider, browser, and native product
  facilities, while redesigning the shipping UI around Apple conventions.
- Make the primary product path conversation-first on both iPhone and iPad.
- Improve cold start, idle work, memory bounds, recovery queries, and binary size.
- Remove only code that has a verified replacement and no production, test,
  debug, resource, or build caller.

## 3. Non-Goals

- A second Rust Core, workspace of micro-crates, or new Swift package graph.
- A component marketplace, dependency graph, component version resolver,
  lockfile, installer, or upgrade planner.
- User-configurable Context algorithms, compaction thresholds, security policy,
  or low-level permissions.
- A generic native plugin loader or runtime dynamic-link system.
- A concrete long-term Memory implementation in this phase.
- Multi-Agent orchestration in this phase.
- Cron or Hooks in this phase. They remain future product features and do not
  justify registries, buses, or lifecycle abstractions now.
- Reimplementing the existing Skills upload/file management path.
- Reimplementing cloud HTTP beside `LocalAgentLLMCloud`.
- Moving Agent orchestration into Swift or C++.
- Making the complete OpenMinis app, navigation, or visual design the product.
- Removing OpenMinis-derived files that still have a shipping caller merely to
  reduce a line-count metric.
- Claiming that raw iSH guest networking is protected by cloud-model egress
  checks.

## 4. Design Principles

### 4.1 One owner per semantic responsibility

- Rust is the only canonical conversation writer and Agent-loop controller.
- Swift is the only credential owner and Apple product host.
- `LocalAgentLLMCloud` is the only executable cloud HTTP transport.
- C++ is the only local tensor/inference engine.
- Swift `ChatStore` is a rebuildable projection, never a second transcript.

### 4.2 Flat data before runtime graphs

A user Agent is data, not an assembly graph. It is a versioned document with a
small set of fields. A conversation copies that document and evolves its own
copy. A Run freezes one revision.

### 4.3 Direct control flow before state machines

Cancellation, retry, tool execution, compaction, and terminal outcomes are
ordinary branches of a direct ReAct loop. Transport lifecycle state remains
where reliability requires it, but it is not exposed as an Agent business
state machine.

### 4.4 Progressive disclosure

- The product begins with a working cloud-recommended default.
- Advanced provider, model, tool, and diagnostic details appear only when
  relevant.
- Skills expose descriptors first and files only when the Agent reads them.
- Context removes or summarizes transient data before asking users to manage it.

### 4.5 Preserve product behavior through vertical slices

Every removal is preceded by a working replacement and zero-caller evidence.
Each slice keeps the shipping App buildable and one real conversation path
usable. Large deletion batches are prohibited.

## 5. Target Architecture

```text
┌──────────────────────── LocalAgentApp / Swift ────────────────────────┐
│ Conversation-first SwiftUI product                                    │
│ Onboarding · Chats · Chat · Control Center · Settings                 │
│                                                                       │
│ RustAgentCoordinator (thin product facade)                            │
│ Projection read models · Keychain · Provider/Model configuration      │
│ OpenMinis-derived iSH · Files · Browser · Skills · Tool batch runtime │
│ LocalAgentLLMCloud · local-model lifecycle/streaming host              │
└──────────────────────────────┬────────────────────────────────────────┘
                               │ existing versioned host/FFI envelopes
┌──────────────────────────────▼────────────────────────────────────────┐
│ Rust Core                                                             │
│ engine · conversation · profile · host · storage · ffi                │
│ direct ReAct · Context/compaction · canonical events · recovery        │
└──────────────────────────────┬────────────────────────────────────────┘
                               │ coarse local-model calls
┌──────────────────────────────▼────────────────────────────────────────┐
│ C++ / llama.cpp                                                       │
│ load · tokenize · generate · stream · cancel · usage                  │
└───────────────────────────────────────────────────────────────────────┘
```

The target remains one Rust crate. The names above are conceptual ownership
boundaries, not a requirement to create packages or traits for every box.

### 5.1 Rust Core boundaries

#### `engine`

- Direct ReAct loop.
- Per-round Context construction and token budgeting.
- Context compaction and transient tool-output elision.
- Run-scoped cancellation and single-active-run enforcement.
- Atomic validation before final or tool-round commit.
- A hard emergency ceiling of 200 ordinary model turns.

#### `conversation`

- Conversation commands and idempotency.
- Canonical events, variant-path ancestry, active variant ID, effective
  transcript, and derived-conversation lineage.
- Retry, edit, resend, path removal, clear, derive conversation, archive, and
  conversation delete.
- Conversation summaries and replayable Swift projections.
- Process-loss terminalization and restart recovery inputs.

#### `profile`

- Reusable Agents and the default Agent.
- Conversation-owned Agent configurations.
- Ordered Prompt documents, selected Skill IDs, selected Tool IDs, model and
  fallback references, and optional Memory backend reference.
- Full-replacement revisions with optimistic `expected_revision` checks.
- Run-start immutable snapshots and digests.

#### `host`

- The existing logical `ModelRuntime` and `ToolRuntime` boundaries.
- Reliable envelope adaptation, receipts, epochs, sequence/digest validation,
  and resource lifecycle.
- No Prompt, Context, transcript, or Agent policy.

#### `storage`

- SQLite transactions for conversations, Agent configurations, requests,
  projections, summaries, active-run records, and recovery indexes.
- No Memory facts. Memory is a separate optional service contract.

#### `ffi`

- Coarse commands, subscriptions, model requests, tool batches, and cancellation.
- Explicit projection-subscription cancellation.
- No view-specific business logic.

### 5.2 Swift boundaries

Swift keeps one thin product facade, based on the existing
`RustAgentCoordinator` and App composition. Views do not call FFI directly.

Swift owns:

- app lifecycle and adaptive navigation;
- onboarding, conversation UI, Settings, and local projection state;
- Keychain credentials, OAuth, Provider/Base URL UI, and late credential lookup;
- explicit ordered fallback configuration;
- iSH/fakefs, virtual host mounts, browser, file/media/native APIs, and tool
  execution policy;
- Skills upload, enablement, session selection, and virtual-path resolution;
- local-model download, compatibility, lifecycle, and C++ invocation;
- bounded transient streaming presentation.

Swift does not own:

- the Agent loop;
- complete Prompt or Context construction;
- canonical message mutations;
- conversation branching semantics;
- a second provider HTTP implementation;
- a second tool catalog maintained independently of the executable tools.

### 5.3 C++ boundary

C++ remains a narrow inference backend. It receives already resolved local-model
requests and returns streaming model events and usage. It contains no Agent,
conversation, Prompt, Skill, Tool, provider-selection, or UI policy. Models load
lazily and unload according to the existing lifecycle policy.

### 5.4 Ownership and lifetime matrix

| Feature | Owner/source of truth | Scope and lifetime | Deletion/reconciliation |
| --- | --- | --- | --- |
| Provider credential | Swift Keychain | Provider instance | Removed only by explicit Provider action; never exported to Rust/iSH |
| Model target | Swift model store | Immutable target revision | Missing targets put dependent Agents/conversations into repairable state |
| Reusable Agent | Rust profile store | Agent revision | Delete is blocked or tombstoned while needed for audit; existing conversations keep copies |
| Conversation Agent config | Rust conversation/profile store | One conversation, versioned | Full replacement; deleted with conversation retention policy |
| Run snapshot | Rust canonical Run data | One Run, immutable | Retained with Run history/usage; never hot-swapped |
| Prompt documents | Rust profile store; Swift editor only | Agent or conversation revision | Imported/edited Markdown enters Rust through profile commands; missing/mismatched content fails before execution |
| Skill files | Swift Skills store | Global asset; selected by Agent/conversation/turn | Rust sees descriptor and virtual path only; file deletion reports unresolved references |
| Tool definitions | Swift executable snapshot validated by Rust | One Run | No independent Rust static OpenMinis catalog |
| Attachment bytes | Swift managed Attachment Repository | Reference-counted asset shared by turns/variants/derived conversations | Rust stores IDs/verified metadata; bytes purge only after the last reference and retention receipt permit it |
| Conversation/transcript | Rust event store | Conversation stream | Archive/delete/tombstone and effective history are projected one way |
| Streaming UI | Swift projection read model | Current process/Run | Bounded and disposable; canonical replay repairs it |
| Token usage | Rust canonical Run usage | Run, variant path, and conversation aggregate | Rebuilt from persisted usage events, never estimated from rendered text |
| Memory facts | Selected external backend | Backend-defined | Not stored in transcript/Context tables |
| iSH kernel/rootfs | Swift runtime host | App-global lazy runtime; run calls have scoped handles and conversation activity | Kernel closes at App lifecycle boundary; conversation deletion removes only its activity/workspace references |
| Browser workspace | Swift runtime host | One lazy workspace per conversation; Runs borrow it | In-flight calls close at Run end; workspace metadata/tabs close on conversation deletion or explicit Close All |

## 6. Agent and Conversation Configuration

### 6.1 Reusable Agent

A reusable Agent is a flat versioned profile:

```text
AgentProfile
  agent_id
  revision
  name
  optional purpose
  ordered prompt_document_refs
  ordered skill_refs
  ordered tool_ids
  model_selection
  ordered fallback_refs
  default_reasoning
  optional memory_backend_ref
```

Context policy, compaction behavior, security policy, and low-level permissions
are product-managed and are not user fields.

The product supplies one useful default Agent. Users may create, duplicate,
rename, update, delete, and choose another default. Internally, updates create a
new immutable revision; the UI simply says Save.

The initial default is deterministic:

- name `LocalAgent` and a short general-assistant purpose;
- `SOUL.md` with concise helpfulness, honesty, user-control, and mobile-product
  behavior;
- `AGENT.md` with direct ReAct/tool-use rules, progressive Skill reading,
  truthful result reporting, and Context discipline;
- file read/search/write, iSH shell, and browser tool categories enabled;
- personal-data/native tools available in the catalog but disabled until the
  user explicitly enables them and their Swift permission manifest passes;
- only bundled Skills marked `default_enabled` in the shipping Skill manifest;
- the onboarding-selected model, `Auto` reasoning, no fallback, and
  `Memory = None`.

Tests snapshot the default filenames, digests, selected capability IDs, and
policy values so a release cannot silently broaden tool or data access.

### 6.2 Conversation-owned Agent configuration

Creating a conversation copies the selected Agent's complete logical
configuration into a `ConversationAgentConfig`. It is not a sparse override
graph. Subsequent changes replace the complete conversation configuration with
an `expected_revision` guard.

Consequences:

- changing a saved Agent affects only conversations created from it later;
- changing a conversation never changes its source Agent or another conversation;
- model, Prompt, Skills, Tools, and Memory edits in Conversation Control Center
  take effect on the next Run in that conversation;
- an active Run remains frozen to its prior revision;
- saving a newer conversation configuration does not cancel or alter an active
  Run; it becomes the latest revision selected by the next Run;
- an explicit “Save as New Agent” is the only path from a conversation back to
  the reusable Agent library.

The canonical configuration stores stable IDs, order, values, and digests, not
credentials or duplicated binary assets.

### 6.3 Run snapshot

At Run start Rust freezes:

- the conversation Agent revision;
- ordered Prompt document content;
- ordered Skill descriptors;
- executable Tool definitions (`name`, `description`, JSON schema);
- selected model, Context window, output reserve, reasoning level, and fallback
  references;
- attachment metadata visible from the effective Context;
- optional Memory provider reference.

Swift resolves model capabilities, Skill descriptors, and executable Tool
schemas once for that snapshot. Rust supplies Prompt documents from its profile
store, validates all resolved inputs, and assembles the request. Neither side
maintains a second static OpenMinis tool-schema catalog.

Selected Skill references and Tool IDs are authoritative filters. Swift resolves
only selected and currently executable entries. In this phase every selected
entry is required: a missing or invalid Skill/Tool fails snapshot preflight with
an actionable repair result. There is no undefined required/optional flag and no
silent omission. Builder selections must never degrade into descriptive UI that
leaves every tool enabled.

Composer reasoning and one-turn Skill chips are `TurnOverrides` carried by the
send command. They are frozen into that Run but do not rewrite the conversation
Agent configuration. The reasoning control initializes from the conversation
default and may retain the user's last draft choice for convenience.

### 6.4 Cross-store model resolution

Provider credentials and immutable model targets remain Swift-owned while Agent
and conversation profiles are Rust-owned. This boundary is deliberately not
presented as one cross-database ACID transaction or a host-binding saga.

The sequence is:

1. Swift validates/saves a Provider and immutable model target;
2. Swift passes the stable target reference and non-secret capabilities to Rust;
3. Rust creates or revises the Agent/conversation configuration;
4. each Run asks Swift to resolve that frozen reference before generation.

Setup persists non-secret progress after step 1. If the App stops between steps,
it resumes Agent creation using the saved target. An unused target may remain in
Models and can be deleted explicitly; destructive rollback is unnecessary.
If a referenced target is later missing, the Agent/conversation becomes
repairable and cannot start a Run until the user selects a replacement. The
target reference, not a shell-global active Agent or inferred binding order,
restores conversation identity after relaunch.

### 6.5 Digest-bound run preparation

Removing host-binding/preparation objects does not remove their trust checks.
They are replaced by one narrow, idempotent prepare/accept handshake keyed by a
Swift-created `submission_id` that exists before a Rust `run_id`.

Rust sends only an opaque immutable model-target reference, expected target and
parameter/capability digests, conversation configuration revision, and request
identity. Swift resolves the target privately and validates:

- exact target ID/revision and host-process epoch;
- model capability and parameter schema/digest;
- credential kind, current credential generation/lease, and secure availability;
- provider retention and egress policy;
- modality/attachment support and execution readiness.

Swift returns a non-secret `RunStartAttestation` containing matching opaque
identity/digests, host epoch, and generic capability/policy claims. Base URL,
codec details, headers, credential values, and credential-generation material
remain Swift-private. Rust validates the attestation before the first model
request and binds the accepted `run_id` to `submission_id`.

Preparation is idempotent. Before Rust acceptance, Stop cancels by
`submission_id` and Swift releases the prepared route. After acceptance, Stop
resolves the exact `run_id`; Coordinator cancellation requests do not release
the route early, and host `CloseSession` is the single post-accept cleanup
owner. Relaunch reconciliation closes unattached prepared routes and rejects
attestations from an old host epoch.

## 7. Prompt, Skills, Tools, and Memory

### 7.1 Prompt documents

Prompt is an ordered Markdown stack. Product-controlled safety/runtime
instructions remain separate from user-editable documents. User documents may
use names such as `SOUL.md`, `AGENT.md`, or another descriptive filename.

Rust stores each Agent/conversation Prompt document revision, filename, body,
digest, and order. Swift provides the native Markdown editor and file import/
export surfaces, but every mutation is a Rust profile command before it appears
in an effective Run snapshot.

Rust is the only complete Prompt assembler. The model runtime encodes exactly
the messages, system Prompt, and tool definitions supplied by Rust. Swift must
not add a second base Prompt, Skill fragment, Memory injection, or tool catalog.

### 7.2 Skills

Skills follow the mature filesystem progressive-disclosure model:

```text
skill-name/
  SKILL.md
  scripts/       optional
  references/    optional
  assets/        optional
```

- Every Skill edit creates an immutable Skill revision with a content digest.
  Existing global or conversation configurations keep their selected revision
  until explicitly updated.
- Run start exposes only ordered descriptors: ID, immutable revision/digest,
  name, description, enabled state, and virtual location.
- The descriptor count is bounded by one profile policy; the current compatibility
  default is 20, not a constant repeated across layers.
- Full `SKILL.md` content is never proactively injected.
- The Agent reads a relevant `SKILL.md` and referenced files through ordinary
  file tools.
- Locations are stable tool-visible virtual paths such as
  `/var/localagent/skills/example/SKILL.md`, never iOS container paths.
- Swift resolves the stable virtual path through the `run_id` snapshot map to
  the frozen revision, then applies normalization, traversal, mount, digest, and
  symbolic-link checks. Editing a Skill while a Run is active cannot change the
  bytes read by that Run.
- Ordinary Linux guest paths such as `/tmp`, `/root`, and `/usr` continue to
  resolve inside iSH.

The current Swift upload/file-management implementation is retained and evolved
to immutable revisions rather than in-place overwrite. The `/` composer action
selects an already conversation-enabled Skill for the next user turn. The send
command stores its ID in `requested_skill_ids`; Context adds a small structured
hint that the user explicitly requested that Skill while still requiring the
Agent to read `SKILL.md` progressively. Persistent conversation enablement is
edited in the Control Center.

Control Center does not mutate a shared global Skill in place. Viewing uses the
selected immutable revision. Choosing Edit creates a conversation-local copy/
revision and replaces only that conversation's Skill reference. Uploading a
global reusable Skill remains a Skills Library action in Settings; importing
from Control Center creates a conversation-local Skill asset.

### 7.3 Tools

Swift supplies the executable tool snapshot and executes one ordered batch:

```text
execute_batch(batch_id, run_id, ordered_calls)
  -> ToolBatchResult(batch_id, run_id, ordered_results)
```

Rust validates batch/run IDs, unique call IDs, names, result count, pairing, and
original order. Swift owns concurrency, preflight, argument repair, iSH/native
dispatch, per-call cancellation handles, and the per-run loop detector.

Tools may execute concurrently, but results and loop-detector recording are
restored to original call order after tasks rejoin. A cancelled batch cannot
start a later chunk. The Swift product policy defaults to at most ten calls in
flight per batch; later chunks atomically register and re-check cancellation
before dispatch. Multimodal tools are offered only when the selected model and
runtime snapshot declare the required modality.

Model-visible atomicity does not imply that external effects are rollbackable.
Before Swift dispatch, Rust durably journals every stable `(run_id, batch_id,
call_id)` as `planned`; execution receipts advance it through `began`,
`completed`, or `failed`. Process loss/cancellation converts a `began` call with
no trustworthy terminal receipt to `uncertain`. The journal is operational
effect evidence, separate from the model-visible transcript. Only after every
ordered result validates does Rust atomically commit assistant tool calls and
tool results to the transcript.

Recovery never replays `began` or `uncertain` effects automatically. The Run is
Interrupted and Conversation Control Center exposes the bounded call metadata,
status, and native effect receipt so the user can inspect what may have happened.
The existing Swift native effect ledger remains the execution authority for
native idempotency; Rust stores its opaque receipt ID/digest rather than creating
a competing native ledger.

`NativeToolManifest` validation, narrow OS permission gates, and persisted
`pending_user_interaction` records are retained. Before Photos, Files, scanner,
editor, share sheet, or another system UI is presented, Swift persists the
interaction identity and owning Run/call. Relaunch presents a recovery card and
requires a fresh user action; it never silently resumes system UI or repeats an
effect. Only the generic Rust/iSH approval state machine is a deletion candidate.

### 7.4 Memory

Memory means durable, fact-like external knowledge. It is not conversation or
session storage and does not own Context compaction.

Rust retains only a minimal interface:

```text
MemoryProvider
  recall(query) -> contributions
  remember_completed_turn(turn)
```

The current phase keeps the interface, contribution types, and a test fake.
Concrete SQLite, HTTP, graph, vector, m_flow, Memori, or Graphify integrations
wait for a selected production backend. The optional backend reference is part
of Agent/conversation configuration but credentials remain in Swift secure
storage.

Because no production Memory backend is selected in this phase, onboarding and
Control Center omit Memory controls and the deterministic default is `None`.
When a backend is registered later, calls use stable IDs, credentials resolve in
Swift, `remember_completed_turn` is idempotent, and provider failure remains
isolated from canonical transcript commit.

## 8. Direct ReAct Engine

The ordinary loop is intentionally direct:

```text
for turn in 0..200
  check cancellation
  rebuild current model-visible Context
  compact if policy requires it
  request one model generation
  if final text: atomically commit final turn and finish
  validate tool calls
  check cancellation before tools
  execute one ordered Swift tool batch
  validate ordered results
  atomically commit assistant tool calls + all tool results
end
return resumable max-turn terminal outcome
```

There is no general Agent state machine. Errors, retry eligibility, fallback,
cancellation, and tool rounds are ordinary control-flow branches. Necessary
transport phases, receipts, and resource lifecycle remain isolated under
`host`.

One conversation may have at most one active Run. Different conversations may
run concurrently. The target product policy allows at most five simultaneous
conversation Runs; this is a new convergence target, not a claim about the
current global-one host implementation.

Admission is target/resource-aware rather than `min(global, host)`. Rust
atomically acquires one product Run slot and every resource token declared by
the attested target: cloud routes may expose independent capacities, while a
memory-heavy local engine normally exposes one generation token. A local Run
therefore need not block unrelated cloud Runs, but a second Run using the same
saturated local resource is rejected before acceptance.

The product does not hide a queue in this phase. When the fifth product slot or
a target resource is unavailable, send returns `runtime_capacity_busy` before
external effects, preserves the composer draft, and shows the running
conversation/target plus Stop or Retry actions. Tokens release exactly once on
terminal `CloseSession`; startup reconciliation releases leases whose Run is no
longer active. Cross-conversation cloud/local concurrency and relaunch tests
must pass before deleting the current global lease.

Transcript and variant-path mutations during a Run first request cancellation
and wait for a terminal outcome; they
never execute external effects concurrently against the same conversation.
Configuration replacement is different: it may commit a next revision while a
Run is active because the Run already owns a frozen prior snapshot and no
external effect is replayed.

## 9. Context and Compaction

Context is rebuilt for every model round. Only the Run's Prompt documents,
Skill descriptors, tool definitions, provider plan, and Agent revision are
frozen. The current canonical conversation, newly committed tool results,
budget, attachment set, Memory contributions, and compaction projection are
recomputed each round.

### 9.1 Model-derived budget

The selected frozen model supplies its Context window and output reserve. A
single `ContextPolicy` calculates the compaction threshold; the default target
is approximately 70% of the usable model window. The value is configurable by
product/model policy and is not repeated as a hard-coded constant across Rust
and Swift.

### 9.2 Cheap reversible reduction first

Before requesting a summary, Context:

1. preserves the canonical transcript unchanged;
2. retains the latest complete tool-call/result batch;
3. replaces older large tool-result bodies with stable placeholders while
   preserving call/result pairing;
4. applies shared token-derived head/tail bounds to large recent results;
5. derives attachment references from the model-visible segments and restores
   their canonical metadata;
6. estimates the complete model input again.

iSH and other tool runtimes also use bounded execution buffers so Context
compaction is not relied on to prevent execution-time OOM or database growth.

### 9.3 Summary checkpoint

If the reduced input still reaches the policy threshold, Rust sends one
text-only compaction request through the current Run's frozen model plan. It
does not expose tools and does not consume an ordinary ReAct turn.

On success, Rust appends a canonical summary checkpoint containing the covered
sequence, active variant identity, and digest of the effective covered
path. It never rewrites or moves conversation events into Memory. The next
round is rebuilt from:

- the summary;
- the latest exact user instruction;
- the latest complete tool batch;
- events after the covered sequence.

Only one automatic compaction may run for a given effective-path digest and
covered sequence. Edit, retry, path removal, variant switching, or deriving a
conversation invalidates any checkpoint whose path digest no longer matches.
Cancellation, tool calls, malformed output, or an empty summary produce no
checkpoint.

## 10. Conversation Commands, Variants, and Derived Conversations

### 10.1 Commands and idempotency

Every durable operation enters Rust first:

- create conversation;
- send;
- edit and resend;
- resend from an anchor;
- retry an assistant response;
- delete from an anchor;
- clear;
- derive a conversation from an anchor;
- rename, pin, archive, and delete conversation;
- replace conversation Agent configuration.

Every command after creation carries `conversation_stream_id` and `request_id`.
Idempotency is keyed by both. `CreateConversation` instead carries a stable
local `creation_scope_id` and `request_id`; the first result stores and returns
the newly allocated `conversation_stream_id`. The same canonical payload returns
that first result, while a different payload with the same creation or stream
key returns a conflict. Duplicate Swift/FFI submission cannot create a second
conversation, append a message, or start another Run.

Rust also owns conversation title, archive/delete state, active variant ID, and
configuration revision so relaunch does not depend on a partially populated
Swift store. Swift-only appearance and transient navigation preferences remain
outside the canonical model.

### 10.2 Atomic rounds

- A completed assistant final response commits once.
- An assistant tool-call round and every validated ordered result commit in one
  transaction.
- Streaming text/reasoning and partial tool arguments remain transient.
- Cancellation or failure cannot leave canonical tool calls without results.

### 10.3 Message management semantics

Message actions are role-specific.

User messages support:

- Edit & Send;
- Resend from Here;
- Branch from Here;
- Copy;
- Delete from Here.

Assistant messages support:

- Retry Response;
- Branch from Here;
- Copy/Share;
- Delete from Here.

Committed content is not overwritten in place:

- **Edit & Send** restores text, attachment metadata, and explicit one-turn
  Skills into the composer. Submission forks the active variant at that user
  anchor, excludes every dependent suffix message from the new effective path,
  and uses the current conversation Agent configuration.
- **Resend from Here** keeps the original text, attachment IDs, and explicitly
  requested one-turn Skills, forks at the user anchor, excludes the dependent
  suffix, and uses the current conversation Agent configuration plus the
  currently selected reasoning `TurnOverride`.
- **Retry Response** removes the selected assistant response from the effective
  path, excludes every dependent suffix message, and regenerates it with the
  original Run's frozen configuration. If that configuration is no longer
  executable, the UI offers `Resend from Here` on the source user message and
  explains that it uses current settings.
- **Delete from Here** appends a tombstone for the target and dependent current
  path. It never leaves an invalid model history.
- **Branch from Here** creates a separate conversation containing the effective
  history through the anchor and a copy of the source conversation's current
  Agent configuration. The source remains unchanged and lineage is projected
  into both conversation details.

Edit, resend, and retry keep the prior variant path, including its dependent
suffix, accessible through a small previous/next version control. Explicit
Branch creates a derived conversation and a new list item; it is not another
name for a variant path. Retry anchors resolve semantic effective user turns,
including an edited user variant; they are not limited to raw original
`UserMessage` events.

### 10.4 Durable usage

Every generation attempt has a stable idempotent `attempt_id` derived from the
Run, ordinary-round/compaction purpose, generation ordinal, and fallback
candidate ordinal. Whenever a Provider reports usage, Rust records input,
output, cached, and reasoning fields plus Context limit, model identity, purpose,
and terminal state—even for a failed fallback candidate or a cancelled request.
Unsupported fields remain unknown, not zero.

Rust derives two clearly labelled views:

- **Active path usage:** successful/accepted attempts that produced the current
  effective variant path, including its compaction requests;
- **All model usage:** every reported attempt attributed to the conversation,
  including prior variants, failed fallback candidates, compaction, and
  cancellation that may still have been billable.

Provider pricing is shown only when authoritative price metadata exists; token
usage is never presented as estimated cost. A derived conversation copies
history/attachment references but inherits no prior attempt ownership or billed
total; the source retains those attempts, and the derived conversation starts
accounting with its first new model request. Conversation deletion follows the
explicit retention policy in Section 10.5. The Control Center never estimates
usage from displayed text.

### 10.5 Clear, delete, and retention semantics

- **Archive** changes visibility only. Transcript, variants, configuration,
  attachments, usage, and drafts remain recoverable.
- **Delete from Here** is a logical removal from the selected variant path. The
  confirmation explains that another variant or derived conversation may still
  contain the content. It appends a path tombstone and does not claim secure
  erasure of shared ancestors.
- **Clear Conversation** first cancels/waits for an active Run, then atomically
  starts a new empty content epoch for the same conversation configuration. It
  removes every prior message/variant payload, summary checkpoint, Run snapshot,
  usage record, and projection cursor for that conversation, resets title/search
  text to `New Conversation`, removes its Swift draft, and decrements attachment
  references. It is not undoable. Derived conversations remain independent.
- **Delete Conversation** performs the Clear purge and additionally removes the
  conversation configuration, metadata, pins, browser workspace, command
  activity, and Swift projection/draft state.

Clear/Delete retain only a non-content receipt containing stream ID, command
request/digest, deletion epoch, and schema version so retries are idempotent and
sync/import cannot resurrect the record. Attachment bytes are physically
removed when the final canonical reference is gone. Native permission/effect
ledgers retain only the minimum receipt required by their safety contract and no
transcript/Prompt payload.

Deleting a reusable Agent is blocked if it is the default until another default
is chosen. Existing conversations need no Agent reference because they own full
copies. Agent-exclusive Prompt revisions are purged; non-secret legacy migration
mappings remain only while their schema compatibility path is supported.

## 11. Existing Transport and Projection

No second Rust/Swift protocol is introduced. Logical model/tool calls continue
through the existing versioned command/event envelopes, IDs, sequences, digests,
receipts, duplicate detection, process epoch, and resource lifecycle.

Projection uses `(conversation_stream_id, sequence)`, not a global cursor.
Observation registers before replay, catches up from canonical storage, detects
gaps, then consumes live wake-ups. Cancellation wakes and unregisters an idle
listener.

Swift persistent feeds cover running conversations plus the currently open
conversation. With the default five concurrent Runs this is at most six
persistent feeds. A dormant mutation may use a short-lived seventh feed and
close it after the terminal projection. A UI feed is never allowed to reject a
valid product command because of an arbitrary capacity number.

Streaming deltas use bounded coalescing mailboxes. When a consumer is slow,
temporary deltas may be merged or dropped; publishing never blocks the Rust
Agent thread. Final content is recovered from the canonical transcript.

`ChatStore` is a rebuildable, one-way read model:

- launch first lists canonical conversation summaries;
- opening a conversation replays after its durable cursor;
- transient assistant-start/delta events build temporary bubbles and true
  running state;
- final events replace temporary content idempotently;
- no UI action directly mutates persistent `ChatStore` transcript rows;
- archived/deleted tombstones are filtered by Rust summaries and effective
  transcript data supplies titles/search text.

## 12. Model Runtime

### 12.1 Unified logical contract

Cloud Swift hosting and C++ local inference implement one Rust logical model
request contract. Chat and Agent configuration select capabilities, not a
different Agent loop.

### 12.2 Frozen provider plan

The prepare/accept handshake in Section 6.5 freezes a non-secret
`ProviderRunPlan` before Rust accepts the Run. The same plan is used for the
complete ReAct run:

- logical model and modality;
- protocol/codec and Base URL;
- explicit ordered fallback candidates;
- compatible Context window and supported reasoning levels.

Each fallback candidate is a complete immutable route containing its opaque
target revision, Provider/credential reference, origin/codec class, retention
mode, capabilities, and resource identity. A group is valid only when every
candidate supports the frozen tool/modality/reasoning contract. Rust budgets
Context against the smallest compatible window and output reserve in the group.
Swift-private origin, codec, and credential details remain behind the attested
route digest rather than being copied into Rust.

Credentials are read from Swift secure storage immediately before each request.
Changing Settings between tool rounds does not affect the active Run.

Fallback index moves only forward. Once candidate B replaces A, later rounds
start at B and never return to A's stale session. A failed candidate route is
closed. Cancellation never triggers retry or fallback. Automatic fallback is
allowed only before the first output-bearing event. “Output-bearing” means any
accepted reasoning, text, tool-call, or partial tool-argument semantic event,
whether or not the user has seen a completed bubble.

Fallback is opt-in. A newly configured model has one candidate. Advanced Agent
or conversation model configuration may add an explicitly ordered group with
visible priorities; binding IDs, revision IDs, or registry iteration order are
never interpreted as fallback priority.

Swift removes a Run plan on host `CloseSession`. Before Rust accepts a command,
the Coordinator may clean failed preparation; after acceptance it only requests
cancellation and leaves resource cleanup to `CloseSession`. Launch removes
orphan persisted plans that do not correspond to an active Rust Run, and
persistence-cleanup errors are surfaced to diagnostics rather than swallowed.

### 12.3 Cloud

OpenMinis-derived Provider/OAuth/API Key/Base URL product facilities are reused,
but executable requests go only through `LocalAgentLLMCloud`. Existing HTTPS,
redirect, DNS, SSRF, response-size, timeout, retention, and credential controls
remain. Provider presets reuse compatible codecs unless protocol or event
semantics require a specific adapter.

Every initial or resumed cloud turn retains the existing semantic validator and
sealed-request boundary. Swift computes an exact disclosure digest for the
Provider/origin and all transmitted Prompt, message, tool, Memory, and attachment
categories, obtains the applicable scope grant before encoding credentials or
opening the network request, and reauthorizes when later tool/Memory/attachment
content expands the disclosure. Redirects cannot broaden the authorized origin.
The attested Provider plan selects the policy; it does not bypass per-turn egress
authorization.

The Settings support matrix is generated from the tested executable registry,
not a decorative Provider list. The current preset set is OpenAI Responses,
OpenAI Chat Completions, Anthropic, Gemini, xAI, DeepSeek, MiniMax, GLM,
OpenRouter, Kimi Code, and Antigravity, plus a custom OpenAI-compatible origin.
Each row declares API-key header mode and OAuth availability from its shipped
profile. A preset is enabled only when its adapter, authentication flow, model
discovery/manual-ID behavior, validation, and streaming semantics pass the
shipping suite; otherwise it is visibly disabled or omitted rather than failing
after selection.

Known presets show their fixed origin. A custom Base URL requires explicit
origin confirmation after SSRF/redirect validation. Before connection testing,
the UI discloses the exact Provider/origin, credential mode, data sent, and that
the smallest model probe may be billable. A non-billable account/model-list
validation is preferred when the Provider supports it.

### 12.4 Local

Swift presents, downloads, verifies, and manages local models. C++ performs
inference. Local models appear alongside configured cloud models in the same
picker, filtered by device support, available storage, modality, and runtime
readiness. Model loading is lazy.

## 13. Tool Runtime and iSH Security

- Swift batch cancellation is keyed by `(batch_id, call_id)` and checked before
  every chunk/call begins.
- Per-run loop-detector state is released on final, cancellation, and error.
- Shell output uses a bounded head/tail buffer with an explicit truncation
  marker.
- Skill, shared, attachment, and user mounts declare explicit access.
- Path traversal, symbolic-link escape, mount visibility, and native offload
  checks remain at the execution boundary.
- API Keys and OAuth tokens never enter iSH files, environment, commands,
  results, Skills, or mounted directories.
- Raw guest networking remains an independent high-privilege capability. Its
  risk is disclosed when Linux/network tools are enabled or first used.
- Command-string matching is not described as a network sandbox. A real guest
  network policy requires future enforcement at the socket/connect boundary.

Opening Conversation Control Center to inspect Terminal or Browser status does
not initialize iSH, WebKit pools, a local model, or provider sessions. The
runtime is created only when the user opens/uses that capability or a Tool Run
requires it.

The iSH kernel/rootfs is one App-global lazy runtime; the product does not claim
that Linux filesystem state is isolated per conversation. Each conversation has
a stable working-directory/mount context and an activity stream, while each
Tool call has a run/call cancellation handle. Control Center Command Activity
attaches to that same stream. A future interactive PTY, when implemented, is a
conversation-scoped shell session over the same kernel—not a second iSH runtime.

Browser tools and the visible conversation Browser converge on one
`ConversationBrowserWorkspace` keyed by `conversation_stream_id`. Runs borrow
the workspace; host `CloseSession` cancels in-flight navigation/evaluation but
does not create or transfer tabs to a separate UI pool. WebViews are lazy and
evictable under memory pressure while bounded tab metadata can restore the
workspace. Conversation deletion or explicit Close All releases it. Global
browser privacy/cookie policy remains Settings-owned, while tabs, downloads,
and activity are conversation-scoped.

### 13.1 Attachment lifecycle

Swift owns an App-managed Attachment Repository. Import first obtains a file
representation and checks configured per-file/total limits before loading or
copying bytes. A completed asset has an opaque `attachment_id`, content hash,
verified byte size, MIME/UTType, modality/dimensions where applicable, source/
privacy label, and managed-storage location. Rust receives only the ID and
verified metadata; host paths never enter Prompt, transcript, tools, or FFI.

Variants and derived conversations reference the same immutable asset by ID.
The repository reference-counts canonical references, so deleting the source
conversation cannot remove bytes still used by another conversation. Export
creates a user-selected copy. The original external picker URL/bookmark is not
required after successful managed import.

There are two explicit model-visible routes:

1. **Tool attachment:** the asset appears under the conversation's virtual
   `/var/localagent/attachments` mount and Context exposes its ID, type, and
   virtual path so ordinary file/media tools can inspect it.
2. **Direct multimodal attachment:** only a model/provider declaring the exact
   modality receives resolved bytes or a provider upload reference.

Before enabling direct cloud transmission, the adapter must implement and test:

- attachment-ID resolution from managed storage;
- hash, size, media-type, and model-capability validation;
- exact Provider/origin egress disclosure and approval where required;
- bounded inline encoding or upload streaming;
- provider upload/reference retention and cleanup;
- cancellation, retry idempotency, and response-size/error behavior;
- local-cache/reference deletion after the final canonical reference.

Until a cloud adapter satisfies that contract, the UI may attach a file for
Tool access but labels direct multimodal delivery unsupported. If the requested
message requires direct modality, Send remains disabled and offers a compatible
local/cloud model; the executable cloud validator must not receive an unsupported
attachment-bearing turn.

## 14. Performance Convergence

Performance work begins with measurement and deletion, not speculative caches.

### 14.1 Baselines

Record Debug and Release measurements for:

- cold and warm App launch;
- Rust initialization;
- first conversation restoration;
- first cloud request and first local request;
- idle CPU wake-ups and SQLite transactions;
- resident memory before and after iSH, browser, and local-model activation;
- 0, 100, and 1,000 conversation summaries;
- 10,000 and 100,000 canonical events;
- linked App and Rust binary size.

### 14.2 Direct improvements

- Replace 250 ms redispatch and host-response polling with event-driven
  notifications/condition variables plus explicit deadlines.
- Query indexed incomplete runs during recovery instead of scanning historical
  streams.
- Gate schema migration by stored schema version rather than replaying work at
  every launch.
- Keep projection and streaming channels bounded and nonblocking.
- Share immutable Prompt, Skill, Tool, and run snapshots instead of repeatedly
  cloning large values.
- Keep FFI calls coarse: one command, one model request, one tool batch, one
  replay subscription.
- Initialize iSH, Browser/WebKit, Provider routes, and local models lazily.
- Remove duplicate registries and preparation objects before adding caches.

Every optimization must move at least one measured startup, RSS, idle-work,
latency, or size metric without weakening correctness.

Phase 0 records the reference device, OS, build configuration, fixture seed,
thermal state, and command used for each metric. Release-gate comparisons use at
least five repetitions and the median. Until a metric has an explicit product
budget, any regression greater than 10% or outside normal run-to-run variance is
investigated and documented rather than silently accepted; this is a review
gate, not a promise to fail a build on simulator noise.

## 15. Architecture Slimming

The target Rust crate contains a small number of real boundaries. The following
are deletion/consolidation candidates, not an unconditional bulk delete:

- `agent_package` installer/lockfile/upgrade planning;
- generic `protocol` plugin modules, typed registries, instance graphs, and
  runtime plugin registries;
- `user_customization` component catalogs, component graph, assembly plan,
  safety/publish ceremony, and template/binding resolution;
- legacy `core` runtime/session-tree/run-state paths superseded by
  `conversation` and the direct ReAct engine;
- legacy `execution` planning, the generic Rust/iSH approval queue, and duplicate
  run lifecycle paths superseded by `agent_loop`, `host`, and native Swift
  checks; `NativeToolManifest`, OS permissions, persisted user interaction, and
  the native effect ledger are explicitly retained;
- `run_snapshot` binding/preparation abstractions superseded by the flat profile
  and Run snapshot;
- host-binding/profile-migration/preparation sagas after current production
  routes use the direct model/tool contract;
- the current global-one Run lease, after per-conversation exclusion, the
  five-slot product admission counter, and attested resource tokens become
  production-authoritative;
- duplicate conversation repositories, frames, branch readers, wrapper services,
  and debug stores after `ConversationStore` has their required callers;
- concrete or duplicate Memory implementations without a production backend;
- old Swift card Builder, Review/Validate/Publish UI, duplicate model/provider
  destinations, route families, and wrappers with no shipping caller.

### 15.1 Persisted-data migration gate

Existing installations may contain published Agent revisions, Swift model
targets/host bindings, Swift Prompt documents, and conversations that were
previously resolved through a shell-global Agent. Those stores cannot be
deleted merely because the target model is simpler.

Before removing their readers, one idempotent migration must:

1. assign stable legacy-to-new IDs and a schema migration marker;
2. import each published Agent's name, instructions/Prompt content and order,
   selected Skills/Tools, immutable model-target reference, parameters, and
   optional Memory reference into a validated Rust `AgentProfile` revision;
3. create a `ConversationAgentConfig` from the last canonical Run identity when
   it exists, otherwise from an explicitly persisted default Agent—not the first
   record returned by a registry;
4. mark a conversation `configuration_repair_required` instead of guessing when
   neither identity is recoverable;
5. keep credentials and model targets in Swift and verify every imported target
   reference resolves without copying secrets;
6. import Swift Prompt documents through Rust profile commands with content
   digests, preserving the old store until readback matches;
7. commit each Agent/conversation migration transactionally and make reruns
   return the first stored mapping;
8. retain a read-only compatibility path until all records pass validation and
   the shipping App has completed at least one successful migration/relaunch
   cycle.

A validation failure writes no partial new profile for that record and leaves
the legacy source available for repair. Deletion requires counts and digests to
match, not merely a new schema-version flag.

For each candidate:

1. name the retained replacement;
2. migrate production and focused tests;
3. prove production/debug/test/build/resource callers are zero;
4. delete that candidate alone or in a small coherent cluster;
5. run the affected focused suite and shipping build.

Useful security validation, envelope reliability, migration needed for stored
user data, and diagnostic measurement code remain even if their file currently
sits beside obsolete machinery. Directory-level deletion without call-site
evidence is forbidden.

## 16. Conversation-First Product Experience

### 16.1 Apple interaction principles

The redesigned UI reuses OpenMinis runtime/product capabilities, not its current
visual hierarchy. It uses system `NavigationStack`, `NavigationSplitView`,
`List`, `Form`, `Menu`, `Sheet`, `Inspector`, Toolbar, Photos picker, and file
importer. Icons are monochrome SF Symbols. There are no draggable search/new-chat
floating buttons, colorful Settings icon tiles, or persistent five-tab bar.

The visual baseline is iMessage-like clarity and native behavior, with
Telegram-like information density, conversation status, search, pin/archive,
and efficient message actions.

### 16.2 Launch and onboarding

The launch router has one rule:

- no runnable Agent/model exists: show resumable setup;
- at least one runnable Agent exists: show Conversations;
- if the saved default is missing or unrunnable, show a nonblocking repair/
  choose-default action and use the chooser for `+`; do not replay onboarding or
  silently select the first registry record.

Setup has two steps.

**Connect a model**

- Cloud is highlighted as recommended.
- Known Providers hide Base URL and request only the required API Key/OAuth.
- Custom compatible Providers reveal Base URL.
- Account/origin reachability is validated before model selection when the
  Provider supports a non-model probe; after selection, the exact model target,
  streaming path, and declared capabilities are validated separately.
- On-device remains available with compatibility, size, available storage, and
  download state.

**Create the default Agent**

- name and optional purpose;
- selected model;
- summaries of default Prompt documents, Skills, and Tools; Memory appears only
  after a production backend is registered;
- advanced details are optional and prefilled.

Completion creates the default Agent and its first conversation, then focuses
the composer. Provider/target creation finishes in Swift before Rust Agent and
conversation creation. Interrupted setup resumes from the last persisted
non-secret target reference, and a missing target opens a repair step rather
than silently choosing the first available model.

### 16.3 Conversations root

On iPhone, the root is a Messages-like conversation list in a
`NavigationStack`. The top bar contains:

- left: `Edit` menu;
- center: `Chats`;
- right: `+`;
- system `.searchable` below.

`Edit` exposes Select Conversations, Archived Conversations, Manage Pins,
Agents, and Settings. Selection mode provides bottom archive/delete actions.
Rows show title, latest effective preview, time, and a restrained running/draft/
failure indicator. Swipe and context actions support pin, archive, rename, and
delete. Destructive actions confirm; archive offers undo.

On iPad, `NavigationSplitView` adapts to:

```text
Conversations sidebar | Chat | optional Conversation Control Center
```

`Edit`, search, and `+` belong to the sidebar. Narrow Stage Manager and compact
windows fold through the same system navigation stack rather than a duplicate
UI implementation.

### 16.4 New conversation

Tapping `+` does not immediately create a partial record. It presents:

1. Use Default Agent;
2. Choose Saved Agent;
3. Customize for This Conversation.

Customization starts from a complete Agent copy and exposes Model/Reasoning,
Prompt documents, Skills, Tools, and—only when registered—Memory as
progressively disclosed rows.
It never asks for Provider credentials already configured elsewhere. Cancelling
before Start writes no conversation. Tapping Start sends one idempotent Rust
command that atomically creates the conversation and initial configuration,
then opens Chat. An empty conversation created by an explicit Start is valid;
failed or cancelled setup creates none.

### 16.5 Chat header

- leading: system Back/sidebar behavior;
- center: conversation title and subtitle `Agent · Provider / Model`;
- tapping the title opens the configured, healthy, modality-compatible model
  picker directly;
- model changes update only this conversation and begin with the next Run;
- trailing: one Conversation Control Center entry.

Provider credentials and Base URL are never edited in the quick model picker.
Its footer links to the canonical Models/Providers Settings destination.
The two-line title is a real Button/Menu accessibility element with label
`Change Model`, value `Current model: <provider>, <model>`, and a hint that the
change begins with the next Run; it is not exposed as static title text.

### 16.6 Composer

The semantic order is stable across size classes:

```text
attachment previews
[ + ] [ / ] [ multiline input ] [ reasoning ] [ send / stop ]
```

- `+` offers Photos and Files. Files are size/type checked before full loading,
  copied into managed storage with bounded I/O, previewed, removable, and
  disclosed before transmission to a cloud Provider. Section 13.1 capability
  gating applies before Send.
- `/` and typing `/` open the same searchable palette of enabled and currently
  executable Skills. Selection creates a one-turn draft chip; it does not
  permanently mutate the conversation.
- Reasoning is capability-driven and discrete (`Auto`, `Low`, `Medium`, `High`
  or the model's equivalent). iPhone uses a compact control opening a draggable
  stepped selector; regular width may show it inline. Unsupported models hide it.
- The selected reasoning level is a next-Run `TurnOverride`; it does not mutate
  the saved Agent or conversation default merely because the slider moved.
- Send is disabled without text or attachments. Once pressed, it becomes Stop
  immediately and covers preparation, FFI submission, model generation, and
  tool execution. Before Run acceptance Stop cancels `submission_id`; after
  acceptance it cancels the mapped `run_id`.
- During a Run the user may prepare a next-turn draft, but cannot send it or
  queue a second Run. Stop never deletes that draft.

Drafts are encrypted/local Swift presentation metadata keyed by conversation,
not transcript events. They include text, managed attachment IDs, requested
Skill IDs, reasoning choice, and any stashed pre-edit draft. Relaunch restores
them and list rows receive their draft indicator from this Swift store. Archive
retains a draft; Clear/Delete removes it.

### 16.7 Message management

Long press, iPad pointer/right-click, keyboard, and VoiceOver actions expose the
role-specific operations in Section 10.3. A tap on a selected bubble also
reveals a compact `More`/action affordance, so a sighted iPhone user is not
required to discover long press. Editing temporarily stores the user's existing
composer draft and restores it after either cancellation or successful
acceptance of Edit & Send.

Alternative edit/resend/retry variants display a minimal previous/next counter.
A separate Branch appears as a derived conversation with lineage. No branch
graph UI is required.

### 16.8 Conversation Control Center

The trailing Chat action opens a real hierarchical control surface, not a flat
information popover.

- iPad regular width: trailing Inspector with its own navigation stack.
- compact width: sheet/root Close, then system Back for child pages.

Root groups:

```text
Conversation
  title · Agent · model · derived-conversation lineage
Runtime
  Terminal · Browser · command activity
Resources
  Attachments (files/images filters)
Agent for This Conversation
  Prompt Documents · Skills · Tools · Memory (only when registered)
Usage
  active-path/all-attempt tokens · Context limit · compaction checkpoints
Actions
  rename · branch · clear · archive · delete
```

Model, Prompt, persistent Skill selection/local copies, Tool selection, and a
registered Memory backend apply only to the current conversation and the next
Run. Prompt pages show ordered Markdown files and support view/edit/add/delete/
reorder. Skill pages view immutable effective revisions, enable/disable them,
and use the conversation-local copy/import behavior in Section 7.2; global
Skill mutation links to Settings. Tool pages show conversation availability and
status. Memory is omitted until a backend exists.

Rename/clear/archive/delete and derived-conversation creation are immediate
conversation commands, not “next Run” edits. Terminal/Browser rows attach to the
scoped runtimes in Section 13 and label idle/running/failed state. Every row
declares `Conversation`, `Run`, or `Global`; global mutations navigate to the
canonical Settings page.

Run snapshots remain read-only. Terminal is labelled Terminal only when the
product exposes a real iSH session/stream; otherwise the existing one-shot
surface is labelled Command Activity rather than faking a PTY.

### 16.9 Settings

Settings remains a secondary hierarchical destination, not a main tab. It is
reachable from the left `Edit` menu and contextual “Manage…” links.

```text
Settings
  Default Agent
  Agents
  Models
  Providers
  Skills Library
  Tools & Linux
  Storage & Privacy
  Advanced Diagnostics
```

Settings owns global resources, credentials, defaults, and runtime environment.
Conversation Control Center owns one conversation's copied Agent configuration.
Provider/model/Agent routes restore exact IDs; no screen falls back to a
hard-coded profile or “first” record when a requested identity is unavailable.

## 17. Accessibility and Microinteraction Contract

- Icon-only controls have at least a 44×44 pt target and accurate labels,
  values, and hints.
- Dynamic Type may reflow the composer; it must not overlap attachments,
  reasoning, or Send/Stop.
- VoiceOver order is header, chronological transcript, attachment draft, then
  composer controls.
- Streaming text is announced by bounded paragraph/completion updates, never
  token by token or by stealing focus.
- Reasoning exposes adjustable actions that announce the actual level.
- Message actions, variant switching, Stop, and attachment removal work with
  VoiceOver, Switch Control, and Full Keyboard Access.
- Sheets, pickers, and the Inspector restore focus to their triggering control
  or composer on dismissal.
- State is never communicated only by color.
- Reduce Motion, Bold Text, RTL, landscape, iPad pointer/keyboard, and Stage
  Manager are part of UI validation.
- System animations and restrained haptics accompany selection, send, archive,
  delete, and navigation; decorative motion and custom gesture physics are out.

## 18. Error Handling and Recovery

- Invalid Prompt, snapshot, tool schema, or Context stops before a model call.
- Provider setup errors stay on the affected field and preserve non-secret
  draft configuration.
- A missing model/credential never deletes a conversation; UI offers Repair or
  Change Model.
- Provider failure after an output-bearing event is terminal and never replayed
  automatically.
- User/Swift/Rust cancellation never triggers fallback.
- Attachment type/size/storage errors occur before unbounded loading and leave
  the composer draft recoverable.
- Optional Skill catalog or Memory recall failure reports diagnostics without
  corrupting the transcript.
- Tool batch identity/order mismatch rejects canonical commit.
- Projection gaps re-fetch from canonical storage. Slow UI projection never
  blocks the Agent loop.
- Accepted but not started Runs may be claimed once after process loss. Started
  Runs without terminal events are marked Interrupted; external tool effects
  are never replayed automatically.
- Startup cleans orphan Swift Provider plans and tool/browser resources against
  Rust active Runs.
- The 200-turn ceiling produces a resumable terminal outcome, not a crash or
  invisible loop.

## 19. Delivery Sequence

The work is deliberately ordered as the user requested: slim first, optimize
the Core second, reconnect the simplified product configuration/UI last.

### Phase 0: evidence and safety baseline

- Record build/test, startup, RSS, idle-work, event-scale, and binary-size
  baselines.
- Map production/debug/test/resource callers for every deletion candidate.
- Freeze the current complete ReAct, local/cloud model, tool, projection, and
  relaunch product paths as regression tests.

### Phase 1: vertical slimming

- Remove only component market/package/upgrade concepts and Swift UI whose
  callers are already zero.
- Collapse duplicate conversation wrappers and old Agent execution paths only
  where the retained canonical store/direct loop already provides the shipping
  behavior.
- Inventory production Builder/publish/binding/preparation callers, but defer
  their deletion until Phase 2 or Phase 3 has installed the flat-profile and UI
  replacement. “Slim first” does not authorize dependency-inverted stubs.
- Keep each deletion small, independently buildable, and reversible in Git.

### Phase 2: Core and performance convergence

- Establish the six Rust ownership boundaries without creating more crates.
- Complete flat Agent/conversation profile revision semantics.
- Complete message variant/branch commands and effective transcript rules.
- Move polling to event-driven waits, index recovery, bound channels/buffers,
  and lazy-load heavy runtimes.
- Finalize model-aware Context/compaction and the minimal Memory interface.

### Phase 3: conversation-first Swift product

- Replace current root/navigation and first-launch routing.
- Implement the default/saved/custom new-conversation flow.
- Redesign Chat header/composer and message management.
- Add hierarchical Conversation Control Center.
- Replace the card Builder and mixed Model Center with Agents, Models,
  Providers, and lightweight Settings destinations.
- Keep existing OpenMinis-derived execution facilities behind these new views.
- Update the migration manifest when retained donor-derived view ownership or
  migration descriptions change; license provenance remains intact.

### Phase 4: cleanup and product validation

- Remove final zero-caller adapters and obsolete tests/docs from the shipping
  path.
- Run clean-checkout Simulator/device native/rootfs builds.
- Compare performance metrics with Phase 0 and investigate regressions.
- Verify the two end-to-end product paths and focused UI/accessibility suites.

Voice, alarms, widgets, extensions, backup, eligible sync, Cron, Hooks, and
Multi-Agent remain independent future slices. Existing shipping callers may be
kept, but these features neither expand nor block the convergence phases.

## 20. Validation Strategy

### 20.1 Focused Rust suites

- direct ReAct final/tool paths and 200-turn terminal outcome;
- command idempotency and one-active-run exclusion;
- conversation config full-replacement revision conflicts;
- edit/resend/retry/delete effective transcript semantics;
- same-conversation variants and separate-conversation branch lineage;
- retry with original snapshot versus resend with current settings;
- atomic tool-round persistence, per-call execution-journal recovery, uncertain
  effect handling, and cancellation races;
- five-slot/resource-token admission, mixed cloud/local Runs, sixth-send
  rejection, exact release, and relaunch reconciliation;
- projection replay, gap recovery, idle cancellation, bounded coalescing, and
  nonblocking publication;
- model-derived budgets, 70% default policy, tool-output elision, attachment
  recovery, summary checkpointing, and unchanged canonical history;
- descriptor-only Skills and virtual path safety;
- Memory interface recall/completed-turn hooks;
- indexed process-loss recovery;
- stable attempt IDs and deduplicated active-path/all-attempt usage across
  fallback, compaction, cancellation, variants, and derived conversations.

### 20.2 Focused Swift/C++ suites

- provider setup, Keychain isolation, explicit fallback order, forward-only
  candidate selection, complete compatible route groups, and cleanup;
- prepare/accept attestation mismatch and old-epoch rejection, Stop before
  acceptance, and `CloseSession` ownership after acceptance;
- per-turn cloud disclosure/egress authorization and sealed-request ordering;
- cloud/local unified model capability filtering;
- attachment preflight, bounded import, direct-cloud capability gating,
  reference counting, and final-byte deletion;
- tool-batch cancellation before later chunks and per-run cleanup;
- native manifest/permission gates and pending-interaction relaunch recovery;
- iSH bounded output and virtual mount security;
- app launch restoration and projection read-model behavior;
- onboarding resume, new-conversation scope isolation, Send/Stop, `/` Skills,
  one-turn Skill hints, reasoning capability mapping, draft lifecycle, and
  Control Center navigation;
- iPhone/iPad size-class navigation and accessibility actions;
- C++ lazy model lifecycle, streaming, cancellation, and usage.

### 20.3 Product-level tests

Keep product integration intentionally small:

1. one complete conversation path: setup/configuration, send, model tool call,
   concurrent tools, final response, and projection;
2. one relaunch path: canonical conversation list, selected conversation,
   transcript replay, interrupted Run handling, and no orphan host resources.

Focused suites own message edit/retry/branch, error, race, validation, layout,
and accessibility variants.
Do not recreate a single integration test with dozens of unrelated scenarios.

## 21. Acceptance Criteria

1. `LocalAgentApp` remains the only shipping App.
2. Rust controls the only Agent loop, canonical conversation, Context, and
   conversation Agent revisions.
3. Swift owns the Apple product, credentials, model/tool hosts, iSH/browser,
   Skills files, and native APIs without a parallel Agent loop or transcript.
4. C++ owns local inference only.
5. The existing reliable host envelopes are retained; no second protocol or
   projection bus exists.
6. The component marketplace, package upgrade planner, component graph,
   publish/binding/preparation ceremony, and duplicate business state machines
   have no shipping path.
7. A default Agent works immediately; saved Agents are flat and editable.
8. Every conversation owns an independent copied Agent configuration and a Run
   freezes one revision.
9. Prompt is ordered Markdown assembled only in Rust.
10. Skills use descriptor-first progressive disclosure and virtual paths.
11. Tools execute as one validated ordered Swift batch; multimodal availability
    follows model/runtime capabilities.
12. Memory remains a fact-oriented optional interface, never transcript or
    Context storage.
13. Context rebuilds every round, uses the frozen model window, defaults to an
    approximately 70% compaction policy, bounds transient tool data, and keeps
    canonical history unchanged.
14. Message edit, resend, retry, delete, variant navigation, and separate
    conversation branching have deterministic Rust semantics and complete UI.
15. Relaunch restores canonical conversation summaries and transcripts before
    live observation.
16. Streaming projection and tool output are bounded and cannot block the Agent
    loop or grow without limit.
17. Provider fallback is explicit, frozen per Run, forward-only, and never
    triggered by cancellation.
18. Cloud requests execute only through `LocalAgentLLMCloud`; credentials remain
    Swift-only and never enter Rust or iSH.
19. iSH guest-network risk is accurately disclosed and host mounts remain
    traversal/symlink protected.
20. Cold/warm start, RSS, idle work, large-event recovery, and binary size are
    measured before and after convergence.
21. The shipping UI is conversation-first, Apple-adaptive, and contains no
    persistent multi-tab product hierarchy.
22. iPhone uses list-to-chat navigation; iPad adapts to sidebar, Chat, and
    optional trailing Control Center.
23. New conversations may use the default, a saved Agent, or a conversation-only
    customization without mutating defaults.
24. Chat contains attachment, Skill, reasoning, Send/Stop, model switch, message
    management, and hierarchical Control Center interactions.
25. Settings is a secondary global-resource destination, not a duplicate of
    conversation configuration.
26. Dynamic Type, VoiceOver, keyboard, Reduce Motion, and Stage Manager behavior
    pass focused validation.
27. Each deletion has a named retained replacement, zero-caller evidence, and a
    passing focused suite/build.
28. Clean-checkout Simulator and device builds regenerate the required pinned
    iSH/rootfs/native artifacts and preserve required third-party licenses.
29. The focused suites and two product-level paths pass.
30. Run preparation is attested before acceptance, cancellable by submission
    identity, and cleaned only by the designated preaccept or `CloseSession`
    owner.
31. Tool effects have durable per-call evidence; uncertain effects are visible
    and never automatically replayed.
32. Cloud transmission retains exact per-turn disclosure and egress
    authorization before credential encoding or network execution.
33. Attachment bytes are bounded, capability-gated, reference-counted across
    variants/derived conversations, and removed after the final reference.
34. Cross-conversation admission allows independent cloud/local work within the
    five-Run product limit without retaining the current global-one lease.

## 22. Implementation Planning Boundary

The implementation plan must follow the four delivery phases and create small
vertical tasks. It must not:

- revive the complete OpenMinis app or its navigation as the product;
- add another Core, package graph, plugin registry, event bus, or transcript;
- delete whole directories before callers and replacements are identified;
- expose internal revisions, bindings, component graphs, Context policy, or
  permissions as ordinary user configuration;
- mix global Agent defaults with conversation-owned edits;
- block Core completion on Cron, Hooks, Multi-Agent, or peripheral product slices;
- repeat every focused scenario in a giant product integration test.

The first implementation plan should cover Phase 0 and Phase 1 in executable
detail, then identify the measured gate for Phase 2. Later phases may be split
into separate plans after the preceding convergence gate is satisfied; the
target architecture and product semantics in this specification remain shared.
