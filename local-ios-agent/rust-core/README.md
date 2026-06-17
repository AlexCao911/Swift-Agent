# Rust Core Runtime

This crate contains the local iOS agent runtime foundation.

## Boundaries

- `core`: agent loop, event stream, session tree, stream batching, run lifecycle
- `memory`: persistence boundary and current in-memory event store
- `context`: PromptFrame construction and tokenizer contract
- `security`: policy and approval suspension types
- `tool`: tool schema and result DTOs
- `utils`: small shared helpers

Swift owns native iOS tools and UI. C++ owns future on-device inference. This
crate owns agent semantics.

## Test

```bash
cargo test
```
