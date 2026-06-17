use std::collections::HashMap;

use crate::context::{ContextController, TokenizerAdapter};
use crate::core::{
    AgentError, EntryId, EventKind, ModelProvider, ModelProviderOutput, RunId, RuntimeEvent,
    SessionId, SessionTree, StreamBatcher,
};
use crate::utils::id::IdGenerator;

pub struct AgentRuntimeConfig {
    pub system_prompt: String,
    pub runtime_policy: String,
    pub tool_schemas: Vec<String>,
    pub tokenizer: Box<dyn TokenizerAdapter>,
    pub provider: Box<dyn ModelProvider>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SendMessageInput {
    pub session_id: SessionId,
    pub parent_event_id: Option<EntryId>,
    pub text: String,
}

pub struct AgentRuntime {
    config: AgentRuntimeConfig,
    ids: IdGenerator,
    sessions: HashMap<SessionId, SessionTree>,
}

impl AgentRuntime {
    pub fn new(config: AgentRuntimeConfig) -> Self {
        Self {
            config,
            ids: IdGenerator::new(),
            sessions: HashMap::new(),
        }
    }

    pub fn create_session(&mut self) -> Result<SessionId, AgentError> {
        let session_id = SessionId(self.ids.next_id("session"));
        let mut tree = SessionTree::new(session_id.clone());
        tree.append(None, EventKind::SessionCreated, "session created")?;
        self.sessions.insert(session_id.clone(), tree);
        Ok(session_id)
    }

    pub fn send_message(
        &mut self,
        input: SendMessageInput,
    ) -> Result<Vec<RuntimeEvent>, AgentError> {
        let run_id = RunId(self.ids.next_id("run"));
        let tree = self.sessions.get_mut(&input.session_id).ok_or_else(|| {
            AgentError::Storage(format!("missing session: {}", input.session_id.0))
        })?;

        let parent_id = input
            .parent_event_id
            .clone()
            .or_else(|| tree.active_leaf().cloned());
        let user_id = tree.append(parent_id, EventKind::UserMessage, input.text)?;
        let branch = tree.active_branch(&user_id)?;

        let context = ContextController::new(
            self.config.system_prompt.clone(),
            self.config.runtime_policy.clone(),
            self.config.tool_schemas.clone(),
            self.config.tokenizer.boxed_clone(),
        );
        let frame = context.build_prompt_frame(branch)?;

        let mut emitted = Vec::new();
        emitted.push(
            tree.active_branch(&user_id)?
                .last()
                .cloned()
                .ok_or_else(|| {
                    AgentError::Storage("missing just-appended user event".to_string())
                })?,
        );

        let assistant_start = tree.append(
            Some(user_id.clone()),
            EventKind::AssistantMessageStarted,
            format!("run {}", run_id.0),
        )?;
        emitted.push(
            tree.active_branch(&assistant_start)?
                .last()
                .cloned()
                .ok_or_else(|| AgentError::Storage("missing assistant start event".to_string()))?,
        );

        let mut batcher = StreamBatcher::new(24);
        let provider_events = self.config.provider.stream_chat(&frame)?;
        let mut parent = assistant_start;

        for provider_event in provider_events {
            match provider_event {
                ModelProviderOutput::TextDelta(delta) => {
                    if let Some(chunk) = batcher.push(&delta) {
                        let delta_id = tree.append(
                            Some(parent.clone()),
                            EventKind::AssistantTextDelta,
                            chunk,
                        )?;
                        parent = delta_id.clone();
                        emitted.push(tree.active_branch(&delta_id)?.last().cloned().ok_or_else(
                            || AgentError::Storage("missing assistant delta event".to_string()),
                        )?);
                    }
                }
                ModelProviderOutput::ToolCall(_) => {}
                ModelProviderOutput::Completed(completed) => {
                    if let Some(chunk) = batcher.flush() {
                        let delta_id = tree.append(
                            Some(parent.clone()),
                            EventKind::AssistantTextDelta,
                            chunk,
                        )?;
                        parent = delta_id.clone();
                        emitted.push(tree.active_branch(&delta_id)?.last().cloned().ok_or_else(
                            || AgentError::Storage("missing assistant delta event".to_string()),
                        )?);
                    }
                    let completed_id = tree.append(
                        Some(parent.clone()),
                        EventKind::AssistantMessageCompleted,
                        completed,
                    )?;
                    emitted.push(
                        tree.active_branch(&completed_id)?
                            .last()
                            .cloned()
                            .ok_or_else(|| {
                                AgentError::Storage("missing assistant completed event".to_string())
                            })?,
                    );
                }
            }
        }

        Ok(emitted)
    }
}
