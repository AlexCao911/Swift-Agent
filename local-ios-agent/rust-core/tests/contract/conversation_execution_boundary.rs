use local_ios_agent_runtime::conversation::{
    AttachmentRef, ConversationFrameId, ConversationFrameMessage, ConversationFrameRepository,
    ConversationLineage, ConversationRunFrame, ConversationRunFrameRef, ConversationService,
    InMemoryBranchEventReader, InMemoryConversationFrameRepository, PrepareUserTurnRequest,
};
use local_ios_agent_runtime::core::{EntryId, EventKind, RuntimeEvent, SessionId};

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
