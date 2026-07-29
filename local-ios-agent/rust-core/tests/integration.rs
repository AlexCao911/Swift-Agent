#[path = "support/mod.rs"]
mod support;

#[path = "integration/agent_builder_assembly_to_profile.rs"]
mod agent_builder_assembly_to_profile;
#[path = "integration/agent_lifecycle_failure_paths.rs"]
mod agent_lifecycle_failure_paths;
#[path = "integration/agent_os_state_sqlite.rs"]
mod agent_os_state_sqlite;
#[path = "integration/app_service_builder_publish.rs"]
mod app_service_builder_publish;
#[path = "integration/context_assembly_lifecycle.rs"]
mod context_assembly_lifecycle;
#[path = "integration/conversation_projection.rs"]
mod conversation_projection;
#[path = "integration/host_llm_ffi.rs"]
mod host_llm_ffi;
#[path = "integration/llm_profile_migration_ffi.rs"]
mod llm_profile_migration_ffi;
#[path = "integration/phase_five_product_path.rs"]
mod phase_five_product_path;
#[path = "integration/prompt_skill_context.rs"]
mod prompt_skill_context;
#[path = "integration/sqlite_resilience.rs"]
mod sqlite_resilience;
