use std::{fs, path::Path};

#[test]
fn runtime_layer_does_not_depend_on_builder_package_or_profile_repositories() {
    let runtime_source = include_str!("../../src/core/runtime.rs");
    let findings = forbidden_runtime_dependency_findings(runtime_source);

    assert!(
        findings.is_empty(),
        "runtime layer must not depend on builder/package/profile repositories: {findings:?}"
    );
}

#[test]
fn runtime_model_calls_flow_through_context_assembly_result_boundary() {
    let runtime_source = include_str!("../../src/core/runtime.rs");

    assert!(
        runtime_source.contains("build_prompt_frame_from_context_assembly"),
        "runtime model calls must go through ContextAssemblyResult before provider PromptFrame compatibility"
    );
    assert!(
        !runtime_source.contains(".build_prompt_frame(branch)?"),
        "runtime must not build provider prompt frames directly from ContextController"
    );
}

#[test]
fn runtime_dependency_lint_detects_alias_imports_and_ignores_comments_and_strings() {
    let source = r#"
        // crate::agent_package::AgentPackageInstaller in a comment should be ignored.
        const NOTE: &str = "AgentProfilePublisher should not trip in strings";
        use crate::agent_package as ap;
        use crate::user_customization::{AgentProfilePublisher as Publisher};
    "#;

    let findings = forbidden_runtime_dependency_findings(source);

    assert!(findings.contains(&"crate::agent_package".to_string()));
    assert!(findings.contains(&"AgentProfilePublisher".to_string()));
    assert_eq!(findings.len(), 2);
}

#[test]
fn agent_profile_reference_public_api_makes_latest_resolution_explicit() {
    let source = include_str!("../../src/user_customization/agent_profile.rs");

    assert!(
        !source.contains("pub fn new(profile_id: AgentProfileId) -> Self"),
        "versionless AgentProfileReference::new must not be public; use pinned(...) or latest(...)"
    );
    assert!(source.contains("pub fn pinned("));
    assert!(source.contains("pub fn latest("));
}

#[test]
fn agent_builder_assembly_layer_stays_out_of_runtime_package_and_inference_execution() {
    let sources = [
        (
            "component_graph.rs",
            include_str!("../../src/user_customization/component_graph.rs"),
        ),
        (
            "assembly_plan.rs",
            include_str!("../../src/user_customization/assembly_plan.rs"),
        ),
        (
            "safety_review.rs",
            include_str!("../../src/user_customization/safety_review.rs"),
        ),
        (
            "settings_schema.rs",
            include_str!("../../src/user_customization/settings_schema.rs"),
        ),
        (
            "binding_resolution.rs",
            include_str!("../../src/user_customization/binding_resolution.rs"),
        ),
        (
            "builder_resolver.rs",
            include_str!("../../src/user_customization/builder_resolver.rs"),
        ),
    ];

    let mut findings = Vec::new();
    for (file, source) in sources {
        for finding in forbidden_builder_assembly_dependency_findings(source) {
            findings.push(format!("{file}: {finding}"));
        }
    }

    assert!(
        findings.is_empty(),
        "agent builder assembly layer must not depend on runtime/package/inference execution:\n{}",
        findings.join("\n")
    );
}

#[test]
fn run_snapshot_resolution_layer_stays_out_of_package_builder_and_runtime_execution() {
    let sources = [
        (
            "resolver.rs",
            include_str!("../../src/run_snapshot/resolver.rs"),
        ),
        (
            "snapshot_service.rs",
            include_str!("../../src/run_snapshot/snapshot_service.rs"),
        ),
        (
            "snapshot.rs",
            include_str!("../../src/run_snapshot/snapshot.rs"),
        ),
        (
            "resolved_bindings.rs",
            include_str!("../../src/run_snapshot/resolved_bindings.rs"),
        ),
    ];

    let mut findings = Vec::new();
    for (file, source) in sources {
        for finding in forbidden_run_snapshot_dependency_findings(source) {
            findings.push(format!("{file}: {finding}"));
        }
    }

    assert!(
        findings.is_empty(),
        "run snapshot resolution must not depend on package install, builder assembly, or runtime execution:\n{}",
        findings.join("\n")
    );
}

#[test]
fn context_layer_stays_out_of_memory_tool_model_and_runtime_execution() {
    let mut findings = Vec::new();
    for (file, source) in context_module_sources() {
        for finding in forbidden_context_dependency_findings(source) {
            findings.push(format!("{file}: {finding}"));
        }
    }

    assert!(
        findings.is_empty(),
        "context layer must consume prepared prompt/memory/tool values without depending on providers, executors, models, or runtime execution:\n{}",
        findings.join("\n")
    );
}

#[test]
fn context_dependency_lint_detects_forbidden_imports_and_ignores_comments() {
    let source = r#"
        // crate::memory::MemoryProvider in a comment should be ignored.
        const NOTE: &str = "InferenceBackend should not trip inside strings";
        use crate::memory::MemoryProvider;
        use crate::tool::ToolRouter as Router;
        use crate::inference as model_runtime;
    "#;

    let findings = forbidden_context_dependency_findings(source);

    assert!(findings.contains(&"MemoryProvider".to_string()));
    assert!(findings.contains(&"ToolRouter".to_string()));
    assert!(findings.contains(&"crate::inference".to_string()));
    assert_eq!(findings.len(), 3);
}

#[test]
fn run_snapshot_dependency_lint_detects_forbidden_imports_and_ignores_comments() {
    let source = r#"
        // crate::agent_package::AgentPackageInstaller in a comment should be ignored.
        use crate::agent_package as package;
        use crate::inference::InferenceBackend;
        let _name = "AgentBuilderResolver should not trip inside strings";
    "#;

    let findings = forbidden_run_snapshot_dependency_findings(source);

    assert!(findings.contains(&"crate::agent_package".to_string()));
    assert!(findings.contains(&"crate::inference".to_string()));
    assert!(findings.contains(&"InferenceBackend".to_string()));
    assert_eq!(findings.len(), 3);
}

#[test]
fn builder_assembly_dependency_lint_detects_forbidden_imports_and_ignores_comments() {
    let source = r#"
        // crate::agent_package::AgentPackageInstaller in a comment should be ignored.
        use crate::inference as execution;
        use crate::agent_package::AgentPackageInstaller;
        let _name = "Runtime should not trip inside strings";
    "#;

    let findings = forbidden_builder_assembly_dependency_findings(source);

    assert!(findings.contains(&"crate::agent_package".to_string()));
    assert!(findings.contains(&"crate::inference".to_string()));
    assert!(findings.contains(&"AgentPackageInstaller".to_string()));
    assert_eq!(findings.len(), 3);
}

#[test]
fn agent_assembly_plan_does_not_expose_mutable_invariant_fields_or_profile_draft_setter() {
    let source = include_str!("../../src/user_customization/assembly_plan.rs");

    for forbidden in [
        "pub component_graph:",
        "pub missing_requirements:",
        "pub required_bindings:",
        "pub warnings:",
        "pub safety_review:",
        "pub readiness_report:",
        "pub fn with_profile_draft",
    ] {
        assert!(
            !source.contains(forbidden),
            "AgentAssemblyPlan must not expose mutable invariant API: {forbidden}"
        );
    }
}

fn forbidden_runtime_dependency_findings(source: &str) -> Vec<String> {
    let stripped = strip_comments_and_strings(source);
    let compact: String = stripped.chars().filter(|ch| !ch.is_whitespace()).collect();
    let mut findings = Vec::new();

    for forbidden_path in [
        "crate::agent_package",
        "crate::{agent_package",
        ",agent_package",
        "super::agent_package",
    ] {
        if compact.contains(forbidden_path) {
            findings.push("crate::agent_package".to_string());
            break;
        }
    }

    for forbidden_type in [
        "AgentPackage",
        "AgentPackageInstaller",
        "PackageInstall",
        "AgentProfilePublisher",
        "InMemoryAgentProfileRepository",
        "ComponentCatalogService",
    ] {
        if contains_identifier(&stripped, forbidden_type) {
            findings.push(forbidden_type.to_string());
        }
    }

    findings.sort();
    findings.dedup();
    findings
}

fn forbidden_builder_assembly_dependency_findings(source: &str) -> Vec<String> {
    let stripped = strip_comments_and_strings(source);
    let compact: String = stripped.chars().filter(|ch| !ch.is_whitespace()).collect();
    let mut findings = Vec::new();

    for forbidden_path in [
        "crate::agent_package",
        "crate::{agent_package",
        ",agent_package",
        "super::agent_package",
    ] {
        if compact.contains(forbidden_path) {
            findings.push("crate::agent_package".to_string());
            break;
        }
    }

    for forbidden_path in ["crate::inference", "crate::{inference", "super::inference"] {
        if compact.contains(forbidden_path) {
            findings.push("crate::inference".to_string());
            break;
        }
    }

    for forbidden_type in [
        "Runtime",
        "ExecutionPlan",
        "GenerationSession",
        "InferenceBackend",
        "AgentPackageInstaller",
    ] {
        if contains_identifier(&stripped, forbidden_type) {
            findings.push(forbidden_type.to_string());
        }
    }

    findings.sort();
    findings.dedup();
    findings
}

fn forbidden_run_snapshot_dependency_findings(source: &str) -> Vec<String> {
    let stripped = strip_comments_and_strings(source);
    let compact: String = stripped.chars().filter(|ch| !ch.is_whitespace()).collect();
    let mut findings = Vec::new();

    for forbidden_path in [
        "crate::agent_package",
        "crate::{agent_package",
        "super::agent_package",
    ] {
        if compact.contains(forbidden_path) {
            findings.push("crate::agent_package".to_string());
            break;
        }
    }

    for forbidden_path in ["crate::inference", "crate::{inference", "super::inference"] {
        if compact.contains(forbidden_path) {
            findings.push("crate::inference".to_string());
            break;
        }
    }

    for forbidden_path in [
        "crate::core::runtime",
        "crate::{core::runtime",
        "super::core::runtime",
    ] {
        if compact.contains(forbidden_path) {
            findings.push("crate::core::runtime".to_string());
            break;
        }
    }

    for forbidden_type in [
        "AgentPackageInstaller",
        "PackageInstallOperation",
        "AgentBuilderResolver",
        "AgentAssemblyPlan",
        "Runtime",
        "ExecutionPlan",
        "GenerationSession",
        "InferenceBackend",
    ] {
        if contains_identifier(&stripped, forbidden_type) {
            findings.push(forbidden_type.to_string());
        }
    }

    findings.sort();
    findings.dedup();
    findings
}

fn forbidden_context_dependency_findings(source: &str) -> Vec<String> {
    let stripped = strip_comments_and_strings(source);
    let compact: String = stripped.chars().filter(|ch| !ch.is_whitespace()).collect();
    let mut findings = Vec::new();

    for forbidden_path in ["crate::inference", "crate::{inference", "super::inference"] {
        if compact.contains(forbidden_path) {
            findings.push("crate::inference".to_string());
            break;
        }
    }

    for forbidden_path in [
        "crate::agent_package",
        "crate::{agent_package",
        "super::agent_package",
    ] {
        if compact.contains(forbidden_path) {
            findings.push("crate::agent_package".to_string());
            break;
        }
    }

    for forbidden_type in [
        "MemoryProvider",
        "MemoryResolver",
        "ToolRouter",
        "ToolExecutor",
        "ModelProvider",
        "InferenceBackend",
        "GenerationSession",
        "Runtime",
        "ExecutionPlan",
        "AgentPackageReader",
    ] {
        if contains_identifier(&stripped, forbidden_type) {
            findings.push(forbidden_type.to_string());
        }
    }

    findings.sort();
    findings.dedup();
    findings
}

fn context_module_sources() -> Vec<(String, &'static str)> {
    let context_dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("src/context");
    let mut sources = Vec::new();
    for entry in fs::read_dir(&context_dir)
        .unwrap_or_else(|err| panic!("failed to read {}: {err}", context_dir.display()))
    {
        let entry = entry.expect("context source entry is readable");
        let path = entry.path();
        if path.extension().and_then(|extension| extension.to_str()) != Some("rs") {
            continue;
        }

        let file_name = entry.file_name().to_string_lossy().to_string();
        let source = fs::read_to_string(&path)
            .unwrap_or_else(|err| panic!("failed to read {}: {err}", path.display()));
        let source: &'static str = Box::leak(source.into_boxed_str());
        sources.push((file_name, source));
    }

    sources.sort_by(|left, right| left.0.cmp(&right.0));
    sources
}

fn contains_identifier(source: &str, needle: &str) -> bool {
    source.match_indices(needle).any(|(index, _)| {
        let before = source[..index].chars().next_back();
        let after = source[index + needle.len()..].chars().next();
        !is_identifier_char(before) && !is_identifier_char(after)
    })
}

fn is_identifier_char(ch: Option<char>) -> bool {
    matches!(ch, Some(ch) if ch == '_' || ch.is_ascii_alphanumeric())
}

fn strip_comments_and_strings(source: &str) -> String {
    #[derive(Clone, Copy, Eq, PartialEq)]
    enum State {
        Code,
        LineComment,
        BlockComment,
        String,
        Char,
    }

    let mut output = String::with_capacity(source.len());
    let mut chars = source.chars().peekable();
    let mut state = State::Code;
    let mut escaped = false;

    while let Some(ch) = chars.next() {
        match state {
            State::Code => match ch {
                '/' if chars.peek() == Some(&'/') => {
                    chars.next();
                    output.push(' ');
                    output.push(' ');
                    state = State::LineComment;
                }
                '/' if chars.peek() == Some(&'*') => {
                    chars.next();
                    output.push(' ');
                    output.push(' ');
                    state = State::BlockComment;
                }
                '"' => {
                    output.push(' ');
                    escaped = false;
                    state = State::String;
                }
                '\'' => {
                    output.push(' ');
                    escaped = false;
                    state = State::Char;
                }
                _ => output.push(ch),
            },
            State::LineComment => {
                if ch == '\n' {
                    output.push('\n');
                    state = State::Code;
                } else {
                    output.push(' ');
                }
            }
            State::BlockComment => {
                if ch == '*' && chars.peek() == Some(&'/') {
                    chars.next();
                    output.push(' ');
                    output.push(' ');
                    state = State::Code;
                } else if ch == '\n' {
                    output.push('\n');
                } else {
                    output.push(' ');
                }
            }
            State::String => {
                if escaped {
                    escaped = false;
                    output.push(' ');
                } else if ch == '\\' {
                    escaped = true;
                    output.push(' ');
                } else if ch == '"' {
                    output.push(' ');
                    state = State::Code;
                } else if ch == '\n' {
                    output.push('\n');
                } else {
                    output.push(' ');
                }
            }
            State::Char => {
                if escaped {
                    escaped = false;
                    output.push(' ');
                } else if ch == '\\' {
                    escaped = true;
                    output.push(' ');
                } else if ch == '\'' {
                    output.push(' ');
                    state = State::Code;
                } else if ch == '\n' {
                    output.push('\n');
                    state = State::Code;
                } else {
                    output.push(' ');
                }
            }
        }
    }

    output
}
