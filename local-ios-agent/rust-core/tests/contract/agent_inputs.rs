use std::sync::{Arc, Mutex};

use local_ios_agent_runtime::{
    agent_input::{
        AgentInputAssembler, PromptDocumentSnapshot, RunStartSnapshot, SkillDescriptor,
        ToolDefinitionSnapshot,
    },
    context::ModelContextWindow,
    memory::{
        CompletedTurnMemoryInput, MemoryContribution, MemoryContributionId, MemoryProvider,
        MemoryProviderError, MemoryProviderId, MemoryQuery, MemoryQueryResult, Provenance,
        SensitivityLevel,
    },
    skills::{render_skill_descriptors, MAX_SKILL_DESCRIPTORS},
};
use serde_json::json;

const SHARED_SNAPSHOT_DIGEST: &str =
    "43492a18fafbde12c99dfc7e37ab97ad006387e00bf4bd6addb113696a853bb7";

fn model_window() -> ModelContextWindow {
    ModelContextWindow {
        context_window_tokens: 8_192,
        max_output_tokens: 1_024,
    }
}

#[test]
fn rust_snapshot_digest_matches_the_swift_fixture() {
    let snapshot = valid_snapshot();

    assert_eq!(snapshot.snapshot_digest, SHARED_SNAPSHOT_DIGEST);
    snapshot.validate().unwrap();
}

#[test]
fn snapshot_accepts_twenty_descriptors_and_rejects_twenty_one() {
    let descriptors = (0..MAX_SKILL_DESCRIPTORS)
        .map(skill_descriptor)
        .collect::<Vec<_>>();
    RunStartSnapshot::make(Vec::new(), descriptors, Vec::new(), model_window()).unwrap();

    let too_many = (0..=MAX_SKILL_DESCRIPTORS)
        .map(skill_descriptor)
        .collect::<Vec<_>>();
    let error =
        RunStartSnapshot::make(Vec::new(), too_many, Vec::new(), model_window()).unwrap_err();

    assert_eq!(error.code(), "run_start_snapshot.too_many_skills");
}

#[test]
fn snapshot_rejects_host_paths_traversal_duplicate_tools_and_non_object_schemas() {
    for location in [
        "/private/var/mobile/Containers/Data/Application/host/SKILL.md",
        "/var/localagent/skills/../shared/secret/SKILL.md",
        "/var/localagent/skills/demo/references/extra.md",
    ] {
        let mut descriptor = skill_descriptor(0);
        descriptor.location = location.to_string();
        let error =
            RunStartSnapshot::make(Vec::new(), vec![descriptor], Vec::new(), model_window())
                .unwrap_err();
        assert_eq!(error.code(), "run_start_snapshot.skill_location_invalid");
    }

    let tool = ToolDefinitionSnapshot {
        name: "shell_execute".into(),
        description: "Run shell commands.".into(),
        input_schema: json!({"type": "object"}),
    };
    let duplicate = RunStartSnapshot::make(
        Vec::new(),
        Vec::new(),
        vec![tool.clone(), tool],
        model_window(),
    )
    .unwrap_err();
    assert_eq!(duplicate.code(), "run_start_snapshot.duplicate_tool_name");

    let non_object = RunStartSnapshot::make(
        Vec::new(),
        Vec::new(),
        vec![ToolDefinitionSnapshot {
            name: "bad".into(),
            description: "Bad".into(),
            input_schema: json!([]),
        }],
        model_window(),
    )
    .unwrap_err();
    assert_eq!(
        non_object.code(),
        "run_start_snapshot.tool_schema_not_object"
    );
}

#[test]
fn skill_prompt_contains_only_progressive_descriptor_metadata() {
    let rendered = render_skill_descriptors(&[SkillDescriptor {
        id: "demo".into(),
        name: "Demo".into(),
        description: "Use for demonstrations.".into(),
        location: "/var/localagent/skills/demo/SKILL.md".into(),
        enabled: true,
    }]);

    assert!(rendered.contains("Demo"));
    assert!(rendered.contains("Use for demonstrations."));
    assert!(rendered.contains("/var/localagent/skills/demo/SKILL.md"));
    assert!(!rendered.contains("scripts/"));
    assert!(!rendered.contains("references/"));
    assert!(!rendered.contains("assets/"));
    assert!(!rendered.contains("full skill body"));
}

#[test]
fn one_memory_provider_interface_supports_recall_and_completed_turn_hooks() {
    let provider = Arc::new(RecordingMemoryProvider::default());
    let assembler = AgentInputAssembler::new(valid_snapshot(), 2_000)
        .unwrap()
        .with_memory_provider(provider.clone());

    assembler
        .assemble_turn("conversation-1", Vec::new())
        .unwrap();
    provider
        .remember_completed_turn(&CompletedTurnMemoryInput {
            conversation_stream_id: "conversation-1".into(),
            user_text: "Remember this".into(),
            assistant_text: "Done".into(),
            tool_results: vec![json!({"ok": true})],
        })
        .unwrap();

    assert_eq!(provider.recalled.lock().unwrap().len(), 1);
    assert_eq!(provider.remembered.lock().unwrap().len(), 1);
}

fn valid_snapshot() -> RunStartSnapshot {
    RunStartSnapshot::make(
        vec![PromptDocumentSnapshot {
            id: "base".into(),
            source: "settings".into(),
            markdown: "You are LocalAgent.".into(),
        }],
        vec![SkillDescriptor {
            id: "demo".into(),
            name: "Demo".into(),
            description: "Use for demonstrations.".into(),
            location: "/var/localagent/skills/demo/SKILL.md".into(),
            enabled: true,
        }],
        vec![ToolDefinitionSnapshot {
            name: "shell_execute".into(),
            description: "Run shell commands.".into(),
            input_schema: json!({"type": "object"}),
        }],
        model_window(),
    )
    .unwrap()
}

fn skill_descriptor(index: usize) -> SkillDescriptor {
    SkillDescriptor {
        id: format!("skill-{index}"),
        name: format!("Skill {index}"),
        description: "Description".into(),
        location: format!("/var/localagent/skills/skill-{index}/SKILL.md"),
        enabled: true,
    }
}

#[derive(Debug, Default)]
struct RecordingMemoryProvider {
    recalled: Mutex<Vec<MemoryQuery>>,
    remembered: Mutex<Vec<CompletedTurnMemoryInput>>,
}

impl MemoryProvider for RecordingMemoryProvider {
    fn provider_id(&self) -> MemoryProviderId {
        MemoryProviderId::new("test.recording")
    }

    fn recall(&self, query: &MemoryQuery) -> MemoryQueryResult {
        self.recalled.lock().unwrap().push(query.clone());
        MemoryQueryResult::from_contributions(vec![MemoryContribution::new(
            "User prefers concise answers",
        )
        .with_id(MemoryContributionId::new("preference"))
        .with_provenance(Provenance::local("test"))
        .with_confidence(1.0)
        .with_sensitivity(SensitivityLevel::Normal)
        .build()
        .unwrap()])
    }

    fn remember_completed_turn(
        &self,
        input: &CompletedTurnMemoryInput,
    ) -> Result<(), MemoryProviderError> {
        self.remembered.lock().unwrap().push(input.clone());
        Ok(())
    }
}
