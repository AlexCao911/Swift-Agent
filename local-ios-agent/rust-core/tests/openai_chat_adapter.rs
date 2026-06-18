use local_ios_agent_runtime::context::{PromptFrame, PromptMessage};
use local_ios_agent_runtime::core::{
    build_openai_chat_request, parse_openai_chat_response, ModelProviderOutput,
};
use serde_json::json;

#[test]
fn openai_chat_request_maps_prompt_frame_to_text_chat_messages() {
    let frame = PromptFrame {
        system_prompt: "system".into(),
        runtime_policy: "policy".into(),
        tool_schemas: vec!["debug.echo".into()],
        messages: vec![
            PromptMessage::User("hello".into()),
            PromptMessage::Assistant("hi".into()),
            PromptMessage::ToolResult("tool said ok".into()),
        ],
    };

    let request = build_openai_chat_request("minicpm", &frame);

    assert_eq!(request["model"], "minicpm");
    assert_eq!(request["stream"], false);
    assert_eq!(request["messages"][0]["role"], "system");
    assert!(request["messages"][0]["content"]
        .as_str()
        .unwrap()
        .contains("system\npolicy"));
    assert!(request["messages"][0]["content"]
        .as_str()
        .unwrap()
        .contains("debug.echo"));
    assert_eq!(
        request["messages"][1],
        json!({"role": "user", "content": "hello"})
    );
    assert_eq!(
        request["messages"][2],
        json!({"role": "assistant", "content": "hi"})
    );
    assert_eq!(
        request["messages"][3],
        json!({"role": "user", "content": "Tool result:\ntool said ok"})
    );
}

#[test]
fn openai_chat_response_parser_returns_completed_text() {
    let output = parse_openai_chat_response(
        r#"{"choices":[{"message":{"role":"assistant","content":"hello back"}}]}"#,
    )
    .unwrap();

    assert_eq!(
        output,
        vec![ModelProviderOutput::Completed("hello back".into())]
    );
}

#[test]
fn openai_chat_response_parser_rejects_missing_content() {
    let error = parse_openai_chat_response(r#"{"choices":[{"message":{"role":"assistant"}}]}"#)
        .unwrap_err();

    assert!(error.to_string().contains("missing assistant content"));
}
