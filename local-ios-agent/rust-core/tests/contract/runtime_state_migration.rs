use rusqlite::{params, Connection};

use local_ios_agent_runtime::storage::{
    runtime_v3_migration_statement_count, MigrationState, RuntimeStateMigrationFailurePoint,
    SqliteRuntimeStateStore,
};

#[test]
fn sidecar_migration_is_atomic_and_not_a_second_authority() {
    let directory = tempfile::tempdir().unwrap();
    let main = directory.path().join("agent.sqlite");
    let sidecar = directory.path().join("agent.sqlite.agent-os");
    seed_legacy_sidecar(&sidecar, 3);

    let store = SqliteRuntimeStateStore::open(&main).unwrap();
    assert_eq!(store.schema_version().unwrap(), 3);
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
fn populated_runtime_v2_migrates_atomically_to_complete_v3() {
    let directory = tempfile::tempdir().unwrap();
    let main = directory.path().join("agent.sqlite");
    seed_runtime_v2(&main);

    let store = SqliteRuntimeStateStore::open(&main).unwrap();

    assert_eq!(store.schema_version().unwrap(), 3);
    assert_eq!(
        store.v3_table_names().unwrap(),
        vec![
            "agent_component_revisions".to_string(),
            "agent_profile_revisions".to_string(),
            "legacy_profile_migration_records".to_string(),
        ]
    );
    let marker: String = Connection::open(&main)
        .unwrap()
        .query_row(
            "select payload from runtime_v2_test_marker where id = 1",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(marker, "preserve-me");
}

#[test]
fn every_runtime_v3_migration_boundary_rolls_back_to_v2() {
    for index in 0..runtime_v3_migration_statement_count() {
        let directory = tempfile::tempdir().unwrap();
        let main = directory.path().join("agent.sqlite");
        seed_runtime_v2(&main);

        let error = SqliteRuntimeStateStore::open_with_migration_failure(
            &main,
            RuntimeStateMigrationFailurePoint::AfterVersionThreeStatement(index),
        )
        .unwrap_err();

        assert_eq!(error.code(), "runtime_state.migration_injected_failure");
        let connection = Connection::open(&main).unwrap();
        let version: u32 = connection
            .query_row(
                "select schema_version from runtime_state_meta where singleton_id = 1",
                [],
                |row| row.get(0),
            )
            .unwrap();
        let marker: String = connection
            .query_row(
                "select payload from runtime_v2_test_marker where id = 1",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(version, 2);
        assert_eq!(marker, "preserve-me");
        for table in [
            "agent_component_revisions",
            "agent_profile_revisions",
            "legacy_profile_migration_records",
        ] {
            let exists: bool = connection
                .query_row(
                    "select exists(
                       select 1 from sqlite_master where type = 'table' and name = ?1
                     )",
                    params![table],
                    |row| row.get(0),
                )
                .unwrap();
            assert!(!exists);
        }
    }
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

fn seed_runtime_v2(path: &std::path::Path) {
    let connection = Connection::open(path).unwrap();
    connection
        .execute_batch(
            "create table runtime_state_meta (
               singleton_id integer primary key,
               schema_version integer not null,
               migration_state text not null,
               migration_source_digest text
             );
             insert into runtime_state_meta values (1, 2, 'unified_v2_active', null);
             create table runtime_v2_test_marker (
               id integer primary key,
               payload text not null
             );
             insert into runtime_v2_test_marker values (1, 'preserve-me');",
        )
        .unwrap();
}
