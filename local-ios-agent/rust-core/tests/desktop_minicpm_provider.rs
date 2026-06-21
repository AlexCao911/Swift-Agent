use std::sync::{Arc, Mutex};

use local_ios_agent_runtime::context::{PromptFrame, PromptMessage};
use local_ios_agent_runtime::core::{
    CancellationToken, DesktopMiniCPMProvider, DesktopMiniCPMTransport, ModelProvider,
    ModelProviderOutput,
};

#[derive(Debug)]
struct FakeTransport {
    requests: Arc<Mutex<Vec<String>>>,
    response: String,
}

impl DesktopMiniCPMTransport for FakeTransport {
    fn chat_completion(
        &self,
        request_json: String,
        cancellation: CancellationToken,
    ) -> Result<String, local_ios_agent_runtime::core::AgentError> {
        assert!(!cancellation.is_cancelled());
        self.requests.lock().unwrap().push(request_json);
        Ok(self.response.clone())
    }
}

#[test]
fn desktop_minicpm_provider_builds_request_and_parses_text_response() {
    let requests = Arc::new(Mutex::new(Vec::new()));
    let provider = DesktopMiniCPMProvider::new(
        "minicpm",
        Box::new(FakeTransport {
            requests: requests.clone(),
            response: r#"{"choices":[{"message":{"content":"desktop response"}}]}"#.into(),
        }),
    );
    let frame = PromptFrame {
        system_prompt: "system".into(),
        runtime_policy: "policy".into(),
        tool_schemas: Vec::new(),
        messages: vec![PromptMessage::User("hello".into())],
    };

    let mut output = Vec::new();
    provider
        .stream_chat(&frame, CancellationToken::default(), &mut |event| {
            output.push(event);
            Ok(())
        })
        .unwrap();

    assert_eq!(provider.id(), "desktop_minicpm");
    assert_eq!(
        output,
        vec![ModelProviderOutput::Completed("desktop response".into())]
    );
    let request: serde_json::Value =
        serde_json::from_str(requests.lock().unwrap().first().unwrap()).unwrap();
    assert_eq!(request["model"], "minicpm");
    assert_eq!(request["messages"][1]["content"], "hello");
}

#[test]
fn desktop_minicpm_provider_checks_cancellation_before_transport() {
    let token = CancellationToken::default();
    token.cancel();
    let provider = DesktopMiniCPMProvider::new(
        "minicpm",
        Box::new(FakeTransport {
            requests: Arc::new(Mutex::new(Vec::new())),
            response: "{}".into(),
        }),
    );
    let frame = PromptFrame {
        system_prompt: String::new(),
        runtime_policy: String::new(),
        tool_schemas: Vec::new(),
        messages: Vec::new(),
    };

    let error = provider
        .stream_chat(&frame, token, &mut |_| Ok(()))
        .unwrap_err();

    assert!(error.to_string().contains("desktop MiniCPM cancelled"));
}
