use std::collections::BTreeSet;

use crate::agent_input::{AgentInputError, SkillDescriptor};

pub const MAX_SKILL_DESCRIPTORS: usize = 20;

pub fn validate_skill_descriptors(descriptors: &[SkillDescriptor]) -> Result<(), AgentInputError> {
    if descriptors.len() > MAX_SKILL_DESCRIPTORS {
        return Err(AgentInputError::new(
            "run_start_snapshot.too_many_skills",
            "run-start snapshot accepts at most twenty Skill descriptors",
        ));
    }

    let mut ids = BTreeSet::new();
    for descriptor in descriptors {
        if !ids.insert(descriptor.id.as_str()) {
            return Err(AgentInputError::new(
                "run_start_snapshot.duplicate_skill_id",
                "Skill descriptor identifiers must be unique",
            ));
        }
        if !descriptor.enabled
            || descriptor.id.is_empty()
            || descriptor.name.is_empty()
            || !valid_location(descriptor)
        {
            return Err(AgentInputError::new(
                "run_start_snapshot.skill_location_invalid",
                "Skill descriptor must use its stable /var/localagent/skills virtual path",
            ));
        }
    }
    Ok(())
}

pub fn render_skill_descriptors(descriptors: &[SkillDescriptor]) -> String {
    if descriptors.is_empty() {
        return String::new();
    }

    let mut rendered = String::from(
        "Available Skills\n\
         Read a Skill's SKILL.md with the ordinary file_read tool only when it is relevant.\n",
    );
    for descriptor in descriptors {
        rendered.push_str(&format!(
            "\n- {}: {}\n  location: {}",
            descriptor.name, descriptor.description, descriptor.location
        ));
    }
    rendered
}

fn valid_location(descriptor: &SkillDescriptor) -> bool {
    const PREFIX: &str = "/var/localagent/skills/";
    const SUFFIX: &str = "/SKILL.md";

    let Some(component) = descriptor
        .location
        .strip_prefix(PREFIX)
        .and_then(|path| path.strip_suffix(SUFFIX))
    else {
        return false;
    };
    component == descriptor.id
        && !component.is_empty()
        && component != "."
        && component != ".."
        && component
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_'))
}
