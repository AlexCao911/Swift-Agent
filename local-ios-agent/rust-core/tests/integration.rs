#[path = "support/mod.rs"]
mod support;

#[path = "integration/agent_builder_assembly_to_profile.rs"]
mod agent_builder_assembly_to_profile;
#[path = "integration/agent_lifecycle_failure_paths.rs"]
mod agent_lifecycle_failure_paths;
#[path = "integration/agent_lifecycle_profile_to_runtime.rs"]
mod agent_lifecycle_profile_to_runtime;
#[path = "integration/agent_loop.rs"]
mod agent_loop;
#[path = "integration/context_assembly_lifecycle.rs"]
mod context_assembly_lifecycle;
#[path = "integration/ffi_bridge.rs"]
mod ffi_bridge;
#[path = "integration/ffi_streaming_events.rs"]
mod ffi_streaming_events;
#[path = "integration/openai_chat_adapter.rs"]
mod openai_chat_adapter;
#[path = "integration/runtime_execution_lifecycle.rs"]
mod runtime_execution_lifecycle;
#[path = "integration/runtime_mock.rs"]
mod runtime_mock;
#[path = "integration/runtime_provider_selection.rs"]
mod runtime_provider_selection;
#[path = "integration/runtime_provider_streaming.rs"]
mod runtime_provider_streaming;
#[path = "integration/runtime_replay.rs"]
mod runtime_replay;
#[path = "integration/runtime_tool_orchestration.rs"]
mod runtime_tool_orchestration;
#[path = "integration/sqlite_resilience.rs"]
mod sqlite_resilience;
