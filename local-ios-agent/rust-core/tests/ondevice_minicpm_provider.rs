use std::ffi::{c_char, c_void};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use local_ios_agent_runtime::context::{PromptFrame, PromptMessage};
use local_ios_agent_runtime::core::{
    AgentError, CAbiFunctions, CAbiLocalAgentBackend, CAbiLocalAgentBackendStream,
    CAbiLocalInferenceBackend, CAbiTokenCallback, CancellationToken, LocalAgentStatus,
    LocalInferenceBackend, MockLocalInferenceBackend, ModelProvider, ModelProviderOutput,
    OnDeviceMiniCPMProvider,
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
}

#[test]
fn on_device_provider_builds_backend_prompt_and_maps_token_outputs() {
    let backend = RecordingBackend::streaming(MOCK_TOKEN_JSON);
    let provider = OnDeviceMiniCPMProvider::new(
        "minicpm",
        r#"{"model_path":"mock.gguf"}"#,
        Box::new(backend.clone()),
    );
    let frame = PromptFrame {
        system_prompt: "system".into(),
        runtime_policy: "policy".into(),
        tool_schemas: vec![r#"{"name":"debug.echo"}"#.into()],
        messages: vec![
            PromptMessage::User("hello".into()),
            PromptMessage::Assistant("hi".into()),
            PromptMessage::ToolResult("done".into()),
        ],
    };

    let output = provider
        .stream_chat(&frame, CancellationToken::default())
        .unwrap();

    assert_eq!(provider.id(), "ondevice_minicpm");
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
    assert!(
        prompt["messages"][0]["content"]
            .as_str()
            .unwrap()
            .contains("Available tools")
    );
}

#[test]
fn on_device_provider_surfaces_backend_cancellation() {
    let backend = RecordingBackend::failing(AgentError::Cancelled("backend stopped".into()));
    let provider = OnDeviceMiniCPMProvider::new(
        "minicpm",
        r#"{"model_path":"mock.gguf"}"#,
        Box::new(backend),
    );
    let frame = PromptFrame {
        system_prompt: String::new(),
        runtime_policy: String::new(),
        tool_schemas: Vec::new(),
        messages: Vec::new(),
    };

    let error = provider
        .stream_chat(&frame, CancellationToken::default())
        .unwrap_err();

    assert_eq!(error, AgentError::Cancelled("backend stopped".into()));
}

#[test]
fn on_device_provider_surfaces_backend_errors() {
    let backend = RecordingBackend::failing(AgentError::Provider("backend offline".into()));
    let provider = OnDeviceMiniCPMProvider::new(
        "minicpm",
        r#"{"model_path":"mock.gguf"}"#,
        Box::new(backend),
    );
    let frame = PromptFrame {
        system_prompt: String::new(),
        runtime_policy: String::new(),
        tool_schemas: Vec::new(),
        messages: Vec::new(),
    };

    let error = provider
        .stream_chat(&frame, CancellationToken::default())
        .unwrap_err();

    assert_eq!(error, AgentError::Provider("backend offline".into()));
}

#[test]
fn on_device_provider_rejects_malformed_backend_token_json() {
    let backend = RecordingBackend::streaming(["not json"]);
    let provider = OnDeviceMiniCPMProvider::new(
        "minicpm",
        r#"{"model_path":"mock.gguf"}"#,
        Box::new(backend),
    );
    let frame = PromptFrame {
        system_prompt: String::new(),
        runtime_policy: String::new(),
        tool_schemas: Vec::new(),
        messages: Vec::new(),
    };

    let error = provider
        .stream_chat(&frame, CancellationToken::default())
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

static CANCEL_CALLS: AtomicUsize = AtomicUsize::new(0);
static RELEASE_STREAM_CALLS: AtomicUsize = AtomicUsize::new(0);
static RELEASE_BACKEND_CALLS: AtomicUsize = AtomicUsize::new(0);

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

unsafe extern "C" fn fake_stream_chat(
    _backend: *mut CAbiLocalAgentBackend,
    _prompt_json: *const c_char,
    callback: CAbiTokenCallback,
    user_data: *mut c_void,
    out_stream: *mut *mut CAbiLocalAgentBackendStream,
) -> LocalAgentStatus {
    *out_stream = 0x22usize as *mut CAbiLocalAgentBackendStream;
    callback(FAKE_TOKEN_JSON.as_ptr() as *const c_char, user_data);
    if CANCEL_CALLS.load(Ordering::SeqCst) == 0 {
        return LocalAgentStatus::Ok;
    }
    LocalAgentStatus::Cancelled
}

unsafe extern "C" fn fake_cancel(
    _stream: *mut CAbiLocalAgentBackendStream,
) -> LocalAgentStatus {
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
    CANCEL_CALLS.store(0, Ordering::SeqCst);
    RELEASE_STREAM_CALLS.store(0, Ordering::SeqCst);
    RELEASE_BACKEND_CALLS.store(0, Ordering::SeqCst);

    let backend = unsafe {
        CAbiLocalInferenceBackend::with_functions(CAbiFunctions {
            init: fake_init,
            load_model: fake_load_model,
            stream_chat: fake_stream_chat,
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
