use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex, Weak};
use std::thread;

use local_ios_agent_runtime::{
    agent_input::{
        PromptDocumentSnapshot, RunStartSnapshot, SkillDescriptor, ToolDefinitionSnapshot,
    },
    agent_loop::{
        AgentLoopError, AgentLoopOutcome, AgentLoopService, AgentRunRequest, AssistantTurn,
        ModelEvent, ModelEventSink, ModelRequest, ModelRequestPurpose, ModelRuntime, ToolBatch,
        ToolBatchResult, ToolCall, ToolCallResult, ToolRuntime, MAX_MODEL_TURNS,
    },
    context::ModelContextWindow,
    conversation::{
        ActiveRunRegistry, ConversationCommandService, ProjectionSubscriptionRegistry,
        TranscriptCommand,
    },
    core::{EntryId, EventKind, RunId, RuntimeEvent, SessionId},
    storage::{ConversationEventStore, InMemoryConversationStore},
};
use serde_json::json;

#[test]
fn text_only_turn_commits_once_and_closes_the_model() {
    let model = Arc::new(ScriptedModel::new(vec![Ok(final_turn("done"))]));
    let tools = Arc::new(RecordingTools::default());
    let setup = make_setup(model.clone(), tools.clone());
    let mut sink = RecordingSink::default();

    let outcome = setup.service.run(setup.request, &mut sink).unwrap();

    assert_eq!(outcome, AgentLoopOutcome::Completed);
    assert_eq!(model.calls.load(Ordering::SeqCst), 1);
    assert_eq!(model.closes.load(Ordering::SeqCst), 1);
    assert_eq!(tools.calls.load(Ordering::SeqCst), 0);
    assert_eq!(
        event_kinds(&setup.store),
        vec![
            EventKind::UserMessage,
            EventKind::AssistantMessageStarted,
            EventKind::AssistantMessageCompleted,
        ]
    );
}

#[test]
fn two_tool_batch_is_ordered_and_the_next_model_turn_sees_results() {
    let model = Arc::new(ScriptedModel::new(vec![
        Ok(tool_turn(vec![
            call("call-1", "file_read"),
            call("call-2", "shell_execute"),
        ])),
        Ok(final_turn("finished")),
    ]));
    let tools = Arc::new(RecordingTools::default());
    let setup = make_setup(model.clone(), tools.clone());
    let mut sink = RecordingSink::default();

    setup.service.run(setup.request, &mut sink).unwrap();

    let batches = tools.batches.lock().unwrap();
    assert_eq!(batches.len(), 1);
    assert_eq!(batches[0].ordered_calls[0].call_id, "call-1");
    assert_eq!(batches[0].ordered_calls[1].call_id, "call-2");
    let requests = model.requests.lock().unwrap();
    assert_eq!(requests.len(), 2);
    let second_text = requests[1]
        .ordered_messages
        .iter()
        .map(|message| message.content.to_string())
        .collect::<Vec<_>>()
        .join("\n");
    assert!(second_text.contains("call-1"));
    assert!(second_text.contains("call-2"));
    assert_eq!(model.closes.load(Ordering::SeqCst), 1);
}

#[test]
fn context_at_seventy_percent_is_compacted_by_the_current_model() {
    let model = Arc::new(ScriptedModel::new(vec![
        Ok(final_turn("Earlier work was summarized.")),
        Ok(final_turn("done")),
    ]));
    let tools = Arc::new(RecordingTools::default());
    let setup = make_setup_with_snapshot(
        model.clone(),
        tools,
        snapshot_with_window(ModelContextWindow {
            context_window_tokens: 240,
            max_output_tokens: 40,
        }),
    );
    {
        let mut store = setup.store.lock().unwrap();
        let mut parent = store
            .last_event(&SessionId("conversation-1".into()))
            .unwrap()
            .unwrap();
        for index in 0..4 {
            let event = RuntimeEvent::new(
                EntryId(format!("historical-{index}")),
                SessionId("conversation-1".into()),
                Some(parent.id.clone()),
                None,
                0,
                parent.depth + 1,
                EventKind::AssistantMessageCompleted,
                format!("historical detail {index}: {}", "large ".repeat(80)),
            );
            store
                .append_transaction("conversation-1", parent.sequence + 1, vec![event])
                .unwrap();
            parent = store
                .last_event(&SessionId("conversation-1".into()))
                .unwrap()
                .unwrap();
        }
    }

    setup
        .service
        .run(setup.request, &mut RecordingSink::default())
        .unwrap();

    let requests = model.requests.lock().unwrap();
    assert_eq!(requests.len(), 2);
    assert_eq!(requests[0].purpose, ModelRequestPurpose::Compaction);
    assert!(requests[0].ordered_tool_definitions.is_empty());
    assert_eq!(requests[1].purpose, ModelRequestPurpose::Generation);
    let normal_context = requests[1]
        .ordered_messages
        .iter()
        .map(|message| message.content.to_string())
        .collect::<Vec<_>>()
        .join("\n");
    assert!(normal_context.contains("Earlier work was summarized."));
    assert!(normal_context.contains("hello"));

    let events = setup
        .store
        .lock()
        .unwrap()
        .events_after(&SessionId("conversation-1".into()), 0)
        .unwrap();
    assert_eq!(
        events
            .iter()
            .filter(|event| event.id.0.starts_with("historical-"))
            .count(),
        4
    );
    assert_eq!(
        events
            .iter()
            .filter(|event| event.kind == EventKind::BranchSummaryCreated)
            .count(),
        1
    );
}

#[test]
fn tool_failure_or_identity_mismatch_leaves_no_half_round() {
    let model = Arc::new(ScriptedModel::new(vec![Ok(tool_turn(vec![call(
        "call-1",
        "file_read",
    )]))]));
    let tools = Arc::new(RecordingTools {
        fail: AtomicBool::new(true),
        ..Default::default()
    });
    let first_setup = make_setup(model, tools);
    let mut sink = RecordingSink::default();

    assert!(first_setup
        .service
        .run(first_setup.request, &mut sink)
        .is_err());
    assert_no_persisted_tool_round(&first_setup.store);

    let model = Arc::new(ScriptedModel::new(vec![Ok(tool_turn(vec![call(
        "call-1",
        "file_read",
    )]))]));
    let tools = Arc::new(RecordingTools {
        wrong_identity: AtomicBool::new(true),
        ..Default::default()
    });
    let second_setup = make_setup(model, tools);
    assert!(second_setup
        .service
        .run(second_setup.request, &mut RecordingSink::default())
        .is_err());
    assert_no_persisted_tool_round(&second_setup.store);
}

#[test]
fn fixed_limit_performs_exactly_two_hundred_model_calls() {
    let model = Arc::new(RepeatingToolModel::default());
    let tools = Arc::new(RecordingTools::default());
    let setup = make_setup(model.clone(), tools);

    let error = setup
        .service
        .run(setup.request, &mut RecordingSink::default())
        .unwrap_err();

    assert_eq!(error.code(), "agent_loop.max_model_turns");
    assert_eq!(model.calls.load(Ordering::SeqCst), MAX_MODEL_TURNS);
    assert_eq!(model.closes.load(Ordering::SeqCst), 1);
}

#[test]
fn cancellation_during_model_or_at_tool_boundary_commits_no_round() {
    let model = Arc::new(BlockingModel::default());
    let tools = Arc::new(RecordingTools::default());
    let setup = make_setup(model.clone(), tools);
    let service = setup.service.clone();
    let request = setup.request.clone();
    let run_id = setup.request.run_id.clone();
    let handle = thread::spawn(move || service.run(request, &mut RecordingSink::default()));
    model.entered.wait();

    setup.service.cancel_run(&run_id).unwrap();
    assert_eq!(
        handle.join().unwrap().unwrap_err().code(),
        "agent_loop.cancelled"
    );
    assert_cancelled_without_persisted_round(&setup.store);

    let model = Arc::new(BoundaryCancellingModel::default());
    let tools = Arc::new(RecordingTools::default());
    let setup = make_setup(model.clone(), tools.clone());
    *model.service.lock().unwrap() = Some(Arc::downgrade(&setup.service));
    let error = setup
        .service
        .run(setup.request, &mut RecordingSink::default())
        .unwrap_err();
    assert_eq!(error.code(), "agent_loop.cancelled");
    assert_eq!(tools.calls.load(Ordering::SeqCst), 0);
    assert_cancelled_without_persisted_round(&setup.store);
}

#[test]
fn cancellation_during_tool_batch_uses_active_batch_id() {
    let model = Arc::new(ScriptedModel::new(vec![Ok(tool_turn(vec![call(
        "call-1",
        "file_read",
    )]))]));
    let tools = Arc::new(BlockingTools::default());
    let setup = make_setup(model, tools.clone());
    let service = setup.service.clone();
    let request = setup.request.clone();
    let run_id = setup.request.run_id.clone();
    let handle = thread::spawn(move || service.run(request, &mut RecordingSink::default()));
    tools.entered.wait();

    setup.service.cancel_run(&run_id).unwrap();

    assert_eq!(
        handle.join().unwrap().unwrap_err().code(),
        "agent_loop.cancelled"
    );
    assert_eq!(tools.cancelled_batches.lock().unwrap().len(), 1);
    assert!(tools.cancelled_batches.lock().unwrap()[0].starts_with("batch-"));
    assert_cancelled_without_persisted_round(&setup.store);
}

#[test]
fn process_recovery_claims_unstarted_runs_once_and_fails_interrupted_runs() {
    let model = Arc::new(ScriptedModel::new(Vec::new()));
    let tools = Arc::new(RecordingTools::default());
    let setup = make_setup(model.clone(), tools.clone());
    let restarted = AgentLoopService::new(
        setup.store.clone(),
        model.clone(),
        tools.clone(),
        ActiveRunRegistry::default(),
        ProjectionSubscriptionRegistry::default(),
    );

    let recovered = restarted.recover_after_process_loss().unwrap();
    assert_eq!(recovered, vec![setup.request.clone()]);
    assert!(restarted.recover_after_process_loss().unwrap().is_empty());

    let mut store = setup.store.lock().unwrap();
    let command = store
        .last_event(&SessionId("conversation-1".into()))
        .unwrap()
        .unwrap();
    store
        .append_transaction(
            "conversation-1",
            command.sequence + 1,
            vec![RuntimeEvent::new(
                EntryId("interrupted-run-started".into()),
                SessionId("conversation-1".into()),
                Some(command.id),
                Some(RunId(setup.request.run_id.clone())),
                0,
                command.depth + 1,
                EventKind::AssistantMessageStarted,
                "",
            )],
        )
        .unwrap();
    drop(store);

    let second_restart = AgentLoopService::new(
        setup.store.clone(),
        model,
        tools,
        ActiveRunRegistry::default(),
        ProjectionSubscriptionRegistry::default(),
    );
    assert!(second_restart
        .recover_after_process_loss()
        .unwrap()
        .is_empty());
    assert_eq!(
        event_kinds(&setup.store).last(),
        Some(&EventKind::RunFailed)
    );
}

struct Setup {
    service: Arc<AgentLoopService<InMemoryConversationStore>>,
    request: AgentRunRequest,
    store: Arc<Mutex<InMemoryConversationStore>>,
}

fn make_setup(model: Arc<dyn ModelRuntime>, tools: Arc<dyn ToolRuntime>) -> Setup {
    make_setup_with_snapshot(model, tools, snapshot())
}

fn make_setup_with_snapshot(
    model: Arc<dyn ModelRuntime>,
    tools: Arc<dyn ToolRuntime>,
    snapshot: RunStartSnapshot,
) -> Setup {
    let store = Arc::new(Mutex::new(InMemoryConversationStore::default()));
    let active = ActiveRunRegistry::default();
    let projections = ProjectionSubscriptionRegistry::default();
    let commands = ConversationCommandService::with_registries(
        store.clone(),
        active.clone(),
        projections.clone(),
    );
    let accepted = commands
        .submit(TranscriptCommand::Send {
            request_id: "request-1".into(),
            conversation_stream_id: "conversation-1".into(),
            client_message_id: "client-1".into(),
            text: "hello".into(),
            attachments: Vec::new(),
            run_start_snapshot: snapshot.clone(),
        })
        .unwrap();
    let run_id = accepted.run_id.unwrap();
    let service = Arc::new(AgentLoopService::new(
        store.clone(),
        model,
        tools,
        active,
        projections,
    ));
    Setup {
        service,
        request: AgentRunRequest {
            run_id,
            conversation_stream_id: "conversation-1".into(),
            run_start_snapshot: snapshot,
            attachment_references: Vec::new(),
        },
        store,
    }
}

fn snapshot() -> RunStartSnapshot {
    snapshot_with_window(ModelContextWindow {
        context_window_tokens: 8_192,
        max_output_tokens: 1_024,
    })
}

fn snapshot_with_window(model_context_window: ModelContextWindow) -> RunStartSnapshot {
    RunStartSnapshot::make(
        vec![PromptDocumentSnapshot {
            id: "base".into(),
            source: "settings".into(),
            markdown: "You are LocalAgent.".into(),
        }],
        vec![SkillDescriptor {
            id: "demo".into(),
            name: "Demo".into(),
            description: "Use when relevant.".into(),
            location: "/var/localagent/skills/demo/SKILL.md".into(),
            enabled: true,
        }],
        vec![
            ToolDefinitionSnapshot {
                name: "file_read".into(),
                description: "Read a file.".into(),
                input_schema: json!({"type": "object"}),
            },
            ToolDefinitionSnapshot {
                name: "shell_execute".into(),
                description: "Run a command.".into(),
                input_schema: json!({"type": "object"}),
            },
        ],
        model_context_window,
    )
    .unwrap()
}

fn call(id: &str, name: &str) -> ToolCall {
    ToolCall {
        call_id: id.into(),
        tool_name: name.into(),
        arguments_json: "{}".into(),
    }
}

fn final_turn(text: &str) -> AssistantTurn {
    AssistantTurn {
        text: text.into(),
        reasoning: String::new(),
        tool_calls: Vec::new(),
        usage: None,
    }
}

fn tool_turn(tool_calls: Vec<ToolCall>) -> AssistantTurn {
    AssistantTurn {
        text: String::new(),
        reasoning: String::new(),
        tool_calls,
        usage: None,
    }
}

fn event_kinds(store: &Arc<Mutex<InMemoryConversationStore>>) -> Vec<EventKind> {
    store
        .lock()
        .unwrap()
        .events_after(&SessionId("conversation-1".into()), 0)
        .unwrap()
        .into_iter()
        .map(|event| event.kind)
        .collect()
}

fn assert_no_persisted_tool_round(store: &Arc<Mutex<InMemoryConversationStore>>) {
    let kinds = event_kinds(store);
    assert!(kinds.contains(&EventKind::AssistantMessageStarted));
    assert_eq!(kinds.last(), Some(&EventKind::RunFailed));
    assert!(!kinds.contains(&EventKind::ToolCallRequested));
    assert!(!kinds.contains(&EventKind::ToolResultMessage));
    assert!(!kinds.contains(&EventKind::AssistantMessageCompleted));
}

fn assert_cancelled_without_persisted_round(store: &Arc<Mutex<InMemoryConversationStore>>) {
    let kinds = event_kinds(store);
    assert!(kinds.contains(&EventKind::AssistantMessageStarted));
    assert_eq!(kinds.last(), Some(&EventKind::RunCancelled));
    assert!(!kinds.contains(&EventKind::ToolCallRequested));
    assert!(!kinds.contains(&EventKind::ToolResultMessage));
    assert!(!kinds.contains(&EventKind::AssistantMessageCompleted));
}

#[derive(Default)]
struct RecordingSink {
    events: Vec<ModelEvent>,
}

impl ModelEventSink for RecordingSink {
    fn emit(&mut self, event: ModelEvent) -> Result<(), AgentLoopError> {
        self.events.push(event);
        Ok(())
    }
}

#[derive(Debug)]
struct ScriptedModel {
    turns: Mutex<VecDeque<Result<AssistantTurn, AgentLoopError>>>,
    requests: Mutex<Vec<ModelRequest>>,
    calls: AtomicUsize,
    closes: AtomicUsize,
}

impl ScriptedModel {
    fn new(turns: Vec<Result<AssistantTurn, AgentLoopError>>) -> Self {
        Self {
            turns: Mutex::new(turns.into()),
            requests: Mutex::new(Vec::new()),
            calls: AtomicUsize::new(0),
            closes: AtomicUsize::new(0),
        }
    }
}

impl ModelRuntime for ScriptedModel {
    fn generate(
        &self,
        request: ModelRequest,
        _sink: &mut dyn ModelEventSink,
    ) -> Result<AssistantTurn, AgentLoopError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        self.requests.lock().unwrap().push(request);
        self.turns.lock().unwrap().pop_front().unwrap()
    }

    fn cancel(&self, _run_id: &str) -> Result<(), AgentLoopError> {
        Ok(())
    }

    fn close(&self, _run_id: &str) -> Result<(), AgentLoopError> {
        self.closes.fetch_add(1, Ordering::SeqCst);
        Ok(())
    }
}

#[derive(Debug, Default)]
struct RepeatingToolModel {
    calls: AtomicUsize,
    closes: AtomicUsize,
}

impl ModelRuntime for RepeatingToolModel {
    fn generate(
        &self,
        request: ModelRequest,
        _sink: &mut dyn ModelEventSink,
    ) -> Result<AssistantTurn, AgentLoopError> {
        if request.purpose == ModelRequestPurpose::Compaction {
            return Ok(final_turn("Previous tool rounds compacted."));
        }
        let index = self.calls.fetch_add(1, Ordering::SeqCst);
        Ok(tool_turn(vec![call(&format!("call-{index}"), "file_read")]))
    }

    fn cancel(&self, _run_id: &str) -> Result<(), AgentLoopError> {
        Ok(())
    }

    fn close(&self, _run_id: &str) -> Result<(), AgentLoopError> {
        self.closes.fetch_add(1, Ordering::SeqCst);
        Ok(())
    }
}

#[derive(Debug, Default)]
struct RecordingTools {
    batches: Mutex<Vec<ToolBatch>>,
    calls: AtomicUsize,
    fail: AtomicBool,
    wrong_identity: AtomicBool,
}

impl ToolRuntime for RecordingTools {
    fn execute_batch(&self, batch: ToolBatch) -> Result<ToolBatchResult, AgentLoopError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        self.batches.lock().unwrap().push(batch.clone());
        if self.fail.load(Ordering::SeqCst) {
            return Err(AgentLoopError::new("tool.failed", "tool failed"));
        }
        let mut result = ToolBatchResult {
            batch_id: batch.batch_id.clone(),
            run_id: batch.run_id.clone(),
            ordered_results: batch
                .ordered_calls
                .iter()
                .map(|call| ToolCallResult {
                    call_id: call.call_id.clone(),
                    tool_name: call.tool_name.clone(),
                    result: json!({"call_id": call.call_id, "ok": true}),
                    is_error: false,
                    data_classes: Vec::new(),
                    highest_sensitivity: "public".into(),
                })
                .collect(),
        };
        if self.wrong_identity.load(Ordering::SeqCst) {
            result.batch_id = "wrong".into();
        }
        Ok(result)
    }

    fn cancel_batch(&self, _batch_id: &str) -> Result<(), AgentLoopError> {
        Ok(())
    }
}

#[derive(Debug, Default)]
struct WaitFlag {
    state: Mutex<bool>,
    changed: Condvar,
}

impl WaitFlag {
    fn wait(&self) {
        let mut state = self.state.lock().unwrap();
        while !*state {
            state = self.changed.wait(state).unwrap();
        }
    }

    fn signal(&self) {
        *self.state.lock().unwrap() = true;
        self.changed.notify_all();
    }
}

#[derive(Debug, Default)]
struct BlockingModel {
    entered: WaitFlag,
    cancelled: WaitFlag,
    closes: AtomicUsize,
}

impl ModelRuntime for BlockingModel {
    fn generate(
        &self,
        _request: ModelRequest,
        _sink: &mut dyn ModelEventSink,
    ) -> Result<AssistantTurn, AgentLoopError> {
        self.entered.signal();
        self.cancelled.wait();
        Err(AgentLoopError::cancelled())
    }

    fn cancel(&self, _run_id: &str) -> Result<(), AgentLoopError> {
        self.cancelled.signal();
        Ok(())
    }

    fn close(&self, _run_id: &str) -> Result<(), AgentLoopError> {
        self.closes.fetch_add(1, Ordering::SeqCst);
        Ok(())
    }
}

#[derive(Debug, Default)]
struct BoundaryCancellingModel {
    service: Mutex<Option<Weak<AgentLoopService<InMemoryConversationStore>>>>,
}

impl ModelRuntime for BoundaryCancellingModel {
    fn generate(
        &self,
        request: ModelRequest,
        _sink: &mut dyn ModelEventSink,
    ) -> Result<AssistantTurn, AgentLoopError> {
        self.service
            .lock()
            .unwrap()
            .as_ref()
            .unwrap()
            .upgrade()
            .unwrap()
            .cancel_run(&request.run_id)?;
        Ok(tool_turn(vec![call("call-1", "file_read")]))
    }

    fn cancel(&self, _run_id: &str) -> Result<(), AgentLoopError> {
        Ok(())
    }

    fn close(&self, _run_id: &str) -> Result<(), AgentLoopError> {
        Ok(())
    }
}

#[derive(Debug, Default)]
struct BlockingTools {
    entered: WaitFlag,
    cancelled: WaitFlag,
    cancelled_batches: Mutex<Vec<String>>,
}

impl ToolRuntime for BlockingTools {
    fn execute_batch(&self, _batch: ToolBatch) -> Result<ToolBatchResult, AgentLoopError> {
        self.entered.signal();
        self.cancelled.wait();
        Err(AgentLoopError::cancelled())
    }

    fn cancel_batch(&self, batch_id: &str) -> Result<(), AgentLoopError> {
        self.cancelled_batches
            .lock()
            .unwrap()
            .push(batch_id.to_string());
        self.cancelled.signal();
        Ok(())
    }
}
