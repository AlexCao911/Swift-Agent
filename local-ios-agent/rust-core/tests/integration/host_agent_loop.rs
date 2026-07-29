use std::sync::Arc;
use std::thread;
use std::time::Duration;

use local_ios_agent_runtime::agent_input::ToolDefinitionSnapshot;
use local_ios_agent_runtime::agent_loop::{
    ModelEvent, ModelEventSink, ModelMessage, ModelRequest, ModelRuntime, ToolRuntime,
};
use local_ios_agent_runtime::host_adapter::{HostModelRuntime, HostToolRuntime};
use local_ios_agent_runtime::llm_contracts::{
    HostCommandAcknowledgement, HostCommandAcknowledgementDisposition, HostCommandKind,
    HostExecutionPhase, HostSessionRecord, HostToolBatchCompletion, HostToolResult,
    HostWorkerRecord, LLMBackendCompletionWire, LLMEventEnvelope, LLMEventKind, LLMEventPayload,
    LLMEventSubmissionResult, ResourceLifecycle,
};
use local_ios_agent_runtime::storage::{InMemoryRuntimeStateStore, UnifiedRuntimeStateRepository};
use local_ios_agent_runtime::tool::{AgentToolCall, ToolBatch};
use serde_json::json;

const RUN: &str = "run-host-adapter";
const SESSION: &str = "session-host-adapter";
const EPOCH: &str = "epoch-host-adapter";

#[test]
fn model_adapter_sends_one_v2_command_and_returns_one_streamed_turn() {
    let store = prepared_store(HostWorkerRecord::new(RUN, SESSION, EPOCH));
    let runtime = HostModelRuntime::new(store.clone()).with_poll_interval(Duration::from_millis(1));
    let host_store = store.clone();
    let host = thread::spawn(move || {
        let command = wait_for_command(&host_store, HostCommandKind::StartGeneration);
        assert_eq!(command.schema_version, 2);
        acknowledge(&host_store, &command);
        let turn_id = command.generation_turn_id.clone().unwrap();
        let worker =
            local_ios_agent_runtime::execution::HostLLMWorkerService::new(host_store.clone());
        submit(
            &worker,
            event(
                1,
                &turn_id,
                LLMEventKind::GenerationStarted,
                LLMEventPayload::default(),
            ),
        );
        let text = event(
            2,
            &turn_id,
            LLMEventKind::TextDelta,
            LLMEventPayload {
                text: Some("hello".into()),
                ..Default::default()
            },
        );
        submit(&worker, text.clone());
        assert_eq!(
            worker.submit_event(&text).unwrap(),
            LLMEventSubmissionResult::Duplicate
        );
        submit(
            &worker,
            event(
                3,
                &turn_id,
                LLMEventKind::GenerationCompleted,
                LLMEventPayload {
                    completion: Some(LLMBackendCompletionWire {
                        outcome: "final_response".into(),
                        ordered_call_ids: Vec::new(),
                        finish_reason: "stop".into(),
                    }),
                    ..Default::default()
                },
            ),
        );
    });

    let mut sink = RecordingSink::default();
    let turn = runtime.generate(model_request(), &mut sink).unwrap();
    host.join().unwrap();

    assert_eq!(turn.text, "hello");
    assert!(turn.tool_calls.is_empty());
    assert_eq!(
        sink.events,
        vec![ModelEvent::TextDelta {
            text: "hello".into()
        }]
    );
}

#[test]
fn tool_adapter_sends_one_batch_and_waits_for_the_matching_ordered_completion() {
    let worker = HostWorkerRecord::new(RUN, SESSION, EPOCH)
        .with_execution_phase(Some(HostExecutionPhase::ExecutingToolBatch))
        .with_resource_lifecycle(ResourceLifecycle::Generating)
        .with_generation_turn_id(Some("turn-tool".into()));
    let store = prepared_store(worker);
    let runtime = HostToolRuntime::new(store.clone()).with_poll_interval(Duration::from_millis(1));
    let host_store = store.clone();
    let host = thread::spawn(move || {
        let command = wait_for_command(&host_store, HostCommandKind::ExecuteToolBatch);
        let batch = command.payload.tool_batch.clone().unwrap();
        acknowledge(&host_store, &command);
        let worker =
            local_ios_agent_runtime::execution::HostLLMWorkerService::new(host_store.clone());
        submit(
            &worker,
            event(
                1,
                "turn-tool",
                LLMEventKind::ToolBatchStarted,
                LLMEventPayload::default(),
            ),
        );
        submit(
            &worker,
            event(
                2,
                "turn-tool",
                LLMEventKind::ToolBatchCompleted,
                LLMEventPayload {
                    tool_batch_completion: Some(HostToolBatchCompletion {
                        batch_id: batch.batch_id,
                        run_id: RUN.into(),
                        ordered_results: vec![HostToolResult {
                            call_id: "call-1".into(),
                            tool_name: "shell".into(),
                            result: json!({"stdout": "ok"}),
                            is_error: false,
                            data_classes: Vec::new(),
                            highest_sensitivity: "public".into(),
                        }],
                    }),
                    ..Default::default()
                },
            ),
        );
    });

    let result = runtime
        .execute_batch(ToolBatch {
            batch_id: "batch-1".into(),
            run_id: RUN.into(),
            ordered_calls: vec![AgentToolCall {
                call_id: "call-1".into(),
                tool_name: "shell".into(),
                arguments_json: "{}".into(),
            }],
        })
        .unwrap();
    host.join().unwrap();

    assert_eq!(result.batch_id, "batch-1");
    assert_eq!(result.run_id, RUN);
    assert_eq!(result.ordered_results[0].tool_name, "shell");
}

#[test]
fn model_and_tool_cancellation_emit_distinct_commands() {
    let model_store = prepared_store(HostWorkerRecord::new(RUN, SESSION, EPOCH));
    let model_runtime = Arc::new(
        HostModelRuntime::new(model_store.clone()).with_poll_interval(Duration::from_millis(1)),
    );
    let model_host_store = model_store.clone();
    let (model_ready_tx, model_ready_rx) = std::sync::mpsc::channel();
    let model_host = thread::spawn(move || {
        let start = wait_for_command(&model_host_store, HostCommandKind::StartGeneration);
        acknowledge(&model_host_store, &start);
        let turn_id = start.generation_turn_id.clone().unwrap();
        let worker =
            local_ios_agent_runtime::execution::HostLLMWorkerService::new(model_host_store.clone());
        submit(
            &worker,
            event(
                1,
                &turn_id,
                LLMEventKind::GenerationStarted,
                LLMEventPayload::default(),
            ),
        );
        model_ready_tx.send(()).unwrap();
        let cancel = wait_for_command(&model_host_store, HostCommandKind::CancelGeneration);
        assert_eq!(cancel.schema_version, 2);
        acknowledge(&model_host_store, &cancel);
        submit(
            &worker,
            event(
                2,
                &turn_id,
                LLMEventKind::Cancelled,
                LLMEventPayload {
                    command_id: Some(cancel.command_id.clone()),
                    ..Default::default()
                },
            ),
        );
    });
    let generation_runtime = model_runtime.clone();
    let generation = thread::spawn(move || {
        generation_runtime.generate(model_request(), &mut RecordingSink::default())
    });
    model_ready_rx.recv().unwrap();
    model_runtime.cancel(RUN).unwrap();
    assert_eq!(
        generation.join().unwrap().unwrap_err().code(),
        "agent_loop.cancelled"
    );
    model_host.join().unwrap();

    let tool_worker = HostWorkerRecord::new(RUN, SESSION, EPOCH)
        .with_execution_phase(Some(HostExecutionPhase::ExecutingToolBatch))
        .with_resource_lifecycle(ResourceLifecycle::Generating)
        .with_generation_turn_id(Some("turn-tool".into()));
    let tool_store = prepared_store(tool_worker);
    let tool_runtime = Arc::new(
        HostToolRuntime::new(tool_store.clone()).with_poll_interval(Duration::from_millis(1)),
    );
    let tool_host_store = tool_store.clone();
    let (tool_ready_tx, tool_ready_rx) = std::sync::mpsc::channel();
    let tool_host = thread::spawn(move || {
        let execute = wait_for_command(&tool_host_store, HostCommandKind::ExecuteToolBatch);
        acknowledge(&tool_host_store, &execute);
        tool_ready_tx.send(()).unwrap();
        let cancel = wait_for_command(&tool_host_store, HostCommandKind::CancelToolBatch);
        assert_eq!(
            cancel.payload.target_batch_id.as_deref(),
            Some("batch-cancel")
        );
        acknowledge(&tool_host_store, &cancel);
        let worker =
            local_ios_agent_runtime::execution::HostLLMWorkerService::new(tool_host_store.clone());
        submit(
            &worker,
            event(
                1,
                "turn-tool",
                LLMEventKind::ToolBatchFailed,
                LLMEventPayload {
                    failure_code: Some("cancelled".into()),
                    ..Default::default()
                },
            ),
        );
    });
    let execution_runtime = tool_runtime.clone();
    let execution = thread::spawn(move || {
        execution_runtime.execute_batch(ToolBatch {
            batch_id: "batch-cancel".into(),
            run_id: RUN.into(),
            ordered_calls: vec![AgentToolCall {
                call_id: "call-1".into(),
                tool_name: "shell".into(),
                arguments_json: "{}".into(),
            }],
        })
    });
    tool_ready_rx.recv().unwrap();
    tool_runtime.cancel_batch("batch-cancel").unwrap();
    assert_eq!(execution.join().unwrap().unwrap_err().code(), "cancelled");
    tool_host.join().unwrap();
}

#[test]
fn close_is_enqueued_once_after_a_direct_model_turn() {
    let store = prepared_store(HostWorkerRecord::new(RUN, SESSION, EPOCH));
    let runtime = HostModelRuntime::new(store.clone()).with_poll_interval(Duration::from_millis(1));
    let host_store = store.clone();
    let host = thread::spawn(move || {
        let command = wait_for_command(&host_store, HostCommandKind::StartGeneration);
        acknowledge(&host_store, &command);
        let turn_id = command.generation_turn_id.clone().unwrap();
        let worker =
            local_ios_agent_runtime::execution::HostLLMWorkerService::new(host_store.clone());
        submit(
            &worker,
            event(
                1,
                &turn_id,
                LLMEventKind::GenerationStarted,
                LLMEventPayload::default(),
            ),
        );
        submit(
            &worker,
            event(
                2,
                &turn_id,
                LLMEventKind::GenerationCompleted,
                LLMEventPayload {
                    completion: Some(LLMBackendCompletionWire {
                        outcome: "final_response".into(),
                        ordered_call_ids: Vec::new(),
                        finish_reason: "stop".into(),
                    }),
                    ..Default::default()
                },
            ),
        );
    });
    runtime
        .generate(model_request(), &mut RecordingSink::default())
        .unwrap();
    host.join().unwrap();

    runtime.close(RUN).unwrap();
    runtime.close(RUN).unwrap();
    assert_eq!(
        store
            .pending_host_commands()
            .unwrap()
            .into_iter()
            .filter_map(|row| row.payload().cloned())
            .filter(|command| command.kind() == HostCommandKind::CloseSession)
            .count(),
        1
    );
}

fn prepared_store(worker: HostWorkerRecord) -> Arc<InMemoryRuntimeStateStore> {
    let store = Arc::new(InMemoryRuntimeStateStore::new());
    store
        .insert_worker_and_session(
            worker,
            HostSessionRecord::new(
                RUN,
                SESSION,
                EPOCH,
                "binding",
                1,
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            ),
        )
        .unwrap();
    store
}

fn wait_for_command(
    store: &InMemoryRuntimeStateStore,
    kind: HostCommandKind,
) -> local_ios_agent_runtime::llm_contracts::HostCommandEnvelope {
    for _ in 0..1_000 {
        if let Some(command) = store
            .pending_host_commands()
            .unwrap()
            .into_iter()
            .filter_map(|row| row.payload().cloned())
            .find(|command| command.kind() == kind)
        {
            return command;
        }
        thread::sleep(Duration::from_millis(1));
    }
    panic!("command was not enqueued");
}

fn acknowledge(
    store: &InMemoryRuntimeStateStore,
    command: &local_ios_agent_runtime::llm_contracts::HostCommandEnvelope,
) {
    store
        .acknowledge_command(&HostCommandAcknowledgement {
            command_id: command.command_id.clone(),
            session_handle: command.session_handle.clone(),
            command_sequence: command.command_sequence,
            command_envelope_digest: command.command_envelope_digest.clone(),
            disposition: HostCommandAcknowledgementDisposition::Accepted,
            rejection_code: None,
        })
        .unwrap();
}

fn submit(
    worker: &local_ios_agent_runtime::execution::HostLLMWorkerService<InMemoryRuntimeStateStore>,
    event: LLMEventEnvelope,
) {
    assert_eq!(
        worker.submit_event(&event).unwrap(),
        LLMEventSubmissionResult::Accepted
    );
}

fn event(
    sequence: u64,
    turn_id: &str,
    kind: LLMEventKind,
    payload: LLMEventPayload,
) -> LLMEventEnvelope {
    let mut event = LLMEventEnvelope {
        schema_version: if matches!(
            kind,
            LLMEventKind::ToolBatchStarted
                | LLMEventKind::ToolBatchCompleted
                | LLMEventKind::ToolBatchFailed
        ) {
            2
        } else {
            1
        },
        event_id: format!("event-{sequence}"),
        run_id: RUN.into(),
        session_handle: SESSION.into(),
        host_process_epoch: EPOCH.into(),
        generation_turn_id: Some(turn_id.into()),
        event_sequence: sequence,
        kind,
        payload,
        event_envelope_digest: String::new(),
    };
    event.event_envelope_digest = event.expected_digest().unwrap();
    event
}

fn model_request() -> ModelRequest {
    ModelRequest {
        run_id: RUN.into(),
        conversation_stream_id: "conversation-1".into(),
        system_prompt: "system".into(),
        ordered_messages: vec![ModelMessage {
            role: "user".into(),
            content: json!("hello"),
        }],
        attachment_references: Vec::new(),
        ordered_tool_definitions: vec![ToolDefinitionSnapshot {
            name: "shell".into(),
            description: "run a command".into(),
            input_schema: json!({"type": "object"}),
        }],
        ordered_tool_results: Vec::new(),
        purpose: local_ios_agent_runtime::agent_loop::ModelRequestPurpose::Generation,
    }
}

#[derive(Default)]
struct RecordingSink {
    events: Vec<ModelEvent>,
}

impl ModelEventSink for RecordingSink {
    fn emit(
        &mut self,
        event: ModelEvent,
    ) -> Result<(), local_ios_agent_runtime::agent_loop::AgentLoopError> {
        self.events.push(event);
        Ok(())
    }
}
