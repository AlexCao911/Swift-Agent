use local_ios_agent_runtime::{
    app_service::{AgentBuilderCardDraftInput, AgentOSApplicationService},
    user_customization::AgentSlotKind,
};

#[test]
fn card_backed_publish_binds_prompt_tool_and_context_components() {
    let service = AgentOSApplicationService::empty();

    let profile = service
        .build_agent_from_template(
            Some("profile.builder.card_components"),
            "template_1",
            AgentBuilderCardDraftInput {
                display_name: Some("Research Agent".into()),
                system_prompt: Some("You are careful.".into()),
                persona: Some("Researcher".into()),
                response_style: Some("Concise".into()),
                selected_tool_ids: vec![
                    "calendar.search_events".into(),
                    "web.fetch_url_text".into(),
                ],
                context_step_ids: vec![
                    "system_prompt".into(),
                    "conversation_history".into(),
                    "tool_results".into(),
                ],
            },
        )
        .expect("card-backed profile should publish");

    assert_eq!(profile.name(), "Research Agent");
    assert_eq!(profile.bindings_for_kind(AgentSlotKind::Persona).len(), 1);
    assert_eq!(
        profile.bindings_for_kind(AgentSlotKind::Instruction).len(),
        1
    );
    assert_eq!(profile.bindings_for_kind(AgentSlotKind::Toolset).len(), 1);
}
