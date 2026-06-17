use std::fmt;

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub struct SessionId(pub String);

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub struct EntryId(pub String);

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub struct RunId(pub String);

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum AgentError {
    Storage(String),
    Provider(String),
    ToolParse(String),
    ToolValidation(String),
    ToolPermission(String),
    ToolExecution(String),
    PolicyDenied(String),
    Cancelled(String),
    Ffi(String),
    Unknown(String),
}

impl fmt::Display for AgentError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Storage(message) => write!(f, "storage error: {message}"),
            Self::Provider(message) => write!(f, "provider error: {message}"),
            Self::ToolParse(message) => write!(f, "tool parse error: {message}"),
            Self::ToolValidation(message) => write!(f, "tool validation error: {message}"),
            Self::ToolPermission(message) => write!(f, "tool permission error: {message}"),
            Self::ToolExecution(message) => write!(f, "tool execution error: {message}"),
            Self::PolicyDenied(message) => write!(f, "policy denied: {message}"),
            Self::Cancelled(message) => write!(f, "cancelled: {message}"),
            Self::Ffi(message) => write!(f, "ffi error: {message}"),
            Self::Unknown(message) => write!(f, "unknown error: {message}"),
        }
    }
}

impl std::error::Error for AgentError {}
