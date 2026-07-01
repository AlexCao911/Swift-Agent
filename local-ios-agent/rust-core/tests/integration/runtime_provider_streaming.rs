use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};

use local_ios_agent_runtime::context::{MockTokenizer, PromptFrame};
use local_ios_agent_runtime::core::{
    AgentError, AgentRuntime, AgentRuntimeConfig, CancellationToken, EventKind, ModelProvider,
    ModelProviderOutput, RunState, SendMessageInput, SessionId,
};

struct ProbeProvider {
    delta_was_observed_by_runtime: Arc<AtomicBool>,
}

impl ModelProvider for ProbeProvider {
    fn id(&self) -> &str {
        "probe"
    }

    fn stream_chat(
        &self,
        _frame: &PromptFrame,
        _cancellation: CancellationToken,
        on_output: &mut dyn FnMut(ModelProviderOutput) -> Result<(), AgentError>,
    ) -> Result<(), AgentError> {
        on_output(ModelProviderOutput::TextDelta(
            "streamed token chunk longer than threshold".into(),
        ))?;
        assert!(
            self.delta_was_observed_by_runtime.load(Ordering::SeqCst),
            "runtime must emit the text delta before provider stream_chat returns"
        );
        on_output(ModelProviderOutput::Completed(
            "streamed token chunk longer than threshold".into(),
        ))?;
        Ok(())
    }
}

#[test]
fn runtime_emits_provider_outputs_during_provider_callback() {
    let observed_delta = Arc::new(AtomicBool::new(false));
    let mut runtime = AgentRuntime::new(AgentRuntimeConfig {
        system_prompt: "system".into(),
        runtime_policy: "policy".into(),
        tool_schemas: Vec::new(),
        tokenizer: Box::new(MockTokenizer::new(100)),
        provider: Box::new(ProbeProvider {
            delta_was_observed_by_runtime: observed_delta.clone(),
        }),
        tool_router: None,
    });
    let session_id = runtime.create_session().unwrap();
    let mut streamed_kinds = Vec::new();

    let result = runtime
        .send_message_streaming(
            SendMessageInput {
                session_id: SessionId(session_id.0.clone()),
                parent_event_id: None,
                text: "hello".into(),
                blob_refs: Vec::new(),
            },
            &mut |event| {
                streamed_kinds.push(event.kind.clone());
                if event.kind == EventKind::AssistantTextDelta {
                    observed_delta.store(true, Ordering::SeqCst);
                }
                Ok(())
            },
        )
        .unwrap();

    assert_eq!(result.state, RunState::Completed);
    assert!(streamed_kinds.contains(&EventKind::AssistantTextDelta));
    assert!(streamed_kinds.contains(&EventKind::AssistantMessageCompleted));
}
