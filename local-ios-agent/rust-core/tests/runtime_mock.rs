use std::sync::{Arc, Mutex};

use local_ios_agent_runtime::context::{MockTokenizer, PromptFrame, PromptMessage};
use local_ios_agent_runtime::core::{
    AgentError, AgentRuntime, AgentRuntimeConfig, EventKind, MockStreamingProvider, ModelProvider,
    ModelProviderOutput, SendMessageInput,
};

#[derive(Debug)]
struct CaptureFramesProvider {
    frames: Arc<Mutex<Vec<PromptFrame>>>,
}

impl CaptureFramesProvider {
    fn new(frames: Arc<Mutex<Vec<PromptFrame>>>) -> Self {
        Self { frames }
    }
}

impl ModelProvider for CaptureFramesProvider {
    fn id(&self) -> &str {
        "capture-frames"
    }

    fn stream_chat(&self, frame: &PromptFrame) -> Result<Vec<ModelProviderOutput>, AgentError> {
        self.frames.lock().unwrap().push(frame.clone());
        Ok(vec![ModelProviderOutput::Completed("captured".into())])
    }
}

#[test]
fn runtime_streams_mock_response_and_persists_events() {
    let mut runtime = AgentRuntime::new(AgentRuntimeConfig {
        system_prompt: "system".to_string(),
        runtime_policy: "policy".to_string(),
        tool_schemas: Vec::new(),
        tokenizer: Box::new(MockTokenizer::new(100)),
        provider: Box::new(MockStreamingProvider::new()),
        tool_router: None,
    });

    let session_id = runtime.create_session().unwrap();
    let events = runtime
        .send_message(SendMessageInput {
            session_id,
            parent_event_id: None,
            text: "hello".to_string(),
        })
        .unwrap();

    assert!(events
        .iter()
        .any(|event| event.kind == EventKind::UserMessage));
    assert!(events
        .iter()
        .any(|event| event.kind == EventKind::AssistantTextDelta));
    assert!(events
        .iter()
        .any(|event| event.kind == EventKind::AssistantMessageCompleted));
}

#[test]
fn runtime_persists_compaction_events_when_context_exceeds_budget() {
    let mut runtime = AgentRuntime::new(AgentRuntimeConfig {
        system_prompt: "system".to_string(),
        runtime_policy: "policy".to_string(),
        tool_schemas: Vec::new(),
        tokenizer: Box::new(MockTokenizer::new(13)),
        provider: Box::new(MockStreamingProvider::new()),
        tool_router: None,
    });

    let session_id = runtime.create_session().unwrap();
    runtime
        .send_message(SendMessageInput {
            session_id: session_id.clone(),
            parent_event_id: None,
            text: "first turn".to_string(),
        })
        .unwrap();

    let events = runtime
        .send_message(SendMessageInput {
            session_id,
            parent_event_id: None,
            text: "second turn".to_string(),
        })
        .unwrap();

    assert!(events
        .iter()
        .any(|event| event.kind == EventKind::CompactionCreated));
    assert!(events
        .iter()
        .any(|event| event.kind == EventKind::BranchSummaryCreated));
    assert!(events
        .iter()
        .any(|event| event.kind == EventKind::AssistantMessageCompleted));
}

#[test]
fn compaction_keeps_current_user_message_last_in_provider_prompt() {
    let frames = Arc::new(Mutex::new(Vec::new()));
    let mut runtime = AgentRuntime::new(AgentRuntimeConfig {
        system_prompt: "system".to_string(),
        runtime_policy: "policy".to_string(),
        tool_schemas: Vec::new(),
        tokenizer: Box::new(MockTokenizer::new(13)),
        provider: Box::new(CaptureFramesProvider::new(frames.clone())),
        tool_router: None,
    });

    let session_id = runtime.create_session().unwrap();
    runtime
        .send_message(SendMessageInput {
            session_id: session_id.clone(),
            parent_event_id: None,
            text: "first turn".to_string(),
        })
        .unwrap();
    runtime
        .send_message(SendMessageInput {
            session_id,
            parent_event_id: None,
            text: "second turn".to_string(),
        })
        .unwrap();

    let frames = frames.lock().unwrap();
    let second_frame = frames.last().unwrap();

    assert_eq!(
        second_frame.messages.last(),
        Some(&PromptMessage::User("second turn".into()))
    );
    assert!(!matches!(
        second_frame.messages.last(),
        Some(PromptMessage::Summary(_))
    ));
}

#[test]
fn repeated_compaction_preserves_existing_summary_in_new_summary_snapshot() {
    let mut runtime = AgentRuntime::new(AgentRuntimeConfig {
        system_prompt: "system".to_string(),
        runtime_policy: "policy".to_string(),
        tool_schemas: Vec::new(),
        tokenizer: Box::new(MockTokenizer::new(13)),
        provider: Box::new(MockStreamingProvider::new()),
        tool_router: None,
    });

    let session_id = runtime.create_session().unwrap();
    runtime
        .send_message(SendMessageInput {
            session_id: session_id.clone(),
            parent_event_id: None,
            text: "first turn".to_string(),
        })
        .unwrap();
    let second_events = runtime
        .send_message(SendMessageInput {
            session_id: session_id.clone(),
            parent_event_id: None,
            text: "second turn".to_string(),
        })
        .unwrap();
    let third_events = runtime
        .send_message(SendMessageInput {
            session_id,
            parent_event_id: None,
            text: "third turn".to_string(),
        })
        .unwrap();

    assert!(second_events
        .iter()
        .any(|event| event.kind == EventKind::BranchSummaryCreated));
    let second_summary = second_events
        .iter()
        .find(|event| event.kind == EventKind::BranchSummaryCreated)
        .unwrap()
        .payload
        .clone();
    let third_summary = third_events
        .iter()
        .find(|event| event.kind == EventKind::BranchSummaryCreated)
        .unwrap()
        .payload
        .clone();

    assert!(third_summary.contains("second turn"));
    assert!(third_summary.contains(&second_summary));
}
