use local_ios_agent_runtime::prompt::{
    CompiledPrompt, PromptCompiler, PromptSourceMap, PromptStack, PromptStackEntry,
    PromptVariableBinding, PromptVariableSourceMapEntry, PromptVariableSpan,
};
use local_ios_agent_runtime::prompt::{CompiledPromptArchive, PromptDocument};
use local_ios_agent_runtime::storage::{
    ArchiveId, ArchiveRecord, ArchiveStore, InMemoryTransactionRunner, TransactionName,
    TransactionOperation, TransactionRunner, UnitOfWork,
};

#[test]
fn prompt_document_versions_are_immutable() {
    let mut doc = PromptDocument::new("identity");
    let v1 = doc.publish("You are concise.").unwrap();
    doc.update_draft("You are detailed.").unwrap();

    assert_eq!(doc.version(v1).unwrap().body, "You are concise.");
}

#[test]
fn compiler_records_source_map_entries() {
    let stack = PromptStack::fixture_identity_persona();
    let compiled = PromptCompiler::default().compile(stack).unwrap();

    assert!(compiled
        .source_map
        .entries
        .iter()
        .any(|entry| entry.slot == "identity"));
    assert!(compiled.text.contains("You are"));
}

#[test]
fn compiler_redacts_sensitive_variables_before_returning_compiled_prompt() {
    let compiled = PromptCompiler::default()
        .compile(PromptStack::fixture_with_variable("api_key", "abcd1234"))
        .unwrap();

    assert!(!compiled.text.contains("abcd1234"));
    assert!(!format!("{compiled:?}").contains("abcd1234"));
}

#[test]
fn prompt_archive_redacts_secret_like_variables() {
    let stack = PromptStack::fixture_with_variable("api_key", "sk-secret");
    let compiled = PromptCompiler::default().compile(stack).unwrap();
    let archive = CompiledPromptArchive::from_compiled("run_1", compiled.clone()).unwrap();

    assert!(!archive.redacted_text.contains("sk-secret"));
    assert_eq!(archive.redacted_text, compiled.text);
    assert_eq!(archive.redacted_text.len(), compiled.text.len());
}

#[test]
fn prompt_archive_redacts_sensitive_variable_by_name_when_value_looks_plain() {
    let stack = PromptStack::fixture_with_variable("api_key", "abcd1234");
    let compiled = PromptCompiler::default().compile(stack).unwrap();
    let archive = CompiledPromptArchive::from_compiled("run_1", compiled).unwrap();

    assert!(!archive.redacted_text.contains("abcd1234"));
    assert!(!archive.compiled_text.contains("abcd1234"));
    assert!(!format!("{archive:?}").contains("abcd1234"));
}

#[test]
fn prompt_archive_never_exposes_unredacted_secret_text() {
    let stack = PromptStack::fixture_with_variable("api_key", "sk-secret");
    let compiled = PromptCompiler::default().compile(stack).unwrap();
    let archive = CompiledPromptArchive::from_compiled("run_1", compiled).unwrap();

    assert!(!archive.compiled_text.contains("sk-secret"));
    assert!(!format!("{archive:?}").contains("sk-secret"));
}

#[test]
fn prompt_preview_uses_compile_redaction_without_runtime() {
    let stack = PromptStack::fixture_with_variable("api_key", "sk-secret");
    let preview = PromptCompiler::default().preview(stack).unwrap();

    assert!(!preview.redacted_text.contains("sk-secret"));
    assert!(preview.source_map.variables.iter().any(|variable| {
        variable.name == "api_key" && variable.provenance == "fixture.prompt.variable"
    }));
}

#[test]
fn prompt_archive_writes_append_only_storage_record_in_transaction() {
    let runner = InMemoryTransactionRunner::default();
    let archive_store = runner.archive_store();
    let compiled = PromptCompiler::default()
        .compile(PromptStack::fixture_identity_persona())
        .unwrap();
    let archive = CompiledPromptArchive::from_compiled("run_1", compiled).unwrap();
    let mut op = AppendPromptArchiveOperation {
        archive_store: archive_store.clone(),
        archive,
        archive_id: None,
    };

    runner
        .run(TransactionName::new("prompt.archive.write"), &mut op)
        .unwrap();

    let archive_id = op.archive_id.unwrap();
    let record = archive_store.get(archive_id).unwrap();
    assert_eq!(record.run_id(), "run_1");
    assert_eq!(record.kind(), "prompt_archive");
    assert_eq!(
        archive_store
            .replace(archive_id, ArchiveRecord::new("run_1", "mutated"))
            .unwrap_err()
            .code(),
        "storage.archive_append_only"
    );
}

#[test]
fn prompt_archive_record_persists_redacted_prompt_and_source_map_payload() {
    let stack = PromptStack::fixture_with_variable("api_key", "abcd1234");
    let compiled = PromptCompiler::default().compile(stack).unwrap();
    let archive = CompiledPromptArchive::from_compiled("run_1", compiled).unwrap();
    let record = archive.to_archive_record();
    let payload: serde_json::Value = serde_json::from_str(record.payload()).unwrap();

    assert_eq!(payload["redacted_text"], archive.redacted_text);
    assert_eq!(payload["source_map"]["entries"][0]["slot"], "identity");
    assert_eq!(payload["source_map"]["variables"][0]["name"], "api_key");
    assert!(!record.payload().contains("abcd1234"));
}

#[test]
fn prompt_redaction_preserves_source_map_offsets_and_whitespace() {
    let mut doc = PromptDocument::new("identity");
    let version_id = doc.publish("Alpha {{api_key}}\n\nBeta  tail").unwrap();
    let version = doc.version(version_id).unwrap();
    let stack = PromptStack::new(vec![PromptStackEntry::new(
        "identity",
        version.document_id.clone(),
        version.id,
        version.body.clone(),
    )])
    .with_variable(PromptVariableBinding::new(
        "api_key",
        "abcd1234",
        "user.secret",
    ));
    let compiled = PromptCompiler::default().compile(stack).unwrap();
    let archive = CompiledPromptArchive::from_compiled("run_1", compiled.clone()).unwrap();

    assert_eq!(archive.redacted_text.len(), compiled.text.len());
    assert!(archive.redacted_text.contains("\n\nBeta  tail"));
    let source_entry = &archive.source_map.entries[0];
    assert_eq!(source_entry.start, 0);
    assert_eq!(source_entry.end, archive.redacted_text.len());
    let variable_span = &archive.source_map.variables[0].spans[0];
    assert_eq!(
        archive.redacted_text[variable_span.start..variable_span.end].len(),
        "abcd1234".len()
    );
}

#[test]
fn prompt_archive_rejects_forged_variable_span_crossing_utf8_boundary() {
    let compiled = CompiledPrompt {
        text: "éabcd1234".to_string(),
        source_map: PromptSourceMap {
            entries: Vec::new(),
            variables: vec![PromptVariableSourceMapEntry {
                name: "api_key".to_string(),
                provenance: "user.secret".to_string(),
                redacted_value: "[redacted]".to_string(),
                spans: vec![PromptVariableSpan { start: 1, end: 4 }],
            }],
        },
    };

    let error = CompiledPromptArchive::from_compiled("run_1", compiled).unwrap_err();
    assert!(error.to_string().contains("invalid prompt variable span"));
}

#[test]
fn prompt_archive_rejects_forged_variable_span_outside_compiled_text() {
    let compiled = CompiledPrompt {
        text: "abcd1234".to_string(),
        source_map: PromptSourceMap {
            entries: Vec::new(),
            variables: vec![PromptVariableSourceMapEntry {
                name: "api_key".to_string(),
                provenance: "user.secret".to_string(),
                redacted_value: "[redacted]".to_string(),
                spans: vec![PromptVariableSpan { start: 0, end: 99 }],
            }],
        },
    };

    let error = CompiledPromptArchive::from_compiled("run_1", compiled).unwrap_err();
    assert!(error.to_string().contains("invalid prompt variable span"));
}

struct AppendPromptArchiveOperation {
    archive_store: local_ios_agent_runtime::storage::InMemoryArchiveStore,
    archive: CompiledPromptArchive,
    archive_id: Option<ArchiveId>,
}

impl TransactionOperation for AppendPromptArchiveOperation {
    fn execute(
        &mut self,
        tx: &mut UnitOfWork,
    ) -> local_ios_agent_runtime::storage::StorageResult<()> {
        self.archive_id = Some(
            self.archive_store
                .append_immutable(tx, self.archive.to_archive_record())?,
        );
        Ok(())
    }
}
