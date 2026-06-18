pub mod desktop_minicpm;
pub mod event;
pub mod openai_chat;
pub mod provider;
pub mod provider_profile;
pub mod provider_registry;
pub mod run_state;
pub mod runtime;
pub mod session_cursor;
pub mod session_tree;
pub mod stream_batcher;
pub mod turn;
pub mod types;

pub use desktop_minicpm::{
    DesktopMiniCPMProvider, DesktopMiniCPMTransport, LocalhostHttpTransport,
};
pub use event::{EventKind, RuntimeEvent};
pub use openai_chat::{build_openai_chat_request, parse_openai_chat_response};
pub use provider::{CancellationToken, MockStreamingProvider, ModelProvider, ModelProviderOutput};
pub use provider_profile::{ProviderKind, ProviderProfile};
pub use provider_registry::{ProviderBundle, ProviderRegistry};
pub use run_state::{RunRecord, RunState};
pub use runtime::{AgentRuntime, AgentRuntimeConfig, SendMessageInput};
pub use session_cursor::SessionCursor;
pub use session_tree::SessionTree;
pub use stream_batcher::StreamBatcher;
pub use turn::AgentTurnResult;
pub use types::{AgentError, EntryId, RunId, SessionId};
