#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ComponentKind {
    Prompt,
    Persona,
    Instruction,
    Skill,
    ToolRecipe,
    MemoryProfile,
    VoiceProfile,
    BrainPreset,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ComponentContent {
    Prompt(PromptComponentContent),
    Persona(PersonaComponentContent),
    Instruction(InstructionComponentContent),
    Skill(SkillComponentContent),
    ToolRecipe(ToolRecipeComponentContent),
    MemoryProfile(MemoryProfileComponentContent),
    VoiceProfile(VoiceProfileComponentContent),
    BrainPreset(BrainPresetComponentContent),
}

impl ComponentContent {
    pub fn prompt(text: impl Into<String>) -> Self {
        Self::Prompt(PromptComponentContent { text: text.into() })
    }

    pub fn persona(name: impl Into<String>) -> Self {
        Self::Persona(PersonaComponentContent { name: name.into() })
    }

    pub fn instruction(text: impl Into<String>) -> Self {
        Self::Instruction(InstructionComponentContent { text: text.into() })
    }

    pub fn skill(markdown: impl Into<String>) -> Self {
        Self::Skill(SkillComponentContent {
            markdown: markdown.into(),
        })
    }

    pub fn tool_recipe(name: impl Into<String>) -> Self {
        Self::ToolRecipe(ToolRecipeComponentContent { name: name.into() })
    }

    pub fn memory_profile(policy: impl Into<String>) -> Self {
        Self::MemoryProfile(MemoryProfileComponentContent {
            policy: policy.into(),
        })
    }

    pub fn voice_profile(
        display_style: impl Into<String>,
        speaking_tone: impl Into<String>,
        preferred_modality: impl Into<String>,
    ) -> Self {
        Self::VoiceProfile(VoiceProfileComponentContent {
            display_style: display_style.into(),
            speaking_tone: speaking_tone.into(),
            preferred_modality: preferred_modality.into(),
        })
    }

    pub fn brain_preset(name: impl Into<String>) -> Self {
        Self::BrainPreset(BrainPresetComponentContent { name: name.into() })
    }

    pub fn kind(&self) -> ComponentKind {
        match self {
            Self::Prompt(_) => ComponentKind::Prompt,
            Self::Persona(_) => ComponentKind::Persona,
            Self::Instruction(_) => ComponentKind::Instruction,
            Self::Skill(_) => ComponentKind::Skill,
            Self::ToolRecipe(_) => ComponentKind::ToolRecipe,
            Self::MemoryProfile(_) => ComponentKind::MemoryProfile,
            Self::VoiceProfile(_) => ComponentKind::VoiceProfile,
            Self::BrainPreset(_) => ComponentKind::BrainPreset,
        }
    }

    pub fn content_text(&self) -> &str {
        match self {
            Self::Prompt(content) => &content.text,
            Self::Persona(content) => &content.name,
            Self::Instruction(content) => &content.text,
            Self::Skill(content) => &content.markdown,
            Self::ToolRecipe(content) => &content.name,
            Self::MemoryProfile(content) => &content.policy,
            Self::VoiceProfile(content) => &content.display_style,
            Self::BrainPreset(content) => &content.name,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PromptComponentContent {
    pub text: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PersonaComponentContent {
    pub name: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct InstructionComponentContent {
    pub text: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SkillComponentContent {
    pub markdown: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ToolRecipeComponentContent {
    pub name: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MemoryProfileComponentContent {
    pub policy: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct VoiceProfileComponentContent {
    pub display_style: String,
    pub speaking_tone: String,
    pub preferred_modality: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BrainPresetComponentContent {
    pub name: String,
}
