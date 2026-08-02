# LocalAgent Architecture Convergence and Conversation-First Product Design

**Status:** Design approved in conversation; written-spec revision review pending

**Date:** 2026-08-02

**Last revised:** 2026-08-03

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
- Remove obsolete code after production, test, debug, resource, and build callers
  are gone. Require a replacement only for capabilities the product retains;
  development-only data may follow the explicit reset contract in Section 15.2.

## 3. Non-Goals

- A second Rust Core, workspace of micro-crates, or new Swift package graph.
- A component marketplace, dependency graph, component version resolver,
  lockfile, installer, or upgrade planner.
- Compatibility with any pre-release development database, component graph,
  binding, package, Prompt store, or fixture.
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

Every retained capability has a working replacement before its old path is
removed. A capability proven unnecessary needs zero-caller evidence or the
explicit development-data reset—not a ceremonial replacement. Each slice keeps
the shipping App buildable and one real conversation path usable. Active paths
are replaced vertically. A whole subsystem proven to have zero production,
debug, test, build, and resource callers may instead be deleted in one buildable
subsystem commit; it does not require a file-by-file ceremony or replacement.

### 4.6 One production path after every slice

Refactoring is not a license for old and new implementations to drive production
simultaneously. A vertical slice establishes the smallest retained interface,
moves one real product caller, fixes the relevant correctness contract,
deletes that caller's old path, and proves zero remaining production callers
before the next slice starts. A temporary cutover adapter may exist only inside
that slice and is deleted with it; it never becomes another permanent service,
manager, facade, or registry.

## 5. Target Architecture

```text
┌──────────────────────── LocalAgentApp / Swift ────────────────────────┐
│ Conversation-first SwiftUI product                                    │
│ Onboarding · Chats · Chat · Control Center · Settings                 │
│                                                                       │
│ ProductEnvironment (sole raw Bridge lifecycle owner)                  │
│ conversations · profiles · models · tools · settings clients          │
│ Projection read models · Keychain · Provider/Model configuration      │
│ OpenMinis-derived iSH · Files · Browser · Skills · Tool batch runtime │
│ LocalAgentLLMCloud · local-model lifecycle/streaming host              │
└──────────────────────────────┬────────────────────────────────────────┘
                               │ existing versioned host/FFI envelopes
┌──────────────────────────────▼────────────────────────────────────────┐
│ Rust Core                                                             │
│ internal: engine · conversation · profile · host · storage             │
│ external: ffi / C ABI                                                  │
│ direct ReAct · Context/compaction · canonical events · recovery        │
└──────────────────────────────┬────────────────────────────────────────┘
                               │ coarse local-model calls
┌──────────────────────────────▼────────────────────────────────────────┐
│ C++ / llama.cpp                                                       │
│ load · tokenize · generate · stream · cancel · usage                  │
└───────────────────────────────────────────────────────────────────────┘
```

The target remains one Rust crate. These six names are structural module roots,
not six public APIs, packages, facades, or traits. At the Phase 2 Core-shape
gate, every one of the 23 current public roots has an explicit moved/private/
deleted disposition. `engine`, `conversation`, `profile`, `host`, and `storage`
are private or `pub(crate)`; only `ffi` is an external Rust module boundary, and
shipping integration remains the C ABI. The old Builder may still exist at that
point only as the single production implementation, private under `profile`,
until its Phase 3 replacement. Phase 2 therefore closes the external surface
without pretending the Phase 3 Builder deletion has already happened.

### 5.1 Rust Core boundaries

#### `engine`

- Direct ReAct loop.
- Per-round Context construction and token budgeting.
- Context compaction and transient tool-output elision.
- Run-scoped cancellation and single-active-run enforcement.
- Atomic validation before final or tool-round commit.
- Accepted intent, attested Run snapshot, and compact Run audit/lineage records.
- A hard emergency ceiling of 200 ordinary model turns.

#### `conversation`

- Conversation commands and idempotency.
- Conversation-owned complete Agent configuration and full-replacement writes.
- Canonical events, variant-path ancestry, active variant ID, effective
  transcript, and derived-conversation lineage.
- Retry, edit, resend, path removal, clear, derive conversation, archive, and
  conversation delete.
- Conversation summaries and replayable Swift projections.
- Process-loss terminalization and restart recovery inputs.

#### `profile`

- Reusable Agents and the default Agent.
- Complete Agent configuration value/revision types reused by conversations.
- Ordered Prompt documents, selected Skill IDs, selected Tool IDs, model and
  fallback references, and optional Memory backend reference.
- Full-replacement revisions with optimistic `expected_revision` checks.
- Immutable values/references consumed when `engine` freezes a Run.

#### `host`

- The existing logical `ModelRuntime` and `ToolRuntime` boundaries.
- Reliable envelope adaptation, receipts, epochs, sequence/digest validation,
  and resource lifecycle.
- No Prompt, Context, transcript, or Agent policy.

#### `storage`

- One concrete `LocalAgentStore` over one Rust-owned `localagent.sqlite` for
  conversations, profiles, Runs, requests/idempotency, projections, summaries,
  Host envelope/outbox/receipts, and recovery indexes.
- Short cross-domain transactions used by Run acceptance and terminal commit.
- No Memory facts. Memory is a separate optional service contract.

#### `ffi`

- Coarse commands, subscriptions, model requests, tool batches, and cancellation.
- Explicit projection-subscription cancellation.
- No view-specific business logic.

#### Allowed dependency direction

The six target roots form one acyclic dependency graph:

```text
Swift / C ABI
      |
      v
ffi -> engine | conversation::facade | profile::facade | host ingress

engine -> conversation | profile | host | storage
conversation -> profile value/transaction helpers | storage
profile -> storage
host -> storage

storage -> SQLite/filesystem/standard-library primitives only
```

More explicitly:

- `ffi` translates versioned wire DTOs, submits Host callbacks/envelopes, and
  calls crate-private entry points. It never opens or queries storage directly
  and does not expose its DTOs to business modules.
- `engine` is the concrete runtime composition root. It owns the shared
  `LocalAgentStore`, orchestrates `conversation`, `profile`, and `host`, and may
  open a cross-owner transaction; it does not encode owner-specific records or
  bypass their write methods. None of those modules calls back into `engine`.
- `conversation` may use immutable profile values and transaction-scoped profile
  helpers; both `conversation` and `profile` use the concrete store.
- `host` owns model/tool transport contracts and reliability lifecycle. It does
  persist envelopes, outbox commands, receipts, and epochs in the same store,
  but does not assemble Prompt/Context or mutate transcript/profile data.
- `storage` owns transactions and neutral persisted records. It imports no
  business module and contains no Agent policy.

Reverse edges and cross-layer shortcuts are forbidden. In particular:

- `engine`, `conversation`, and `profile` never depend on Swift/FFI DTOs;
- `ffi` never depends directly on `storage`;
- `host` never writes transcript/profile state or selects Prompt, Skills, Tools,
  or models;
- no new general `core`, `service`, `manager`, registry, or facade is introduced
  to aggregate the six roots;
- legacy `execution`/`RunMachine` and the new `engine` may not both accept or
  drive a production Run.

The final `lib.rs` is intentionally small:

```rust
mod engine;
mod conversation;
mod profile;
mod host;
mod storage;
pub mod ffi;
```

Owner-specific helpers remain private below one of those roots; there is no
generic `utils` dumping ground. External integration tests exercise `ffi`/C ABI.
White-box Rust tests live in the owning module and do not force internals public.
A small source-boundary check enforces visibility and forbidden imports without
adding a runtime architecture framework.

#### Dynamic-port and persistence budget

Only three Core ports justify runtime polymorphism:

- `ModelRuntime`;
- `ToolRuntime`;
- `MemoryProvider`.

They remain crate-private dynamic boundaries. An in-memory fake, mock, or test
implementation does not count as a second production implementation. Clock and
ID seams use private generics, closures, or `#[cfg(test)]` helpers. Conversation,
Profile, and Storage use concrete structs; no table or aggregate receives a
`Repository` trait merely to support tests.

All Rust canonical state uses one physical `localagent.sqlite` and one concrete
store owner. Tests use that same store with an in-memory connection or temporary
file. In-memory construction is test-only: a shipping database open/recovery
failure blocks canonical mutation and presents an explicit reset/recovery error;
it never starts an ephemeral Agent store. Swift continues to own Keychain,
Skills and attachment files, model files, projection read models, and the effect
ledger. Rust does not add a `blobs/`
subsystem without measured large-payload pressure; any future content-addressed
spill remains a private Storage optimization, not another repository boundary.

### 5.2 Swift boundaries

Swift has one raw Bridge ownership boundary, not one giant facade.
`ProductEnvironment` owns the `RustRuntimeClient`/gateway lifetime and constructs
five concrete feature clients:

```text
ProductEnvironment
  conversations
  profiles
  models
  tools
  settings
```

Each ViewModel depends only on its feature client; Views and ViewModels never
receive the raw Bridge or call FFI. The existing `RustAgentCoordinator` either
becomes a private implementation detail of `conversations` or is deleted—it does
not expand into a product-wide God object. Feature clients default to concrete
actors/structs; they do not each gain a protocol unless a second production
implementation or necessary test/platform boundary exists.

`ProductEnvironment` and the five feature-client implementations are the
only Swift product code allowed to import/access the raw LocalAgent Bridge. The
environment alone creates, recovers, and closes its lifetime; clients expose
feature-shaped methods and do not own a second runtime or store.

Swift owns:

- app lifecycle and adaptive navigation;
- onboarding, conversation UI, Settings, and local projection state;
- Keychain credentials, OAuth, Provider/Base URL UI, and late credential lookup;
- explicit ordered fallback configuration;
- iSH/fakefs, virtual host mounts, browser, file/media/native APIs, and tool
  execution policy;
- Skills file storage, upload/import UI, immutable revision materialization, and
  virtual-path resolution;
- local-model download, compatibility, lifecycle, and C++ invocation;
- bounded transient streaming presentation.

Swift does not own:

- the Agent loop;
- complete Prompt or Context construction;
- Agent, conversation, or one-turn Skill selection/enabled state;
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
| Conversation Agent config | Rust conversation owner using profile value types | One conversation, versioned | Full replacement; deleted with conversation retention policy |
| Product policy | Rust shipping policy implementation | Current product revision; Run records `ProductPolicyRef` for audit | Old executable policy/Context code is not retained; Retry uses the current revision |
| Run snapshot | Rust canonical Run data | One Run, immutable audit/lineage record; inherited history keeps compact provenance | Stores non-owning IDs/digests, not old executable policy or asset ownership |
| Prompt documents | Rust profile store; Swift editor only | Immutable revision strongly referenced by Agent/conversation/active Run | Reusable-Agent edits use `ProfileService`; conversation edits use `ConversationFacade`; delete after zero owning references |
| Skill files | Swift Skills store; Rust owns all selection references | Immutable revision owned by Agent/conversation/explicit source turn/active Run | Swift tombstones visibility; compact Run audit is non-owning; physical deletion requires Rust retirement epoch and zero-reference proof |
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

`ProfileService` is the only direct Agent-library/Builder command surface for
reusable Agents:

```text
create_agent(request_id, complete_config)
duplicate_agent(request_id, source_agent_id, optional_name)
replace_agent_config(request_id, agent_id, expected_revision, complete_config)
delete_agent(request_id, agent_id)
set_default_agent(request_id, agent_id)
```

Every Profile command uses the common durable request-receipt table. A globally
unique `request_id` plus identical command kind/payload returns the first result;
reusing it with another kind or payload is an idempotency conflict. Internal
helpers never write a second receipt.

`complete_config` always contains name and optional purpose, ordered Prompt
document revisions, selected Skill revisions, selected Tool IDs, model and
explicit fallback selection, default reasoning, and optional Memory reference.
Save performs validation once and returns structured field errors directly.
There is no draft/publish/review/readiness/binding/component-assembly/upgrade
state between an edit and the next immutable revision.

`ProfileService` is the sole writer of reusable Agent/profile records; its store
mutation methods are private. FFI, bootstrap, engine, and tests call this
surface rather than writing profile tables directly. Prompt/Skill edits are
part of one complete replacement, not independent publishable components.

Conversation configuration and lifecycle operations belong to
`ConversationFacade`:

```text
create_conversation_from_agent(creation_scope_id, request_id, agent_id)
replace_conversation_config(conversation_stream_id, request_id,
                            expected_content_epoch, expected_revision,
                            complete_config)
save_conversation_as_agent(conversation_stream_id, request_id,
                           expected_content_epoch, optional_name)
```

The outer conversation command owns its idempotency key—
`(creation_scope_id, request_id)` while allocating a new stream and
`(conversation_stream_id, request_id)` thereafter—plus payload digest, content-
epoch validation, and the complete storage transaction. It may call one private
transaction-scoped profile helper,
`create_from_complete_config_in(tx, complete_config)`, when Save as New Agent
needs a new reusable profile. That helper is not a second public command
surface. `ProfileService` never accepts `conversation_stream_id`, and `profile`
never imports `conversation`. Creating a conversation copies the selected
Agent's complete configuration inside the same transaction; Save as New Agent
reads only the stored conversation configuration, not transcript events.

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

Independently of Agent configuration, the App-global iSH external-network
setting defaults Off under Section 13. It is never copied into an Agent,
conversation configuration, or Run snapshot.

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

### 6.3 Accepted intent and complete Run snapshot

`RunAccepted` first freezes an `AcceptedRunIntent` containing only data and
commitments available without a Swift `await`:

- the conversation Agent revision and triggering command/TurnOverrides;
- ordered user Prompt document revision/content references;
- the current `ProductPolicyRef(revision, digest)`;
- ordered `SkillRevisionRef(id, digest)` values, not file bytes or host paths;
- ordered selected Tool IDs and one `ToolManifestRef(digest)`, not a duplicate
  Rust tool-schema catalog;
- ordered `ModelTargetRef(revision_id)` candidates and their corresponding
  `CredentialRef(record_id, generation)` values;
- reasoning level;
- attachment metadata visible from the effective Context;
- optional Memory provider reference.

The five named `*Ref` types are the only Run-configuration/Host-capability
identity commitments copied across the language boundary. Canonical attachment
IDs and optional Memory data keep their existing content contracts rather than
gaining parallel capability digests. Post-accept Host preparation resolves the
five refs once. Swift materializes the immutable Skill descriptor/virtual-path
map, executable Tool definitions (`name`, `description`, JSON schema), and
the selected model's Context window, output reserve, modality/capability values,
and private `ProviderRunPlan`. `RunStartAttestation` echoes the five stable
reference kinds, `run_id`, and `host_epoch`; it carries the needed materialized
model/tool/Skill values and one attestation digest. Rust supplies Prompt
documents from `profile`, validates the references and attestation, and
atomically attaches the resulting `RunStartSnapshot` with `RunStarted`.

Swift-private Base URLs, headers, codecs, resource tokens, lease identity, and
credential bytes never become Rust commitments. A changed or missing stable
reference fails the accepted Run; preparation never substitutes a new revision
or generation. Neither side maintains a second static OpenMinis tool-schema
catalog, and independent capability/parameter/resource digests are not copied
across the boundary when the attested model target already owns them.

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

Prompt and Skill revisions are immutable retained assets. Owning references come
only from reusable Agents, conversation configurations, active Runs, and source
turns with explicit one-turn Skills. A terminal Run keeps non-owning IDs/digests
for audit and releases its temporary asset ownership. For Swift-owned Skill
bytes, Rust publishes the authoritative reference state. Skill deletion first
tombstones discoverability; then one Rust transaction permanently marks that
exact revision/digest
non-referenceable, rejects future Agent/conversation/turn references, and
returns a monotonic retention epoch plus zero-reference proof. Only that proof
allows Swift to delete bytes idempotently. Relaunch reconciles retired-but-not-
deleted revisions. A transient “not in current live set” snapshot is never
sufficient. Deleting an Agent or hiding a Skill from the global library cannot
physically remove a Prompt/Skill revision with an owning reference. Deriving a
conversation copies/increments source-turn attachment and explicit one-turn
Skill references, so clearing the source cannot break Retry in the derived
conversation. Compact Run audit records never pin those assets.

A `RunSnapshot` records what the attempt used for history, diagnostics, usage
attribution, and lineage. It is not an executable archive of an old product
runtime. Retry forks from the semantic source user turn and preserves its text,
attachments, explicit one-turn overrides, and original model identity, but
builds the new Run with the conversation's current Agent configuration and the
current `ProductPolicyRef`, Context/compaction implementation, and Tool runtime.
The original `ModelTargetRef` acts only as a new-Run model override and is
resolved against current credentials and Host code; no old route/session is
resurrected. The UI says “Regenerate using current runtime policy.” If a required
attachment,
explicitly selected one-turn Skill, or requested model target is unavailable,
Retry is unavailable and the UI offers Edit/Resend with a repair choice. No old
policy bytes, algorithm registry, `canExecute(old_revision)`, or security-floor
branch is retained.

### 6.4 Cross-store model resolution

Provider credentials and immutable model targets remain Swift-owned while Agent
and conversation profiles are Rust-owned. This boundary is deliberately not
presented as one cross-database ACID transaction or a host-binding saga.

The sequence is:

1. Swift validates and saves an immutable model target revision;
2. Swift passes `ModelTargetRef(revision_id)` to Rust. Every Run-producing
   submission—Send, Edit & Send, Resend, or Retry—also includes the current
   `CredentialRef(record_id, generation)` for each effective candidate, without
   preparing a route or holding a Rust lock. Retry takes its requested
   `ModelTargetRef` from source provenance but its `CredentialRef` from this new
   submission;
3. Rust creates or revises the Agent/conversation configuration;
4. each Run asks Swift to resolve that frozen reference before generation.

Setup persists non-secret progress after step 1. If the App stops between steps,
it resumes Agent creation using the saved target. An unused target may remain in
Models and can be deleted explicitly; destructive rollback is unnecessary.
If a referenced target is later missing, the Agent/conversation becomes
repairable and cannot start a Run until the user selects a replacement. The
target reference, not a shell-global active Agent or inferred binding order,
restores conversation identity after relaunch.

### 6.5 One atomic Run acceptance boundary

Run acceptance is Rust-first. There is no Swift-first prepared Run and no
cross-store `PendingSubmission` state machine.

Swift creates `submission_id` for immediate Send/Stop identity and sends one
idempotent command. In one short Rust storage transaction, before any Swift
`await` or model/tool effect, Rust:

1. checks `(conversation_stream_id, request_id)`, `submission_id`, content
   epoch, and expected conversation configuration revision;
2. rejects an existing per-conversation active Run or unavailable five-Run
   product slot;
3. allocates `run_id`, freezes `AcceptedRunIntent`—including each candidate's
   `ModelTargetRef` and `CredentialRef`—and stores the submission-to-Run mapping;
4. acquires the per-conversation/product reservations and atomically applies the
   triggering transcript command—including the effective source/submitted user
   turn, attachments, and `TurnOverrides` for every Run-producing command—plus
   `RunAccepted`
   (`accepted_preparing`).

A preaccept idempotency/epoch/revision/capacity rejection writes neither the
transcript mutation nor a Run and leaves the Swift draft intact.

That transaction is the only acceptance boundary. No storage/conversation lock
is held across a Swift call. After it commits, `engine` asks `host` through the
existing reliable envelope transport to prepare the exact frozen target. Swift
privately resolves and validates:

- every `ModelTargetRef`, selected `SkillRevisionRef`, and the
  `ToolManifestRef` against the current host-process epoch;
- model capability, execution readiness, Context window, output reserve, and
  modality/attachment support;
- each credential record ID, exact generation, kind, and secure availability;
- Provider retention and egress policy.

Swift freezes a private `ProviderRunPlan`, acquires the exact target resource,
and returns `RunStartAttestation`. Base URL, codec details, headers, credential
bytes, resource token, and lease identity remain Swift-private. Rust verifies
the stable references and attestation digest and then atomically attaches the
attestation and appends `RunStarted`. No model request, credential
encoding, network request, or tool effect may occur before that commit.
Preparation failure appends `RunFailed`; cancellation appends
`RunCancelled`. The Rust terminal transaction releases its conversation/product
reservations exactly once and enqueues an idempotent `CloseSession(run_id)`
outbox action. Swift `CloseSession` is the sole owner for releasing Swift Host
resources—Provider plan, target token, credential lease, tool handles, and
session state—including partial/failed preparation. Those private Host handles
are addressed only by `run_id`. Startup reconciliation repairs either missing
half without transferring ownership across languages.

Stop before acceptance writes an idempotent cancellation receipt keyed by
`submission_id`; a late matching send observes it and never accepts a Run. Once
accepted, the same submission maps Stop to `run_id`. An accepted-but-not-started
Run may be claimed once after process loss and prepared again against the new
host epoch using its frozen stable references. Any old-epoch attestation is
rejected. Preparation must compare-and-swap each frozen `CredentialRef`; it
cannot bind a newer generation during recovery. If exact target or credential
preparation can no longer succeed,
recovery writes `RunFailed` rather than silently changing the Run plan.

## 7. Prompt, Skills, Tools, and Memory

### 7.1 Prompt documents

Prompt is an ordered Markdown stack. Product-controlled safety/runtime
instructions remain separate from user-editable documents. User documents may
use names such as `SOUL.md`, `AGENT.md`, or another descriptive filename.

Rust stores each Agent/conversation Prompt document revision, filename, body,
digest, and order. Swift provides the native Markdown editor and file import/
export surfaces. Reusable-Agent changes enter `ProfileService`; conversation-
local changes enter `ConversationFacade`. Both validate the same complete-
configuration value before it appears in an effective Run snapshot.

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

- Every Skill edit creates an immutable whole-tree revision whose manifest
  digest covers `SKILL.md` and every referenced script/reference/asset path and
  byte digest. Existing global or conversation configurations keep their
  selected revision until explicitly updated.
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
There is one durable effect ledger, owned by Swift at the execution boundary,
not a competing Rust journal. The frozen tool manifest classifies a call as
read-only or effectful; shell, browser, native-write, network, and unknown tools
are effectful unless a narrower manifest proves otherwise. Before an effectful
child task performs its first external side effect, Swift transactionally
persists stable `(run_id, batch_id, call_id)`, arguments digest, tool identity,
and `began`, then executes. It advances the same record to `completed`,
`proven_not_applied`, or `uncertain` and returns an opaque receipt ID/digest with
the ordered result. Only authoritative evidence that no effect crossed the
boundary may produce `proven_not_applied`; timeout, cancellation, host loss, or
an error after dispatch is `uncertain` even if Swift caught an error. Read-only
calls do not pay this durability cost.

The ledger wrapper sits in `OpenMinisToolBatchExecutor` immediately before
dispatcher execution, so shell/file/browser/native paths share it;
`NativeHostToolDriver` is no longer a second ledger boundary. Its permission and
pending-interaction records remain distinct safety state. The single effect-
ledger key/schema includes batch ID and arguments digest, and `host` exposes
idempotent query/resolve receipts to Rust for startup reconciliation.
Shipping composition must inject a durable file-backed ledger into the batch
executor; there is no optional `fileURL:nil`/in-memory fallback outside explicit
tests. A relaunch test proves the pre-effect record survives process loss.

Before dispatch, Rust transactionally persists a non-transcript
`PendingToolRound` containing assistant text, ordered calls, stable run/batch/
call IDs, arguments digests, and an outbox command. It is mandatory correlation
and reconstruction evidence, never proof that an effect did or did not occur.
Swift terminal receipts retain the bounded canonical result or an immutable
result reference/digest. Only after every ordered result and effect receipt
validates does Rust atomically commit assistant text, tool calls, and tool
results, then clear the pending round. On recovery, Rust joins
`PendingToolRound` with Swift receipts by stable call identity: complete
recoverable results commit once; a `began` call without a trustworthy terminal
receipt becomes `uncertain`; an unrecoverable non-effectful result interrupts
the Run without inventing output.

Recovery never replays an uncertain effect. Rust appends a canonical
stream-level `EffectResolutionRequired` barrier outside variant-path message
events. Edit/Delete-from-Here cannot hide or tombstone it. Every Run-starting
command—Send, Edit & Send, Retry, and Resend—rejects until resolution.
Model-visible Context carries a non-sensitive “outcome uncertain; do not repeat”
barrier until resolution. Control Center exposes bounded call metadata and the
native receipt so the user can resolve whether to treat the effect as completed
or not completed. That explicit resolution becomes a model-visible safety
contribution on the next Run; it is never fabricated as an ordinary tool result
and never causes automatic re-execution.

Clear and Branch are rejected while an unresolved effect barrier exists, so a
new epoch or derived conversation cannot bypass it. Delete may terminalize the
conversation but retains the minimum non-content effect identity/receipt
required by the safety policy.

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
  response = request one model generation
  if response.tool_calls.is_empty():
    validate and atomically commit assistant final text, then finish
  validate tool calls
  check cancellation before tools
  execute one ordered Swift tool batch
  validate ordered results
  atomically commit assistant text + tool calls + all tool results
end
return resumable max-turn terminal outcome
```

Assistant text does not imply terminality. A response containing both text and
tool calls executes the tools and commits that text in the same atomic tool
round; only a response with no tool calls may become the final assistant turn.
An empty response with neither text nor tool calls is a model-protocol error.

There is no general Agent state machine. Errors, retry eligibility, fallback,
cancellation, and tool rounds are ordinary control-flow branches. Necessary
transport phases, receipts, and resource lifecycle remain isolated under
`host`.

One conversation may have at most one active Run. Different conversations may
run concurrently. The target product policy allows at most five simultaneous
conversation Runs; this is a new convergence target, not a claim about the
current global-one host implementation.

Admission is target/resource-aware rather than `min(global, host)`. The Rust
acceptance transaction acquires the per-conversation guard and one of five
product Run slots. Post-accept Host preparation acquires the exact attested
target token: cloud routes may expose independent capacities, while a
memory-heavy local engine normally exposes one generation token. A local Run
therefore need not block unrelated cloud Runs.

The product does not hide a queue. An unavailable product slot rejects before
acceptance with `runtime_capacity_busy` and preserves the composer draft. An
unavailable exact target token is discovered after `RunAccepted`, so that Run
terminates as `RunFailed(runtime_capacity_busy)` attached to the submitted user
turn; the draft is not falsely presented as unsent, and UI offers Retry when
capacity changes. The Rust terminal transaction releases product/conversation
reservations; Swift `CloseSession` releases exact Host resource tokens. Startup
reconciliation repairs leases whose Run is no longer active.
Cross-conversation cloud/local concurrency and relaunch tests must pass before
deleting the current global lease.

Transcript and variant-path mutations during a Run first request cancellation
and wait for a terminal outcome; they never execute external effects
concurrently against the same conversation.
Configuration replacement is different: it may commit a next revision while a
Run is active because the Run already owns a frozen prior snapshot and no
external effect is replayed.

### 8.1 Bounded synchronous execution

The Core keeps its current low-cost advantage: it introduces no Tokio,
`async-std`, general futures executor, actor system, or speculative task
registry. Admission completes before spawning work. Each accepted active Run
owns at most one controlled standard-library worker thread, so the product limit
also bounds ordinary Run workers at five.

Host replies and cancellation wake the owning worker through a `Condvar` or
bounded mailbox. A timed wait is allowed only until the nearest persisted active
transport/watchdog deadline, such as acknowledgement timeout, redispatch due,
or cancel/close deadline; there is no fixed 10 ms response poll, 250 ms
redispatch tick, database poll loop, or idle timer. Projection listeners use
bounded event-driven waits and never hold a registry/store mutex while notifying
or waiting for Swift. With zero active Runs, no pending Host commands, and no
real deadlines, Rust performs zero periodic wake-ups and zero SQLite polling.
iSH, Browser, and local-model runtimes remain lazy.

## 9. Context and Compaction

Context is rebuilt for every model round. Only the Run's Prompt documents,
Skill descriptors, tool definitions, provider plan, Agent revision, and
`ProductPolicyRef` are frozen. The current canonical conversation, newly
committed tool results, budget usage, attachment set, Memory contributions, and
compaction projection are recomputed each round under that frozen policy.

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

Every command after creation carries `conversation_stream_id`, `request_id`, and
`expected_content_epoch`. Idempotency is keyed by stream/request and the stored
payload digest; epoch mismatch is a stale-command error, never a new mutation.
`CreateConversation` instead carries a stable local `creation_scope_id` and
`request_id`; the first result stores and returns the newly allocated
`conversation_stream_id`. The same canonical payload returns that first result,
while a different payload with the same creation or stream key returns a
conflict. Duplicate or delayed Swift/FFI submission cannot create a second
conversation, append a message, cross a Clear boundary, or start another Run.

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
  path, excludes every dependent suffix message, and regenerates from the
  semantic source user turn. It preserves that turn's text, attachments,
  explicit one-turn Skills/reasoning, and requested model identity, while using
  the conversation's current Agent configuration and current product runtime
  policy. Missing source assets make Retry unavailable; the UI offers Edit or
  Resend with current available choices.
- **Delete from Here** appends a tombstone for the target and dependent current
  path. It never leaves an invalid model history.
- **Branch from Here** creates a separate conversation containing the effective
  history through the anchor and a copy of the source conversation's current
  Agent configuration. It copies/increments owning attachment and explicit one-
  turn Skill references for inherited source turns and copies the requested
  `ModelTargetRef` plus compact provenance IDs/digests. Inherited messages retain
  immutable source event/Run identities; they are not rewritten with an empty/
  new `run_id`. The source remains unchanged and lineage is projected into both
  conversation details. The derived conversation does not inherit executable
  old policy or Context code.

Edit, resend, and retry keep the prior variant path, including its dependent
suffix, accessible through a small previous/next version control. Explicit
Branch creates a derived conversation and a new list item; it is not another
name for a variant path. Retry anchors resolve semantic effective user turns,
including an edited user variant; they are not limited to raw original
`UserMessage` events. Retry in a derived conversation resolves inherited source
events and attachments, then uses the derived conversation's current Agent and
product runtime policy.

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
  increments `content_epoch` and appends one reset record at the next monotonic
  stream sequence for the same conversation configuration. That Rust
  transaction removes the conversation's prior message/variant payload, summary
  checkpoints, Run/usage ownership, resets canonical title/search text to `New
  Conversation`, and decrements attachment/explicit one-turn Skill references
  owned by purged source turns plus any temporary active-Run references.
  Prompt/Skill references held by the unchanged `ConversationAgentConfig`
  remain.
  Shared immutable assets remain while a derived conversation still references
  them. Clear is not undoable; derived conversations remain independent.
- **Delete Conversation** performs the same content purge and additionally
  removes the conversation configuration, metadata, pins, and other Rust-owned
  state. Unlike Clear, terminal Delete is allowed with an unresolved effect and
  retains its minimal safety receipt. The stream ID remains a tombstone and is
  never reused.

Swift cleanup is not part of the Rust transaction. After applying
`ProjectionReset`, Swift idempotently removes draft/projection rows from the old
epoch; after applying the terminal Delete projection it removes remaining local
conversation state, Browser workspace, and command activity. Failure retries
locally and can never roll back or reuse the Rust epoch/sequence.

Per-stream `sequence` never resets even when old content payload rows are
physically purged. Stream metadata retains current epoch, next sequence,
`minimum_replay_sequence`, the reset/terminal snapshot, and non-content command
receipts containing stream ID, request/digest, expected/result epoch, and schema
version. Every mutating command carries `expected_content_epoch`; a stale epoch
is rejected, and an old request cannot execute again in a new epoch. These
minimal receipts outlive content deletion so retry/sync/import cannot resurrect
data. Attachment and immutable revision bytes are physically removed only after
the final canonical reference is gone. Native permission/effect ledgers retain
only the minimum receipt required by their safety contract and no transcript/
Prompt payload.

Deleting a reusable Agent is blocked if it is the default until another default
is chosen. Existing conversations need no Agent reference because they own full
configuration copies. Agent-owned revision references are released, but Prompt/
Skill assets are purged only after all Agent, conversation, active-Run, and
source-turn owning references reach zero. Non-owning Run audit IDs/digests do not
delay deletion. No pre-release legacy mapping survives
the development-data reset in Section 15.2.

## 11. Existing Transport and Projection

No second Rust/Swift protocol is introduced. Logical model/tool calls continue
through the existing versioned command/event envelopes, IDs, sequences, digests,
receipts, duplicate detection, process epoch, and resource lifecycle.

Projection uses `(conversation_stream_id, content_epoch, sequence)`, not a
global cursor. Sequence remains monotonic for the life of a stream. Observation
registers before replay, catches up from canonical storage, detects gaps, then
consumes live wake-ups. If a Swift cursor predates `minimum_replay_sequence`,
Rust returns `ProjectionReset(current_epoch, reset_sequence,
minimum_replay_sequence, reset_snapshot)`; Swift atomically replaces that
conversation's local rows, installs `reset_sequence` as its cursor, and resumes
after it instead of treating the purge as an unfillable gap. Cancellation wakes
and unregisters an idle listener.

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

Host preparation after `RunAccepted` and before `RunStarted`, as defined in
Section 6.5, freezes a non-secret `ProviderRunPlan`. The same plan is used for
the complete ReAct run:

- logical model and modality;
- protocol/codec and Base URL;
- explicit ordered fallback candidates;
- compatible Context window and supported reasoning levels.

Each fallback candidate is a complete immutable Swift-private route. A group is
valid only when every candidate supports the frozen tool/modality/reasoning
contract. Rust stores only the ordered `ModelTargetRef`/`CredentialRef` pairs
and the attested minimum compatible Context window, output reserve, and needed
capabilities. Origin, codec, Base URL, headers, retention details, credential
bytes, lease/resource identity, and route objects remain inside the Swift Host
session addressed by `run_id`; they are not copied into Rust as parallel
commitments.

The plan freezes an exact credential record ID and generation. Swift reads the
secret from secure storage immediately before each request only if that same
generation still exists. A Settings edit that rotates/replaces it during the
Run terminates with `credential_changed`; it never silently switches a key,
route, or fallback candidate, and `credential_changed` itself cannot trigger
fallback. Provider-authorized OAuth access-token refresh may update secret
bytes inside the same logical credential generation and lease; account or grant
replacement creates a new generation.

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

Swift removes a Run plan on idempotent host `CloseSession`. The Coordinator
never owns a prepared route before Rust accepts a Run and never removes one
after acceptance; it only requests cancellation. Launch removes orphan
persisted plans that do not correspond to an active Rust Run, and persistence-
cleanup errors are surfaced to diagnostics rather than swallowed.

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
- External guest networking is an independent high-privilege capability and is
  disabled by default at the iSH network-adapter/socket-connect boundary;
  loopback required by internal product services remains narrowly allowed. A
  static App-global Tools & Linux Settings switch enables external networking
  after one clear disclosure; there is no per-command approval queue. Turning
  the switch off requires an acknowledged iSH runtime restart that terminates
  guest processes and closes all existing external sockets before UI reports
  Off. Narrow loopback is re-established after restart. Network-dependent tools
  report `guest_network_disabled` while it is off.
- Command-string matching is never treated as enforcement. Until the real
  adapter/socket boundary and toggle exist, the product must not claim external
  guest networking is disabled or expose the enable switch; the convergence
  slice retains and clearly discloses the current uncontrolled behavior until
  it is replaced.

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
- Keep active work to one controlled standard-library worker per accepted Run;
  add no general async executor, actor runtime, or idle scheduler.
- Query indexed incomplete runs during recovery instead of scanning historical
  streams.
- Starting with the first shipping schema, gate small forward storage migrations
  by stored schema version rather than replaying work at every launch; pre-release
  development stores reset under Section 15.2 instead.
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
  run lifecycle paths superseded by `engine`, `host`, and native Swift
  checks; `NativeToolManifest`, OS permissions, persisted user interaction, and
  the native effect ledger are explicitly retained;
- `run_snapshot` binding/preparation abstractions superseded by the flat profile
  and Run snapshot;
- host-binding and preparation sagas after current production routes use the
  direct model/tool contract; no pre-release compatibility reader remains;
- the current global-one Run lease, after per-conversation exclusion, the
  five-slot product admission counter, and attested resource tokens become
  production-authoritative;
- duplicate conversation repositories, frames, branch readers, wrapper services,
  and debug stores after `LocalAgentStore` has their required callers;
- concrete or duplicate Memory implementations without a production backend;
- the general `app_service` once `engine::Runtime` owns composition and `ffi`
  delegates only through its handles;
- old Swift card Builder, Review/Validate/Publish UI, duplicate model/provider
  destinations, route families, and wrappers with no shipping caller.

### 15.1 Current 23 roots to final 6

This is the cumulative P0 disposition ledger, not optional cleanup. Public-root
ownership closes in Phase 2, transitional Builder deletion closes in Phase 3,
and the complete ledger is verified at the Phase 5 global gate. “Private” means
nested below one owner; it does not remain a public compatibility root or
re-export.

| Current public root | Final disposition |
| --- | --- |
| `agent_input` | `engine::input`; snapshot-owned profile values remain in `profile` |
| `agent_loop` | `engine`; this is the only surviving production ReAct loop |
| `agent_package` | Delete installer/export/lockfile/upgrade root in Phase 3; no compatibility reader remains |
| `app_service` | Runtime composition moves into `engine::Runtime`; `ffi` retains only C ABI handles/lifecycle and DTO translation; delete general application service |
| `canonical_digest` | Private owner-local digest helpers; no public root |
| `context` | `engine::context` |
| `conversation` | `conversation` |
| `core` | Retained transcript/event IDs move to `conversation`; Run orchestration moves to `engine`; delete legacy runtime/session tree |
| `execution` | Retained direct-loop logic moves to `engine`, transport lifecycle to `host`, recovery persistence to `storage`; delete planner/RunMachine/approval path |
| `ffi_bridge` | `ffi` |
| `host_adapter` | `host` |
| `llm_contracts` | `host::transport`; keep envelopes/receipts/epochs, delete binding/preparation saga |
| `memory` | Minimal `engine::memory` interface only; delete concrete unused backends |
| `migration` | Delete the pre-release legacy translator and FFI surface; future post-release schema steps live privately under `storage` |
| `prompt` | Immutable documents/revisions in `profile`; assembly/budget contribution in `engine::context` |
| `protocol` | Delete generic plugin/binding/instance registries; retained wire contracts live in `host::transport` |
| `run_snapshot` | Compact immutable audit/lineage data moves under `engine`/`storage`; delete staging/resolver graph and executable old-policy retention |
| `security` | Retained cloud/transport policy contracts move to `host`; native permission/effect enforcement stays Swift; delete generic manager/approval queue |
| `skills` | Descriptor/revision/selection values move to `profile`; Swift keeps files/path resolution |
| `storage` | One concrete `LocalAgentStore` and one `localagent.sqlite`; delete aggregate/table Repository traits and duplicate stores |
| `tool` | Executable contracts/receipts move to `host`; call/result validation moves to `engine` |
| `user_customization` | Flat reusable/conversation configuration moves to `profile`; delete component graph/catalog/version/publish/readiness machinery |
| `utils` | Private owner-local helpers or delete; never a public business root |

`ModelRuntime`, `ToolRuntime`, model/tool request/event DTOs, and transport
receipts live under `host`. `engine` imports those ports; `host` never imports
`engine`. This prevents the current `host_adapter -> agent_loop::contracts`
inversion from surviving under new names.

### 15.2 Development-data reset and first-release baseline

This App has never shipped and has no users. The product decision is therefore
`supported_upgrade = ∅`: no current Rust or Swift database, component graph,
binding, package, Prompt store, or test fixture has a compatibility obligation.
Existing migration code proves only that development schemas changed; it is a
deletion candidate, not a reason to preserve the old architecture.

Phase 0 records one short reset inventory so the cutover is deliberate rather
than a collection of ad hoc deletes:

| Development data | Convergence action |
| --- | --- |
| Rust conversation/profile/runtime databases and old sidecars | Stop all development Runs, delete every old store/sidecar together, and bootstrap one `localagent.sqlite` plus the default Agent; write no translator |
| Swift Provider/model/binding/Prompt metadata | Reset the old business metadata and remove App-owned orphan Keychain references; configure the new model/profile path normally |
| Projection databases, caches, catalogs, download jobs, and previews | Regenerate; already-downloaded model files may be rediscovered only through the final model repository format |
| Skill file trees and other source-like developer assets | Re-index when already in the final file format, otherwise manually re-import; do not create a schema compatibility layer |
| Provider plans, pending interactions, tool-effect records, and Run leases | Terminate development Runs and reset them coherently with canonical Run state so no half-reset effect can resume |
| Tests, golden databases, and legacy fixtures | Delete or regenerate against the converged schema |

The reset happens in the vertical slice that installs the sole replacement
writer. That slice removes the old startup migration call, translator, FFI
operation, schema tables, and tests before it completes. After clean bootstrap
passes, the one-time reset code, old schema constants, and reset-only fixtures
are deleted as well. Old and new stores do not both accept writes, and no
temporary reader survives the slice. The OpenMinis migration manifest remains
only as source/license provenance; it is not a data compatibility mechanism.

The first actually distributed LocalAgent build defines the future compatibility
baseline. From that point onward, necessary forward storage migrations are
small, explicit, owner-private steps under `storage`; they never revive the
component graph, package system, binding saga, or a generic migration framework.
Security validation, reliable envelopes, effect safety, and diagnostics remain
because they protect current execution, not because of legacy data.

### 15.3 Staged slimming gates

The phases intentionally have different completion gates. Passing an earlier
gate never claims that a later deletion has already happened.

#### Phase 2 Core-shape gate

Phase 2 is complete when:

- `lib.rs` declares exactly the six structural roots in Section 5, only `ffi` is
  external/public, and no legacy public re-export facade remains;
- a checked import allowlist is acyclic and has zero forbidden edges;
- `storage` imports no business owner, `ffi` never opens storage, and the one
  concrete `LocalAgentStore`/`localagent.sqlite` is the only Rust persistence
  topology;
- shipping store open/recovery failure is explicit and blocks mutation; only
  tests may construct an in-memory canonical store;
- outside the sole transitional private old Builder, the only runtime dynamic
  ports are `ModelRuntime`, `ToolRuntime`, and `MemoryProvider`; no table/
  aggregate Repository trait survives;
- all 23 rows in Section 15.1 have a closed public-root disposition;
- there is exactly one production Agent loop, one canonical conversation
  store/path, and one Host transport path; old `execution`/`RunMachine` cannot
  accept a production Run;
- any still-live old Builder is the sole production Builder, is private under
  `profile`, and has no simultaneous flat `ProfileService` replacement path;
- accepted Runs use at most one controlled worker each, Host/projection waits are
  event-driven and bounded, and idle Rust has no fixed polling/timer loop;
- the Phase 0 development-data reset inventory is complete, and no legacy
  migration root, FFI operation, or startup path survives speculatively.

This gate permits `agent_package`, component graph/catalog/version,
publish/readiness, and legacy binding internals only where the private old
Builder still requires them. It does not permit them as public roots or as a
second Agent/Run path.

#### Phase 3 Builder-replacement gate

Phase 3 is complete when:

- there is exactly one production `ProfileService` implementing Section 6.1;
- every reusable Agent/profile write reaches `ProfileService`; every
  conversation/configuration write reaches `ConversationFacade`, whose outer
  command owns idempotency and any transaction-scoped profile helper;
- `agent_package`, generic component graph/catalog/version,
  publish/review/readiness, legacy binding/preparation, old `run_snapshot`, the
  general `app_service`, and old Builder operations have zero production
  references and no public or private production path;
- old build/publish/rebind/preparation FFI operations have zero callers;
- every pre-release legacy reader, translator, migration FFI operation, schema
  table used only by that path, and compatibility fixture is deleted;
- no Builder/component trait survives; the three Section 5 runtime ports are the
  crate's complete dynamic-port set;
- no compatibility adapter allows old and new Builders to accept the same
  operation.

#### Phase 5 global slimming gate

Architecture convergence is complete only when the Phase 2 and Phase 3 gates
still pass and all of the following are also true:

- one `ProductEnvironment` owns the raw Swift Bridge; Views/ViewModels depend on
  the appropriate concrete feature client and never call FFI directly;
- no pre-release migration or cutover adapter remains, and no old/new
  implementation pair accepts the same production operation;
- a retained wrapper has at least two real production callers or is a necessary
  Apple/C/FFI/transport boundary; otherwise it is inlined or deleted;
- each slice records retained replacement, moved production caller, relevant
  P0/P1 contract test, old implementation deletion, zero-caller evidence, and a
  passing focused suite/shipping build.

Lines deleted are a diagnostic, not the completion metric. Each staged gate is
one owner and one production path for the responsibilities completed in that
phase; the Phase 5 gate is the full-project completion claim.

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

Drafts are encrypted/local Swift presentation metadata keyed by
`(conversation_stream_id, content_epoch)`, not transcript events. They include
text, managed attachment IDs, requested Skill IDs, reasoning choice, and any
stashed pre-edit draft. Relaunch renders/sends a draft only when its epoch
matches the canonical projection; stale drafts are quarantined then purged.
List rows receive their draft indicator from this Swift store. Archive retains a
draft; Clear/Delete removes it after the reset/terminal projection. The submitted
draft clears only after `RunAccepted`; a preaccept rejection preserves it, while
a postaccept preparation failure remains represented by its canonical user turn
and terminal failure rather than resurrecting an “unsent” draft.

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
- Host preparation/resource/credential failure after `RunAccepted` commits a
  visible terminal failure on that submitted turn; it is not presented as an
  unsent draft and never changes target/credential generation silently.
- User/Swift/Rust cancellation never triggers fallback.
- Attachment type/size/storage errors occur before unbounded loading and leave
  the composer draft recoverable.
- Optional Skill catalog or Memory recall failure reports diagnostics without
  corrupting the transcript.
- Tool batch identity/order mismatch rejects canonical commit.
- An uncertain effect places the conversation behind
  `EffectResolutionRequired`; no retry/resend/automatic loop may cross it until
  explicit resolution is committed.
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

The order is fixed: minimal evidence, pure deletion, Rust Core convergence,
flat Builder, Swift UIUX, then final cleanup. Within Phases 2–4, every task is a
vertical slice with this required shape:

```text
retained replacement
-> move one production caller
-> fix the P0/P1 contract for that path
-> run focused tests
-> delete the old implementation/export in the same slice
-> prove zero callers and one remaining production path
```

P0/P1 findings are acceptance conditions inside these slices, not reasons to
create a new framework or dozens of horizontal infrastructure tasks.

### Phase 0: minimal evidence

Time-box this phase and do not repair the old architecture. Produce only:

- a production/debug/test/build/resource caller matrix for all 23 Rust roots;
- Swift/Xcode target, source-membership, build-phase, package/framework, and
  resource callers;
- the development-data reset inventory from Section 15.2, naming every store,
  source-like asset, coordinated runtime reset, and regenerated fixture;
- one complete ReAct product smoke path and one relaunch/projection replay path;
- startup, RSS, idle activity, first-turn latency, and binary-size baselines.

No compatibility migration task enters a later phase. The accepted inventory
uses reset, reseed, re-index, or manual developer re-import and deletes the
legacy component/profile/binding migration path.

### Phase 1: pure deletion

Create no replacement framework. Delete only proven zero-caller code, including
where the caller matrix confirms it:

- generic `protocol` plugin machinery;
- stale mocks and obsolete DTOs;
- duplicate adapters;
- non-shipping LiteRT paths;
- unreachable Swift runtime/inline-card UI;
- unused debug/archive/utility code;
- zero-caller migration code and legacy fixtures classified resettable or
  generated by the Phase 0 reset inventory.

Each proven-zero-caller subsystem may be removed as one whole, buildable commit;
it does not need one task per file. Live Builder, Run, conversation, Host, and
FFI behavior still waits for a Phase 2/3 vertical replacement slice. Phase 1
does not create placeholder facades for either case.

### Phase 2: Rust Core 23 to 6

Make Section 5's six-root dependency graph structural, remove every legacy
top-level export, and satisfy the Phase 2 Core-shape gate in Section 15.3. A
still-live Builder implementation may be relocated privately under `profile` as
its sole production implementation until its Phase 3 replacement slice; it is
not re-exported and no flat replacement runs beside it. In vertical slices,
establish exactly one production path for:

- mixed text/tool ReAct rounds and one direct Agent loop;
- Rust-first atomic Run acceptance, post-accept Host attestation, cancellation,
  and admission;
- the runtime-critical `AcceptedRunIntent`/`RunStartSnapshot` commitments:
  `ProductPolicyRef`, `SkillRevisionRef`, `ToolManifestRef`, `ModelTargetRef`,
  and per-candidate `CredentialRef` generation CAS;
- monotonic sequence/content-epoch Clear/Delete and projection reset;
- pre-effect Swift ledger receipts and uncertain-effect barriers;
- one active Run per conversation plus product/target resource admission;
- one canonical conversation/event/projection path;
- one reliable Host transport path;
- one concrete `LocalAgentStore`/`localagent.sqlite`, with no duplicate Rust
  repository topology;
- only the three crate-private runtime ports outside the sole transitional
  private Builder, and at most one controlled worker per active Run, with
  bounded event-driven waits and no idle polling;
- model-aware Context/compaction and the minimal Memory interface.

After correctness cutover, move polling to event-driven waits, index recovery,
bound channels/buffers, and lazy-load heavy runtimes. A slice is incomplete if
the old `execution`/RunMachine or another legacy root can still accept the same
production Run. Phase 2 is complete when the Core-shape gate passes; it does not
claim the private old Builder has been replaced.

### Phase 3: flat Agent Builder

Install the unique `ProfileService` and `ConversationFacade` commands in Section
6.1 and the simple create/duplicate/edit/delete/default/new-conversation/
save-as-Agent UI contract.
The slices also finish:

- final ProfileService ownership of reusable Agent Skill selection and
  ConversationFacade ownership of conversation-local selection, with
  Swift-owned immutable files;
- Prompt/Skill revision authoring, retirement, and garbage collection;
- coordinated reset/bootstrap of the old profile, Prompt, binding, snapshot,
  and development runtime stores under Section 15.2;
- Builder field errors and the first-release profile schema baseline.

Phase 3 does not postpone any Run-safety field required by Phase 2; it replaces
the authoring/storage path while preserving the Phase 2-established runtime
commitments.

As each real caller moves, delete the corresponding `user_customization`
component graph/catalog/version, publish/review/readiness, `agent_package`, host
binding, old `run_snapshot`, and general `app_service` operation in the same
slice. Save-time field validation replaces the old ceremony; no adapter keeps
both Builder systems live. Phase 3 is incomplete until the Builder-replacement
gate in Section 15.3 passes.

### Phase 4: Swift conversation-first UIUX

- Replace the root with iPhone conversation navigation and iPad adaptive
  sidebar/Chat/Control Center.
- Complete Chat header/composer, attachment/Skill/reasoning controls,
  Send/Stop, and Edit/Resend/Retry/Branch.
- Complete Agent create/edit, Models/Providers, and the hierarchical
  Conversation Control Center.
- Enforce and expose the real iSH external-network default at the socket/adapter
  boundary and attachment/model capability UI.
- Make `ProductEnvironment` the sole raw Bridge owner and route each ViewModel
  through its concrete conversations/profiles/models/tools/settings client.
- Delete old tabs, card Builder, Model Center, duplicate ViewModels, and routes
  as their replacement screen ships.
- Update the OpenMinis migration manifest when retained donor-derived ownership
  changes; license provenance remains intact.

### Phase 5: final cleanup and validation

- Verify every pre-release migration/cutover adapter was deleted in its owning
  slice; delete only unrelated final zero-caller remnants. No legacy reader,
  writer, FFI operation, or fixture remains.
- Verify the complete Phase 5 global slimming gate in Section 15.3 passes.
- Run clean-checkout Simulator/device native/rootfs builds.
- Compare performance with Phase 0 and investigate regressions.
- Pass the two product paths and focused correctness/UI/accessibility suites.

Voice, alarms, widgets, extensions, backup, eligible sync, Cron, Hooks, and
Multi-Agent remain independent future slices. Existing shipping callers may be
kept, but these features neither expand nor block the convergence phases.

## 20. Validation Strategy

### 20.1 Focused Rust suites

- direct ReAct final, tool-only, mixed text-plus-tool, empty-response, and
  200-turn terminal paths;
- Rust-first acceptance transaction, submission cancellation, post-accept Host
  attestation/start, recovery, and one-active-run exclusion;
- command idempotency, stale content-epoch rejection, Clear/Delete reset replay,
  monotonic sequence, and minimum replay handling;
- unique ProfileService reusable-Agent surface, unique ConversationFacade
  conversation surface, profile request receipts, creation-scope/stream
  idempotency, content-epoch checks, and complete-replacement revision conflicts;
- edit/resend/retry/delete effective transcript semantics;
- same-conversation variants and separate-conversation branch lineage;
- Retry preserving semantic source text/attachments/turn overrides/model identity
  while using current Agent/product runtime policy, with no old-policy executor;
- atomic tool-round persistence, pre-effect Swift-ledger reconciliation,
  model-visible uncertain-effect barriers, Clear/Branch bypass rejection, and
  cancellation races;
- five-slot/resource-token admission, mixed cloud/local Runs, sixth-send
  rejection, exact release, and relaunch reconciliation;
- projection replay, gap recovery, idle cancellation, bounded coalescing, and
  nonblocking publication;
- model-derived budgets, 70% default policy, tool-output elision, attachment
  recovery, summary checkpointing, and unchanged canonical history;
- descriptor-only Skills and virtual path safety;
- owning Prompt/Skill/source-turn references, non-owning compact Run audit,
  derived-reference copying, and Skill retirement epoch/zero-reference proof;
- coordinated development-store reset, clean bootstrap, and absence of old
  migration/startup/FFI paths;
- Memory interface recall/completed-turn hooks;
- indexed process-loss recovery;
- stable attempt IDs and deduplicated active-path/all-attempt usage across
  fallback, compaction, cancellation, variants, and derived conversations;
- Phase 2 six-structural-root/only-FFI-public/import-direction check, one concrete
  SQLite store, three runtime ports outside any sole transitional private
  Builder, bounded worker count, and zero idle polls;
- Phase 3 unique-`ProfileService`/`ConversationFacade` ownership and
  zero-legacy-Builder-reference check;
- Phase 5 complete disposition-ledger/global-slimming check.

### 20.2 Focused Swift/C++ suites

- provider setup, Keychain isolation, explicit fallback order, forward-only
  candidate selection, complete compatible route groups, and cleanup;
- accept/prepare/start attestation mismatch, credential-generation change,
  old-host-epoch recovery, Stop by submission/Run identity, and idempotent
  `CloseSession` ownership after acceptance;
- credential rotation after Send/before prepare fails generation CAS and the
  accepted Run; rotation between rounds terminates without fallback/key switch;
  Retry after rotation freezes the new generation and never resurrects the
  source generation; same-generation OAuth access-token refresh remains allowed;
- per-turn cloud disclosure/egress authorization and sealed-request ordering;
- cloud/local unified model capability filtering;
- attachment preflight, bounded import, direct-cloud capability gating,
  reference counting, and final-byte deletion;
- tool-batch cancellation before later chunks, ledger coverage immediately
  before every effectful dispatcher path, durable file-backed relaunch,
  query/resolve receipts, and per-run cleanup;
- native manifest/permission gates and pending-interaction relaunch recovery;
- iSH bounded output and virtual mount security; with external networking off,
  IPv4/IPv6 TCP/UDP/connect and DNS/non-connect escape paths fail while required
  loopback remains usable, and toggle restart/existing-socket semantics hold;
- app launch restoration and projection read-model behavior;
- onboarding resume, new-conversation scope isolation, Send/Stop, `/` Skills,
  one-turn Skill hints, reasoning capability mapping, draft lifecycle, and
  Control Center navigation;
- iPhone/iPad size-class navigation and accessibility actions;
- one `ProductEnvironment` raw-Bridge owner, feature-client isolation, and zero
  direct View/ViewModel-to-FFI calls;
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
   legacy publish/binding/preparation saga, and duplicate business state
   machines have no public root or production reference.
7. A default Agent works immediately; saved Agents are flat and editable.
8. Every conversation owns an independent complete Agent configuration. A Run
   freezes its Agent values and the five stable cross-layer reference kinds;
   Host materialization is attested once and private transport details remain in
   Swift. Every Run-producing submission supplies current credential
   generations; Retry never reuses the source Run's credential generation.
9. Prompt is ordered Markdown assembled only in Rust.
10. Skills use descriptor-first progressive disclosure and virtual paths; Rust
    owns all selection state while Swift owns immutable file revisions and path
    resolution.
11. Tools execute as one validated ordered Swift batch; multimodal availability
    follows model/runtime capabilities, and assistant text accompanying tool
    calls commits with that tool round rather than ending the Run.
12. Memory remains a fact-oriented optional interface, never transcript or
    Context storage.
13. Context rebuilds every round, uses the frozen model window, defaults to an
    approximately 70% compaction policy, bounds transient tool data, and keeps
    canonical history unchanged.
14. Message edit, resend, retry, delete, variant navigation, and separate
    conversation branching have deterministic Rust semantics and complete UI.
    Retry preserves the semantic source turn while using current Agent/product
    runtime policy; historical Run snapshots remain immutable audit data only.
15. Relaunch restores canonical conversation summaries and transcripts before
    live observation.
16. Streaming projection and tool output are bounded and cannot block the Agent
    loop or grow without limit.
17. Provider fallback is explicit, frozen per Run, forward-only, and never
    triggered by cancellation.
18. Cloud requests execute only through `LocalAgentLLMCloud`; credentials remain
    Swift-only and never enter Rust or iSH.
19. iSH external guest networking is disabled by default at the real network
    boundary, loopback exceptions and toggle semantics are tested, risk is
    accurately disclosed, and host mounts remain traversal/symlink protected.
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
27. Each vertical replacement—not a structural relocation—names the retained
    implementation, moves a real production caller, fixes its contract,
    passes focused tests, deletes the implementation/export it replaces in the
    same slice, and proves zero callers. Phase 2 may relocate the sole old
    Builder privately; the Phase 3 `ProfileService` replacement slice must
    delete it.
28. Clean-checkout Simulator and device builds regenerate the required pinned
    iSH/rootfs/native artifacts and preserve required third-party licenses.
29. The focused suites and two product-level paths pass.
30. Run acceptance is one idempotent Rust transaction; post-accept Host
    preparation is attested before `RunStarted`, performs no model/tool/network
    effect, Rust releases its own reservations transactionally, and idempotent
    `CloseSession` exclusively releases Swift Host resources.
31. Effectful tools persist one Swift-ledger receipt before the effect boundary;
    only `proven_not_applied` is replayable, while uncertain effects create a
    visible, model-aware barrier and are never automatically repeated.
32. Cloud transmission retains exact per-turn disclosure and egress
    authorization before credential encoding or network execution.
33. Attachment bytes are bounded, capability-gated, reference-counted across
    variants/derived conversations, and removed after the final reference.
34. Cross-conversation admission allows independent cloud/local work within the
    five-Run product limit without retaining the current global-one lease.
35. Phase 2 passes when `lib.rs` declares the six structural roots but exposes
    only `ffi`; the checked import DAG is valid; every former public root is
    deleted or privately owned; and only one Agent loop, conversation path, and
    Host path drives production. The sole old Builder may remain only as a
    private `profile` implementation.
36. Phase 3 passes only when the unique `ProfileService` owns reusable Agent
    writes, `ConversationFacade` owns conversation/configuration writes, and the
    old Builder, component/package/binding/preparation, old `run_snapshot`, and
    obsolete `app_service` paths are deleted with zero production references.
37. Clear/Delete retain monotonic stream sequences and idempotency receipts,
    reject stale content epochs, and repair old Swift cursors with an explicit
    reset/terminal projection.
38. Prompt, Skill, and attachment assets are physically deleted only after every
    Agent, conversation, active-Run, and source-turn owning reference is gone.
    Derived conversations copy needed source-turn references; compact Run audit
    records are non-owning and keep no executable old product-policy bytes or
    algorithm assets.
39. Phase 5 passes only when the complete Section 15.3 global slimming gate
    passes, including one `ProductEnvironment` Bridge owner, feature-client
    isolation, zero direct View-to-FFI calls, and no pre-release migration/
    cutover abstraction.
40. `supported_upgrade = ∅`. Phase 0 records how every development store and
    fixture resets, reseeds, re-indexes, or regenerates; no current legacy schema
    receives a translator. The first distributed schema is the future
    compatibility baseline.
41. Rust canonical persistence is one concrete `LocalAgentStore` over one
    `localagent.sqlite`; the only crate-private dynamic ports are `ModelRuntime`,
    `ToolRuntime`, and `MemoryProvider`.
42. Rust introduces no general async/actor runtime: admission precedes at most
    one controlled worker per active Run, bounded event-driven waits replace
    polling, and an idle Core has no periodic worker or SQLite wake-up.

## 22. Implementation Planning Boundary

The implementation plan must follow the six delivery phases and create small
vertical tasks. It must not:

- revive the complete OpenMinis app or its navigation as the product;
- add another Core, package graph, plugin registry, event bus, or transcript;
- bulk-delete an active production path; a whole zero-caller subsystem may be
  removed only after the caller matrix proves it unreachable;
- expose internal revisions, bindings, component graphs, Context policy, or
  permissions as ordinary user configuration;
- mix global Agent defaults with conversation-owned edits;
- block Core completion on Cron, Hooks, Multi-Agent, or peripheral product slices;
- repeat every focused scenario in a giant product integration test.

Future extension uses only the retained seams:

| Extension | Mechanism |
| --- | --- |
| Prompt | Ordered Markdown documents |
| Skill | File tree, descriptor, and virtual path |
| Tool | Swift executable manifest plus `ToolRuntime` |
| Cloud/local model | `ModelRuntime` plus Swift/C++ adapter |
| Memory | `MemoryProvider` |
| UI | Concrete Swift feature client and ViewModel |

It does not create a plugin registry, component graph, package installer, or
generic event bus. Cron, Hooks, and Multi-Agent enter later through concrete
command/tool requirements if and when a product slice exists.

The first implementation plan should cover Phase 0 and Phase 1 in executable
detail, then identify the Phase 2 Core-shape gate defined in Section 15.3. It
must schedule reset/reseed/re-index/deletion under Section 15.2 and must not
schedule a pre-release compatibility translator. Later phases may be split into
separate plans after the preceding convergence gate is satisfied; the target
architecture and product semantics in this specification remain shared.
