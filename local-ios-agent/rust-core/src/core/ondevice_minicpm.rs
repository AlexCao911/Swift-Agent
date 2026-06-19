use std::ffi::{c_char, c_void, CStr, CString};
use std::ptr;
use std::sync::Mutex;

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

pub type CAbiTokenCallback = unsafe extern "C" fn(*const c_char, *mut c_void);

pub type CAbiInitFn =
    unsafe extern "C" fn(*mut *mut CAbiLocalAgentBackend) -> LocalAgentStatus;
pub type CAbiLoadModelFn =
    unsafe extern "C" fn(*mut CAbiLocalAgentBackend, *const c_char) -> LocalAgentStatus;
pub type CAbiStreamChatFn = unsafe extern "C" fn(
    *mut CAbiLocalAgentBackend,
    *const c_char,
    CAbiTokenCallback,
    *mut c_void,
    *mut *mut CAbiLocalAgentBackendStream,
) -> LocalAgentStatus;
pub type CAbiCancelFn =
    unsafe extern "C" fn(*mut CAbiLocalAgentBackendStream) -> LocalAgentStatus;
pub type CAbiReleaseStreamFn =
    unsafe extern "C" fn(*mut CAbiLocalAgentBackendStream) -> LocalAgentStatus;
pub type CAbiReleaseBackendFn =
    unsafe extern "C" fn(*mut CAbiLocalAgentBackend) -> LocalAgentStatus;

#[derive(Clone, Copy)]
pub struct CAbiFunctions {
    pub init: CAbiInitFn,
    pub load_model: CAbiLoadModelFn,
    pub stream_chat: CAbiStreamChatFn,
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

pub struct OnDeviceMiniCPMProvider {
    model: String,
    model_config_json: String,
    backend: Box<dyn LocalInferenceBackend>,
    model_loaded: Mutex<bool>,
}

#[derive(Clone, Copy)]
struct CAbiBackendHandle(*mut CAbiLocalAgentBackend);

unsafe impl Send for CAbiBackendHandle {}

struct CallbackState<'a> {
    on_token: &'a mut dyn FnMut(&str) -> Result<(), AgentError>,
    cancellation: CancellationToken,
    stream_slot: *mut *mut CAbiLocalAgentBackendStream,
    cancel: CAbiCancelFn,
    error: &'a mut Option<AgentError>,
}

extern "C" {
    fn local_agent_backend_init(out_backend: *mut *mut CAbiLocalAgentBackend)
        -> LocalAgentStatus;
    fn local_agent_backend_load_model(
        backend: *mut CAbiLocalAgentBackend,
        model_config_json: *const c_char,
    ) -> LocalAgentStatus;
    fn local_agent_backend_stream_chat(
        backend: *mut CAbiLocalAgentBackend,
        prompt_json: *const c_char,
        callback: CAbiTokenCallback,
        user_data: *mut c_void,
        out_stream: *mut *mut CAbiLocalAgentBackendStream,
    ) -> LocalAgentStatus;
    fn local_agent_backend_cancel(
        stream: *mut CAbiLocalAgentBackendStream,
    ) -> LocalAgentStatus;
    fn local_agent_backend_release_stream(
        stream: *mut CAbiLocalAgentBackendStream,
    ) -> LocalAgentStatus;
    fn local_agent_backend_release(
        backend: *mut CAbiLocalAgentBackend,
    ) -> LocalAgentStatus;
}

impl CAbiFunctions {
    pub fn linked() -> Self {
        Self {
            init: local_agent_backend_init,
            load_model: local_agent_backend_load_model,
            stream_chat: local_agent_backend_stream_chat,
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
            return Err(AgentError::Provider(
                "on-device model is not loaded".into(),
            ));
        }

        for token in &self.tokens {
            if cancellation.is_cancelled() {
                return Err(AgentError::Cancelled(
                    "on-device backend cancelled".into(),
                ));
            }

            on_token(token)?;

            if cancellation.is_cancelled() {
                return Err(AgentError::Cancelled(
                    "on-device backend cancelled".into(),
                ));
            }
        }
        Ok(())
    }
}

impl CAbiLocalInferenceBackend {
    pub fn new() -> Result<Self, AgentError> {
        unsafe { Self::with_functions(CAbiFunctions::linked()) }
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

impl OnDeviceMiniCPMProvider {
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

impl ModelProvider for OnDeviceMiniCPMProvider {
    fn id(&self) -> &str {
        "ondevice_minicpm"
    }

    fn stream_chat(
        &self,
        frame: &PromptFrame,
        cancellation: CancellationToken,
    ) -> Result<Vec<ModelProviderOutput>, AgentError> {
        if cancellation.is_cancelled() {
            return Err(AgentError::Cancelled(
                "on-device MiniCPM cancelled".into(),
            ));
        }

        self.ensure_model_loaded()?;

        let mut prompt = build_openai_chat_request(&self.model, frame);
        prompt["stream"] = Value::Bool(true);

        let mut output = Vec::new();
        self.backend.stream_chat(
            &prompt.to_string(),
            cancellation,
            &mut |token_json| {
                output.push(parse_backend_token(token_json)?);
                Ok(())
            },
        )?;
        Ok(output)
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
            return Err(AgentError::Cancelled(
                "on-device backend cancelled".into(),
            ));
        }

        let prompt = c_string(prompt_json, "prompt")?;
        let backend = self.backend.lock().unwrap();
        if backend.0.is_null() {
            return Err(AgentError::Provider(
                "on-device backend has been released".into(),
            ));
        }

        let mut stream = ptr::null_mut();
        let mut callback_error = None;
        let mut state = CallbackState {
            on_token,
            cancellation,
            stream_slot: &mut stream,
            cancel: self.functions.cancel,
            error: &mut callback_error,
        };

        let status = unsafe {
            (self.functions.stream_chat)(
                backend.0,
                prompt.as_ptr(),
                collect_c_token,
                &mut state as *mut CallbackState<'_> as *mut c_void,
                &mut stream,
            )
        };

        let release_status = if stream.is_null() {
            LocalAgentStatus::Ok
        } else {
            unsafe { (self.functions.release_stream)(stream) }
        };

        if let Some(error) = callback_error {
            return Err(error);
        }
        status_to_result(status, "stream on-device chat")?;
        status_to_result(release_status, "release on-device stream")
    }
}

fn parse_backend_token(token_json: &str) -> Result<ModelProviderOutput, AgentError> {
    let value: Value = serde_json::from_str(token_json).map_err(|error| {
        AgentError::Provider(format!("invalid on-device token JSON: {error}"))
    })?;
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

unsafe extern "C" fn collect_c_token(token_json: *const c_char, user_data: *mut c_void) {
    let state = &mut *(user_data as *mut CallbackState<'_>);
    if token_json.is_null() {
        *state.error = Some(AgentError::Provider(
            "on-device backend emitted null token".into(),
        ));
        cancel_stream(state);
        return;
    }

    let token = match CStr::from_ptr(token_json).to_str() {
        Ok(token) => token,
        Err(error) => {
            *state.error = Some(AgentError::Provider(format!(
                "on-device backend emitted invalid UTF-8 token: {error}"
            )));
            cancel_stream(state);
            return;
        }
    };

    if let Err(error) = (state.on_token)(token) {
        *state.error = Some(error);
        cancel_stream(state);
        return;
    }

    if state.cancellation.is_cancelled() {
        cancel_stream(state);
    }
}

unsafe fn cancel_stream(state: &mut CallbackState<'_>) {
    if state.stream_slot.is_null() {
        return;
    }

    let stream = *state.stream_slot;
    if !stream.is_null() {
        (state.cancel)(stream);
    }
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
        LocalAgentStatus::Cancelled => {
            AgentError::Cancelled("on-device backend cancelled".into())
        }
        LocalAgentStatus::InvalidArgument => {
            AgentError::Provider(format!("{action} rejected invalid argument"))
        }
        LocalAgentStatus::Error => AgentError::Provider(format!("{action} failed")),
    }
}
