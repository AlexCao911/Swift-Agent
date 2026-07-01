use local_ios_agent_runtime::context::{ContextBudget, PromptMessage};

#[test]
fn budget_drops_oldest_messages_at_message_boundaries() {
    let messages = vec![
        PromptMessage::User("one two three four".into()),
        PromptMessage::Assistant("five six seven eight".into()),
        PromptMessage::User("nine ten".into()),
    ];

    let kept = ContextBudget::new(4).fit_messages(messages);

    assert_eq!(kept, vec![PromptMessage::User("nine ten".into())]);
}
