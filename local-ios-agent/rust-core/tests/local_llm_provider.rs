use local_ios_agent_runtime::context::{PromptFrame, PromptMessage};
use local_ios_agent_runtime::core::{
    CancellationToken, LocalLLMProvider, MockLocalInferenceBackend, ModelProvider,
    ModelProviderOutput,
};

#[test]
fn local_llm_provider_is_model_agnostic() {
    let backend = MockLocalInferenceBackend::new([
        r#"{"type":"text_delta","text":"local "}"#,
        r#"{"type":"completed","text":"local answer"}"#,
    ]);
    let provider = LocalLLMProvider::new(
        "local.gguf.simulator",
        r#"{"backend":"mock","model_path":"/tmp/mock.gguf"}"#,
        Box::new(backend),
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

    assert_eq!(provider.id(), "local_llm");
    assert_eq!(
        output,
        vec![
            ModelProviderOutput::TextDelta("local ".into()),
            ModelProviderOutput::Completed("local answer".into()),
        ]
    );
}
