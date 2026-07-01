use local_ios_agent_runtime::core::AgentError;
use local_ios_agent_runtime::tool::ToolCallParser;

#[test]
fn parser_reads_structured_tool_call_json() {
    let call = ToolCallParser::new()
        .parse(r#"{"id":"call_1","name":"calendar.search_events","arguments":{"query":"today"}}"#)
        .unwrap();

    assert_eq!(call.id, "call_1");
    assert_eq!(call.name, "calendar.search_events");
    assert_eq!(call.arguments_json, r#"{"query":"today"}"#);
}

#[test]
fn parser_rejects_missing_tool_name() {
    let error = ToolCallParser::new()
        .parse(r#"{"id":"call_1","arguments":{}}"#)
        .unwrap_err();

    assert!(matches!(error, AgentError::ToolParse(_)));
}

#[test]
fn parser_rejects_missing_tool_call_id() {
    let error = ToolCallParser::new()
        .parse(r#"{"name":"calendar.search_events","arguments":{}}"#)
        .unwrap_err();

    assert!(matches!(error, AgentError::ToolParse(_)));
}

#[test]
fn parser_rejects_missing_arguments() {
    let error = ToolCallParser::new()
        .parse(r#"{"id":"call_1","name":"calendar.search_events"}"#)
        .unwrap_err();

    assert!(matches!(error, AgentError::ToolParse(_)));
}

#[test]
fn parser_rejects_non_object_arguments() {
    let error = ToolCallParser::new()
        .parse(r#"{"id":"call_1","name":"calendar.search_events","arguments":null}"#)
        .unwrap_err();

    assert!(matches!(error, AgentError::ToolParse(_)));
}
