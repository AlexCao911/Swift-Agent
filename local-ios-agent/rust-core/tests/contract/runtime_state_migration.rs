use rusqlite::{params, Connection};

use local_ios_agent_runtime::storage::{
    MigrationState, RuntimeStateMigrationFailurePoint, SqliteRuntimeStateStore,
};

#[test]
fn sidecar_migration_is_atomic_and_not_a_second_authority() {
    let directory = tempfile::tempdir().unwrap();
    let main = directory.path().join("agent.sqlite");
    let sidecar = directory.path().join("agent.sqlite.agent-os");
    seed_legacy_sidecar(&sidecar, 3);

    let store = SqliteRuntimeStateStore::open(&main).unwrap();
    assert_eq!(store.schema_version().unwrap(), 2);
    assert_eq!(
        store.migration_state().unwrap(),
        MigrationState::UnifiedV2Active
    );
    assert_eq!(store.global_lease_generation().unwrap(), Some(3));
    assert!(store.migration_source_digest().unwrap().is_some());
    drop(store);

    Connection::open(&sidecar)
        .unwrap()
        .execute(
            "update global_run_lease set lease_generation = 99 where singleton_id = 1",
            [],
        )
        .unwrap();
    let reopened = SqliteRuntimeStateStore::open(&main).unwrap();
    assert_eq!(reopened.global_lease_generation().unwrap(), Some(3));
}

#[test]
fn failed_sidecar_migration_rolls_back_and_clean_retry_imports_once() {
    let directory = tempfile::tempdir().unwrap();
    let main = directory.path().join("agent.sqlite");
    let sidecar = directory.path().join("agent.sqlite.agent-os");
    seed_legacy_sidecar(&sidecar, 7);

    let error = SqliteRuntimeStateStore::open_with_migration_failure(
        &main,
        RuntimeStateMigrationFailurePoint::AfterLegacyCopy,
    )
    .unwrap_err();
    assert_eq!(error.code(), "runtime_state.migration_injected_failure");

    let store = SqliteRuntimeStateStore::open(&main).unwrap();
    assert_eq!(store.global_lease_generation().unwrap(), Some(7));
    assert_eq!(
        store.migration_state().unwrap(),
        MigrationState::UnifiedV2Active
    );
}

#[test]
fn future_runtime_schema_is_rejected() {
    let directory = tempfile::tempdir().unwrap();
    let main = directory.path().join("agent.sqlite");
    let connection = Connection::open(&main).unwrap();
    connection
        .execute_batch(
            "create table runtime_state_meta (
               singleton_id integer primary key,
               schema_version integer not null,
               migration_state text not null,
               migration_source_digest text
             );
             insert into runtime_state_meta values (1, 99, 'unified_v2_active', null);",
        )
        .unwrap();
    drop(connection);

    let error = SqliteRuntimeStateStore::open(&main).unwrap_err();
    assert_eq!(error.code(), "runtime_state.schema_future");
}

#[test]
fn invalid_sidecar_rows_fail_before_activation() {
    let directory = tempfile::tempdir().unwrap();
    let main = directory.path().join("agent.sqlite");
    let sidecar = directory.path().join("agent.sqlite.agent-os");
    seed_legacy_sidecar(&sidecar, 3);
    Connection::open(&sidecar)
        .unwrap()
        .execute(
            "update global_run_lease set binding_schema = 'provider_specific' where singleton_id = 1",
            [],
        )
        .unwrap();

    let error = SqliteRuntimeStateStore::open(&main).unwrap_err();
    assert_eq!(error.code(), "runtime_state.legacy_row_invalid");
    let state: String = Connection::open(&main)
        .unwrap()
        .query_row(
            "select migration_state from runtime_state_meta where singleton_id = 1",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(state, "pending");
}

#[test]
fn agent_os_view_writes_through_the_unified_main_database() {
    let directory = tempfile::tempdir().unwrap();
    let main = directory.path().join("agent.sqlite");
    let sidecar = directory.path().join("agent.sqlite.agent-os");
    let store = SqliteRuntimeStateStore::open(&main).unwrap();
    let state = store.agent_os_state();
    let lease = state
        .with_mut(|repository| {
            repository.acquire_preparation(
                "preparation-1",
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                300_000,
            )
        })
        .unwrap();

    assert_eq!(
        store.global_lease_generation().unwrap(),
        Some(lease.generation())
    );
    assert!(!sidecar.exists());
}

fn seed_legacy_sidecar(path: &std::path::Path, generation: u64) {
    let connection = Connection::open(path).unwrap();
    connection
        .execute_batch(
            "create table agent_os_schema_meta (
               singleton_id integer primary key,
               schema_version integer not null,
               last_lease_generation integer not null default 0
             );
             create table global_run_lease (
               singleton_id integer primary key,
               lease_generation integer not null,
               owner_run_id text,
               preparation_id text,
               binding_schema text not null,
               host_process_epoch text not null,
               state text not null,
               preparation_expiration text
             );",
        )
        .unwrap();
    connection
        .execute(
            "insert into agent_os_schema_meta values (1, 1, ?1)",
            params![generation],
        )
        .unwrap();
    connection
        .execute(
            "insert into global_run_lease values (1, ?1, null, 'prep-1', 'host_slot_v2', ?2, 'preparing', '300000')",
            params![generation, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"],
        )
        .unwrap();
}
