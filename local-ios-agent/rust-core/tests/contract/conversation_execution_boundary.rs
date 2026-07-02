use local_ios_agent_runtime::conversation::{
    AttachmentRef, BranchEventReader, ConversationCommitService, ConversationFrameId,
    ConversationFrameMessage, ConversationFrameProjector, ConversationFrameRepository,
    ConversationLineage, ConversationRunFrame, ConversationRunFrameRef, ConversationService,
    InMemoryBranchEventReader, InMemoryConversationFrameRepository, PrepareUserTurnRequest,
};
use local_ios_agent_runtime::core::{AgentError, EntryId, EventKind, RuntimeEvent, SessionId};
use local_ios_agent_runtime::execution::{
    CompletedRunRegistry, ExecutionEventLog, ExecutionPlanner, ExecutionService,
    InferenceSettingsService, RunLifecycleService, RuntimeOptions, StartExecutionRequest,
};
use local_ios_agent_runtime::run_snapshot::RunSnapshotService;

#[test]
fn conversation_run_frame_ref_pins_branch_and_user_turn() {
    let frame_ref = ConversationRunFrameRef::new(
        ConversationFrameId::new("frame_1"),
        SessionId("session_1".into()),
        EntryId("branch_head_1".into()),
        EntryId("user_turn_1".into()),
    );

    assert_eq!(frame_ref.frame_id().as_str(), "frame_1");
    assert_eq!(frame_ref.session_id().0, "session_1");
    assert_eq!(frame_ref.branch_head_id().0, "branch_head_1");
    assert_eq!(frame_ref.user_turn_id().0, "user_turn_1");
}

#[test]
fn conversation_frame_is_projection_not_execution_input() {
    let frame_ref = ConversationRunFrameRef::new(
        ConversationFrameId::new("frame_2"),
        SessionId("session_1".into()),
        EntryId("user_turn_1".into()),
        EntryId("user_turn_1".into()),
    );
    let frame = ConversationRunFrame::new(
        frame_ref.clone(),
        None,
        vec![ConversationFrameMessage::user(
            EntryId("user_turn_1".into()),
            "hello",
        )],
        vec![AttachmentRef::new("attachment_1")],
        ConversationLineage::new(EntryId("user_turn_1".into()), None, None),
    );

    assert_eq!(frame.frame_ref(), &frame_ref);
    assert_eq!(frame.messages()[0].role(), "user");
    assert_eq!(frame.system_prompt(), None);
}

#[test]
fn conversation_service_prepares_and_persists_trusted_frame_ref() {
    let repository = InMemoryConversationFrameRepository::default();
    let branch_reader = InMemoryBranchEventReader::default().with_branch(
        SessionId("session_1".into()),
        EntryId("assistant_1".into()),
        vec![
            RuntimeEvent::new(
                EntryId("user_0".into()),
                SessionId("session_1".into()),
                None,
                None,
                1,
                0,
                EventKind::UserMessage,
                "earlier question",
            ),
            RuntimeEvent::new(
                EntryId("assistant_1".into()),
                SessionId("session_1".into()),
                Some(EntryId("user_0".into())),
                None,
                2,
                1,
                EventKind::AssistantMessageCompleted,
                "earlier answer",
            ),
        ],
    );
    let service = ConversationService::new(repository.clone(), branch_reader);

    let prepared = service
        .prepare_user_turn(PrepareUserTurnRequest::new(
            Some(SessionId("session_1".into())),
            Some(EntryId("assistant_1".into())),
            "hello",
            vec!["blob_1".to_string()],
        ))
        .unwrap();

    let frame = repository
        .get(prepared.conversation_run_frame_ref())
        .expect("prepared frame is persisted");

    assert_eq!(prepared.session_id().0, "session_1");
    assert_eq!(prepared.user_message_id().0, "user_turn_1");
    assert_eq!(frame.frame_ref(), prepared.conversation_run_frame_ref());
    assert_eq!(
        frame
            .messages()
            .iter()
            .map(|message| message.content())
            .collect::<Vec<_>>(),
        vec!["earlier question", "earlier answer", "hello"]
    );
    assert_eq!(frame.messages()[2].blob_refs(), &["blob_1".to_string()]);
    assert_eq!(frame.parent_event_id().unwrap().0, "assistant_1");
    assert_eq!(frame.lineage().branch_head_id().0, "assistant_1");
}

#[test]
fn conversation_service_returns_structured_error_for_unreadable_branch() {
    #[derive(Clone)]
    struct FailingBranchReader;

    impl BranchEventReader for FailingBranchReader {
        fn active_branch(
            &self,
            _session_id: &SessionId,
            _branch_head_id: Option<&EntryId>,
        ) -> Result<(Option<EntryId>, Vec<RuntimeEvent>), AgentError> {
            Err(AgentError::Storage(
                "leaf has no path rows: stale_leaf".into(),
            ))
        }
    }

    let service = ConversationService::new(
        InMemoryConversationFrameRepository::default(),
        FailingBranchReader,
    );

    let error = service
        .prepare_user_turn(PrepareUserTurnRequest::new(
            Some(SessionId("session_1".into())),
            Some(EntryId("stale_leaf".into())),
            "hello",
            Vec::new(),
        ))
        .unwrap_err();

    assert_eq!(error.code(), "conversation.branch_unreadable");
}

#[test]
fn frame_repository_rejects_tampered_ref_with_real_frame_id() {
    let repository = InMemoryConversationFrameRepository::default();
    let frame_ref = ConversationRunFrameRef::new(
        ConversationFrameId::new("frame_1"),
        SessionId("session_1".into()),
        EntryId("assistant_1".into()),
        EntryId("user_turn_1".into()),
    );
    repository.put(ConversationRunFrame::new(
        frame_ref.clone(),
        Some(EntryId("assistant_1".into())),
        vec![ConversationFrameMessage::user(
            EntryId("user_turn_1".into()),
            "hello",
        )],
        Vec::new(),
        ConversationLineage::new(EntryId("assistant_1".into()), None, None),
    ));

    let tampered = ConversationRunFrameRef::new(
        ConversationFrameId::new("frame_1"),
        SessionId("other_session".into()),
        EntryId("assistant_1".into()),
        EntryId("user_turn_1".into()),
    );

    assert!(repository.get(&tampered).is_none());
    assert!(!repository.contains(&tampered));
}

#[test]
fn execution_events_replay_from_durable_sequence() {
    let event_log = ExecutionEventLog::default();
    let lifecycle = RunLifecycleService::new(event_log.clone());

    let handle = lifecycle.start_run("run_1");
    event_log.append("run_1", "assistant.delta");

    let replayed = event_log.replay("run_1", handle.replay_from_sequence());

    assert_eq!(
        replayed
            .iter()
            .map(|event| event.code())
            .collect::<Vec<_>>(),
        vec!["run.started", "assistant.delta"]
    );
}

#[test]
fn execution_events_replay_then_tail_live_events() {
    let event_log = ExecutionEventLog::default();
    event_log.append("run_1", "run.started");

    let mut stream = event_log.subscribe("run_1", Some(0));

    assert_eq!(
        stream
            .replay()
            .iter()
            .map(|event| event.code())
            .collect::<Vec<_>>(),
        vec!["run.started"]
    );

    event_log.append("run_1", "assistant.delta");
    let live = stream.next_live().unwrap();

    assert_eq!(live.code(), "assistant.delta");
}

#[test]
fn inference_settings_service_persists_runtime_options() {
    let settings = InferenceSettingsService::default();
    let options = RuntimeOptions {
        system_prompt: "system".to_string(),
        runtime_policy: "policy".to_string(),
        temperature: Some(0.25),
        top_p: Some(0.8),
    };

    settings.update_runtime_options(options.clone()).unwrap();

    assert_eq!(settings.runtime_options(), Some(options));
}

#[test]
fn execution_context_input_uses_conversation_frame_and_runtime_options() {
    use local_ios_agent_runtime::context::ModelInputRole;
    use local_ios_agent_runtime::execution::ExecutionContextInputAssembler;

    let frame_ref = ConversationRunFrameRef::new(
        ConversationFrameId::new("frame_context_1"),
        SessionId("session_1".into()),
        EntryId("assistant_1".into()),
        EntryId("user_turn_2".into()),
    );
    let frame = ConversationRunFrame::new(
        frame_ref,
        Some(EntryId("assistant_1".into())),
        vec![
            ConversationFrameMessage::user(EntryId("user_1".into()), "earlier question"),
            ConversationFrameMessage::assistant(EntryId("assistant_1".into()), "earlier answer"),
            ConversationFrameMessage::user(EntryId("user_turn_2".into()), "new question"),
        ],
        Vec::new(),
        ConversationLineage::new(EntryId("assistant_1".into()), None, None),
    );
    let assembler = ExecutionContextInputAssembler::new(Some(RuntimeOptions {
        system_prompt: "system from execution settings".to_string(),
        runtime_policy: "policy from execution settings".to_string(),
        temperature: Some(0.25),
        top_p: Some(0.8),
    }));

    let input = assembler.assemble_initial(&frame).unwrap();

    assert!(input.messages().iter().any(|message| {
        message.role() == ModelInputRole::System
            && message.content().contains("system from execution settings")
    }));
    assert!(input.messages().iter().any(|message| {
        message.role() == ModelInputRole::User && message.content() == "earlier question"
    }));
    assert!(input.messages().iter().any(|message| {
        message.role() == ModelInputRole::Assistant && message.content() == "earlier answer"
    }));
    assert!(input.messages().iter().any(|message| {
        message.role() == ModelInputRole::User && message.content() == "new question"
    }));
}

#[test]
fn react_worker_emits_final_response_without_synthetic_adapter() {
    use local_ios_agent_runtime::execution::{
        ExecutionContextInputAssembler, ExecutionModelClient, ExecutionModelTurn,
        ExecutionReactWorker, NoopExecutionToolExecutor,
    };

    #[derive(Clone)]
    struct FinalModel;

    impl ExecutionModelClient for FinalModel {
        fn next_turn(
            &self,
            _input: &local_ios_agent_runtime::context::ModelInputMessages,
        ) -> Result<ExecutionModelTurn, String> {
            Ok(ExecutionModelTurn::Final {
                message_id: "final_model_1".to_string(),
                text: "real model answer".to_string(),
            })
        }
    }

    let frame_ref = ConversationRunFrameRef::new(
        ConversationFrameId::new("frame_react_1"),
        SessionId("session_1".into()),
        EntryId("user_turn_1".into()),
        EntryId("user_turn_1".into()),
    );
    let frame = ConversationRunFrame::new(
        frame_ref.clone(),
        None,
        vec![ConversationFrameMessage::user(
            EntryId("user_turn_1".into()),
            "hello",
        )],
        Vec::new(),
        ConversationLineage::new(EntryId("user_turn_1".into()), None, None),
    );
    let event_log = ExecutionEventLog::default();
    let completed_runs = CompletedRunRegistry::default();
    let worker = ExecutionReactWorker::new(
        FinalModel,
        NoopExecutionToolExecutor,
        ExecutionContextInputAssembler::new(None),
        event_log.clone(),
        completed_runs.clone(),
    );

    worker.run("run_1", &frame, &frame_ref).unwrap();

    let events = event_log.replay("run_1", Some(0));
    assert!(events.iter().any(|event| {
        event.code() == "assistant_message_completed"
            && event.payload().contains("real model answer")
    }));
    assert!(events.iter().any(|event| event.code() == "run.completed"));
    assert!(completed_runs.get("run_1", "final_model_1").is_some());
}

#[test]
fn conversation_assistant_commit_is_idempotent_after_execution_completion() {
    let completed_runs = CompletedRunRegistry::default();
    let service = ConversationCommitService::new(completed_runs.clone());
    let frame_ref = ConversationRunFrameRef::new(
        ConversationFrameId::new("frame_commit_1"),
        SessionId("session_1".into()),
        EntryId("branch_head_1".into()),
        EntryId("user_turn_1".into()),
    );
    completed_runs.record_completed("run_1", "final_1", frame_ref.clone());

    let first = service
        .commit_assistant_result("run_1", "final_1", &frame_ref)
        .unwrap();
    let second = service
        .commit_assistant_result("run_1", "final_1", &frame_ref)
        .unwrap();

    assert_eq!(first.assistant_message_id(), second.assistant_message_id());
    assert_eq!(service.commit_count(), 1);
}

#[test]
fn conversation_assistant_commit_rejects_mismatched_frame_ref() {
    let completed_runs = CompletedRunRegistry::default();
    let service = ConversationCommitService::new(completed_runs.clone());
    let completed_ref = ConversationRunFrameRef::new(
        ConversationFrameId::new("frame_commit_1"),
        SessionId("session_1".into()),
        EntryId("branch_head_1".into()),
        EntryId("user_turn_1".into()),
    );
    let tampered_ref = ConversationRunFrameRef::new(
        ConversationFrameId::new("frame_commit_1"),
        SessionId("other_session".into()),
        EntryId("branch_head_1".into()),
        EntryId("user_turn_1".into()),
    );
    completed_runs.record_completed("run_1", "final_1", completed_ref);

    let error = service
        .commit_assistant_result("run_1", "final_1", &tampered_ref)
        .unwrap_err();

    assert_eq!(error.code(), "conversation_commit.frame_ref_mismatch");
}

#[test]
fn execution_service_is_thin_facade() {
    let frames = InMemoryConversationFrameRepository::default();
    let frame_ref = ConversationRunFrameRef::new(
        ConversationFrameId::new("frame_facade_1"),
        SessionId("session_1".into()),
        EntryId("user_turn_1".into()),
        EntryId("user_turn_1".into()),
    );
    frames.put(ConversationRunFrame::new(
        frame_ref.clone(),
        None,
        vec![ConversationFrameMessage::user(
            EntryId("user_turn_1".into()),
            "hello",
        )],
        Vec::new(),
        ConversationLineage::new(EntryId("user_turn_1".into()), None, None),
    ));
    let event_log = ExecutionEventLog::default();
    let service = ExecutionService::with_runtime_parts(
        frames,
        RunSnapshotService::fixture(),
        ExecutionPlanner::default(),
        event_log.clone(),
        CompletedRunRegistry::default(),
    );

    let handle = service
        .start_run(StartExecutionRequest::new(
            "run_facade_1",
            "profile_1",
            "hello",
            frame_ref,
        ))
        .unwrap();
    let events = service.observe_events(handle.run_id(), handle.replay_from_sequence());

    assert!(events.iter().any(|event| event.code() == "run.started"));
    assert_eq!(service.tool_loop().pending_count(), 1);
}

#[test]
fn execution_start_loads_frame_resolves_snapshot_and_schedules_tool_loop() {
    let frames = InMemoryConversationFrameRepository::default();
    let frame_ref = ConversationRunFrameRef::new(
        ConversationFrameId::new("frame_exec_1"),
        SessionId("session_1".into()),
        EntryId("user_turn_1".into()),
        EntryId("user_turn_1".into()),
    );
    frames.put(ConversationRunFrame::new(
        frame_ref.clone(),
        None,
        vec![ConversationFrameMessage::user(
            EntryId("user_turn_1".into()),
            "hello",
        )],
        Vec::new(),
        ConversationLineage::new(EntryId("user_turn_1".into()), None, None),
    ));
    let event_log = ExecutionEventLog::default();
    let completed_runs = CompletedRunRegistry::default();
    let service = ExecutionService::with_runtime_parts(
        frames,
        RunSnapshotService::fixture(),
        ExecutionPlanner::default(),
        event_log.clone(),
        completed_runs,
    );

    let handle = service
        .start_run(StartExecutionRequest::new(
            "run_1",
            "profile_1",
            "hello",
            frame_ref,
        ))
        .unwrap();

    let events = event_log.replay(handle.run_id(), handle.replay_from_sequence());
    assert_eq!(handle.run_id(), "run_1");
    assert!(events.iter().any(|event| event.code() == "run.started"));
    assert_eq!(service.tool_loop().pending_count(), 1);
}

#[test]
fn execution_start_rejects_unissued_frame_ref() {
    let service = ExecutionService::with_runtime_parts(
        InMemoryConversationFrameRepository::default(),
        RunSnapshotService::fixture(),
        ExecutionPlanner::default(),
        ExecutionEventLog::default(),
        CompletedRunRegistry::default(),
    );
    let missing_ref = ConversationRunFrameRef::new(
        ConversationFrameId::new("missing_frame"),
        SessionId("session_1".into()),
        EntryId("branch_head_1".into()),
        EntryId("user_turn_1".into()),
    );

    let error = service
        .start_run(StartExecutionRequest::new(
            "run_1",
            "profile_1",
            "hello",
            missing_ref,
        ))
        .unwrap_err();

    assert_eq!(error.code(), "execution.frame_ref_untrusted");
}

#[test]
fn execution_start_rejects_tampered_frame_ref_with_real_frame_id() {
    let frames = InMemoryConversationFrameRepository::default();
    let issued_ref = ConversationRunFrameRef::new(
        ConversationFrameId::new("frame_exec_1"),
        SessionId("session_1".into()),
        EntryId("branch_head_1".into()),
        EntryId("user_turn_1".into()),
    );
    frames.put(ConversationRunFrame::new(
        issued_ref.clone(),
        None,
        vec![ConversationFrameMessage::user(
            EntryId("user_turn_1".into()),
            "hello",
        )],
        Vec::new(),
        ConversationLineage::new(EntryId("branch_head_1".into()), None, None),
    ));
    let service = ExecutionService::with_runtime_parts(
        frames,
        RunSnapshotService::fixture(),
        ExecutionPlanner::default(),
        ExecutionEventLog::default(),
        CompletedRunRegistry::default(),
    );
    let tampered_ref = ConversationRunFrameRef::new(
        issued_ref.frame_id().clone(),
        SessionId("other_session".into()),
        EntryId("branch_head_1".into()),
        EntryId("user_turn_1".into()),
    );

    let error = service
        .start_run(StartExecutionRequest::new(
            "run_1",
            "profile_1",
            "hello",
            tampered_ref,
        ))
        .unwrap_err();

    assert_eq!(error.code(), "execution.frame_ref_untrusted");
}

#[test]
fn conversation_frame_projector_outputs_visible_messages() {
    let user_event = RuntimeEvent::new(
        EntryId("user_1".into()),
        SessionId("session_1".into()),
        None,
        None,
        1,
        0,
        EventKind::UserMessage,
        "hello",
    );
    let assistant_event = RuntimeEvent::new(
        EntryId("assistant_1".into()),
        SessionId("session_1".into()),
        Some(EntryId("user_1".into())),
        None,
        2,
        1,
        EventKind::AssistantMessageCompleted,
        "hi",
    );

    let messages = ConversationFrameProjector::new().project(vec![user_event, assistant_event]);

    assert_eq!(messages[0].role(), "user");
    assert_eq!(messages[0].content(), "hello");
    assert_eq!(messages[1].role(), "assistant");
    assert_eq!(messages[1].content(), "hi");
}
