use std::ffi::{c_char, c_void};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use local_ios_agent_runtime::context::{InferenceOptions, PromptFrame, PromptMessage};
use local_ios_agent_runtime::core::{
    AgentError, CAbiFunctions, CAbiLocalAgentBackend, CAbiLocalAgentBackendStream,
    CAbiLocalInferenceBackend, CAbiTokenCallback, CancellationToken, ImageInput, LocalAgentStatus,
    LocalInferenceBackend, LocalLLMProvider, MockLocalInferenceBackend, ModelProvider,
    ModelProviderOutput,
};

const MOCK_TOKEN_JSON: [&str; 3] = [
    r#"{"type":"text_delta","text":"On-device "}"#,
    r#"{"type":"text_delta","text":"mock response"}"#,
    r#"{"type":"completed","text":"On-device mock response"}"#,
];
const FAKE_TOKEN_JSON: &[u8] = b"{\"type\":\"text_delta\",\"text\":\"On-device \"}\0";

#[derive(Clone)]
struct RecordingBackend {
    state: Arc<RecordingBackendState>,
    tokens: Vec<String>,
    stream_error: Option<AgentError>,
}

#[derive(Default)]
struct RecordingBackendState {
    loaded_configs: Mutex<Vec<String>>,
    prompts: Mutex<Vec<String>>,
    image_inputs: Mutex<Vec<ImageInput>>,
}

impl RecordingBackend {
    fn streaming<I, S>(tokens: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        Self {
            state: Arc::new(RecordingBackendState::default()),
            tokens: tokens.into_iter().map(Into::into).collect(),
            stream_error: None,
        }
    }

    fn failing(error: AgentError) -> Self {
        Self {
            state: Arc::new(RecordingBackendState::default()),
            tokens: Vec::new(),
            stream_error: Some(error),
        }
    }

    fn loaded_configs(&self) -> Vec<String> {
        self.state.loaded_configs.lock().unwrap().clone()
    }

    fn prompts(&self) -> Vec<String> {
        self.state.prompts.lock().unwrap().clone()
    }

    fn image_inputs(&self) -> Vec<ImageInput> {
        self.state.image_inputs.lock().unwrap().clone()
    }
}

impl LocalInferenceBackend for RecordingBackend {
    fn load_model(&self, model_config_json: &str) -> Result<(), AgentError> {
        self.state
            .loaded_configs
            .lock()
            .unwrap()
            .push(model_config_json.to_string());
        Ok(())
    }

    fn stream_chat(
        &self,
        prompt_json: &str,
        _cancellation: CancellationToken,
        on_token: &mut dyn FnMut(&str) -> Result<(), AgentError>,
    ) -> Result<(), AgentError> {
        self.state
            .prompts
            .lock()
            .unwrap()
            .push(prompt_json.to_string());
        if let Some(error) = &self.stream_error {
            return Err(error.clone());
        }
        for token in &self.tokens {
            on_token(token)?;
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
        self.state.image_inputs.lock().unwrap().push(image);
        self.stream_chat(prompt_json, cancellation, on_token)
    }
}

#[test]
fn local_llm_provider_builds_backend_prompt_and_maps_token_outputs() {
    let backend = RecordingBackend::streaming(MOCK_TOKEN_JSON);
    let provider = LocalLLMProvider::new(
        "minicpm",
        r#"{"model_path":"mock.gguf"}"#,
        Box::new(backend.clone()),
    );
    let frame = PromptFrame {
        system_prompt: "system".into(),
        runtime_policy: "policy".into(),
        tool_schemas: vec![r#"{"name":"debug.echo"}"#.into()],
        inference_options: InferenceOptions::default(),
        messages: vec![
            PromptMessage::User("hello".into()),
            PromptMessage::Assistant("hi".into()),
            PromptMessage::ToolResult("done".into()),
        ],
    };

    let mut output = Vec::new();
    provider
        .stream_chat(&frame, CancellationToken::default(), &mut |event| {
            output.push(event);
            Ok(())
        })
        .unwrap();

    assert_eq!(provider.id(), "local_llm");
    assert_eq!(
        output,
        vec![
            ModelProviderOutput::TextDelta("On-device ".into()),
            ModelProviderOutput::TextDelta("mock response".into()),
            ModelProviderOutput::Completed("On-device mock response".into()),
        ]
    );
    assert_eq!(
        backend.loaded_configs(),
        vec![r#"{"model_path":"mock.gguf"}"#.to_string()]
    );
    let prompt: serde_json::Value = serde_json::from_str(&backend.prompts()[0]).unwrap();
    assert_eq!(prompt["model"], "minicpm");
    assert_eq!(prompt["stream"], true);
    assert_eq!(prompt["messages"][1]["content"], "hello");
    assert!(prompt["messages"][0]["content"]
        .as_str()
        .unwrap()
        .contains("Available tools"));
}

#[test]
fn local_llm_provider_streams_single_image_blob_through_backend() {
    let backend = RecordingBackend::streaming(MOCK_TOKEN_JSON);
    let provider = LocalLLMProvider::new(
        "minicpm",
        r#"{"model_path":"mock.gguf"}"#,
        Box::new(backend.clone()),
    );
    let frame = PromptFrame {
        system_prompt: "system".into(),
        runtime_policy: "policy".into(),
        tool_schemas: Vec::new(),
        inference_options: InferenceOptions::default(),
        messages: vec![PromptMessage::UserWithBlobRefs {
            content: "what is in this picture?".into(),
            blob_refs: vec![
                "local-agent-chat:v1:eyJ0eXBlIjoiaW1hZ2VfaW5wdXQiLCJpbWFnZVdpZHRoIjoyLCJpbWFnZUhlaWdodCI6MSwicmdiRGF0YUJhc2U2NCI6IkFRSURCQVVHIn0".into(),
            ],
        }],
    };

    let mut output = Vec::new();
    provider
        .stream_chat(&frame, CancellationToken::default(), &mut |event| {
            output.push(event);
            Ok(())
        })
        .unwrap();

    assert_eq!(
        output,
        vec![
            ModelProviderOutput::TextDelta("On-device ".into()),
            ModelProviderOutput::TextDelta("mock response".into()),
            ModelProviderOutput::Completed("On-device mock response".into()),
        ]
    );
    assert_eq!(
        backend.image_inputs(),
        vec![ImageInput {
            width: 2,
            height: 1,
            rgb_data: vec![1, 2, 3, 4, 5, 6],
        }]
    );
}

#[test]
fn local_llm_provider_streams_latest_image_blob_through_backend() {
    let backend = RecordingBackend::streaming(MOCK_TOKEN_JSON);
    let provider = LocalLLMProvider::new(
        "minicpm",
        r#"{"model_path":"mock.gguf"}"#,
        Box::new(backend.clone()),
    );
    let frame = PromptFrame {
        system_prompt: "system".into(),
        runtime_policy: "policy".into(),
        tool_schemas: Vec::new(),
        inference_options: InferenceOptions::default(),
        messages: vec![
            PromptMessage::UserWithBlobRefs {
                content: "what is in this first picture?".into(),
                blob_refs: vec![
                    "local-agent-chat:v1:eyJ0eXBlIjoiaW1hZ2VfaW5wdXQiLCJpbWFnZVdpZHRoIjoyLCJpbWFnZUhlaWdodCI6MSwicmdiRGF0YUJhc2U2NCI6IkFRSURCQVVHIn0".into(),
                ],
            },
            PromptMessage::Assistant("the first picture shows flowers".into()),
            PromptMessage::User("does that place look good for ice cream?".into()),
            PromptMessage::Assistant("the flower area looks nice".into()),
            PromptMessage::UserWithBlobRefs {
                content: "what is this new picture?".into(),
                blob_refs: vec![
                    "local-agent-chat:v1:eyJ0eXBlIjoiaW1hZ2VfaW5wdXQiLCJpbWFnZVdpZHRoIjoxLCJpbWFnZUhlaWdodCI6MSwicmdiRGF0YUJhc2U2NCI6IkNRZ0gifQ".into(),
                ],
            },
        ],
    };

    provider
        .stream_chat(&frame, CancellationToken::default(), &mut |_| Ok(()))
        .unwrap();

    assert_eq!(
        backend.image_inputs(),
        vec![ImageInput {
            width: 1,
            height: 1,
            rgb_data: vec![9, 8, 7],
        }]
    );
}

#[test]
fn local_llm_provider_surfaces_backend_cancellation() {
    let backend = RecordingBackend::failing(AgentError::Cancelled("backend stopped".into()));
    let provider = LocalLLMProvider::new(
        "minicpm",
        r#"{"model_path":"mock.gguf"}"#,
        Box::new(backend),
    );
    let frame = PromptFrame {
        system_prompt: String::new(),
        runtime_policy: String::new(),
        tool_schemas: Vec::new(),
        inference_options: InferenceOptions::default(),
        messages: Vec::new(),
    };

    let error = provider
        .stream_chat(&frame, CancellationToken::default(), &mut |_| Ok(()))
        .unwrap_err();

    assert_eq!(error, AgentError::Cancelled("backend stopped".into()));
}

#[test]
fn local_llm_provider_surfaces_backend_errors() {
    let backend = RecordingBackend::failing(AgentError::Provider("backend offline".into()));
    let provider = LocalLLMProvider::new(
        "minicpm",
        r#"{"model_path":"mock.gguf"}"#,
        Box::new(backend),
    );
    let frame = PromptFrame {
        system_prompt: String::new(),
        runtime_policy: String::new(),
        tool_schemas: Vec::new(),
        inference_options: InferenceOptions::default(),
        messages: Vec::new(),
    };

    let error = provider
        .stream_chat(&frame, CancellationToken::default(), &mut |_| Ok(()))
        .unwrap_err();

    assert_eq!(error, AgentError::Provider("backend offline".into()));
}

#[test]
fn local_llm_provider_rejects_malformed_backend_token_json() {
    let backend = RecordingBackend::streaming(["not json"]);
    let provider = LocalLLMProvider::new(
        "minicpm",
        r#"{"model_path":"mock.gguf"}"#,
        Box::new(backend),
    );
    let frame = PromptFrame {
        system_prompt: String::new(),
        runtime_policy: String::new(),
        tool_schemas: Vec::new(),
        inference_options: InferenceOptions::default(),
        messages: Vec::new(),
    };

    let error = provider
        .stream_chat(&frame, CancellationToken::default(), &mut |_| Ok(()))
        .unwrap_err();

    assert!(error.to_string().contains("invalid on-device token"));
}

#[test]
fn mock_local_backend_loads_and_streams_tokens() {
    let backend = MockLocalInferenceBackend::new(MOCK_TOKEN_JSON);
    backend.load_model(r#"{"model_path":"mock.gguf"}"#).unwrap();

    let mut tokens = Vec::new();
    backend
        .stream_chat(
            r#"{"messages":[{"role":"user","content":"hello"}]}"#,
            CancellationToken::default(),
            &mut |token| {
                tokens.push(token.to_string());
                Ok(())
            },
        )
        .unwrap();

    assert_eq!(tokens, MOCK_TOKEN_JSON);
}

#[test]
fn mock_local_backend_stops_when_cancelled_by_token_callback() {
    let backend = MockLocalInferenceBackend::new(MOCK_TOKEN_JSON);
    backend.load_model(r#"{"model_path":"mock.gguf"}"#).unwrap();
    let cancellation = CancellationToken::default();

    let mut tokens = Vec::new();
    let error = backend
        .stream_chat(
            r#"{"messages":[{"role":"user","content":"cancel"}]}"#,
            cancellation.clone(),
            &mut |token| {
                tokens.push(token.to_string());
                cancellation.cancel();
                Ok(())
            },
        )
        .unwrap_err();

    assert_eq!(tokens, vec![MOCK_TOKEN_JSON[0]]);
    assert!(matches!(error, AgentError::Cancelled(_)));
}

#[cfg(feature = "link-mock-local-inference")]
#[test]
fn c_abi_backend_streams_through_linked_mock_backend() {
    let backend = CAbiLocalInferenceBackend::new().unwrap();
    backend.load_model(r#"{"model_path":"mock.gguf"}"#).unwrap();

    let mut tokens = Vec::new();
    backend
        .stream_chat(
            r#"{"messages":[{"role":"user","content":"hello"}]}"#,
            CancellationToken::default(),
            &mut |token| {
                tokens.push(token.to_string());
                Ok(())
            },
        )
        .unwrap();

    assert_eq!(tokens, MOCK_TOKEN_JSON);
}

#[cfg(not(feature = "link-mock-local-inference"))]
#[test]
fn c_abi_backend_new_reports_not_linked_when_backend_feature_is_disabled() {
    let error = match CAbiLocalInferenceBackend::new() {
        Ok(_) => panic!("expected C ABI backend creation to fail when backend is not linked"),
        Err(error) => error,
    };

    assert!(error
        .to_string()
        .contains("Rust direct on-device C ABI linking is retired"));
}

static CANCEL_CALLS: AtomicUsize = AtomicUsize::new(0);
static RELEASE_STREAM_CALLS: AtomicUsize = AtomicUsize::new(0);
static RELEASE_BACKEND_CALLS: AtomicUsize = AtomicUsize::new(0);
static START_IMAGE_CALLS: AtomicUsize = AtomicUsize::new(0);
static C_ABI_FAKE_LOCK: Mutex<()> = Mutex::new(());

unsafe extern "C" fn fake_init(out_backend: *mut *mut CAbiLocalAgentBackend) -> LocalAgentStatus {
    *out_backend = 0x11usize as *mut CAbiLocalAgentBackend;
    LocalAgentStatus::Ok
}

unsafe extern "C" fn fake_load_model(
    _backend: *mut CAbiLocalAgentBackend,
    _model_config_json: *const c_char,
) -> LocalAgentStatus {
    LocalAgentStatus::Ok
}

unsafe extern "C" fn fake_start_chat(
    _backend: *mut CAbiLocalAgentBackend,
    _prompt_json: *const c_char,
    out_stream: *mut *mut CAbiLocalAgentBackendStream,
) -> LocalAgentStatus {
    *out_stream = 0x22usize as *mut CAbiLocalAgentBackendStream;
    LocalAgentStatus::Ok
}

unsafe extern "C" fn fake_start_chat_with_image(
    _backend: *mut CAbiLocalAgentBackend,
    _prompt_json: *const c_char,
    rgb_data: *const u8,
    width: u32,
    height: u32,
    out_stream: *mut *mut CAbiLocalAgentBackendStream,
) -> LocalAgentStatus {
    if rgb_data.is_null() || width != 2 || height != 1 {
        return LocalAgentStatus::InvalidArgument;
    }
    START_IMAGE_CALLS.fetch_add(1, Ordering::SeqCst);
    *out_stream = 0x33usize as *mut CAbiLocalAgentBackendStream;
    LocalAgentStatus::Ok
}

unsafe extern "C" fn fake_start_chat_with_image_error(
    _backend: *mut CAbiLocalAgentBackend,
    _prompt_json: *const c_char,
    _rgb_data: *const u8,
    _width: u32,
    _height: u32,
    out_stream: *mut *mut CAbiLocalAgentBackendStream,
) -> LocalAgentStatus {
    *out_stream = std::ptr::null_mut();
    LocalAgentStatus::Error
}

unsafe extern "C" fn fake_read_stream(
    _stream: *mut CAbiLocalAgentBackendStream,
    callback: CAbiTokenCallback,
    user_data: *mut c_void,
) -> LocalAgentStatus {
    let callback_status = callback(FAKE_TOKEN_JSON.as_ptr() as *const c_char, user_data);
    if callback_status != LocalAgentStatus::Ok {
        return callback_status;
    }
    if CANCEL_CALLS.load(Ordering::SeqCst) == 0 {
        return LocalAgentStatus::Ok;
    }
    LocalAgentStatus::Cancelled
}

unsafe extern "C" fn fake_blocking_read_stream(
    _stream: *mut CAbiLocalAgentBackendStream,
    _callback: CAbiTokenCallback,
    _user_data: *mut c_void,
) -> LocalAgentStatus {
    for _ in 0..200 {
        if CANCEL_CALLS.load(Ordering::SeqCst) > 0 {
            return LocalAgentStatus::Cancelled;
        }
        thread::sleep(Duration::from_millis(1));
    }
    LocalAgentStatus::Error
}

unsafe extern "C" fn fake_cancel(_stream: *mut CAbiLocalAgentBackendStream) -> LocalAgentStatus {
    CANCEL_CALLS.fetch_add(1, Ordering::SeqCst);
    LocalAgentStatus::Cancelled
}

unsafe extern "C" fn fake_release_stream(
    _stream: *mut CAbiLocalAgentBackendStream,
) -> LocalAgentStatus {
    RELEASE_STREAM_CALLS.fetch_add(1, Ordering::SeqCst);
    LocalAgentStatus::Ok
}

unsafe extern "C" fn fake_release_backend(
    _backend: *mut CAbiLocalAgentBackend,
) -> LocalAgentStatus {
    RELEASE_BACKEND_CALLS.fetch_add(1, Ordering::SeqCst);
    LocalAgentStatus::Ok
}

#[test]
fn c_abi_backend_calls_cancel_and_releases_stream_once() {
    let _guard = C_ABI_FAKE_LOCK.lock().unwrap();
    CANCEL_CALLS.store(0, Ordering::SeqCst);
    RELEASE_STREAM_CALLS.store(0, Ordering::SeqCst);
    RELEASE_BACKEND_CALLS.store(0, Ordering::SeqCst);
    START_IMAGE_CALLS.store(0, Ordering::SeqCst);

    let backend = unsafe {
        CAbiLocalInferenceBackend::with_functions(CAbiFunctions {
            init: fake_init,
            load_model: fake_load_model,
            start_chat: fake_start_chat,
            start_chat_with_image: fake_start_chat_with_image,
            read_stream: fake_read_stream,
            cancel: fake_cancel,
            release_stream: fake_release_stream,
            release_backend: fake_release_backend,
        })
    }
    .unwrap();
    backend.load_model(r#"{"model_path":"mock.gguf"}"#).unwrap();
    let cancellation = CancellationToken::default();

    let mut tokens = Vec::new();
    let error = backend
        .stream_chat(
            r#"{"messages":[{"role":"user","content":"cancel"}]}"#,
            cancellation.clone(),
            &mut |token| {
                tokens.push(token.to_string());
                cancellation.cancel();
                Ok(())
            },
        )
        .unwrap_err();

    assert_eq!(tokens, vec![MOCK_TOKEN_JSON[0]]);
    assert!(matches!(error, AgentError::Cancelled(_)));
    assert_eq!(CANCEL_CALLS.load(Ordering::SeqCst), 1);
    assert_eq!(RELEASE_STREAM_CALLS.load(Ordering::SeqCst), 1);

    drop(backend);
    assert_eq!(RELEASE_BACKEND_CALLS.load(Ordering::SeqCst), 1);
}

#[test]
fn c_abi_backend_cancels_blocked_read_from_cancellation_token() {
    let _guard = C_ABI_FAKE_LOCK.lock().unwrap();
    CANCEL_CALLS.store(0, Ordering::SeqCst);
    RELEASE_STREAM_CALLS.store(0, Ordering::SeqCst);
    RELEASE_BACKEND_CALLS.store(0, Ordering::SeqCst);
    START_IMAGE_CALLS.store(0, Ordering::SeqCst);

    let backend = unsafe {
        CAbiLocalInferenceBackend::with_functions(CAbiFunctions {
            init: fake_init,
            load_model: fake_load_model,
            start_chat: fake_start_chat,
            start_chat_with_image: fake_start_chat_with_image,
            read_stream: fake_blocking_read_stream,
            cancel: fake_cancel,
            release_stream: fake_release_stream,
            release_backend: fake_release_backend,
        })
    }
    .unwrap();
    backend.load_model(r#"{"model_path":"mock.gguf"}"#).unwrap();
    let cancellation = CancellationToken::default();
    let cancellation_from_runtime = cancellation.clone();
    let canceller = thread::spawn(move || {
        thread::sleep(Duration::from_millis(10));
        cancellation_from_runtime.cancel();
    });

    let error = backend
        .stream_chat(
            r#"{"messages":[{"role":"user","content":"cancel while blocked"}]}"#,
            cancellation,
            &mut |_token| Ok(()),
        )
        .unwrap_err();

    canceller.join().unwrap();
    assert!(matches!(error, AgentError::Cancelled(_)));
    assert!(CANCEL_CALLS.load(Ordering::SeqCst) > 0);
    assert_eq!(RELEASE_STREAM_CALLS.load(Ordering::SeqCst), 1);
}

#[test]
fn c_abi_backend_image_start_error_mentions_mtmd_build_requirement() {
    let _guard = C_ABI_FAKE_LOCK.lock().unwrap();
    CANCEL_CALLS.store(0, Ordering::SeqCst);
    RELEASE_STREAM_CALLS.store(0, Ordering::SeqCst);
    RELEASE_BACKEND_CALLS.store(0, Ordering::SeqCst);
    START_IMAGE_CALLS.store(0, Ordering::SeqCst);

    let backend = unsafe {
        CAbiLocalInferenceBackend::with_functions(CAbiFunctions {
            init: fake_init,
            load_model: fake_load_model,
            start_chat: fake_start_chat,
            start_chat_with_image: fake_start_chat_with_image_error,
            read_stream: fake_read_stream,
            cancel: fake_cancel,
            release_stream: fake_release_stream,
            release_backend: fake_release_backend,
        })
    }
    .unwrap();
    backend.load_model(r#"{"model_path":"mock.gguf"}"#).unwrap();

    let error = backend
        .stream_chat_with_image(
            r#"{"messages":[{"role":"user","content":"describe"}]}"#,
            ImageInput {
                width: 2,
                height: 1,
                rgb_data: vec![1, 2, 3, 4, 5, 6],
            },
            CancellationToken::default(),
            &mut |_token| Ok(()),
        )
        .unwrap_err();

    assert!(
        error
            .to_string()
            .contains("link-llama-cpp-mtmd-local-inference"),
        "{error}"
    );
    assert_eq!(RELEASE_STREAM_CALLS.load(Ordering::SeqCst), 0);
}
