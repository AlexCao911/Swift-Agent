use local_ios_agent_runtime::core::StreamBatcher;

#[test]
fn stream_batcher_flushes_after_byte_threshold() {
    let mut batcher = StreamBatcher::new(5);

    assert_eq!(batcher.push("he"), None);
    assert_eq!(batcher.push("llo"), Some("hello".to_string()));
    assert_eq!(batcher.push("!"), None);
    assert_eq!(batcher.flush(), Some("!".to_string()));
}
