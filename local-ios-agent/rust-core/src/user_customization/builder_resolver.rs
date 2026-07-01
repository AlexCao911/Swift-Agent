use crate::user_customization::{
    AgentProfileDraft, AgentReadinessIssue, AgentReadinessReport, AgentSlotKind, AgentTemplate,
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

    pub fn readiness_for_draft(
        &self,
        draft: &AgentProfileDraft,
        template: &AgentTemplate,
    ) -> AgentReadinessReport {
        let mut report = AgentReadinessReport::ready();

        for slot in template.slots().iter().filter(|slot| slot.is_required()) {
            let satisfied = match slot.kind() {
                AgentSlotKind::Model => draft
                    .model_binding()
                    .map(|binding| binding.slot_id() == slot.id())
                    .unwrap_or(false),
                _ => draft
                    .bindings()
                    .iter()
                    .any(|binding| binding.slot_id() == slot.id()),
            };
            if satisfied {
                continue;
            }

            match slot.kind() {
                AgentSlotKind::Persona => report.push_issue(AgentReadinessIssue::new(
                    "component.persona.missing",
                    "required persona component is missing",
                )),
                AgentSlotKind::Model => report.push_issue(AgentReadinessIssue::new(
                    "model.missing",
                    "required model binding is missing",
                )),
                _ => report.push_issue(AgentReadinessIssue::new(
                    format!("slot.{}.missing", slot.id().as_str()),
                    format!("required slot {} is missing", slot.id().as_str()),
                )),
            }
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
