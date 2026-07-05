# Minimal Agent Capability Contract

This note records the smallest Rust-side abstraction layer needed before the Swift app product design. It is not a full agent platform design.

## Implemented Now

### Skill Package v0

`SkillPackage` is a data-only package:

- manifest id, version, title, description
- required capabilities
- allowed capabilities
- markdown instructions
- data-only sandbox policy
- activation into context contribution segments
- in-memory repository interface for install/list/get
- `ComponentContent::Skill` can carry the same package manifest shape

The v0 contract intentionally does not execute scripts, load assets, or parse a full `SKILL.md` bundle.

### Tool Capability Metadata

`ToolSchema` keeps the existing JSON metadata channel and adds typed helpers for:

- capability id
- permission scope
- host platform availability

Rust can validate capability availability without knowing platform APIs. iOS, macOS, Android, desktop, and web hosts can provide different executors behind the same capability id.

### Memory Policy Boundary

Memory is split into three minimal policy stages:

- extraction policy: what runtime events can produce memory candidates and what kinds to extract
- selection policy: how many memories to retrieve and which query sources may drive retrieval
- injection policy: how selected memories enter context, including token budget and review requirements
- memory candidates can record source event id, extracted kind, confidence, sensitivity, and review state

This is only the boundary. Semantic retrieval, memory review UI, and automatic memory updates are later work.

### Context Contributions

`ContextContributionBundle` lets skill, memory, and other providers contribute structured `ContextSegment`s to `ContextAssembler`.

Rust remains responsible for final model input assembly, ordering, budgeting, sensitivity filtering, and trace output.

## Deferred Issues

Create GitHub issues for these instead of blocking Swift app design:

- Binding skill packages into published agent profile slots.
- Resolving skill bindings into `ResolvedRunSnapshot`.
- Calling memory resolvers from the active execution LLM loop.
- Verifying skill-required capabilities against the production tool registry.
- Full `SKILL.md` runtime with progressive disclosure.
- Executable skill sandbox and signed extension model.
- Skill references, assets, and scripts.
- Skill package signing, import/export hardening, and marketplace.
- Semantic/vector memory retrieval.
- Memory review inbox and automatic memory write policy UI.
- Visual context pipeline editor.
- Cross-platform host SDK beyond the current Rust contract and iOS Swift host.
- User-defined remote tool connector builder with OAuth/secret vault/egress review.

## Swift Design Implication

Swift should treat this as a host implementation boundary:

- render and install data-only skills
- map native iOS tools to capability metadata
- expose permission and approval UX
- choose model/provider/local engine
- preview context contributions and debug traces

Swift should not assemble final model context directly, execute skill code, or bypass Rust tool routing.
