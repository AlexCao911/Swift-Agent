use std::ffi::{c_char, c_void, CStr, CString};
use std::ptr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use serde_json::Value;

use crate::context::PromptFrame;
use crate::core::{
    build_openai_chat_request, AgentError, CancellationToken, ModelProvider, ModelProviderOutput,
};

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LocalAgentStatus {
    Ok = 0,
    Error = 1,
    Cancelled = 2,
    InvalidArgument = 3,
}

#[repr(C)]
pub struct CAbiLocalAgentBackend {
    _private: [u8; 0],
}

#[repr(C)]
pub struct CAbiLocalAgentBackendStream {
    _private: [u8; 0],
}

pub type CAbiTokenCallback = unsafe extern "C" fn(*const c_char, *mut c_void) -> LocalAgentStatus;

pub type CAbiInitFn = unsafe extern "C" fn(*mut *mut CAbiLocalAgentBackend) -> LocalAgentStatus;
pub type CAbiLoadModelFn =
    unsafe extern "C" fn(*mut CAbiLocalAgentBackend, *const c_char) -> LocalAgentStatus;
pub type CAbiStartChatFn = unsafe extern "C" fn(
    *mut CAbiLocalAgentBackend,
    *const c_char,
    *mut *mut CAbiLocalAgentBackendStream,
) -> LocalAgentStatus;
pub type CAbiReadStreamFn = unsafe extern "C" fn(
    *mut CAbiLocalAgentBackendStream,
    CAbiTokenCallback,
    *mut c_void,
) -> LocalAgentStatus;
pub type CAbiCancelFn = unsafe extern "C" fn(*mut CAbiLocalAgentBackendStream) -> LocalAgentStatus;
pub type CAbiReleaseStreamFn =
    unsafe extern "C" fn(*mut CAbiLocalAgentBackendStream) -> LocalAgentStatus;
pub type CAbiReleaseBackendFn =
    unsafe extern "C" fn(*mut CAbiLocalAgentBackend) -> LocalAgentStatus;

#[derive(Clone, Copy)]
pub struct CAbiFunctions {
    pub init: CAbiInitFn,
    pub load_model: CAbiLoadModelFn,
    pub start_chat: CAbiStartChatFn,
    pub read_stream: CAbiReadStreamFn,
    pub cancel: CAbiCancelFn,
    pub release_stream: CAbiReleaseStreamFn,
    pub release_backend: CAbiReleaseBackendFn,
}

pub trait LocalInferenceBackend: Send + Sync {
    fn load_model(&self, model_config_json: &str) -> Result<(), AgentError>;
    fn stream_chat(
        &self,
        prompt_json: &str,
        cancellation: CancellationToken,
        on_token: &mut dyn FnMut(&str) -> Result<(), AgentError>,
    ) -> Result<(), AgentError>;
}

pub struct MockLocalInferenceBackend {
    tokens: Vec<String>,
    loaded: Mutex<bool>,
}

pub struct CAbiLocalInferenceBackend {
    functions: CAbiFunctions,
    backend: Mutex<CAbiBackendHandle>,
}

pub struct LocalLLMProvider {
    model: String,
    model_config_json: String,
    backend: Box<dyn LocalInferenceBackend>,
    model_loaded: Mutex<bool>,
}

#[derive(Clone, Copy)]
struct CAbiBackendHandle(*mut CAbiLocalAgentBackend);

unsafe impl Send for CAbiBackendHandle {}

#[derive(Clone, Copy)]
struct CAbiStreamHandle(*mut CAbiLocalAgentBackendStream);

unsafe impl Send for CAbiStreamHandle {}

impl CAbiStreamHandle {
    fn as_ptr(self) -> *mut CAbiLocalAgentBackendStream {
        self.0
    }
}

struct CallbackState<'a> {
    on_token: &'a mut dyn FnMut(&str) -> Result<(), AgentError>,
    cancellation: CancellationToken,
    stream: *mut CAbiLocalAgentBackendStream,
    cancel: CAbiCancelFn,
    error: &'a mut Option<AgentError>,
}

#[cfg(feature = "link-mock-local-inference")]
extern "C" {
    fn local_agent_backend_init(out_backend: *mut *mut CAbiLocalAgentBackend) -> LocalAgentStatus;
    fn local_agent_backend_load_model(
        backend: *mut CAbiLocalAgentBackend,
        model_config_json: *const c_char,
    ) -> LocalAgentStatus;
    fn local_agent_backend_start_chat(
        backend: *mut CAbiLocalAgentBackend,
        prompt_json: *const c_char,
        out_stream: *mut *mut CAbiLocalAgentBackendStream,
    ) -> LocalAgentStatus;
    fn local_agent_backend_read_stream(
        stream: *mut CAbiLocalAgentBackendStream,
        callback: CAbiTokenCallback,
        user_data: *mut c_void,
    ) -> LocalAgentStatus;
    fn local_agent_backend_cancel(stream: *mut CAbiLocalAgentBackendStream) -> LocalAgentStatus;
    fn local_agent_backend_release_stream(
        stream: *mut CAbiLocalAgentBackendStream,
    ) -> LocalAgentStatus;
    fn local_agent_backend_release(backend: *mut CAbiLocalAgentBackend) -> LocalAgentStatus;
}

impl CAbiFunctions {
    #[cfg(feature = "link-mock-local-inference")]
    pub fn linked() -> Self {
        Self {
            init: local_agent_backend_init,
            load_model: local_agent_backend_load_model,
            start_chat: local_agent_backend_start_chat,
            read_stream: local_agent_backend_read_stream,
            cancel: local_agent_backend_cancel,
            release_stream: local_agent_backend_release_stream,
            release_backend: local_agent_backend_release,
        }
    }
}

impl MockLocalInferenceBackend {
    pub fn new<I, S>(tokens: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        Self {
            tokens: tokens.into_iter().map(Into::into).collect(),
            loaded: Mutex::new(false),
        }
    }
}

impl LocalInferenceBackend for MockLocalInferenceBackend {
    fn load_model(&self, model_config_json: &str) -> Result<(), AgentError> {
        if model_config_json.is_empty() {
            return Err(AgentError::Provider(
                "on-device model config must not be empty".into(),
            ));
        }

        *self.loaded.lock().unwrap() = true;
        Ok(())
    }

    fn stream_chat(
        &self,
        prompt_json: &str,
        cancellation: CancellationToken,
        on_token: &mut dyn FnMut(&str) -> Result<(), AgentError>,
    ) -> Result<(), AgentError> {
        if prompt_json.is_empty() {
            return Err(AgentError::Provider(
                "on-device prompt JSON must not be empty".into(),
            ));
        }
        if !*self.loaded.lock().unwrap() {
            return Err(AgentError::Provider("on-device model is not loaded".into()));
        }

        for token in &self.tokens {
            if cancellation.is_cancelled() {
                return Err(AgentError::Cancelled("on-device backend cancelled".into()));
            }

            on_token(token)?;

            if cancellation.is_cancelled() {
                return Err(AgentError::Cancelled("on-device backend cancelled".into()));
            }
        }
        Ok(())
    }
}

impl CAbiLocalInferenceBackend {
    pub fn new() -> Result<Self, AgentError> {
        let functions = linked_c_abi_functions()?;
        unsafe { Self::with_functions(functions) }
    }

    pub unsafe fn with_functions(functions: CAbiFunctions) -> Result<Self, AgentError> {
        let mut backend = ptr::null_mut();
        let status = (functions.init)(&mut backend);
        if status != LocalAgentStatus::Ok {
            return Err(status_to_error(status, "initialize on-device backend"));
        }
        if backend.is_null() {
            return Err(AgentError::Provider(
                "on-device backend init returned null".into(),
            ));
        }

        Ok(Self {
            functions,
            backend: Mutex::new(CAbiBackendHandle(backend)),
        })
    }
}

#[cfg(feature = "link-mock-local-inference")]
fn linked_c_abi_functions() -> Result<CAbiFunctions, AgentError> {
    Ok(CAbiFunctions::linked())
}

#[cfg(not(feature = "link-mock-local-inference"))]
fn linked_c_abi_functions() -> Result<CAbiFunctions, AgentError> {
    Err(AgentError::Provider(
        "on-device backend is not linked; enable link-mock-local-inference or provide C ABI functions".into(),
    ))
}

impl LocalLLMProvider {
    pub fn new(
        model: impl Into<String>,
        model_config_json: impl Into<String>,
        backend: Box<dyn LocalInferenceBackend>,
    ) -> Self {
        Self {
            model: model.into(),
            model_config_json: model_config_json.into(),
            backend,
            model_loaded: Mutex::new(false),
        }
    }

    fn ensure_model_loaded(&self) -> Result<(), AgentError> {
        let mut loaded = self.model_loaded.lock().unwrap();
        if !*loaded {
            self.backend.load_model(&self.model_config_json)?;
            *loaded = true;
        }
        Ok(())
    }
}

impl ModelProvider for LocalLLMProvider {
    fn id(&self) -> &str {
        "local_llm"
    }

    fn stream_chat(
        &self,
        frame: &PromptFrame,
        cancellation: CancellationToken,
        on_output: &mut dyn FnMut(ModelProviderOutput) -> Result<(), AgentError>,
    ) -> Result<(), AgentError> {
        if cancellation.is_cancelled() {
            return Err(AgentError::Cancelled("local LLM cancelled".into()));
        }

        self.ensure_model_loaded()?;

        let mut prompt = build_openai_chat_request(&self.model, frame);
        prompt["stream"] = Value::Bool(true);

        self.backend
            .stream_chat(&prompt.to_string(), cancellation, &mut |token_json| {
                on_output(parse_backend_token(token_json)?)
            })?;
        Ok(())
    }
}

impl LocalInferenceBackend for CAbiLocalInferenceBackend {
    fn load_model(&self, model_config_json: &str) -> Result<(), AgentError> {
        let model_config = c_string(model_config_json, "model config")?;
        let backend = self.backend.lock().unwrap();
        if backend.0.is_null() {
            return Err(AgentError::Provider(
                "on-device backend has been released".into(),
            ));
        }

        let status = unsafe { (self.functions.load_model)(backend.0, model_config.as_ptr()) };
        status_to_result(status, "load on-device model")
    }

    fn stream_chat(
        &self,
        prompt_json: &str,
        cancellation: CancellationToken,
        on_token: &mut dyn FnMut(&str) -> Result<(), AgentError>,
    ) -> Result<(), AgentError> {
        if cancellation.is_cancelled() {
            return Err(AgentError::Cancelled("on-device backend cancelled".into()));
        }

        let prompt = c_string(prompt_json, "prompt")?;
        let backend_ptr = {
            let backend = self.backend.lock().unwrap();
            if backend.0.is_null() {
                return Err(AgentError::Provider(
                    "on-device backend has been released".into(),
                ));
            }
            backend.0
        };

        let mut stream = ptr::null_mut();
        let start_status =
            unsafe { (self.functions.start_chat)(backend_ptr, prompt.as_ptr(), &mut stream) };
        status_to_result(start_status, "start on-device stream")?;
        if stream.is_null() {
            return Err(AgentError::Provider(
                "on-device stream start returned null".into(),
            ));
        }

        let done = Arc::new(AtomicBool::new(false));
        let cancel_called = Arc::new(AtomicBool::new(false));
        let watcher = spawn_cancellation_watcher(
            CAbiStreamHandle(stream),
            cancellation.clone(),
            self.functions.cancel,
            done.clone(),
            cancel_called.clone(),
        );

        let mut callback_error = None;
        let mut state = CallbackState {
            on_token,
            cancellation: cancellation.clone(),
            stream,
            cancel: self.functions.cancel,
            error: &mut callback_error,
        };

        let read_status = unsafe {
            (self.functions.read_stream)(
                stream,
                collect_c_token,
                &mut state as *mut CallbackState<'_> as *mut c_void,
            )
        };
        done.store(true, Ordering::SeqCst);
        let watcher_panicked = watcher.join().is_err();
        if watcher_panicked {
            unsafe {
                (self.functions.cancel)(stream);
            }
        }
        let release_status = unsafe { (self.functions.release_stream)(stream) };

        if watcher_panicked {
            status_to_result(release_status, "release on-device stream")?;
            return Err(AgentError::Provider(
                "on-device cancellation watcher panicked".into(),
            ));
        }

        if let Some(error) = callback_error {
            return Err(error);
        }
        if cancellation.is_cancelled()
            || cancel_called.load(Ordering::SeqCst)
            || read_status == LocalAgentStatus::Cancelled
        {
            status_to_result(release_status, "release on-device stream")?;
            return Err(AgentError::Cancelled("on-device backend cancelled".into()));
        }
        status_to_result(read_status, "read on-device stream")?;
        status_to_result(release_status, "release on-device stream")
    }
}

fn parse_backend_token(token_json: &str) -> Result<ModelProviderOutput, AgentError> {
    let value: Value = serde_json::from_str(token_json)
        .map_err(|error| AgentError::Provider(format!("invalid on-device token JSON: {error}")))?;
    let token_type = value
        .get("type")
        .and_then(Value::as_str)
        .ok_or_else(|| AgentError::Provider("missing on-device token type".into()))?;
    let text = value
        .get("text")
        .and_then(Value::as_str)
        .ok_or_else(|| AgentError::Provider("missing on-device token text".into()))?;

    match token_type {
        "text_delta" => Ok(ModelProviderOutput::TextDelta(text.to_string())),
        "completed" => Ok(ModelProviderOutput::Completed(text.to_string())),
        other => Err(AgentError::Provider(format!(
            "unknown on-device token type: {other}"
        ))),
    }
}

impl Drop for CAbiLocalInferenceBackend {
    fn drop(&mut self) {
        if let Ok(mut backend) = self.backend.lock() {
            if !backend.0.is_null() {
                unsafe {
                    (self.functions.release_backend)(backend.0);
                }
                backend.0 = ptr::null_mut();
            }
        }
    }
}

unsafe extern "C" fn collect_c_token(
    token_json: *const c_char,
    user_data: *mut c_void,
) -> LocalAgentStatus {
    let state = &mut *(user_data as *mut CallbackState<'_>);
    if token_json.is_null() {
        *state.error = Some(AgentError::Provider(
            "on-device backend emitted null token".into(),
        ));
        cancel_stream(state);
        return LocalAgentStatus::Error;
    }

    let token = match CStr::from_ptr(token_json).to_str() {
        Ok(token) => token,
        Err(error) => {
            *state.error = Some(AgentError::Provider(format!(
                "on-device backend emitted invalid UTF-8 token: {error}"
            )));
            cancel_stream(state);
            return LocalAgentStatus::Error;
        }
    };

    if let Err(error) = (state.on_token)(token) {
        let status = match &error {
            AgentError::Cancelled(_) => LocalAgentStatus::Cancelled,
            _ => LocalAgentStatus::Error,
        };
        *state.error = Some(error);
        cancel_stream(state);
        return status;
    }

    if state.cancellation.is_cancelled() {
        cancel_stream(state);
        return LocalAgentStatus::Cancelled;
    }

    LocalAgentStatus::Ok
}

unsafe fn cancel_stream(state: &mut CallbackState<'_>) {
    if !state.stream.is_null() {
        (state.cancel)(state.stream);
    }
}

fn spawn_cancellation_watcher(
    stream: CAbiStreamHandle,
    cancellation: CancellationToken,
    cancel: CAbiCancelFn,
    done: Arc<AtomicBool>,
    cancel_called: Arc<AtomicBool>,
) -> thread::JoinHandle<()> {
    thread::spawn(move || {
        while !done.load(Ordering::SeqCst) {
            if cancellation.is_cancelled() {
                unsafe {
                    cancel(stream.as_ptr());
                }
                cancel_called.store(true, Ordering::SeqCst);
                return;
            }
            thread::sleep(Duration::from_millis(1));
        }
    })
}

fn c_string(value: &str, label: &str) -> Result<CString, AgentError> {
    CString::new(value).map_err(|error| {
        AgentError::Provider(format!("on-device {label} contains interior NUL: {error}"))
    })
}

fn status_to_result(status: LocalAgentStatus, action: &str) -> Result<(), AgentError> {
    if status == LocalAgentStatus::Ok {
        Ok(())
    } else {
        Err(status_to_error(status, action))
    }
}

fn status_to_error(status: LocalAgentStatus, action: &str) -> AgentError {
    match status {
        LocalAgentStatus::Ok => AgentError::Provider(format!("{action} unexpectedly failed")),
        LocalAgentStatus::Cancelled => AgentError::Cancelled("on-device backend cancelled".into()),
        LocalAgentStatus::InvalidArgument => {
            AgentError::Provider(format!("{action} rejected invalid argument"))
        }
        LocalAgentStatus::Error => AgentError::Provider(format!("{action} failed")),
    }
}
