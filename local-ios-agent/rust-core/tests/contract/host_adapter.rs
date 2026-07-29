use std::fs;
use std::path::Path;

use local_ios_agent_runtime::agent_loop::{ModelRuntime, ToolRuntime};
use local_ios_agent_runtime::host_adapter::{HostModelRuntime, HostToolRuntime};
use local_ios_agent_runtime::storage::InMemoryRuntimeStateStore;

#[test]
fn concrete_host_adapters_implement_the_agent_loop_ports() {
    fn model<T: ModelRuntime>() {}
    fn tools<T: ToolRuntime>() {}

    model::<HostModelRuntime<InMemoryRuntimeStateStore>>();
    tools::<HostToolRuntime<InMemoryRuntimeStateStore>>();
}

#[test]
fn agent_loop_has_no_transport_dependency() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("src/agent_loop");
    for entry in fs::read_dir(root).unwrap() {
        let path = entry.unwrap().path();
        if path.extension().and_then(|value| value.to_str()) != Some("rs") {
            continue;
        }
        let source = fs::read_to_string(&path).unwrap();
        for forbidden in ["host_adapter", "llm_contracts", "HostExecutionPhase"] {
            assert!(
                !source.contains(forbidden),
                "{} imports transport detail {forbidden}",
                path.display()
            );
        }
    }
}
