use local_ios_agent_runtime::context::{ContextAssembler, ContextBudget};
use local_ios_agent_runtime::memory::{
    MemoryContribution, MemoryContributionId, Provenance, SensitivityLevel as MemorySensitivity,
};
use local_ios_agent_runtime::prompt::{PromptCompiler, PromptStack};

#[test]
fn context_archive_summary_matches_golden_and_is_redacted() {
    let compiled_prompt = PromptCompiler::default()
        .compile(PromptStack::fixture_with_variable(
            "api_key",
            "plain-secret-value",
        ))
        .unwrap();
    let memory = MemoryContribution::new("likes quiet mornings")
        .with_id(MemoryContributionId::new("memory.local.preference"))
        .with_provenance(Provenance::local("profile-memory"))
        .with_confidence(0.9)
        .with_sensitivity(MemorySensitivity::Normal)
        .build()
        .unwrap();

    let archive = ContextAssembler::new()
        .with_compiled_prompt(compiled_prompt)
        .with_memory_contribution(memory)
        .assemble(ContextBudget::tokens(100))
        .unwrap()
        .archive("run.golden");
    let actual = serde_json::to_string_pretty(&archive.debug_summary()).unwrap() + "\n";

    assert!(!actual.contains("plain-secret-value"));
    assert!(!actual.contains("api_key"));
    assert_eq!(
        actual,
        include_str!("../fixtures/golden/context/context_archive_summary.json")
    );
}
