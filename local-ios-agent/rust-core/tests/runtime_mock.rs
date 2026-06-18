use std::sync::{Arc, Mutex};

use local_ios_agent_runtime::context::{MockTokenizer, PromptFrame, PromptMessage};
use local_ios_agent_runtime::core::{
    AgentError, AgentRuntime, AgentRuntimeConfig, CancellationToken, EventKind,
    MockStreamingProvider, ModelProvider, ModelProviderOutput, SendMessageInput,
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

    fn stream_chat(
        &self,
        frame: &PromptFrame,
        _cancellation: CancellationToken,
    ) -> Result<Vec<ModelProviderOutput>, AgentError> {
        self.frames.lock().unwrap().push(frame.clone());
        Ok(vec![ModelProviderOutput::Completed("captured".into())])
    }
}

#[derive(Debug)]
struct CaptureCancellationProvider {
    observed_states: Arc<Mutex<Vec<bool>>>,
}

impl CaptureCancellationProvider {
    fn new(observed_states: Arc<Mutex<Vec<bool>>>) -> Self {
        Self { observed_states }
    }
}

impl ModelProvider for CaptureCancellationProvider {
    fn id(&self) -> &str {
        "capture-cancellation"
    }

    fn stream_chat(
        &self,
        _frame: &PromptFrame,
        cancellation: CancellationToken,
    ) -> Result<Vec<ModelProviderOutput>, AgentError> {
        self.observed_states
            .lock()
            .unwrap()
            .push(cancellation.is_cancelled());
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
fn runtime_passes_cancellation_token_to_provider_calls() {
    let observed_states = Arc::new(Mutex::new(Vec::new()));
    let mut runtime = AgentRuntime::new(AgentRuntimeConfig {
        system_prompt: "system".to_string(),
        runtime_policy: "policy".to_string(),
        tool_schemas: Vec::new(),
        tokenizer: Box::new(MockTokenizer::new(100)),
        provider: Box::new(CaptureCancellationProvider::new(observed_states.clone())),
        tool_router: None,
    });

    let session_id = runtime.create_session().unwrap();
    runtime
        .send_message_turn(SendMessageInput {
            session_id,
            parent_event_id: None,
            text: "hello".to_string(),
        })
        .unwrap();

    assert_eq!(*observed_states.lock().unwrap(), vec![false]);
}

#[test]
fn runtime_captures_latest_prompt_debug_snapshot_at_provider_call() {
    let mut runtime = AgentRuntime::new(AgentRuntimeConfig {
        system_prompt: "system".to_string(),
        runtime_policy: "policy".to_string(),
        tool_schemas: Vec::new(),
        tokenizer: Box::new(MockTokenizer::new(100)),
        provider: Box::new(MockStreamingProvider::new()),
        tool_router: None,
    });

    assert_eq!(runtime.latest_prompt_debug_snapshot(), None);

    let session_id = runtime.create_session().unwrap();
    runtime
        .send_message_turn(SendMessageInput {
            session_id,
            parent_event_id: None,
            text: "hello".to_string(),
        })
        .unwrap();

    let snapshot = runtime.latest_prompt_debug_snapshot().unwrap();
    assert!(snapshot.rendered_text.contains("system\npolicy"));
    assert!(snapshot.rendered_text.contains("hello"));
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
