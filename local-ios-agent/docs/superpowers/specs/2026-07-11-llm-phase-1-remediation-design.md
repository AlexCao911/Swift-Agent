# LLM Phase 1 Trust and Durability Remediation Design

**Date:** 2026-07-11  
**Status:** Approved direction; implementation pending  
**Scope:** Correct the Phase 1 foundation before any Provider adapter, local
inference backend, generation callback, credential, or egress implementation is
added.

## 1. Objective

Phase 1 already establishes provider-neutral Rust/Swift contracts, portable
`LLMSlotV2`, host-binding saga records, a global single-run lease, and a
non-runnable two-phase preparation flow. This remediation makes those contracts
safe to reuse in later phases.

The corrected foundation must guarantee all of the following:

1. Rust derives every Rust-owned preparation digest from the actual start
   request and current Rust-owned sources. Swift cannot submit those digests.
2. A preparation record and its global lease are created, renewed, aborted,
   closed, and recovered with repository-level atomic operations.
3. A prepared session can release the lease only after an acknowledged cleanup
   command and a receipt whose digest Rust recomputes from the complete stored
   command and registration.
4. Normal callers cannot claim `epoch_ended`; only Rust startup recovery may
   apply that disposition.
5. Phase C has one provider-neutral public-binding validator that is complete
   enough to be reused by the future runnable commit path.
6. Host-binding operations change actual Profile/Package lifecycle state, not
   only Agent OS side tables.
7. Swift host state is stored in normalized SQLite tables with transactions,
   compare-and-swap updates, migrations, and indexes.
8. Saga and preparation bearer tokens contain 256 bits from the operating
   system CSPRNG and only their canonical digests are persisted.

## 2. Non-goals

This remediation does not:

- connect to a cloud Provider;
- read or write API keys;
- perform network egress or approval;
- load a local model or call C++ inference;
- start a host-backed generation worker;
- add concurrent Agent execution;
- remove the legacy production route; or
- make `LLMSlotV2` runnable.

After successful Phase C validation, Phase 1 still begins prepared-session
cleanup and returns `execution.host_slot_v2_not_runnable`.

## 3. Authority boundaries

### 3.1 Rust-owned inputs

Rust owns and computes:

- Agent Profile and revision lookup;
- `LLMSlotV2` slot and `AgentLLMRequirements` lookup;
- conversation frame resolution;
- execution plan and tool schemas;
- context, memory, and attachment source revisions;
- canonical first-turn `AgentLLMInput`;
- `GenerationDisclosure` for that input;
- every digest over those values; and
- the global run/preparation lease.

Swift receives provider-neutral requirements and digests. It cannot provide
`conversationFrameDigest`, `executionPlanDigest`, `requirementsHash`,
`toolSchemaDigest`, `modelInputDigest`, `sourceRevisionsDigest`, or
`initialDisclosureDigest` to Phase A.

### 3.2 Swift-owned inputs

Swift owns:

- the concrete host binding behind an opaque binding tuple;
- the sanitized Swift configuration snapshot;
- observed generic capabilities;
- the prepared host session identity; and
- an opaque egress subject digest.

Rust interprets only route-neutral public capability and disclosure fields. It
does not interpret Provider names, model names, URLs, credentials, local paths,
or backend-specific parameter keys.

### 3.3 Trust model

Canonical digests prevent mismatched state and make reconciliation
deterministic. They are not a cryptographic isolation boundary against Swift,
which runs in the trusted app host. Random bearer tokens still prevent an
unrelated or stale caller from guessing a saga/preparation authority.

## 4. Authoritative Phase A preview

### 4.1 FFI request

Replace the current digest-bearing `RunPreparationRequest` FFI shape with:

```text
AuthoritativeRunPreparationRequest {
  idempotencyKey
  preparationID
  proposedRunID
  startRequest {
    agentProfileID
    profileRevisionID
    userIntent
    conversationRunFrameRef
  }
}
```

Unknown fields are rejected. In particular, the request has no field in which
Swift can supply a Rust-owned digest or disclosure.

### 4.2 Rust preview pipeline

`RunPreparationService` receives an `AuthoritativePreparationPreviewService`,
not a prebuilt `PreparationBinding`. That service shares the source-capture
path used by `RunSnapshotService.preview`:

1. Load the exact Profile revision.
2. Require one matching `LLMSlotV2` and an active opaque host-binding cross-link
   for that profile/revision/slot. Do not resolve a legacy concrete model.
3. Resolve the conversation frame by the supplied frame reference.
4. Preview the execution plan and canonical ordered tool schemas.
5. Assemble context under the requested budget and build the first-turn
   `AgentLLMInput`.
6. Compute its `GenerationDisclosure` from the actual assembled input.
7. Capture exact profile, frame, component, memory, context, attachment, and
   tool-schema revisions.
8. Compute all registered canonical digests inside Rust.

The legacy `RunSnapshotService.preview` remains unchanged for legacy execution.
The shared trusted-source capture and component/tool resolution code is
extracted so the V2 preparation preview cannot accidentally call
`resolve_model_binding`.

### 4.3 Frozen input custody

The canonical bytes of the first-turn `AgentLLMInput` are inserted into a
process-scoped `PreparedModelInputVault` before the durable preparation
transaction. The durable record stores only its opaque input ID, digest, and
source revision digest. The vault never exposes input bytes through the Phase 1
FFI.

Uncommitted preparations are invalid after process restart, so the input vault
does not need disk persistence. If the durable transaction fails, the vault
entry is removed. Startup recovery closes every old-epoch preparation before
the runtime accepts calls. A future runnable start command must load the bytes
by frozen input ID and recheck the digest before copying a command to Swift.

### 4.4 Idempotency

An exact replay is defined by the canonical digest of
`AuthoritativeRunPreparationRequest`, not by caller-supplied derived digests.
Within one process, an exact replay returns the existing preview and current
ephemeral bearer token. A conflicting request under the same idempotency key
fails with `preparation.idempotency_conflict`.

## 5. Atomic Rust preparation repository

The public repository no longer exposes independent lease and preparation
writes for preparation lifecycle operations. It exposes these atomic methods:

```text
create_preparation_and_acquire_lease(
  expectedEmptyLease,
  newPreparationRecord)
  -> { persistedPreparation, leaseGeneration }

renew_preparation_and_lease(
  preparationID,
  leaseGeneration,
  hostProcessEpoch,
  expectedState,
  expectedTokenGeneration,
  expectedTokenDigest,
  renewedRecord)
  -> persistedPreparation

abort_preparation_and_begin_release(
  preparationID,
  leaseGeneration,
  hostProcessEpoch,
  expectedState,
  abortRecord,
  optionalCleanupOutbox)
  -> persistedPreparation

close_preparation_and_release(
  preparationID,
  leaseGeneration,
  hostProcessEpoch,
  expectedCleanupState,
  closedRecord,
  receiptLedgerEntry)
  -> persistedPreparation

recover_preparations_for_new_epoch(newEpoch)
  -> [RecoveredPreparationID]
```

Every SQLite implementation uses `BEGIN IMMEDIATE`. Creation inserts both the
`global_run_lease` and `run_preparations` state in the same transaction.
Renewal updates `run_preparations.token_generation`,
`run_preparations.token_digest`, `record_json`, and
`global_run_lease.preparation_expiration` under one CAS. The CAS includes
preparation ID, lease generation, host epoch, current state, old token
generation, and old token digest.

In-memory implementations perform the same validation while holding one store
lock. The old public combination of `acquire_preparation` followed by
`create_run_preparation` is removed so production code cannot reintroduce the
split transaction.

## 6. Cleanup command and close receipt protocol

### 6.1 Durable cleanup outbox

Add `preparation_cleanup_outbox` with:

```text
cleanup_command_id primary key
preparation_id unique
host_process_epoch
cleanup_sequence
registration_digest
command_digest
state: pending | acknowledged | closed | cancelled_epoch_end
acknowledged_at_millis nullable
closed_at_millis nullable
record_json
```

`begin_abort_preparation` writes the aborting preparation, moves the lease to
`releasing`, and inserts the outbox row in one transaction. The cleanup command
is delivered only from that outbox.

Swift accepts a cleanup envelope into its actor/SQLite transaction and returns
an acknowledgement containing `cleanupCommandID`, `cleanupSequence`, and
`commandDigest`. Rust persists the transition `pending -> acknowledged` before
accepting a normal close receipt. Duplicate acknowledgement is accepted only
when all three fields match.

### 6.2 Command digest

Rust computes `prepared-session-cleanup-command:v1` over:

```text
cleanupCommandID
preparationID
proposedRunID
sessionHandle
hostProcessEpoch
cleanupSequence
abortReason
preparedSessionRegistrationDigest
```

The command ID is random and the sequence is monotonically increasing per
preparation. It is a persisted correlation identifier, not a bearer authority.
The digest does not include its own field.

### 6.3 Close receipt digest

External close dispositions are limited to `closed | already_closed`. Swift
computes `prepared-session-close-receipt:v1` over:

```text
cleanupCommandID
preparationID
proposedRunID
sessionHandle
hostProcessEpoch
cleanupSequence
preparedSessionRegistrationDigest
cleanupCommandDigest
closeDisposition
```

Rust loads the persisted acknowledged outbox row, reconstructs the same
canonical document, recomputes the receipt digest, and uses constant-time byte
comparison. Identity matching without digest validation is insufficient.

Only `close_preparation_and_release` can persist the accepted receipt and
release the exact lease. Duplicate close is idempotent only for the identical
receipt digest.

### 6.4 Epoch recovery

`epoch_ended` is removed from the external receipt enum. On startup,
`recover_preparations_for_new_epoch` performs one transaction that:

1. finds every non-closed preparation from another epoch;
2. writes an internal `EpochEndedRecoveryRecord` for each;
3. marks each preparation closed;
4. marks any cleanup outbox row `cancelled_epoch_end`; and
5. releases the matching old global lease.

The bridge constructs `RunPreparationService` only after this transaction
succeeds. It must not call the lower-level lease-only recovery method.

## 7. Complete Phase C public-binding validator

Create one pure `PreparedStartValidator::validate` used by Phase 1 and retained
for the future runnable commit. It returns a validated value rather than a
boolean:

```text
ValidatedPreparedStart {
  preparationID
  proposedRunID
  frozenModelInputID
  frozenModelInputDigest
  hostBindingTuple
  registrationDigest
  capabilityAttestationDigest
  egressAttestationDigest
}
```

Validation performs all of the following before any run state is committed:

- verify the current token digest, generation, epoch, expiry, and binding
  digest;
- recompute `prepared-session-registration:v1` after removing the supplied
  `registrationDigest` field;
- require the registration to match the persisted preparation/session identity;
- query the active host-binding cross-link by profile ID, profile revision, slot
  ID, binding ID, binding revision, and binding hash;
- recompute the route-neutral capability attestation digest;
- check streaming, tool-calling, modality, parallel-call, and context-length
  claims against the frozen `AgentLLMRequirements`;
- require capability evidence and the host attestation to be unexpired;
- recompute `egress-attestation:v1` from the preparation binding digest,
  registration digest, frozen disclosure digest, disclosure grant ID, public
  data classes/sensitivity, and opaque Swift subject digest; and
- recheck that the `PreparedModelInputVault` still contains bytes matching the
  frozen input digest.

`PreparedSessionRegistration` is extended with the opaque binding ID, binding
revision, and binding hash. `HostAttestation` is extended with the generic
capability attestation and complete public egress-attestation fields. No
Provider or local-backend identifier crosses into Rust.

On Phase 1 success, `commit_start` passes the validated value to the existing
non-runnable cleanup path and returns
`execution.host_slot_v2_not_runnable`. Validation failure uses the same cleanup
path with `commit_rejected` and never creates a run snapshot.

## 8. Host-binding Saga integration

### 8.1 Service boundary

Raw Agent OS tables become persistence primitives. FFI calls an
`AgentHostBindingService` that also owns adapters for actual Profile and Package
state:

```text
HostBindingSubjectCatalog
  require_pending_profile_revision(profileID, revision, slotID, requirementsHash)
  mark_profile_host_unbound(profileID, revision, crossLink)
  activate_profile_binding(profileID, revision, crossLink)
  require_package_needs_binding(installationID, profileID, revision, slotID, requirementsHash)
  mark_package_host_unbound(installationID, crossLink)
  activate_package_binding(installationID, crossLink)
```

The in-memory Profile and Package repositories implement this interface in
Phase 1. A later persistent Profile/Package repository can replace the adapter
without changing the saga protocol.

### 8.2 Profile lifecycle

V2 profile publication stages a hidden `pending_host_binding` revision before
`prepare_profile_publish`. That call rejects missing, visible, wrong-revision,
wrong-slot, or requirements-mismatched subjects.

After Swift stages the exact binding, `commit_profile_publish` verifies the
receipt and writes the opaque cross-link, then makes the Profile revision
visible with readiness `host_unbound`. It is selectable for configuration but
cannot start a run. After Swift activation, a new
`confirm_host_binding_activation` operation moves both the saga and Profile
readiness to `active` using the exact binding tuple and staging receipt.

Legacy profile publication is unchanged.

### 8.3 Package lifecycle

A V2 package installation is recorded as `needs_llm_binding` with its actual
installation ID and Profile revision before `begin_package_binding`. The begin
call validates that exact record. `attach_host_binding` writes the cross-link
and changes it to `host_unbound`; only
`confirm_host_binding_activation` changes the installation to `ready`.

Missing or mismatched subjects fail before any saga operation is created.
Reconciliation compares the operation row, cross-link, actual subject state,
and Swift staging state, and advances only forward through
`pending -> host_unbound -> active`.

### 8.4 Stable operation identity and rotating authority

A host-binding operation has two distinct identities:

- `operationID` and `operationRequestDigest` are stable reconciliation keys;
- `operationToken` is a random, rotatable bearer authority used to commit or
  resume the operation.

`host-binding-staging-receipt:v2` binds the stable operation ID/request digest,
subject, slot, requirements hash, and opaque binding tuple. It does not bind the
current bearer token digest. Rust separately validates the presented bearer
against the operation's current token generation and digest. Therefore a lost
response or process restart may rotate the bearer without invalidating an
already durable Swift staging receipt.

## 9. Swift SQLite `LLMStore`

Replace whole-document JSON persistence with a SQLite repository. Add a small
`CSQLite` system-library target that links the Apple platform `sqlite3`
library; do not add a third-party database dependency.

The schema contains:

```text
llm_schema_metadata(version)
host_binding_staging(
  operation_id primary key,
  operation_request_digest unique,
  operation_kind,
  subject_id,
  binding_id,
  binding_revision,
  binding_hash,
  receipt_digest,
  state,
  record_json,
  updated_at_millis)
prepared_sessions(
  preparation_id primary key,
  proposed_run_id unique,
  session_handle unique,
  registration_digest,
  state,
  record_json,
  updated_at_millis)
prepared_cleanup_commands(
  cleanup_command_id primary key,
  preparation_id unique,
  cleanup_sequence,
  command_digest,
  state,
  close_receipt_digest nullable,
  record_json,
  updated_at_millis)
```

Every stage, activation, cleanup acceptance, and close operation uses
`BEGIN IMMEDIATE`, validates the expected state and digest in SQL, and commits
all related rows together. Zero affected rows are distinguished as an exact
idempotent replay or a CAS conflict by rereading the row.

`PRAGMA user_version` controls forward-only migrations. Version 1 creates the
tables and indexes. If an existing Phase 1 JSON file is detected, it is decoded
once, imported inside one SQLite transaction, renamed to a `.migrated` backup
after commit, and never used as an active store again. Corrupt JSON or failed
import leaves the source untouched and fails store initialization closed.

The in-memory test store remains available behind the same repository protocol.
Neither SQLite nor migration records store credentials, Provider payloads,
resolved local paths, model input bytes, or bearer tokens.

## 10. Random bearer tokens

Rust directly depends on `getrandom` and requests 32 random bytes for every
host-binding token and preparation token, including every token rotation. Bytes
are encoded as unpadded base64url. Generation failure aborts the operation
before any durable state change. Cleanup command IDs also use 32 random bytes
for collision resistance, but remain persisted correlation identifiers rather
than bearer authorities.

The durable representation contains:

```text
token_generation
CanonicalDigestV1(<token-domain>, rawBearerToken)
```

It never contains the raw token. Persisted operation/preparation records and
FFI response objects are separate types so a `record_json` column cannot
accidentally serialize a response bearer. A process-scoped token vault allows
an exact same-process idempotent retry to return the current bearer token.
After process restart, unfinished run preparations are closed by epoch
recovery. A pending host-binding operation can be resumed by an exact
idempotency replay, which atomically rotates its token generation/digest and
returns a new bearer; the old bearer becomes stale. Stable staging receipts
remain valid because they bind `operationID` and `operationRequestDigest`, not
the rotated bearer digest.

Token validation uses constant-time digest comparison. Logs, errors, debug
archives, Codable descriptions, and FFI diagnostics must redact the bearer.

## 11. Failure behavior and invariants

- No preparation row may exist without the matching preparing/releasing lease,
  and no preparation-owned lease may exist without its preparation row.
- Renewal cannot change frozen input, source revisions, disclosure, Profile,
  frame, plan, requirements, tool schemas, binding, proposed run ID, or total
  deadline.
- A failed or expired preparation with no registered session closes and
  releases in one transaction.
- A registered session holds the lease in `releasing` until an acknowledged,
  digest-valid close receipt is committed or startup recovery closes its old
  epoch.
- External callers cannot submit `epoch_ended`.
- A Profile/Package host-binding operation cannot exist for a nonexistent or
  mismatched actual subject revision.
- A V2 Profile/Package is not runnable before both Rust cross-link commit and
  Swift binding activation are confirmed.
- Phase 1 never sends model input bytes across the bridge.
- Legacy execution behavior and single-Agent global lease behavior remain
  unchanged.

## 12. Verification strategy

Implementation follows test-first batches, each committed separately.

### 12.1 Rust authoritative preview tests

- FFI rejects every former caller-supplied digest field.
- Changing Profile, frame, tool schema, context, memory, or attachment source
  changes the Rust-derived digest.
- The frozen model-input digest equals the canonical bytes stored in the vault.
- V2 preview does not call the legacy concrete model resolver.
- Exact idempotency replay returns the same frozen preparation; a changed start
  request conflicts.

### 12.2 Repository atomicity tests

- Inject failure at every SQL statement in create/renew/abort/close/recovery and
  prove no partial lease/preparation state commits.
- Renewal changes lease expiration and preparation expiration together.
- Wrong generation, epoch, state, old token generation, or old token digest
  loses the CAS.
- Startup recovery closes all old preparations, cancels their outboxes, and
  releases the lease in one reopen transaction.

### 12.3 Cleanup tests

- Close before acknowledgement is rejected.
- Wrong command ID, sequence, registration digest, command digest,
  disposition, or receipt digest is rejected without releasing the lease.
- Duplicate exact acknowledgement/receipt succeeds; conflicting replay fails.
- Decoding an external `epoch_ended` disposition fails.

### 12.4 Commit validation tests

- Independently mutate registration, cross-link, capability claim,
  requirements, attestation expiry, disclosure field, egress digest, frozen
  input bytes, and source revisions; each mutation is rejected before run state.
- A fully valid attestation reaches only the deliberate Phase 1 non-runnable
  error and cleanup path.

### 12.5 Host-binding integration tests

- Missing Profile/Package revisions cannot open operations.
- V2 Profile visibility and Package readiness advance through the defined
  states only after exact cross-link and Swift activation.
- Failure/reopen reconciliation converges actual subject state and side tables.
- Legacy Profile publication and legacy package behavior do not change.

### 12.6 Swift SQLite and token tests

- Reopen, rollback, CAS conflict, schema migration, JSON import, corrupt import,
  and multi-row atomicity are covered.
- SQLite inspection proves bearer tokens and forbidden Provider/credential/path
  fields are absent.
- Repeated token generation produces unique 256-bit bearer values; persisted
  rows contain only registered-domain digests.
- Swift cleanup receipt parity matches Rust golden fixtures including
  registration digest, command digest, and close disposition.

### 12.7 Final gate

`scripts/run-llm-phase-1-contracts.sh` remains the final gate and is extended
to run the new architecture lints. The lints reject:

- digest-bearing Phase A request DTOs;
- preparation lifecycle code calling split lease/preparation writes;
- external `epoch_ended` decoding;
- raw bearer token columns or serialized record fields;
- JSON-document production `LLMStore`; and
- host-binding FFI paths that bypass `AgentHostBindingService`.

## 13. Finding disposition

| Finding | Design resolution |
|---|---|
| Phase A authority reversed | Sections 3–4 |
| Prepared-session cleanup bypass | Section 6 |
| Lease/preparation split transaction | Section 5 |
| Startup recovery leaves preparation records | Section 6.4 |
| Incomplete public-binding commit validation | Section 7 |
| Saga detached from Profile/Package state | Section 8 |
| Swift store is JSON rather than SQLite | Section 9 |
| Predictable bearer tokens | Section 10 |
