use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use local_ios_agent_runtime::context::{
    MockTokenizer, PromptFrame, PromptMessage, TokenizerAdapter,
};
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
        on_output: &mut dyn FnMut(ModelProviderOutput) -> Result<(), AgentError>,
    ) -> Result<(), AgentError> {
        self.frames.lock().unwrap().push(frame.clone());
        on_output(ModelProviderOutput::Completed("captured".into()))?;
        Ok(())
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
        on_output: &mut dyn FnMut(ModelProviderOutput) -> Result<(), AgentError>,
    ) -> Result<(), AgentError> {
        self.observed_states
            .lock()
            .unwrap()
            .push(cancellation.is_cancelled());
        on_output(ModelProviderOutput::Completed("captured".into()))?;
        Ok(())
    }
}

#[derive(Clone, Debug)]
struct CountingCloneTokenizer {
    clone_count: Arc<AtomicUsize>,
    max_context_tokens: usize,
}

impl TokenizerAdapter for CountingCloneTokenizer {
    fn provider_id(&self) -> &str {
        "counting"
    }

    fn max_context_tokens(&self) -> usize {
        self.max_context_tokens
    }

    fn safety_margin_tokens(&self) -> usize {
        0
    }

    fn count_text(&self, text: &str) -> usize {
        text.split_whitespace().count()
    }

    fn count_prompt_frame(&self, frame: &PromptFrame) -> usize {
        self.count_text(&frame.system_prompt)
            + self.count_text(&frame.runtime_policy)
            + frame
                .tool_schemas
                .iter()
                .map(|tool| self.count_text(tool))
                .sum::<usize>()
            + frame
                .messages
                .iter()
                .map(|message| self.count_text(message.content()))
                .sum::<usize>()
    }

    fn boxed_clone(&self) -> Box<dyn TokenizerAdapter> {
        self.clone_count.fetch_add(1, Ordering::SeqCst);
        Box::new(self.clone())
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
            blob_refs: Vec::new(),
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
fn runtime_reuses_context_controller_between_turns() {
    let clone_count = Arc::new(AtomicUsize::new(0));
    let mut runtime = AgentRuntime::new(AgentRuntimeConfig {
        system_prompt: "system".to_string(),
        runtime_policy: "policy".to_string(),
        tool_schemas: Vec::new(),
        tokenizer: Box::new(CountingCloneTokenizer {
            clone_count: clone_count.clone(),
            max_context_tokens: 100,
        }),
        provider: Box::new(MockStreamingProvider::new()),
        tool_router: None,
    });

    let session_id = runtime.create_session().unwrap();
    runtime
        .send_message_turn(SendMessageInput {
            session_id: session_id.clone(),
            parent_event_id: None,
            text: "first".to_string(),
            blob_refs: Vec::new(),
        })
        .unwrap();
    runtime
        .send_message_turn(SendMessageInput {
            session_id,
            parent_event_id: None,
            text: "second".to_string(),
            blob_refs: Vec::new(),
        })
        .unwrap();

    assert_eq!(clone_count.load(Ordering::SeqCst), 1);
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
            blob_refs: Vec::new(),
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
            blob_refs: Vec::new(),
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
            blob_refs: Vec::new(),
        })
        .unwrap();

    let events = runtime
        .send_message(SendMessageInput {
            session_id,
            parent_event_id: None,
            text: "second turn".to_string(),
            blob_refs: Vec::new(),
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
            blob_refs: Vec::new(),
        })
        .unwrap();
    runtime
        .send_message(SendMessageInput {
            session_id,
            parent_event_id: None,
            text: "second turn".to_string(),
            blob_refs: Vec::new(),
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
            blob_refs: Vec::new(),
        })
        .unwrap();
    let second_events = runtime
        .send_message(SendMessageInput {
            session_id: session_id.clone(),
            parent_event_id: None,
            text: "second turn".to_string(),
            blob_refs: Vec::new(),
        })
        .unwrap();
    let third_events = runtime
        .send_message(SendMessageInput {
            session_id,
            parent_event_id: None,
            text: "third turn".to_string(),
            blob_refs: Vec::new(),
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
