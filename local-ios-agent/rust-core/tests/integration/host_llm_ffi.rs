use std::ffi::c_void;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use local_ios_agent_runtime::execution::{
    HostLLMDispatcherConfig, HostLLMDispatcherRuntime, LocalAgentLLMHostCopyReceipt,
    LocalAgentLLMHostVTable,
};
use local_ios_agent_runtime::ffi_bridge::{
    local_agent_runtime_bridge_drive_llm_host, local_agent_runtime_bridge_free,
    local_agent_runtime_bridge_install_llm_host, local_agent_runtime_bridge_new_with_config,
    local_agent_runtime_bridge_resume_llm_host, local_agent_runtime_bridge_suspend_llm_host,
    local_agent_runtime_bridge_uninstall_llm_host,
};
use local_ios_agent_runtime::llm_contracts::{
    HostCommandAcknowledgement, HostCommandAcknowledgementDisposition, HostCommandCopyReceipt,
    HostCommandEnvelope, HostCommandKind, HostExecutionPhase, HostSessionRecord, HostWorkerRecord,
    LogicalRunOutcome, ResourceLifecycle,
};
use local_ios_agent_runtime::storage::{
    HostCommandOutboxStatus, InMemoryRuntimeStateStore, RuntimeTransition, SqliteRuntimeStateStore,
    UnifiedRuntimeStateRepository,
};
use serde::de::DeserializeOwned;
use serde_json::Value;
use std::ffi::CString;

const EPOCH: &str = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";

#[test]
fn dispatcher_never_calls_host_while_repository_is_locked() {
    let store = InMemoryRuntimeStateStore::new();
    enqueue_start(&store);
    let probe = Box::new(HostProbe::new(store.clone()));
    let probe_ptr = Box::into_raw(probe);
    let dispatcher =
        HostLLMDispatcherRuntime::new(Arc::new(store), HostLLMDispatcherConfig::for_tests());
    dispatcher.install(vtable(probe_ptr)).unwrap();

    dispatcher.drive_once().unwrap();

    let probe = unsafe { &*probe_ptr };
    assert!(probe.repository_reentry_succeeded.load(Ordering::SeqCst));
    assert_eq!(probe.copied_bytes.lock().unwrap().len(), 1);
    dispatcher.uninstall().unwrap();
}

#[test]
fn copied_unacknowledged_command_redispatches_identical_bytes_after_reopen() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("agent.sqlite");
    let first_store = SqliteRuntimeStateStore::open(&path).unwrap();
    enqueue_start(&first_store);
    let first_probe = Box::into_raw(Box::new(HostProbe::new(first_store.clone())));
    let first = HostLLMDispatcherRuntime::new(
        Arc::new(first_store.clone()),
        HostLLMDispatcherConfig::for_tests(),
    );
    first.install(vtable(first_probe)).unwrap();
    first.drive_once().unwrap();
    let first_bytes = unsafe { &*first_probe }.copied_bytes.lock().unwrap()[0].clone();
    first.uninstall().unwrap();
    drop(first);
    drop(first_store);

    let reopened = SqliteRuntimeStateStore::open(&path).unwrap();
    let second_probe = Box::into_raw(Box::new(HostProbe::new(reopened.clone())));
    let second =
        HostLLMDispatcherRuntime::new(Arc::new(reopened), HostLLMDispatcherConfig::for_tests());
    second.install(vtable(second_probe)).unwrap();
    std::thread::sleep(Duration::from_millis(30));
    second.drive_once().unwrap();
    let second_bytes = unsafe { &*second_probe }.copied_bytes.lock().unwrap()[0].clone();

    assert_eq!(second_bytes, first_bytes);
    let first_wire: Value = serde_json::from_slice(&first_bytes).unwrap();
    let second_wire: Value = serde_json::from_slice(&second_bytes).unwrap();
    assert_eq!(
        first_wire["command"]["command_id"],
        second_wire["command"]["command_id"]
    );
    assert_eq!(
        first_wire["command"]["command_sequence"],
        second_wire["command"]["command_sequence"]
    );
    second.uninstall().unwrap();
}

#[test]
fn acknowledgement_timeout_fires_without_followup_ffi_call() {
    let store = InMemoryRuntimeStateStore::new();
    enqueue_start(&store);
    let probe = Box::into_raw(Box::new(HostProbe::new(store.clone())));
    let dispatcher = HostLLMDispatcherRuntime::new(
        Arc::new(store.clone()),
        HostLLMDispatcherConfig {
            acknowledgement_timeout: Duration::from_millis(40),
            redispatch_interval: Duration::from_millis(10),
        },
    );
    dispatcher.install(vtable(probe)).unwrap();

    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        let worker = store.host_worker("run-1").unwrap().unwrap();
        if matches!(
            worker.logical_outcome(),
            LogicalRunOutcome::Failed { code } if code == "llm.command.ack_timeout"
        ) {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "scheduler did not fire acknowledgement timeout"
        );
        std::thread::sleep(Duration::from_millis(5));
    }
    let pending = store.pending_host_commands().unwrap();
    assert!(pending.iter().any(|row| {
        row.payload()
            .is_some_and(|command| command.kind() == HostCommandKind::CloseSession)
    }));
    dispatcher.uninstall().unwrap();
}

#[test]
fn rejected_start_ack_fails_logical_run_and_atomically_schedules_close() {
    let store = InMemoryRuntimeStateStore::new();
    enqueue_start(&store);
    let command: HostCommandEnvelope = wire_fixture("host-command-envelope-v1.json");

    let acknowledgement = HostCommandAcknowledgement {
        command_id: command.command_id().into(),
        session_handle: command.session_handle().into(),
        command_sequence: command.command_sequence(),
        command_envelope_digest: command.command_envelope_digest().into(),
        disposition: HostCommandAcknowledgementDisposition::Rejected,
        rejection_code: Some("host.start_rejected".into()),
    };
    store.acknowledge_command(&acknowledgement).unwrap();
    store.acknowledge_command(&acknowledgement).unwrap();
    let row = store
        .record_copy_receipt(command.command_id(), HostCommandCopyReceipt::Copied)
        .unwrap();
    assert_eq!(row.status(), HostCommandOutboxStatus::Rejected);

    let worker = store.host_worker("run-1").unwrap().unwrap();
    assert!(matches!(
        worker.logical_outcome(),
        LogicalRunOutcome::Failed { code } if code == "host.start_rejected"
    ));
    assert_eq!(
        worker.resource_lifecycle(),
        &ResourceLifecycle::AwaitingCloseCommandAck
    );
    let pending = store.pending_host_commands().unwrap();
    assert_eq!(pending.len(), 1);
    assert_eq!(
        pending[0].payload().unwrap().kind(),
        HostCommandKind::CloseSession
    );
    assert_eq!(pending[0].command_sequence(), 2);
}

#[test]
fn sqlite_duplicate_ack_and_late_copy_receipt_cannot_reopen_terminal_command() {
    let store = SqliteRuntimeStateStore::open_in_memory().unwrap();
    enqueue_start(&store);
    let command: HostCommandEnvelope = wire_fixture("host-command-envelope-v1.json");
    let acknowledgement = HostCommandAcknowledgement {
        command_id: command.command_id().into(),
        session_handle: command.session_handle().into(),
        command_sequence: command.command_sequence(),
        command_envelope_digest: command.command_envelope_digest().into(),
        disposition: HostCommandAcknowledgementDisposition::Accepted,
        rejection_code: None,
    };

    store.acknowledge_command(&acknowledgement).unwrap();
    store.acknowledge_command(&acknowledgement).unwrap();
    let row = store
        .record_copy_receipt(command.command_id(), HostCommandCopyReceipt::Copied)
        .unwrap();

    assert_eq!(row.status(), HostCommandOutboxStatus::Accepted);
    assert!(row.payload().is_none());
    assert!(store.pending_host_commands().unwrap().is_empty());
}

#[test]
fn suspend_blocks_backend_start_until_resume() {
    let store = InMemoryRuntimeStateStore::new();
    enqueue_start(&store);
    let probe = Box::into_raw(Box::new(HostProbe::new(store.clone())));
    let dispatcher =
        HostLLMDispatcherRuntime::new(Arc::new(store), HostLLMDispatcherConfig::for_tests());
    dispatcher.install(vtable(probe)).unwrap();
    dispatcher.suspend().unwrap();
    dispatcher.drive_once().unwrap();
    assert!(unsafe { &*probe }.copied_bytes.lock().unwrap().is_empty());

    dispatcher.resume().unwrap();
    dispatcher.drive_once().unwrap();
    assert_eq!(unsafe { &*probe }.copied_bytes.lock().unwrap().len(), 1);
    dispatcher.uninstall().unwrap();
}

#[test]
fn dispatcher_drop_waits_for_blocked_callback_before_releasing_context() {
    let store = InMemoryRuntimeStateStore::new();
    enqueue_start(&store);
    let probe = Box::into_raw(Box::new(HostProbe::blocking(store.clone())));
    let dispatcher =
        HostLLMDispatcherRuntime::new(Arc::new(store), HostLLMDispatcherConfig::for_tests());
    dispatcher.install(vtable(probe)).unwrap();
    dispatcher.wake();
    unsafe { &*probe }.wait_until_entered();

    let finished = Arc::new(AtomicBool::new(false));
    let finished_on_drop = finished.clone();
    let drop_thread = std::thread::spawn(move || {
        drop(dispatcher);
        finished_on_drop.store(true, Ordering::SeqCst);
    });
    std::thread::sleep(Duration::from_millis(20));
    assert!(!finished.load(Ordering::SeqCst));
    assert_eq!(unsafe { &*probe }.release_count.load(Ordering::SeqCst), 0);

    unsafe { &*probe }.release_blocked_callback();
    drop_thread.join().unwrap();
    assert!(finished.load(Ordering::SeqCst));
}

#[test]
fn c_abi_install_uninstall_reinstall_and_runtime_free_release_each_context_once() {
    let config = CString::new(
        r#"{
          "system_prompt":"system",
          "runtime_policy":"policy",
          "provider_id":"mock",
          "host_process_epoch":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
          "store":{"kind":"in_memory"}
        }"#,
    )
    .unwrap();
    let runtime = unsafe { local_agent_runtime_bridge_new_with_config(config.as_ptr()) };
    assert!(!runtime.is_null());

    let first = Box::into_raw(Box::new(HostProbe::new(InMemoryRuntimeStateStore::new())));
    let first_vtable = vtable(first);
    assert_eq!(
        unsafe { local_agent_runtime_bridge_install_llm_host(runtime, &first_vtable) },
        0
    );
    assert_eq!(
        unsafe { local_agent_runtime_bridge_install_llm_host(runtime, &first_vtable) },
        -1
    );
    assert_eq!(
        unsafe { local_agent_runtime_bridge_suspend_llm_host(runtime) },
        0
    );
    assert_eq!(
        unsafe { local_agent_runtime_bridge_drive_llm_host(runtime) },
        0
    );
    assert_eq!(
        unsafe { local_agent_runtime_bridge_resume_llm_host(runtime) },
        0
    );
    assert_eq!(
        unsafe { local_agent_runtime_bridge_uninstall_llm_host(runtime) },
        0
    );
    assert_eq!(unsafe { &*first }.release_count.load(Ordering::SeqCst), 1);

    let second = Box::into_raw(Box::new(HostProbe::new(InMemoryRuntimeStateStore::new())));
    let second_vtable = vtable(second);
    assert_eq!(
        unsafe { local_agent_runtime_bridge_install_llm_host(runtime, &second_vtable) },
        0
    );
    unsafe { local_agent_runtime_bridge_free(runtime) };
    assert_eq!(unsafe { &*second }.release_count.load(Ordering::SeqCst), 1);
}

struct HostProbe {
    repository: Arc<dyn UnifiedRuntimeStateRepository>,
    copied_bytes: Mutex<Vec<Vec<u8>>>,
    repository_reentry_succeeded: AtomicBool,
    release_count: AtomicUsize,
    block: AtomicBool,
    entered: (Mutex<bool>, Condvar),
    release: (Mutex<bool>, Condvar),
}

impl HostProbe {
    fn new(repository: impl UnifiedRuntimeStateRepository) -> Self {
        Self {
            repository: Arc::new(repository),
            copied_bytes: Mutex::new(Vec::new()),
            repository_reentry_succeeded: AtomicBool::new(false),
            release_count: AtomicUsize::new(0),
            block: AtomicBool::new(false),
            entered: (Mutex::new(false), Condvar::new()),
            release: (Mutex::new(false), Condvar::new()),
        }
    }

    fn blocking(repository: impl UnifiedRuntimeStateRepository) -> Self {
        let value = Self::new(repository);
        value.block.store(true, Ordering::SeqCst);
        value
    }

    fn wait_until_entered(&self) {
        let (lock, condition) = &self.entered;
        let mut entered = lock.lock().unwrap();
        while !*entered {
            entered = condition.wait(entered).unwrap();
        }
    }

    fn release_blocked_callback(&self) {
        let (lock, condition) = &self.release;
        *lock.lock().unwrap() = true;
        condition.notify_all();
    }
}

unsafe extern "C" fn submit_command(bytes: *const u8, length: usize, context: *mut c_void) -> i32 {
    let probe = &*(context as *const HostProbe);
    probe
        .copied_bytes
        .lock()
        .unwrap()
        .push(std::slice::from_raw_parts(bytes, length).to_vec());
    probe.repository_reentry_succeeded.store(
        probe.repository.pending_host_commands().is_ok(),
        Ordering::SeqCst,
    );
    if probe.block.load(Ordering::SeqCst) {
        let (entered_lock, entered_condition) = &probe.entered;
        *entered_lock.lock().unwrap() = true;
        entered_condition.notify_all();
        let (release_lock, release_condition) = &probe.release;
        let mut released = release_lock.lock().unwrap();
        while !*released {
            released = release_condition.wait(released).unwrap();
        }
    }
    LocalAgentLLMHostCopyReceipt::Copied as i32
}

unsafe extern "C" fn release_context(context: *mut c_void) {
    let probe = Box::from_raw(context as *mut HostProbe);
    probe.release_count.fetch_add(1, Ordering::SeqCst);
    // Keep the probe allocated for assertions made through its stable test pointer.
    let _ = Box::into_raw(probe);
}

fn vtable(probe: *mut HostProbe) -> LocalAgentLLMHostVTable {
    LocalAgentLLMHostVTable {
        abi_version: 1,
        submit_command: Some(submit_command),
        release_context: Some(release_context),
        context: probe.cast(),
    }
}

fn enqueue_start(store: &impl UnifiedRuntimeStateRepository) {
    let worker = HostWorkerRecord::new("run-1", "session-1", EPOCH)
        .with_execution_phase(Some(HostExecutionPhase::AwaitingStartCommandAck));
    let session = HostSessionRecord::new(
        "run-1",
        "session-1",
        EPOCH,
        "binding-1",
        1,
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    );
    store
        .insert_worker_and_session(worker.clone(), session)
        .unwrap();
    let command: HostCommandEnvelope = wire_fixture("host-command-envelope-v1.json");
    store
        .transition_and_enqueue(RuntimeTransition::new(
            worker.revision(),
            worker
                .with_revision(1)
                .with_execution_phase(Some(HostExecutionPhase::AwaitingStartCommandAck)),
            command,
        ))
        .unwrap();
}

fn wire_fixture<T: DeserializeOwned>(name: &str) -> T {
    let value: Value =
        serde_json::from_slice(&fs::read(contracts_root().join(name)).unwrap()).unwrap();
    serde_json::from_value(value["wire"].clone()).unwrap()
}

fn contracts_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("contracts/canonical-digest-v1/fixtures")
}
