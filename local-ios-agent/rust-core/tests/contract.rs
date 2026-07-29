#[path = "support/mod.rs"]
mod support;

#[path = "contract/agent_builder_agent_os.rs"]
mod agent_builder_agent_os;
#[path = "contract/agent_builder_assembly_graph_agent_os.rs"]
mod agent_builder_assembly_graph_agent_os;
#[path = "contract/agent_capability_contract.rs"]
mod agent_capability_contract;
#[path = "contract/agent_inputs.rs"]
mod agent_inputs;
#[path = "contract/agent_loop_contract.rs"]
mod agent_loop_contract;
#[path = "contract/agent_package_agent_os.rs"]
mod agent_package_agent_os;
#[path = "contract/agent_profile_contract.rs"]
mod agent_profile_contract;
#[path = "contract/agent_profile_sqlite.rs"]
mod agent_profile_sqlite;
#[path = "contract/bearer_token.rs"]
mod bearer_token;
#[path = "contract/canonical_digest_v1.rs"]
mod canonical_digest_v1;
#[path = "contract/context_agent_os.rs"]
mod context_agent_os;
#[path = "contract/conversation_execution_boundary.rs"]
mod conversation_execution_boundary;
#[path = "contract/conversation_command.rs"]
mod conversation_command;
#[path = "contract/global_run_lease.rs"]
mod global_run_lease;
#[path = "contract/host_binding_saga.rs"]
mod host_binding_saga;
#[path = "contract/host_llm_contracts.rs"]
mod host_llm_contracts;
#[path = "contract/host_llm_event_ingress.rs"]
mod host_llm_event_ingress;
#[path = "contract/host_llm_outbox.rs"]
mod host_llm_outbox;
#[path = "contract/host_llm_recovery.rs"]
mod host_llm_recovery;
#[path = "contract/host_llm_worker.rs"]
mod host_llm_worker;
#[path = "contract/llm_profile_migration.rs"]
mod llm_profile_migration;
#[path = "contract/llm_slot_v2.rs"]
mod llm_slot_v2;
#[path = "contract/memory_agent_os.rs"]
mod memory_agent_os;
#[path = "contract/prompt_archive_agent_os.rs"]
mod prompt_archive_agent_os;
#[path = "contract/protocol_lifecycle.rs"]
mod protocol_lifecycle;
#[path = "contract/protocol_registry.rs"]
mod protocol_registry;
#[path = "contract/run_preparation.rs"]
mod run_preparation;
#[path = "contract/runtime_state_migration.rs"]
mod runtime_state_migration;
#[path = "contract/security_approval_protocol.rs"]
mod security_approval_protocol;
#[path = "contract/security_data_egress.rs"]
mod security_data_egress;
#[path = "contract/security_manager.rs"]
mod security_manager;
#[path = "contract/storage_transaction.rs"]
mod storage_transaction;
#[path = "contract/tool_recipe_agent_os.rs"]
mod tool_recipe_agent_os;
#[path = "contract/tool_security_contract.rs"]
mod tool_security_contract;
#[path = "contract/user_component.rs"]
mod user_component;
