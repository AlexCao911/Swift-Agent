use serde::{Deserialize, Deserializer, Serialize, Serializer};

use crate::user_customization::skill_package::SkillPackageManifest;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
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

impl ComponentKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Prompt => "prompt",
            Self::Persona => "persona",
            Self::Instruction => "instruction",
            Self::Skill => "skill",
            Self::ToolRecipe => "tool_recipe",
            Self::MemoryProfile => "memory_profile",
            Self::VoiceProfile => "voice_profile",
            Self::BrainPreset => "brain_preset",
        }
    }

    fn from_stable_str(value: &str) -> Option<Self> {
        match value {
            "prompt" => Some(Self::Prompt),
            "persona" => Some(Self::Persona),
            "instruction" => Some(Self::Instruction),
            "skill" => Some(Self::Skill),
            "tool_recipe" => Some(Self::ToolRecipe),
            "memory_profile" => Some(Self::MemoryProfile),
            "voice_profile" => Some(Self::VoiceProfile),
            "brain_preset" => Some(Self::BrainPreset),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ComponentKindDTO {
    Known(ComponentKind),
    Unknown(String),
}

impl From<ComponentKind> for ComponentKindDTO {
    fn from(kind: ComponentKind) -> Self {
        Self::Known(kind)
    }
}

impl Serialize for ComponentKindDTO {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        match self {
            Self::Known(kind) => serializer.serialize_str(kind.as_str()),
            Self::Unknown(value) => serializer.serialize_str(value),
        }
    }
}

impl<'de> Deserialize<'de> for ComponentKindDTO {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let value = String::deserialize(deserializer)?;
        Ok(ComponentKind::from_stable_str(&value)
            .map(Self::Known)
            .unwrap_or(Self::Unknown(value)))
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
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
        Self::skill_package(
            SkillPackageManifest::new("skill.legacy.markdown", "0.0.0", "Legacy Skill"),
            markdown,
        )
    }

    pub fn skill_package(
        manifest: SkillPackageManifest,
        instructions_markdown: impl Into<String>,
    ) -> Self {
        Self::Skill(SkillComponentContent {
            manifest,
            markdown: instructions_markdown.into(),
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

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct PromptComponentContent {
    pub text: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct PersonaComponentContent {
    pub name: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct InstructionComponentContent {
    pub text: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct SkillComponentContent {
    #[serde(default = "default_skill_manifest")]
    pub manifest: SkillPackageManifest,
    pub markdown: String,
}

impl SkillComponentContent {
    pub fn manifest(&self) -> &SkillPackageManifest {
        &self.manifest
    }

    pub fn instructions_markdown(&self) -> &str {
        &self.markdown
    }
}

fn default_skill_manifest() -> SkillPackageManifest {
    SkillPackageManifest::new("skill.legacy.markdown", "0.0.0", "Legacy Skill")
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ToolRecipeComponentContent {
    pub name: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct MemoryProfileComponentContent {
    pub policy: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct VoiceProfileComponentContent {
    pub display_style: String,
    pub speaking_tone: String,
    pub preferred_modality: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct BrainPresetComponentContent {
    pub name: String,
}
