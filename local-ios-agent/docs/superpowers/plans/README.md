# LocalAgent Implementation Plans

The current architecture source of truth is:

- `../specs/2026-08-02-localagent-architecture-convergence-uiux-design.md`

The active implementation sequence begins with:

1. `2026-08-03-localagent-convergence-phase-0-1-evidence-deletion.md` — establish the evidence baseline and delete only proven non-shipping code.
2. Phase 2 — converge the Rust Core from 23 public roots to six structural roots. Write this plan only after the Phase 0/1 gate passes.
3. Phase 3 — replace the old Builder/component graph with the flat, revisioned Agent Profile service.
4. Phase 4 — implement the conversation-first iPhone/iPad UIUX over one Swift product facade.
5. Phase 5 — remove final adapters and verify the clean first-release architecture and performance gates.

Older dated plans and archived plans are historical evidence. They are not execution inputs when they conflict with the current design or active sequence.
