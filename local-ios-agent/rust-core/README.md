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

## Memory Stores

The `memory` module exposes an `EventStore` trait so the runtime can keep one
session-tree API while swapping persistence backends.

- `InMemoryEventStore` is the default MVP runtime store. It keeps tests and the
  mock provider fast while the Swift and UniFFI surfaces are still evolving.
- `SqliteEventStore` persists events, sessions, and closure-table path rows. The
  closure table lets `active_branch(session_id, leaf_id)` reconstruct the
  current root-to-leaf branch without loading an entire tree into memory.

The SQLite schema currently stores text payloads and blob references. Encryption,
blob file storage, and process restart recovery are deliberately left for later
plans so the persistence boundary can stay small and well-tested first.

## Test

```bash
cargo test
```
