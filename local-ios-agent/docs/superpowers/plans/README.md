# LLM Runtime Delivery Plans

This directory contains only the active LLM runtime plan sequence. Historical plans created before the unified Swift-managed Cloud/Local LLM architecture are preserved under `archive/legacy-pre-llm-runtime/`; they are reference material, not execution inputs for the current delivery stream. The completed Phase 1 remediation is under `archive/completed-llm-phase-1/`, and unrelated Native Toolkit work is under `archive/non-llm-workstreams/`.

## Active sequence

1. **Foundation — complete.** `2026-07-11-swift-llm-phase-1-foundation-implementation.md` establishes portable LLM slots, durable host bindings, a single-Agent lease, preparation contracts, and Rust–Swift bridge contracts.
2. **Cloud Provider Runtime — planned.** Provider profiles, Keychain credentials, egress approval, connectivity checks, streaming, cancellation, and the first OpenAI-compatible adapter.
3. **Local Model Lifecycle — planned.** Curated model catalogue, download/resume/verification, deletion, and disk-space management.
4. **Local C++ Inference Runtime — planned.** Backend loading, RAM residency, generation streaming, cancellation, capability reporting, and iPhone/iPad memory policy.
5. **Unified Agent Execution — planned.** One Agent Profile selects either Cloud or Local, with normalized generation/tool-call events and end-to-end approval coverage.

Plans 2 and 3 may proceed in parallel. Plan 4 depends on Plan 3, and Plan 5 integrates Plans 2 and 4.
