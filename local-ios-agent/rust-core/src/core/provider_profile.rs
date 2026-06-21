use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ProviderKind {
    Mock,
    DesktopMiniCpm,
    OnDeviceMiniCpm,
    OpenAiCompatibleLocal,
    LocalLlm,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ProviderProfile {
    pub id: String,
    pub display_name: String,
    pub kind: ProviderKind,
    pub max_context_tokens: usize,
}
