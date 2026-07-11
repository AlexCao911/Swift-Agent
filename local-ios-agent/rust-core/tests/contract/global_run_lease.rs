use std::sync::{Arc, Barrier};

use local_ios_agent_runtime::llm_contracts::{GlobalRunLeaseState, LLMBindingSchema};
use local_ios_agent_runtime::storage::agent_os_state::{
    GlobalRunLeaseRepository, InMemoryAgentOSStateStore, SqliteAgentOSStateStore,
};

#[test]
fn legacy_and_preparation_routes_share_one_lease() {
    let mut store = InMemoryAgentOSStateStore::new();
    let legacy = store.acquire_legacy("run-1", "epoch-1").unwrap();
    assert_eq!(legacy.state(), GlobalRunLeaseState::Active);
    assert_eq!(legacy.binding_schema(), LLMBindingSchema::LegacyV1);
    assert_eq!(legacy.owner_run_id(), Some("run-1"));

    let error = store
        .acquire_preparation("preparation-1", "epoch-1", 1_000)
        .unwrap_err();
    assert_eq!(error.code(), "execution.global_run_busy");

    let releasing = store
        .begin_release(legacy.generation(), "run-1", "epoch-1")
        .unwrap();
    assert_eq!(releasing.state(), GlobalRunLeaseState::Releasing);
    assert_eq!(
        store.acquire_legacy("run-2", "epoch-1").unwrap_err().code(),
        "execution.global_run_busy"
    );
    store
        .complete_release(legacy.generation(), "epoch-1")
        .unwrap();

    let preparation = store
        .acquire_preparation("preparation-1", "epoch-1", 1_000)
        .unwrap();
    assert!(preparation.generation() > legacy.generation());
    assert_eq!(preparation.state(), GlobalRunLeaseState::Preparing);
    assert_eq!(preparation.binding_schema(), LLMBindingSchema::HostSlotV2);
}

#[test]
fn preparation_promote_and_release_are_generation_checked_cas() {
    let mut store = InMemoryAgentOSStateStore::new();
    let preparation = store
        .acquire_preparation("preparation-1", "epoch-1", 1_000)
        .unwrap();
    let active = store
        .promote_preparation(
            preparation.generation(),
            "preparation-1",
            "run-v2-1",
            "epoch-1",
        )
        .unwrap();
    assert_eq!(active.state(), GlobalRunLeaseState::Active);
    assert_eq!(active.owner_run_id(), Some("run-v2-1"));

    assert_eq!(
        store
            .begin_release(preparation.generation() + 1, "run-v2-1", "epoch-1")
            .unwrap_err()
            .code(),
        "execution.global_run_lease_stale"
    );
    assert_eq!(store.current_global_run_lease().unwrap(), Some(active));
}

#[test]
fn old_epoch_recovery_releases_only_an_old_owner() {
    let mut store = InMemoryAgentOSStateStore::new();
    let lease = store.acquire_legacy("run-1", "epoch-old").unwrap();
    assert!(store.recover_old_epoch("epoch-old").unwrap().is_none());
    assert_eq!(
        store.current_global_run_lease().unwrap(),
        Some(lease.clone())
    );

    assert_eq!(store.recover_old_epoch("epoch-new").unwrap(), Some(lease));
    assert!(store.current_global_run_lease().unwrap().is_none());
}

#[test]
fn sqlite_concurrent_legacy_and_v2_acquisition_has_one_winner() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("agent-os.sqlite");
    SqliteAgentOSStateStore::open(&path).unwrap();
    let barrier = Arc::new(Barrier::new(3));

    let legacy_path = path.clone();
    let legacy_barrier = barrier.clone();
    let legacy = std::thread::spawn(move || {
        let mut store = SqliteAgentOSStateStore::open(legacy_path).unwrap();
        legacy_barrier.wait();
        store.acquire_legacy("run-1", "epoch-1")
    });
    let v2_path = path.clone();
    let v2_barrier = barrier.clone();
    let v2 = std::thread::spawn(move || {
        let mut store = SqliteAgentOSStateStore::open(v2_path).unwrap();
        v2_barrier.wait();
        store.acquire_preparation("preparation-1", "epoch-1", 1_000)
    });
    barrier.wait();

    let results = [legacy.join().unwrap(), v2.join().unwrap()];
    assert_eq!(results.iter().filter(|result| result.is_ok()).count(), 1);
    assert_eq!(
        results
            .iter()
            .filter_map(|result| result.as_ref().err())
            .next()
            .unwrap()
            .code(),
        "execution.global_run_busy"
    );
}
