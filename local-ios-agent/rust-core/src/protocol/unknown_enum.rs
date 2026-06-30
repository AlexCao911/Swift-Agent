use serde::{Deserialize, Deserializer, Serialize, Serializer};

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ProviderKindDTO {
    Local,
    Remote,
    Unknown(String),
}

impl<'de> Deserialize<'de> for ProviderKindDTO {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let value = String::deserialize(deserializer)?;
        Ok(match value.as_str() {
            "local" => Self::Local,
            "remote" => Self::Remote,
            _ => Self::Unknown(value),
        })
    }
}

impl Serialize for ProviderKindDTO {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        let value = match self {
            Self::Local => "local",
            Self::Remote => "remote",
            Self::Unknown(value) => value.as_str(),
        };

        serializer.serialize_str(value)
    }
}
