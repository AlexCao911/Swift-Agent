use crate::user_customization::{
    AgentReadinessIssue, AgentReadinessReport, AgentSlotKind, AgentTemplate,
};

#[derive(Clone, Debug)]
pub struct AgentBuilderResolver {
    has_persona_component: bool,
    has_model: bool,
    calendar_permission_ready: bool,
}

impl AgentBuilderResolver {
    pub fn fixture_missing_model_and_calendar_permission() -> Self {
        Self {
            has_persona_component: true,
            has_model: false,
            calendar_permission_ready: false,
        }
    }

    pub fn fixture_missing_persona_component() -> Self {
        Self {
            has_persona_component: false,
            has_model: true,
            calendar_permission_ready: true,
        }
    }

    pub fn readiness_for_template(&self, template: &AgentTemplate) -> AgentReadinessReport {
        let mut report = AgentReadinessReport::ready();

        if template.requires_slot(AgentSlotKind::Persona) && !self.has_persona_component {
            report.push_issue(AgentReadinessIssue::new(
                "component.persona.missing",
                "required persona component is missing",
            ));
        }

        if template.requires_slot(AgentSlotKind::Model) && !self.has_model {
            report.push_issue(AgentReadinessIssue::new(
                "model.missing",
                "required model binding is missing",
            ));
        }

        if !self.calendar_permission_ready {
            report.push_issue(AgentReadinessIssue::new(
                "permission.calendar.missing",
                "calendar permission is missing",
            ));
        }

        report
    }
}
