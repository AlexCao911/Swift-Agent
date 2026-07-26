use std::ffi::c_void;
use std::sync::{Arc, Condvar, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use crate::llm_contracts::{
    HostCommandAcknowledgement, HostCommandCopyReceipt, HostCommandKind, HostDispatchEnvelope,
    LLMEventEnvelope, LLMEventSubmissionResult,
};
use crate::storage::agent_os_state::SharedAgentOSStateStore;
use crate::storage::{runtime_now_millis, RuntimeStateError, UnifiedRuntimeStateRepository};

pub const LOCAL_AGENT_LLM_HOST_ABI_VERSION: u32 = 1;

#[repr(i32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LocalAgentLLMHostCopyReceipt {
    Copied = 0,
    Backpressure = 1,
    HostUnavailable = 2,
}

pub type LocalAgentLLMHostCommandFn =
    unsafe extern "C" fn(bytes: *const u8, length: usize, context: *mut c_void) -> i32;

pub type LocalAgentLLMHostReleaseContextFn = unsafe extern "C" fn(context: *mut c_void);

#[repr(C)]
#[derive(Clone, Copy)]
pub struct LocalAgentLLMHostVTable {
    pub abi_version: u32,
    pub submit_command: Option<LocalAgentLLMHostCommandFn>,
    pub release_context: Option<LocalAgentLLMHostReleaseContextFn>,
    pub context: *mut c_void,
}

// The context is never dereferenced by Rust and every access is serialized through
// `InstalledHost`. Swift owns its validity until `release_context` is invoked.
unsafe impl Send for LocalAgentLLMHostVTable {}
unsafe impl Sync for LocalAgentLLMHostVTable {}

#[derive(Clone, Copy, Debug)]
pub struct HostLLMDispatcherConfig {
    pub acknowledgement_timeout: Duration,
    pub redispatch_interval: Duration,
}

impl Default for HostLLMDispatcherConfig {
    fn default() -> Self {
        Self {
            acknowledgement_timeout: Duration::from_secs(10),
            redispatch_interval: Duration::from_millis(250),
        }
    }
}

impl HostLLMDispatcherConfig {
    pub fn for_tests() -> Self {
        Self {
            acknowledgement_timeout: Duration::from_secs(2),
            redispatch_interval: Duration::from_millis(25),
        }
    }
}

struct CallbackLifecycle {
    accepting: bool,
    in_flight: usize,
    released: bool,
}

struct InstalledHost {
    vtable: LocalAgentLLMHostVTable,
    lifecycle: Mutex<CallbackLifecycle>,
    condition: Condvar,
}

impl InstalledHost {
    fn new(vtable: LocalAgentLLMHostVTable) -> Result<Self, RuntimeStateError> {
        if vtable.abi_version != LOCAL_AGENT_LLM_HOST_ABI_VERSION
            || vtable.submit_command.is_none()
            || vtable.release_context.is_none()
            || vtable.context.is_null()
        {
            return Err(RuntimeStateError::new(
                "llm.host.invalid_vtable",
                "the LLM host vtable is incomplete or has an unsupported ABI version",
            ));
        }
        Ok(Self {
            vtable,
            lifecycle: Mutex::new(CallbackLifecycle {
                accepting: true,
                in_flight: 0,
                released: false,
            }),
            condition: Condvar::new(),
        })
    }

    fn submit(&self, bytes: &[u8]) -> Option<HostCommandCopyReceipt> {
        {
            let mut lifecycle = self.lifecycle.lock().ok()?;
            if !lifecycle.accepting || lifecycle.released {
                return None;
            }
            lifecycle.in_flight += 1;
        }

        // SAFETY: the validated vtable remains retained by this `InstalledHost`, and
        // the in-flight guard prevents context release until this call returns.
        let callback = self.vtable.submit_command?;
        let receipt = unsafe { callback(bytes.as_ptr(), bytes.len(), self.vtable.context) };

        let mut lifecycle = self
            .lifecycle
            .lock()
            .unwrap_or_else(|value| value.into_inner());
        lifecycle.in_flight -= 1;
        if lifecycle.in_flight == 0 {
            self.condition.notify_all();
        }
        Some(match receipt {
            0 => HostCommandCopyReceipt::Copied,
            1 => HostCommandCopyReceipt::Backpressure,
            _ => HostCommandCopyReceipt::HostUnavailable,
        })
    }

    fn quiesce_and_release(&self) {
        let mut lifecycle = self
            .lifecycle
            .lock()
            .unwrap_or_else(|value| value.into_inner());
        lifecycle.accepting = false;
        while lifecycle.in_flight != 0 {
            lifecycle = self
                .condition
                .wait(lifecycle)
                .unwrap_or_else(|value| value.into_inner());
        }
        if lifecycle.released {
            return;
        }
        lifecycle.released = true;
        drop(lifecycle);
        // SAFETY: release is invoked exactly once, after new intake is stopped and all
        // callback invocations have returned.
        if let Some(release) = self.vtable.release_context {
            unsafe { release(self.vtable.context) };
        }
    }
}

struct DispatcherControl {
    stopped: bool,
    suspended: bool,
    wake_generation: u64,
    installed: Option<Arc<InstalledHost>>,
}

struct DispatcherShared {
    repository: Arc<dyn UnifiedRuntimeStateRepository>,
    preparation_store: Option<SharedAgentOSStateStore>,
    config: HostLLMDispatcherConfig,
    control: Mutex<DispatcherControl>,
    condition: Condvar,
    drive_serial: Mutex<()>,
}

pub struct HostLLMDispatcherRuntime {
    shared: Arc<DispatcherShared>,
    scheduler: Mutex<Option<JoinHandle<()>>>,
}

impl HostLLMDispatcherRuntime {
    pub fn new(
        repository: Arc<dyn UnifiedRuntimeStateRepository>,
        config: HostLLMDispatcherConfig,
    ) -> Self {
        Self::new_with_preparations(repository, None, config)
    }

    pub fn new_with_preparations(
        repository: Arc<dyn UnifiedRuntimeStateRepository>,
        preparation_store: Option<SharedAgentOSStateStore>,
        config: HostLLMDispatcherConfig,
    ) -> Self {
        let shared = Arc::new(DispatcherShared {
            repository,
            preparation_store,
            config,
            control: Mutex::new(DispatcherControl {
                stopped: false,
                suspended: false,
                wake_generation: 0,
                installed: None,
            }),
            condition: Condvar::new(),
            drive_serial: Mutex::new(()),
        });
        let scheduler_shared = shared.clone();
        let scheduler = thread::Builder::new()
            .name("host-llm-dispatcher".into())
            .spawn(move || scheduler_loop(scheduler_shared))
            .ok();
        Self {
            shared,
            scheduler: Mutex::new(scheduler),
        }
    }

    pub fn install(&self, vtable: LocalAgentLLMHostVTable) -> Result<(), RuntimeStateError> {
        if self.scheduler.lock().map_err(|_| poisoned())?.is_none() {
            return Err(RuntimeStateError::new(
                "llm.host.scheduler_unavailable",
                "the LLM host dispatcher scheduler could not be started",
            ));
        }
        let host = Arc::new(InstalledHost::new(vtable)?);
        let mut control = self.shared.control.lock().map_err(|_| poisoned())?;
        if control.stopped {
            return Err(RuntimeStateError::new(
                "llm.host.stopped",
                "the LLM host dispatcher is stopped",
            ));
        }
        if control.installed.is_some() {
            return Err(RuntimeStateError::new(
                "llm.host.already_installed",
                "an LLM host is already installed",
            ));
        }
        control.installed = Some(host);
        control.wake_generation = control.wake_generation.wrapping_add(1);
        self.shared.condition.notify_all();
        Ok(())
    }

    pub fn uninstall(&self) -> Result<(), RuntimeStateError> {
        let host = {
            let mut control = self.shared.control.lock().map_err(|_| poisoned())?;
            let host = control.installed.take().ok_or_else(|| {
                RuntimeStateError::new("llm.host.not_installed", "no LLM host is installed")
            })?;
            control.wake_generation = control.wake_generation.wrapping_add(1);
            self.shared.condition.notify_all();
            host
        };
        host.quiesce_and_release();
        Ok(())
    }

    pub fn suspend(&self) -> Result<(), RuntimeStateError> {
        let mut control = self.shared.control.lock().map_err(|_| poisoned())?;
        control.suspended = true;
        control.wake_generation = control.wake_generation.wrapping_add(1);
        self.shared.condition.notify_all();
        Ok(())
    }

    pub fn resume(&self) -> Result<(), RuntimeStateError> {
        let mut control = self.shared.control.lock().map_err(|_| poisoned())?;
        control.suspended = false;
        control.wake_generation = control.wake_generation.wrapping_add(1);
        self.shared.condition.notify_all();
        Ok(())
    }

    pub fn wake(&self) {
        if let Ok(mut control) = self.shared.control.lock() {
            control.wake_generation = control.wake_generation.wrapping_add(1);
            self.shared.condition.notify_all();
        }
    }

    pub fn drive_once(&self) -> Result<(), RuntimeStateError> {
        drive_once(&self.shared)
    }

    pub fn acknowledge_command(
        &self,
        acknowledgement: &HostCommandAcknowledgement,
    ) -> Result<crate::storage::HostCommandOutboxRow, RuntimeStateError> {
        let row = self
            .shared
            .repository
            .acknowledge_command(acknowledgement)?;
        self.wake();
        Ok(row)
    }

    pub fn submit_event(
        &self,
        event: &LLMEventEnvelope,
    ) -> Result<LLMEventSubmissionResult, RuntimeStateError> {
        let result =
            super::HostLLMWorkerService::new(self.shared.repository.clone()).submit_event(event)?;
        self.wake();
        Ok(result)
    }
}

impl Drop for HostLLMDispatcherRuntime {
    fn drop(&mut self) {
        let installed = {
            let mut control = self
                .shared
                .control
                .lock()
                .unwrap_or_else(|value| value.into_inner());
            control.stopped = true;
            control.wake_generation = control.wake_generation.wrapping_add(1);
            let installed = control.installed.take();
            self.shared.condition.notify_all();
            installed
        };
        if let Some(scheduler) = self
            .scheduler
            .lock()
            .unwrap_or_else(|value| value.into_inner())
            .take()
        {
            let _ = scheduler.join();
        }
        if let Some(installed) = installed {
            installed.quiesce_and_release();
        }
    }
}

fn scheduler_loop(shared: Arc<DispatcherShared>) {
    loop {
        let control = shared
            .control
            .lock()
            .unwrap_or_else(|value| value.into_inner());
        if control.stopped {
            return;
        }
        let generation = control.wake_generation;
        let wait = shared
            .config
            .redispatch_interval
            .max(Duration::from_millis(1));
        let (control, _) = shared
            .condition
            .wait_timeout_while(control, wait, |state| {
                !state.stopped && state.wake_generation == generation
            })
            .unwrap_or_else(|value| value.into_inner());
        if control.stopped {
            return;
        }
        drop(control);
        let _ = drive_once(&shared);
    }
}

fn drive_once(shared: &DispatcherShared) -> Result<(), RuntimeStateError> {
    let _serial = shared.drive_serial.lock().map_err(|_| poisoned())?;
    let (host, suspended) = {
        let control = shared.control.lock().map_err(|_| poisoned())?;
        if control.stopped {
            return Ok(());
        }
        (control.installed.clone(), control.suspended)
    };
    let Some(host) = host else {
        return Ok(());
    };

    // This returns owned rows, so no repository mutex or SQLite transaction remains
    // held while Swift receives immutable bytes.
    let rows = shared.repository.pending_host_commands()?;
    for row in rows {
        let now = runtime_now_millis();
        if row.is_acknowledgement_overdue(now) {
            let _ = shared
                .repository
                .fail_command_acknowledgement_timeout(row.command_id());
            continue;
        }
        if !row.is_dispatch_due(now) {
            continue;
        }
        let Some(command) = row.payload().cloned() else {
            continue;
        };
        if suspended
            && matches!(
                command.kind(),
                HostCommandKind::StartGeneration | HostCommandKind::ResumeGeneration
            )
        {
            continue;
        }
        let bytes =
            serde_json::to_vec(&HostDispatchEnvelope::command(command)).map_err(|error| {
                RuntimeStateError::new("llm.host.dispatch_encoding_failed", error.to_string())
            })?;
        let Some(receipt) = host.submit(&bytes) else {
            continue;
        };
        shared.repository.record_copy_receipt_at(
            row.command_id(),
            receipt,
            runtime_now_millis(),
            shared.config.acknowledgement_timeout,
            shared.config.redispatch_interval,
        )?;
    }

    if let Some(preparation_store) = &shared.preparation_store {
        let cleanups = preparation_store
            .with_preparation(|repository| repository.list_run_preparations())
            .map_err(|error| {
                RuntimeStateError::new("llm.host.preparation_query_failed", error.to_string())
            })?
            .into_iter()
            .filter(|record| record.cleanup_acknowledgement().is_none())
            .filter_map(|record| record.cleanup().cloned())
            .collect::<Vec<_>>();
        for cleanup in cleanups {
            let bytes =
                serde_json::to_vec(&HostDispatchEnvelope::prepared_session_cleanup(cleanup))
                    .map_err(|error| {
                        RuntimeStateError::new(
                            "llm.host.dispatch_encoding_failed",
                            error.to_string(),
                        )
                    })?;
            let _ = host.submit(&bytes);
        }
    }
    Ok(())
}

fn poisoned() -> RuntimeStateError {
    RuntimeStateError::new(
        "llm.host.lock_poisoned",
        "host dispatcher lock was poisoned",
    )
}
