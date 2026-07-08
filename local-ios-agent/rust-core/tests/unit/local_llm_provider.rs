use local_ios_agent_runtime::context::{InferenceOptions, PromptFrame, PromptMessage};
use local_ios_agent_runtime::core::{
    CancellationToken, LocalLLMProvider, MockLocalInferenceBackend, ModelProvider,
    ModelProviderOutput,
};

#[cfg(feature = "link-mock-local-inference")]
use local_ios_agent_runtime::core::CAbiV2LocalInferenceBackend;

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
        inference_options: InferenceOptions::default(),
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

#[cfg(feature = "link-mock-local-inference")]
#[test]
fn local_llm_provider_can_use_linked_c_abi_v2_mock_engine() {
    let backend = CAbiV2LocalInferenceBackend::new("mock").unwrap();
    let provider = LocalLLMProvider::new(
        "mock.local",
        r#"{"engine":"mock","model_path":"/tmp/mock.local","model_format":"mock"}"#,
        Box::new(backend),
    );
    let frame = PromptFrame {
        system_prompt: "system".into(),
        runtime_policy: "policy".into(),
        tool_schemas: Vec::new(),
        inference_options: InferenceOptions::default(),
        messages: vec![PromptMessage::User("hello".into())],
    };

    let mut output = Vec::new();
    provider
        .stream_chat(&frame, CancellationToken::default(), &mut |event| {
            output.push(event);
            Ok(())
        })
        .unwrap();

    assert!(output.contains(&ModelProviderOutput::TextDelta("On-device ".into())));
    assert!(output.contains(&ModelProviderOutput::Completed(
        "On-device mock response".into()
    )));
}
