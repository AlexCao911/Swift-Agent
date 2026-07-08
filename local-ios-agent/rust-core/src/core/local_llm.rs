use std::ffi::{c_char, c_void, CStr, CString};
use std::ptr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use serde_json::{json, Value};

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

// Retired v1 C ABI compatibility surface.
//
// Product local inference now uses the C++ v2 engine/model/generation ABI below.
// These declarations remain only so older tests and injected compatibility
// backends can be understood without keeping the old direct-link path alive.
#[repr(C)]
pub struct CAbiLocalAgentBackend {
    _private: [u8; 0],
}

#[repr(C)]
pub struct CAbiLocalAgentBackendStream {
    _private: [u8; 0],
}

#[repr(C)]
pub struct CAbiV2EngineHandle {
    _private: [u8; 0],
}

#[repr(C)]
pub struct CAbiV2ModelHandle {
    _private: [u8; 0],
}

#[repr(C)]
pub struct CAbiV2GenerationHandle {
    _private: [u8; 0],
}

#[repr(C)]
pub struct CAbiV2ImageInput {
    pub bytes: *const u8,
    pub byte_count: u64,
    pub width: u32,
    pub height: u32,
    pub pixel_format: *const c_char,
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
pub type CAbiStartChatWithImageFn = unsafe extern "C" fn(
    *mut CAbiLocalAgentBackend,
    *const c_char,
    *const u8,
    u32,
    u32,
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

pub type CAbiV2EngineCreateFn =
    unsafe extern "C" fn(*const c_char, *mut *mut CAbiV2EngineHandle) -> LocalAgentStatus;
pub type CAbiV2EngineReleaseFn = unsafe extern "C" fn(*mut CAbiV2EngineHandle) -> LocalAgentStatus;
pub type CAbiV2ModelLoadFn = unsafe extern "C" fn(
    *mut CAbiV2EngineHandle,
    *const c_char,
    *mut *mut CAbiV2ModelHandle,
) -> LocalAgentStatus;
pub type CAbiV2ModelUnloadFn = unsafe extern "C" fn(*mut CAbiV2ModelHandle) -> LocalAgentStatus;
pub type CAbiV2GenerationStartFn = unsafe extern "C" fn(
    *mut CAbiV2ModelHandle,
    *const c_char,
    *const CAbiV2ImageInput,
    u64,
    *mut *mut CAbiV2GenerationHandle,
) -> LocalAgentStatus;
pub type CAbiV2GenerationReadFn = unsafe extern "C" fn(
    *mut CAbiV2GenerationHandle,
    CAbiTokenCallback,
    *mut c_void,
) -> LocalAgentStatus;
pub type CAbiV2GenerationCancelFn =
    unsafe extern "C" fn(*mut CAbiV2GenerationHandle) -> LocalAgentStatus;
pub type CAbiV2GenerationReleaseFn =
    unsafe extern "C" fn(*mut CAbiV2GenerationHandle) -> LocalAgentStatus;

#[derive(Clone, Copy)]
pub struct CAbiFunctions {
    pub init: CAbiInitFn,
    pub load_model: CAbiLoadModelFn,
    pub start_chat: CAbiStartChatFn,
    pub start_chat_with_image: CAbiStartChatWithImageFn,
    pub read_stream: CAbiReadStreamFn,
    pub cancel: CAbiCancelFn,
    pub release_stream: CAbiReleaseStreamFn,
    pub release_backend: CAbiReleaseBackendFn,
}

#[derive(Clone, Copy)]
pub struct CAbiV2Functions {
    pub engine_create: CAbiV2EngineCreateFn,
    pub engine_release: CAbiV2EngineReleaseFn,
    pub model_load: CAbiV2ModelLoadFn,
    pub model_unload: CAbiV2ModelUnloadFn,
    pub generation_start: CAbiV2GenerationStartFn,
    pub generation_read: CAbiV2GenerationReadFn,
    pub generation_cancel: CAbiV2GenerationCancelFn,
    pub generation_release: CAbiV2GenerationReleaseFn,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ImageInput {
    pub width: u32,
    pub height: u32,
    pub rgb_data: Vec<u8>,
}

pub trait LocalInferenceBackend: Send + Sync {
    fn load_model(&self, model_config_json: &str) -> Result<(), AgentError>;
    fn stream_chat(
        &self,
        prompt_json: &str,
        cancellation: CancellationToken,
        on_token: &mut dyn FnMut(&str) -> Result<(), AgentError>,
    ) -> Result<(), AgentError>;
    fn stream_chat_with_image(
        &self,
        prompt_json: &str,
        image: ImageInput,
        cancellation: CancellationToken,
        on_token: &mut dyn FnMut(&str) -> Result<(), AgentError>,
    ) -> Result<(), AgentError> {
        let _ = (prompt_json, image, cancellation, on_token);
        Err(AgentError::Provider(
            "on-device backend does not support image input".into(),
        ))
    }
}

pub struct MockLocalInferenceBackend {
    tokens: Vec<String>,
    loaded: Mutex<bool>,
}

pub struct CAbiLocalInferenceBackend {
    functions: CAbiFunctions,
    backend: Mutex<CAbiBackendHandle>,
}

pub struct CAbiV2LocalInferenceBackend {
    functions: CAbiV2Functions,
    engine_id: String,
    engine: Mutex<CAbiV2EngineHandlePtr>,
    model: Mutex<CAbiV2ModelHandlePtr>,
}

pub struct LocalLLMProvider {
    provider_id: String,
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

#[derive(Clone, Copy)]
struct CAbiV2EngineHandlePtr(*mut CAbiV2EngineHandle);

unsafe impl Send for CAbiV2EngineHandlePtr {}

#[derive(Clone, Copy)]
struct CAbiV2ModelHandlePtr(*mut CAbiV2ModelHandle);

unsafe impl Send for CAbiV2ModelHandlePtr {}

#[derive(Clone, Copy)]
struct CAbiV2GenerationHandlePtr(*mut CAbiV2GenerationHandle);

unsafe impl Send for CAbiV2GenerationHandlePtr {}

impl CAbiV2GenerationHandlePtr {
    fn as_ptr(self) -> *mut CAbiV2GenerationHandle {
        self.0
    }
}

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

// Retired v1 symbol imports. Enabling this feature is intentionally rejected in
// build.rs before linking; do not add new product code against these symbols.
#[cfg(feature = "legacy-v1-local-inference-compat")]
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
    fn local_agent_backend_start_chat_with_image(
        backend: *mut CAbiLocalAgentBackend,
        prompt_json: *const c_char,
        rgb_data: *const u8,
        width: u32,
        height: u32,
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

#[cfg(any(
    feature = "link-mock-local-inference",
    feature = "link-llama-cpp-local-inference",
    feature = "link-llama-cpp-mtmd-local-inference",
    feature = "link-litert-local-inference"
))]
extern "C" {
    fn local_agent_engine_create(
        engine_id: *const c_char,
        out_engine: *mut *mut CAbiV2EngineHandle,
    ) -> LocalAgentStatus;
    fn local_agent_engine_release(engine: *mut CAbiV2EngineHandle) -> LocalAgentStatus;
    fn local_agent_model_load(
        engine: *mut CAbiV2EngineHandle,
        model_config_json: *const c_char,
        out_model: *mut *mut CAbiV2ModelHandle,
    ) -> LocalAgentStatus;
    fn local_agent_model_unload(model: *mut CAbiV2ModelHandle) -> LocalAgentStatus;
    fn local_agent_generation_start(
        model: *mut CAbiV2ModelHandle,
        generation_request_json: *const c_char,
        images: *const CAbiV2ImageInput,
        image_count: u64,
        out_generation: *mut *mut CAbiV2GenerationHandle,
    ) -> LocalAgentStatus;
    fn local_agent_generation_read(
        generation: *mut CAbiV2GenerationHandle,
        callback: CAbiTokenCallback,
        user_data: *mut c_void,
    ) -> LocalAgentStatus;
    fn local_agent_generation_cancel(generation: *mut CAbiV2GenerationHandle) -> LocalAgentStatus;
    fn local_agent_generation_release(
        generation: *mut CAbiV2GenerationHandle,
    ) -> LocalAgentStatus;
}

impl CAbiFunctions {
    #[cfg(feature = "legacy-v1-local-inference-compat")]
    pub fn linked() -> Self {
        Self {
            init: local_agent_backend_init,
            load_model: local_agent_backend_load_model,
            start_chat: local_agent_backend_start_chat,
            start_chat_with_image: local_agent_backend_start_chat_with_image,
            read_stream: local_agent_backend_read_stream,
            cancel: local_agent_backend_cancel,
            release_stream: local_agent_backend_release_stream,
            release_backend: local_agent_backend_release,
        }
    }
}

impl CAbiV2Functions {
    #[cfg(any(
        feature = "link-mock-local-inference",
        feature = "link-llama-cpp-local-inference",
        feature = "link-llama-cpp-mtmd-local-inference",
        feature = "link-litert-local-inference"
    ))]
    pub fn linked() -> Self {
        Self {
            engine_create: local_agent_engine_create,
            engine_release: local_agent_engine_release,
            model_load: local_agent_model_load,
            model_unload: local_agent_model_unload,
            generation_start: local_agent_generation_start,
            generation_read: local_agent_generation_read,
            generation_cancel: local_agent_generation_cancel,
            generation_release: local_agent_generation_release,
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

    fn stream_chat_with_image(
        &self,
        prompt_json: &str,
        image: ImageInput,
        cancellation: CancellationToken,
        on_token: &mut dyn FnMut(&str) -> Result<(), AgentError>,
    ) -> Result<(), AgentError> {
        let expected = image
            .width
            .checked_mul(image.height)
            .and_then(|pixels| pixels.checked_mul(3))
            .ok_or_else(|| AgentError::Provider("image dimensions overflow".into()))?;
        if image.rgb_data.len() != expected as usize {
            return Err(AgentError::Provider(
                "image RGB buffer size does not match dimensions".into(),
            ));
        }
        self.stream_chat(prompt_json, cancellation, on_token)
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

impl CAbiV2LocalInferenceBackend {
    pub fn new(engine_id: impl Into<String>) -> Result<Self, AgentError> {
        let functions = linked_c_abi_v2_functions()?;
        unsafe { Self::with_functions(engine_id, functions) }
    }

    pub unsafe fn with_functions(
        engine_id: impl Into<String>,
        functions: CAbiV2Functions,
    ) -> Result<Self, AgentError> {
        let engine_id = engine_id.into();
        let engine_id_c = c_string(&engine_id, "engine id")?;
        let mut engine = ptr::null_mut();
        let status = (functions.engine_create)(engine_id_c.as_ptr(), &mut engine);
        if status != LocalAgentStatus::Ok {
            return Err(status_to_error(status, "create on-device engine"));
        }
        if engine.is_null() {
            return Err(AgentError::Provider(
                "on-device engine create returned null".into(),
            ));
        }

        Ok(Self {
            functions,
            engine_id,
            engine: Mutex::new(CAbiV2EngineHandlePtr(engine)),
            model: Mutex::new(CAbiV2ModelHandlePtr(ptr::null_mut())),
        })
    }

    fn engine_ptr(&self) -> Result<*mut CAbiV2EngineHandle, AgentError> {
        let engine = self.engine.lock().unwrap();
        if engine.0.is_null() {
            return Err(AgentError::Provider(
                "on-device engine has been released".into(),
            ));
        }
        Ok(engine.0)
    }

    fn model_ptr(&self) -> Result<*mut CAbiV2ModelHandle, AgentError> {
        let model = self.model.lock().unwrap();
        if model.0.is_null() {
            return Err(AgentError::Provider(
                "on-device model is not loaded".into(),
            ));
        }
        Ok(model.0)
    }

    fn start_generation(
        &self,
        request: &CString,
        image: Option<&ImageInput>,
    ) -> Result<*mut CAbiV2GenerationHandle, AgentError> {
        let pixel_format = c_string("rgb8", "pixel format")?;
        let image_inputs = image.map(|image| CAbiV2ImageInput {
            bytes: image.rgb_data.as_ptr(),
            byte_count: image.rgb_data.len() as u64,
            width: image.width,
            height: image.height,
            pixel_format: pixel_format.as_ptr(),
        });
        let (images_ptr, image_count) = match &image_inputs {
            Some(image_input) => (image_input as *const CAbiV2ImageInput, 1),
            None => (ptr::null(), 0),
        };

        let mut generation = ptr::null_mut();
        let status = unsafe {
            (self.functions.generation_start)(
                self.model_ptr()?,
                request.as_ptr(),
                images_ptr,
                image_count,
                &mut generation,
            )
        };
        status_to_result(status, "start on-device generation")?;
        if generation.is_null() {
            return Err(AgentError::Provider(
                "on-device generation start returned null".into(),
            ));
        }
        Ok(generation)
    }

    fn read_started_generation(
        &self,
        generation: *mut CAbiV2GenerationHandle,
        cancellation: CancellationToken,
        on_token: &mut dyn FnMut(&str) -> Result<(), AgentError>,
    ) -> Result<(), AgentError> {
        let done = Arc::new(AtomicBool::new(false));
        let cancel_called = Arc::new(AtomicBool::new(false));
        let watcher = spawn_v2_cancellation_watcher(
            CAbiV2GenerationHandlePtr(generation),
            cancellation.clone(),
            self.functions.generation_cancel,
            done.clone(),
            cancel_called.clone(),
        );
        let mut callback_error = None;
        let mut state = CallbackState {
            on_token,
            cancellation: cancellation.clone(),
            stream: ptr::null_mut(),
            cancel: noop_v1_cancel,
            error: &mut callback_error,
        };

        let read_status = unsafe {
            (self.functions.generation_read)(
                generation,
                collect_c_token,
                &mut state as *mut CallbackState<'_> as *mut c_void,
            )
        };
        done.store(true, Ordering::SeqCst);
        let watcher_panicked = watcher.join().is_err();
        if watcher_panicked {
            unsafe {
                (self.functions.generation_cancel)(generation);
            }
        }
        let release_status = unsafe { (self.functions.generation_release)(generation) };

        if watcher_panicked {
            status_to_result(release_status, "release on-device generation")?;
            return Err(AgentError::Provider(
                "on-device v2 cancellation watcher panicked".into(),
            ));
        }
        if let Some(error) = callback_error {
            return Err(error);
        }
        if cancellation.is_cancelled()
            || cancel_called.load(Ordering::SeqCst)
            || read_status == LocalAgentStatus::Cancelled
        {
            status_to_result(release_status, "release on-device generation")?;
            return Err(AgentError::Cancelled("on-device backend cancelled".into()));
        }
        status_to_result(read_status, "read on-device generation")?;
        status_to_result(release_status, "release on-device generation")
    }
}

impl LocalInferenceBackend for CAbiV2LocalInferenceBackend {
    fn load_model(&self, model_config_json: &str) -> Result<(), AgentError> {
        let normalized = normalize_v2_model_config(model_config_json, &self.engine_id)?;
        let model_config = c_string(&normalized, "model config")?;
        let mut model = self.model.lock().unwrap();
        if !model.0.is_null() {
            return Ok(());
        }

        let mut loaded_model = ptr::null_mut();
        let status = unsafe {
            (self.functions.model_load)(self.engine_ptr()?, model_config.as_ptr(), &mut loaded_model)
        };
        status_to_result(status, "load on-device model")?;
        if loaded_model.is_null() {
            return Err(AgentError::Provider(
                "on-device model load returned null".into(),
            ));
        }
        model.0 = loaded_model;
        Ok(())
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
        let request = normalize_v2_generation_request(prompt_json, None)?;
        let request = c_string(&request, "generation request")?;
        let generation = self.start_generation(&request, None)?;
        self.read_started_generation(generation, cancellation, on_token)
    }

    fn stream_chat_with_image(
        &self,
        prompt_json: &str,
        image: ImageInput,
        cancellation: CancellationToken,
        on_token: &mut dyn FnMut(&str) -> Result<(), AgentError>,
    ) -> Result<(), AgentError> {
        if cancellation.is_cancelled() {
            return Err(AgentError::Cancelled("on-device backend cancelled".into()));
        }
        validate_image_input(&image)?;
        let request = normalize_v2_generation_request(prompt_json, Some(&image))?;
        let request = c_string(&request, "generation request")?;
        let generation = self.start_generation(&request, Some(&image))?;
        self.read_started_generation(generation, cancellation, on_token)
    }
}

#[cfg(feature = "legacy-v1-local-inference-compat")]
fn linked_c_abi_functions() -> Result<CAbiFunctions, AgentError> {
    Ok(CAbiFunctions::linked())
}

#[cfg(not(feature = "legacy-v1-local-inference-compat"))]
fn linked_c_abi_functions() -> Result<CAbiFunctions, AgentError> {
    Err(AgentError::Provider(
        "legacy local inference v1 C ABI linking is disabled; use C++ inference v2 instead".into(),
    ))
}

#[cfg(any(
    feature = "link-mock-local-inference",
    feature = "link-llama-cpp-local-inference",
    feature = "link-llama-cpp-mtmd-local-inference",
    feature = "link-litert-local-inference"
))]
fn linked_c_abi_v2_functions() -> Result<CAbiV2Functions, AgentError> {
    Ok(CAbiV2Functions::linked())
}

#[cfg(not(any(
    feature = "link-mock-local-inference",
    feature = "link-llama-cpp-local-inference",
    feature = "link-llama-cpp-mtmd-local-inference",
    feature = "link-litert-local-inference"
)))]
fn linked_c_abi_v2_functions() -> Result<CAbiV2Functions, AgentError> {
    Err(AgentError::Provider(
        "local C++ inference v2 is not linked in this build".into(),
    ))
}

impl LocalLLMProvider {
    pub fn new(
        model: impl Into<String>,
        model_config_json: impl Into<String>,
        backend: Box<dyn LocalInferenceBackend>,
    ) -> Self {
        Self::with_provider_id("local_llm", model, model_config_json, backend)
    }

    pub fn with_provider_id(
        provider_id: impl Into<String>,
        model: impl Into<String>,
        model_config_json: impl Into<String>,
        backend: Box<dyn LocalInferenceBackend>,
    ) -> Self {
        Self {
            provider_id: provider_id.into(),
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
        &self.provider_id
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
        apply_local_generation_defaults(&mut prompt, &self.model_config_json)?;

        let prompt_json = prompt.to_string();
        let image = latest_image_input(frame)?;
        let mut emit_token = |token_json: &str| {
            if let Some(output) = parse_backend_token(token_json)? {
                on_output(output)?;
            }
            Ok(())
        };
        if let Some(image) = image {
            self.backend.stream_chat_with_image(
                &prompt_json,
                image,
                cancellation,
                &mut emit_token,
            )?;
        } else {
            self.backend
                .stream_chat(&prompt_json, cancellation, &mut emit_token)?;
        }
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
        let stream = self.start_stream(&prompt)?;
        self.read_started_stream(stream, cancellation, on_token)
    }

    fn stream_chat_with_image(
        &self,
        prompt_json: &str,
        image: ImageInput,
        cancellation: CancellationToken,
        on_token: &mut dyn FnMut(&str) -> Result<(), AgentError>,
    ) -> Result<(), AgentError> {
        if cancellation.is_cancelled() {
            return Err(AgentError::Cancelled("on-device backend cancelled".into()));
        }
        validate_image_input(&image)?;

        let prompt = c_string(prompt_json, "prompt")?;
        let stream = self.start_image_stream(&prompt, &image)?;
        self.read_started_stream(stream, cancellation, on_token)
    }
}

impl CAbiLocalInferenceBackend {
    fn backend_ptr(&self) -> Result<*mut CAbiLocalAgentBackend, AgentError> {
        let backend = self.backend.lock().unwrap();
        if backend.0.is_null() {
            return Err(AgentError::Provider(
                "on-device backend has been released".into(),
            ));
        }
        Ok(backend.0)
    }

    fn start_stream(
        &self,
        prompt: &CString,
    ) -> Result<*mut CAbiLocalAgentBackendStream, AgentError> {
        let mut stream = ptr::null_mut();
        let start_status = unsafe {
            (self.functions.start_chat)(self.backend_ptr()?, prompt.as_ptr(), &mut stream)
        };
        status_to_result(start_status, "start on-device stream")?;
        ensure_stream(stream)
    }

    fn start_image_stream(
        &self,
        prompt: &CString,
        image: &ImageInput,
    ) -> Result<*mut CAbiLocalAgentBackendStream, AgentError> {
        let mut stream = ptr::null_mut();
        let start_status = unsafe {
            (self.functions.start_chat_with_image)(
                self.backend_ptr()?,
                prompt.as_ptr(),
                image.rgb_data.as_ptr(),
                image.width,
                image.height,
                &mut stream,
            )
        };
        status_to_result(start_status, "start on-device image stream")?;
        ensure_stream(stream)
    }

    fn read_started_stream(
        &self,
        stream: *mut CAbiLocalAgentBackendStream,
        cancellation: CancellationToken,
        on_token: &mut dyn FnMut(&str) -> Result<(), AgentError>,
    ) -> Result<(), AgentError> {
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

fn latest_image_input(frame: &PromptFrame) -> Result<Option<ImageInput>, AgentError> {
    for message in frame.messages.iter().rev() {
        for blob_ref in message.blob_refs().iter().rev() {
            if let Some(image) = image_input_from_blob_ref(blob_ref)? {
                return Ok(Some(image));
            }
        }
    }
    Ok(None)
}

fn image_input_from_blob_ref(blob_ref: &str) -> Result<Option<ImageInput>, AgentError> {
    const PREFIX: &str = "local-agent-chat:v1:";
    if !blob_ref.starts_with(PREFIX) {
        return Ok(None);
    }

    let encoded = &blob_ref[PREFIX.len()..];
    let data = base64_url_decode(encoded).map_err(|error| {
        AgentError::Provider(format!("invalid local image blob metadata: {error}"))
    })?;
    let value: Value = serde_json::from_slice(&data)
        .map_err(|error| AgentError::Provider(format!("invalid local image blob JSON: {error}")))?;
    let rgb_base64 = value
        .get("rgbDataBase64")
        .and_then(Value::as_str)
        .or_else(|| value.get("rgb_data_base64").and_then(Value::as_str));
    let Some(rgb_base64) = rgb_base64 else {
        return Ok(None);
    };
    let width = json_u32(&value, "imageWidth")
        .or_else(|| json_u32(&value, "image_width"))
        .ok_or_else(|| AgentError::Provider("local image blob missing width".into()))?;
    let height = json_u32(&value, "imageHeight")
        .or_else(|| json_u32(&value, "image_height"))
        .ok_or_else(|| AgentError::Provider("local image blob missing height".into()))?;
    let rgb_data = base64_decode(rgb_base64)
        .map_err(|error| AgentError::Provider(format!("invalid local image RGB data: {error}")))?;
    let image = ImageInput {
        width,
        height,
        rgb_data,
    };
    validate_image_input(&image)?;
    Ok(Some(image))
}

fn json_u32(value: &Value, key: &str) -> Option<u32> {
    value.get(key)?.as_u64()?.try_into().ok()
}

fn validate_image_input(image: &ImageInput) -> Result<(), AgentError> {
    if image.width == 0 || image.height == 0 {
        return Err(AgentError::Provider(
            "image dimensions must be non-zero".into(),
        ));
    }
    let expected = image
        .width
        .checked_mul(image.height)
        .and_then(|pixels| pixels.checked_mul(3))
        .ok_or_else(|| AgentError::Provider("image dimensions overflow".into()))?;
    if image.rgb_data.len() != expected as usize {
        return Err(AgentError::Provider(
            "image RGB buffer size does not match dimensions".into(),
        ));
    }
    Ok(())
}

fn base64_url_decode(encoded: &str) -> Result<Vec<u8>, String> {
    let mut standard = encoded.replace('-', "+").replace('_', "/");
    match standard.len() % 4 {
        0 => {}
        remainder => standard.push_str(&"=".repeat(4 - remainder)),
    }
    base64_decode(&standard)
}

fn base64_decode(encoded: &str) -> Result<Vec<u8>, String> {
    let mut output = Vec::with_capacity(encoded.len() * 3 / 4);
    let mut buffer = 0u32;
    let mut bits = 0u8;

    for byte in encoded.bytes() {
        if byte == b'=' {
            break;
        }
        let value = match byte {
            b'A'..=b'Z' => byte - b'A',
            b'a'..=b'z' => byte - b'a' + 26,
            b'0'..=b'9' => byte - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            b'\r' | b'\n' | b'\t' | b' ' => continue,
            other => return Err(format!("invalid base64 byte: {other}")),
        } as u32;
        buffer = (buffer << 6) | value;
        bits += 6;
        while bits >= 8 {
            bits -= 8;
            output.push(((buffer >> bits) & 0xff) as u8);
        }
    }

    Ok(output)
}

fn ensure_stream(
    stream: *mut CAbiLocalAgentBackendStream,
) -> Result<*mut CAbiLocalAgentBackendStream, AgentError> {
    if stream.is_null() {
        Err(AgentError::Provider(
            "on-device stream start returned null".into(),
        ))
    } else {
        Ok(stream)
    }
}

fn normalize_v2_model_config(model_config_json: &str, engine_id: &str) -> Result<String, AgentError> {
    let mut value: Value = serde_json::from_str(model_config_json)
        .map_err(|error| AgentError::Provider(format!("invalid model config JSON: {error}")))?;
    let object = value.as_object_mut().ok_or_else(|| {
        AgentError::Provider("model config must be a JSON object".into())
    })?;

    let engine = object
        .get("engine")
        .and_then(Value::as_str)
        .map(str::to_string)
        .or_else(|| object.get("backend").and_then(Value::as_str).map(str::to_string))
        .unwrap_or_else(|| engine_id.to_string());
    object.insert("engine".to_string(), Value::String(engine));

    if !object.contains_key("context_tokens") {
        if let Some(max_context_tokens) = object.get("max_context_tokens").cloned() {
            object.insert("context_tokens".to_string(), max_context_tokens);
        }
    }

    if !object.contains_key("runtime") {
        let mut runtime = serde_json::Map::new();
        if let Some(n_threads) = object.get("n_threads").cloned() {
            runtime.insert("n_threads".to_string(), n_threads);
        }
        if let Some(n_gpu_layers) = object.get("n_gpu_layers").cloned() {
            runtime.insert("n_gpu_layers".to_string(), n_gpu_layers);
        }
        if !runtime.is_empty() {
            object.insert("runtime".to_string(), Value::Object(runtime));
        }
    }

    Ok(value.to_string())
}

fn apply_local_generation_defaults(
    prompt: &mut Value,
    model_config_json: &str,
) -> Result<(), AgentError> {
    let config: Value = serde_json::from_str(model_config_json)
        .map_err(|error| AgentError::Provider(format!("invalid model config JSON: {error}")))?;
    let Some(prompt_object) = prompt.as_object_mut() else {
        return Err(AgentError::Provider("prompt JSON must be an object".into()));
    };
    let Some(config_object) = config.as_object() else {
        return Err(AgentError::Provider("model config must be a JSON object".into()));
    };

    apply_generation_default(prompt_object, config_object, "max_new_tokens");
    apply_generation_default(prompt_object, config_object, "temperature");
    apply_generation_default(prompt_object, config_object, "top_p");
    Ok(())
}

fn apply_generation_default(
    prompt_object: &mut serde_json::Map<String, Value>,
    config_object: &serde_json::Map<String, Value>,
    key: &str,
) {
    if prompt_object.contains_key(key) {
        return;
    }
    if let Some(value) = config_object.get(key).cloned() {
        prompt_object.insert(key.to_string(), value);
        return;
    }
    if let Some(value) = config_object
        .get("generation")
        .and_then(Value::as_object)
        .and_then(|generation| generation.get(key))
        .cloned()
    {
        prompt_object.insert(key.to_string(), value);
    }
}

fn normalize_v2_generation_request(
    prompt_json: &str,
    image: Option<&ImageInput>,
) -> Result<String, AgentError> {
    let value: Value = serde_json::from_str(prompt_json)
        .map_err(|error| AgentError::Provider(format!("invalid prompt JSON: {error}")))?;
    let messages = value.get("messages").cloned().ok_or_else(|| {
        AgentError::Provider("prompt JSON missing messages".into())
    })?;
    let mut request = serde_json::Map::new();
    request.insert("messages".to_string(), messages);

    if let Some(image) = image {
        request.insert(
            "images".to_string(),
            Value::Array(vec![json!({
                "format": "rgb8",
                "width": image.width,
                "height": image.height,
            })]),
        );
    }

    let mut sampling = value
        .get("sampling")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    if let Some(temperature) = value.get("temperature").cloned() {
        sampling.insert("temperature".to_string(), temperature);
    }
    if let Some(top_p) = value.get("top_p").cloned() {
        sampling.insert("top_p".to_string(), top_p);
    }
    if let Some(max_new_tokens) = value.get("max_new_tokens").cloned() {
        sampling.insert("max_new_tokens".to_string(), max_new_tokens);
    }
    if !sampling.is_empty() {
        request.insert("sampling".to_string(), Value::Object(sampling));
    }

    Ok(Value::Object(request).to_string())
}

fn parse_backend_token(token_json: &str) -> Result<Option<ModelProviderOutput>, AgentError> {
    let value: Value = serde_json::from_str(token_json)
        .map_err(|error| AgentError::Provider(format!("invalid on-device token JSON: {error}")))?;
    let token_type = value
        .get("type")
        .and_then(Value::as_str)
        .ok_or_else(|| AgentError::Provider("missing on-device token type".into()))?;
    match token_type {
        "text_delta" => {
            let text = value
                .get("text")
                .and_then(Value::as_str)
                .ok_or_else(|| AgentError::Provider("missing on-device token text".into()))?;
            Ok(Some(ModelProviderOutput::TextDelta(text.to_string())))
        }
        "completed" => {
            let text = value
                .get("text")
                .and_then(Value::as_str)
                .ok_or_else(|| AgentError::Provider("missing on-device token text".into()))?;
            Ok(Some(ModelProviderOutput::Completed(text.to_string())))
        }
        "usage" | "structured_delta" => Ok(None),
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

impl Drop for CAbiV2LocalInferenceBackend {
    fn drop(&mut self) {
        if let Ok(mut model) = self.model.lock() {
            if !model.0.is_null() {
                unsafe {
                    (self.functions.model_unload)(model.0);
                }
                model.0 = ptr::null_mut();
            }
        }
        if let Ok(mut engine) = self.engine.lock() {
            if !engine.0.is_null() {
                unsafe {
                    (self.functions.engine_release)(engine.0);
                }
                engine.0 = ptr::null_mut();
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

unsafe extern "C" fn noop_v1_cancel(_stream: *mut CAbiLocalAgentBackendStream) -> LocalAgentStatus {
    LocalAgentStatus::Cancelled
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

fn spawn_v2_cancellation_watcher(
    generation: CAbiV2GenerationHandlePtr,
    cancellation: CancellationToken,
    cancel: CAbiV2GenerationCancelFn,
    done: Arc<AtomicBool>,
    cancel_called: Arc<AtomicBool>,
) -> thread::JoinHandle<()> {
    thread::spawn(move || {
        while !done.load(Ordering::SeqCst) {
            if cancellation.is_cancelled() {
                unsafe {
                    cancel(generation.as_ptr());
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
        LocalAgentStatus::Error if action == "start on-device image stream" => {
            AgentError::Provider(
                "start on-device image stream failed; image input requires a llama.cpp mtmd build. Rebuild the simulator runtime with link-llama-cpp-mtmd-local-inference and provide LLAMA_CPP_MTMD_HEADERS plus LLAMA_CPP_MTMD_LIBRARY.".into(),
            )
        }
        LocalAgentStatus::Error => AgentError::Provider(format!("{action} failed")),
    }
}
