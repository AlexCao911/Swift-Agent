use local_ios_agent_runtime::storage::{
    ArchiveId, ArchiveRecord, ArchiveStore, EventRecord, EventStore, InMemoryArchiveStore,
    InMemoryEventStore, InMemoryTransactionRunner, MigrationPlan, MigrationStep, RepositoryName,
    SchemaVersion, StorageRepository, TransactionName, TransactionOperation, TransactionRunner,
    UnitOfWork,
};

struct CountingOperation {
    pub ran: bool,
}

impl TransactionOperation for CountingOperation {
    fn execute(
        &mut self,
        _tx: &mut UnitOfWork,
    ) -> local_ios_agent_runtime::storage::StorageResult<()> {
        self.ran = true;
        Ok(())
    }
}

#[test]
fn transaction_runner_is_object_safe_and_returns_unit() {
    let runner: Box<dyn TransactionRunner> = Box::new(InMemoryTransactionRunner::default());
    let mut op = CountingOperation { ran: false };

    runner
        .run(TransactionName::new("test.counting"), &mut op)
        .unwrap();

    assert!(op.ran);
}

#[test]
fn pending_store_write_commit_phase_is_infallible_contract() {
    let transaction_source = include_str!("../src/storage/transaction.rs");

    assert!(transaction_source.contains("fn commit(self: Box<Self>);"));
    assert!(!transaction_source.contains("fn apply(self: Box<Self>) -> StorageResult<()>;"));
}

#[derive(Debug, Eq, PartialEq)]
struct RunStartCommit {
    run_id: String,
}

struct RunStartOperation {
    result: Option<RunStartCommit>,
}

impl TransactionOperation for RunStartOperation {
    fn execute(
        &mut self,
        _tx: &mut UnitOfWork,
    ) -> local_ios_agent_runtime::storage::StorageResult<()> {
        self.result = Some(RunStartCommit {
            run_id: "run_1".to_string(),
        });
        Ok(())
    }
}

#[test]
fn application_operation_owns_typed_result() {
    let runner = InMemoryTransactionRunner::default();
    let mut op = RunStartOperation { result: None };

    runner
        .run(TransactionName::new("run.start"), &mut op)
        .unwrap();

    assert_eq!(op.result.unwrap().run_id, "run_1");
}

struct FailingEventOperation;

impl TransactionOperation for FailingEventOperation {
    fn execute(
        &mut self,
        tx: &mut UnitOfWork,
    ) -> local_ios_agent_runtime::storage::StorageResult<()> {
        tx.events()
            .append(EventRecord::new("run_1", "run.started"))?;
        Err(local_ios_agent_runtime::storage::StorageError::forced(
            "boom",
        ))
    }
}

struct FailingArchiveEventOperation {
    event_store: InMemoryEventStore,
    archive_store: InMemoryArchiveStore,
    archive_id: Option<ArchiveId>,
}

impl TransactionOperation for FailingArchiveEventOperation {
    fn execute(
        &mut self,
        tx: &mut UnitOfWork,
    ) -> local_ios_agent_runtime::storage::StorageResult<()> {
        self.event_store
            .append(tx, EventRecord::new("run_1", "model_call.started"))?;
        self.archive_id = Some(
            self.archive_store
                .append_immutable(tx, ArchiveRecord::new("run_1", "prompt"))?,
        );
        Err(local_ios_agent_runtime::storage::StorageError::forced(
            "boom",
        ))
    }
}

#[test]
fn transaction_rolls_back_events_on_error() {
    let runner = InMemoryTransactionRunner::default();
    let mut op = FailingEventOperation;

    let error = runner
        .run(TransactionName::new("run.start"), &mut op)
        .unwrap_err();

    assert_eq!(error.code(), "storage.forced");
    assert!(runner.event_store().stream("run_1").unwrap().is_empty());
}

#[test]
fn transaction_rolls_back_archives_and_events_on_error() {
    let runner = InMemoryTransactionRunner::default();
    let event_store = runner.event_store();
    let archive_store = runner.archive_store();
    let mut op = FailingArchiveEventOperation {
        event_store: event_store.clone(),
        archive_store: archive_store.clone(),
        archive_id: None,
    };

    let error = runner
        .run(TransactionName::new("archive.pre_call"), &mut op)
        .unwrap_err();

    let archive_id = op.archive_id.expect("operation reserved archive id");
    assert_eq!(error.code(), "storage.forced");
    assert!(event_store.stream("run_1").unwrap().is_empty());
    assert_eq!(
        archive_store.get(archive_id).unwrap_err().code(),
        "storage.archive_not_found"
    );
}

#[test]
fn rollback_does_not_reserve_event_sequences_or_archive_ids() {
    let runner = InMemoryTransactionRunner::default();
    let event_store = runner.event_store();
    let archive_store = runner.archive_store();
    let mut failing_op = FailingArchiveEventOperation {
        event_store: event_store.clone(),
        archive_store: archive_store.clone(),
        archive_id: None,
    };

    runner
        .run(TransactionName::new("archive.pre_call"), &mut failing_op)
        .unwrap_err();

    let mut success_op = ArchiveEventOperation {
        event_store: event_store.clone(),
        archive_store: archive_store.clone(),
        archive_id: None,
    };

    runner
        .run(TransactionName::new("archive.pre_call"), &mut success_op)
        .unwrap();

    let events = event_store.stream("run_1").unwrap();
    assert_eq!(events[0].sequence.as_u64(), 1);
    assert_eq!(success_op.archive_id.unwrap().as_u64(), 1);
}

struct InvalidEventBatchOperation {
    archive_store: InMemoryArchiveStore,
    archive_id: Option<ArchiveId>,
}

impl TransactionOperation for InvalidEventBatchOperation {
    fn execute(
        &mut self,
        tx: &mut UnitOfWork,
    ) -> local_ios_agent_runtime::storage::StorageResult<()> {
        self.archive_id = Some(
            self.archive_store
                .append_immutable(tx, ArchiveRecord::new("run_1", "prompt"))?,
        );

        let mut started = EventRecord::new("run_1", "model_call.started");
        started.sequence = local_ios_agent_runtime::storage::EventSequence::new(1);
        tx.events().append(started)?;

        let mut completed = EventRecord::new("run_1", "model_call.completed");
        completed.sequence = local_ios_agent_runtime::storage::EventSequence::new(1);
        tx.events().append(completed)?;

        Ok(())
    }
}

#[test]
fn event_validation_failure_rolls_back_archives() {
    let runner = InMemoryTransactionRunner::default();
    let event_store = runner.event_store();
    let archive_store = runner.archive_store();
    let mut op = InvalidEventBatchOperation {
        archive_store: archive_store.clone(),
        archive_id: None,
    };

    let error = runner
        .run(TransactionName::new("archive.pre_call"), &mut op)
        .unwrap_err();

    let archive_id = op.archive_id.expect("operation reserved archive id");
    assert_eq!(error.code(), "storage.event_sequence_conflict");
    assert!(event_store.stream("run_1").unwrap().is_empty());
    assert_eq!(
        archive_store.get(archive_id).unwrap_err().code(),
        "storage.archive_not_found"
    );
}

struct ArchiveEventOperation {
    event_store: InMemoryEventStore,
    archive_store: InMemoryArchiveStore,
    archive_id: Option<ArchiveId>,
}

impl TransactionOperation for ArchiveEventOperation {
    fn execute(
        &mut self,
        tx: &mut UnitOfWork,
    ) -> local_ios_agent_runtime::storage::StorageResult<()> {
        self.event_store
            .append(tx, EventRecord::new("run_1", "model_call.started"))?;
        self.archive_id = Some(
            self.archive_store
                .append_immutable(tx, ArchiveRecord::new("run_1", "prompt"))?,
        );
        Ok(())
    }
}

#[test]
fn transaction_commits_archives_and_events_together() {
    let runner = InMemoryTransactionRunner::default();
    let event_store = runner.event_store();
    let archive_store = runner.archive_store();
    let mut op = ArchiveEventOperation {
        event_store: event_store.clone(),
        archive_store: archive_store.clone(),
        archive_id: None,
    };

    runner
        .run(TransactionName::new("archive.pre_call"), &mut op)
        .unwrap();

    let archive_id = op.archive_id.expect("operation reserved archive id");
    assert_eq!(event_store.stream("run_1").unwrap().len(), 1);
    assert_eq!(archive_store.get(archive_id).unwrap().kind(), "prompt");
}

struct BoundaryTransactionOperation {
    event_store: InMemoryEventStore,
    archive_store: InMemoryArchiveStore,
    stream_id: &'static str,
    event_type: &'static str,
    archive_kinds: Vec<&'static str>,
    archive_ids: Vec<ArchiveId>,
    fail_after_writes: bool,
}

impl TransactionOperation for BoundaryTransactionOperation {
    fn execute(
        &mut self,
        tx: &mut UnitOfWork,
    ) -> local_ios_agent_runtime::storage::StorageResult<()> {
        for kind in &self.archive_kinds {
            self.archive_ids.push(
                self.archive_store
                    .append_immutable(tx, ArchiveRecord::new(self.stream_id, *kind))?,
            );
        }

        self.event_store
            .append(tx, EventRecord::new(self.stream_id, self.event_type))?;

        if self.fail_after_writes {
            return Err(local_ios_agent_runtime::storage::StorageError::forced(
                "boom",
            ));
        }

        Ok(())
    }
}

#[test]
fn package_install_like_transaction_rolls_back_all_records() {
    let runner = InMemoryTransactionRunner::default();
    let event_store = runner.event_store();
    let archive_store = runner.archive_store();
    let mut op = BoundaryTransactionOperation {
        event_store: event_store.clone(),
        archive_store: archive_store.clone(),
        stream_id: "package_1",
        event_type: "PackageInstalled",
        archive_kinds: vec![
            "package_installation",
            "imported_component_version",
            "agent_profile",
            "agent_package_lock",
        ],
        archive_ids: Vec::new(),
        fail_after_writes: true,
    };

    runner
        .run(TransactionName::new("package.install"), &mut op)
        .unwrap_err();

    assert!(event_store.stream("package_1").unwrap().is_empty());
    for archive_id in op.archive_ids {
        assert_eq!(
            archive_store.get(archive_id).unwrap_err().code(),
            "storage.archive_not_found"
        );
    }
}

#[test]
fn component_publish_like_transaction_commits_version_pointer_and_event() {
    let runner = InMemoryTransactionRunner::default();
    let event_store = runner.event_store();
    let archive_store = runner.archive_store();
    let mut op = BoundaryTransactionOperation {
        event_store: event_store.clone(),
        archive_store: archive_store.clone(),
        stream_id: "component_1",
        event_type: "ComponentPublished",
        archive_kinds: vec!["user_component_version", "published_pointer"],
        archive_ids: Vec::new(),
        fail_after_writes: false,
    };

    runner
        .run(TransactionName::new("component.publish"), &mut op)
        .unwrap();

    assert_eq!(event_store.stream("component_1").unwrap().len(), 1);
    assert_eq!(
        archive_store.get(op.archive_ids[0]).unwrap().kind(),
        "user_component_version"
    );
    assert_eq!(
        archive_store.get(op.archive_ids[1]).unwrap().kind(),
        "published_pointer"
    );
}

#[test]
fn run_start_like_transaction_commits_snapshot_plan_state_and_event() {
    let runner = InMemoryTransactionRunner::default();
    let event_store = runner.event_store();
    let archive_store = runner.archive_store();
    let mut op = BoundaryTransactionOperation {
        event_store: event_store.clone(),
        archive_store: archive_store.clone(),
        stream_id: "run_1",
        event_type: "RunStarted",
        archive_kinds: vec!["resolved_run_snapshot", "execution_plan", "run_state"],
        archive_ids: Vec::new(),
        fail_after_writes: false,
    };

    runner
        .run(TransactionName::new("run.start"), &mut op)
        .unwrap();

    let events = event_store.stream("run_1").unwrap();
    assert_eq!(events[0].event_type(), "RunStarted");
    assert_eq!(events[0].sequence.as_u64(), 1);
    assert_eq!(
        archive_store.get(op.archive_ids[0]).unwrap().kind(),
        "resolved_run_snapshot"
    );
    assert_eq!(
        archive_store.get(op.archive_ids[1]).unwrap().kind(),
        "execution_plan"
    );
    assert_eq!(
        archive_store.get(op.archive_ids[2]).unwrap().kind(),
        "run_state"
    );
}

#[test]
fn checkpoint_like_transaction_rolls_back_checkpoint_event_and_run_state() {
    let runner = InMemoryTransactionRunner::default();
    let event_store = runner.event_store();
    let archive_store = runner.archive_store();
    let mut op = BoundaryTransactionOperation {
        event_store: event_store.clone(),
        archive_store: archive_store.clone(),
        stream_id: "run_1",
        event_type: "CheckpointCommitted",
        archive_kinds: vec!["checkpoint_record", "effect_idempotency", "run_state"],
        archive_ids: Vec::new(),
        fail_after_writes: true,
    };

    runner
        .run(TransactionName::new("checkpoint.commit"), &mut op)
        .unwrap_err();

    assert!(event_store.stream("run_1").unwrap().is_empty());
    for archive_id in op.archive_ids {
        assert_eq!(
            archive_store.get(archive_id).unwrap_err().code(),
            "storage.archive_not_found"
        );
    }
}

#[test]
fn archive_pre_call_and_post_call_are_separate_ordered_transactions() {
    let runner = InMemoryTransactionRunner::default();
    let event_store = runner.event_store();
    let archive_store = runner.archive_store();
    let mut pre_call = BoundaryTransactionOperation {
        event_store: event_store.clone(),
        archive_store: archive_store.clone(),
        stream_id: "run_1",
        event_type: "ModelCallStarted",
        archive_kinds: vec!["prompt_archive", "context_archive"],
        archive_ids: Vec::new(),
        fail_after_writes: false,
    };
    let mut post_call = BoundaryTransactionOperation {
        event_store: event_store.clone(),
        archive_store: archive_store.clone(),
        stream_id: "run_1",
        event_type: "ModelCallCompleted",
        archive_kinds: vec!["usage_metadata"],
        archive_ids: Vec::new(),
        fail_after_writes: false,
    };

    runner
        .run(TransactionName::new("archive.pre_call"), &mut pre_call)
        .unwrap();
    runner
        .run(TransactionName::new("archive.post_call"), &mut post_call)
        .unwrap();

    let events = event_store.stream("run_1").unwrap();
    assert_eq!(events[0].event_type(), "ModelCallStarted");
    assert_eq!(events[0].sequence.as_u64(), 1);
    assert_eq!(events[1].event_type(), "ModelCallCompleted");
    assert_eq!(events[1].sequence.as_u64(), 2);
    assert_eq!(
        archive_store.get(pre_call.archive_ids[0]).unwrap().kind(),
        "prompt_archive"
    );
    assert_eq!(
        archive_store.get(pre_call.archive_ids[1]).unwrap().kind(),
        "context_archive"
    );
    assert_eq!(
        archive_store.get(post_call.archive_ids[0]).unwrap().kind(),
        "usage_metadata"
    );
}

#[test]
fn migration_plan_is_forward_only() {
    let backward = MigrationStep::new(
        SchemaVersion::new(2),
        SchemaVersion::new(1),
        "drop_user_configuration",
    )
    .unwrap_err();
    assert_eq!(backward.code(), "storage.migration_not_forward");

    let plan = MigrationPlan::new(vec![
        MigrationStep::new(
            SchemaVersion::new(1),
            SchemaVersion::new(2),
            "create_events",
        )
        .unwrap(),
        MigrationStep::new(
            SchemaVersion::new(2),
            SchemaVersion::new(3),
            "create_archives",
        )
        .unwrap(),
    ])
    .unwrap();

    assert_eq!(
        plan.target_version(SchemaVersion::new(1)).unwrap().as_u32(),
        3
    );
}

struct TestRepository;

impl StorageRepository for TestRepository {
    fn repository_name(&self) -> RepositoryName {
        RepositoryName::new("test.repository")
    }
}

#[test]
fn repository_contract_is_object_safe_and_business_logic_free() {
    let repository: Box<dyn StorageRepository> = Box::new(TestRepository);

    assert_eq!(repository.repository_name().as_str(), "test.repository");
}

#[test]
fn event_and_archive_store_contracts_are_object_safe() {
    let event_store: Box<dyn EventStore> = Box::new(InMemoryEventStore::default());
    let archive_store: Box<dyn ArchiveStore> = Box::new(InMemoryArchiveStore::default());
    let mut tx = UnitOfWork::default();

    event_store
        .append(&mut tx, EventRecord::new("run_1", "run.started"))
        .unwrap();
    archive_store
        .append_immutable(&mut tx, ArchiveRecord::new("run_1", "context"))
        .unwrap();
    assert!(event_store.stream("missing").unwrap().is_empty());
    assert_eq!(
        archive_store
            .replace(ArchiveId::new(1), ArchiveRecord::new("run_1", "changed"))
            .unwrap_err()
            .code(),
        "storage.archive_append_only"
    );
}

struct TwoEventOperation {
    event_store: InMemoryEventStore,
}

impl TransactionOperation for TwoEventOperation {
    fn execute(
        &mut self,
        tx: &mut UnitOfWork,
    ) -> local_ios_agent_runtime::storage::StorageResult<()> {
        self.event_store
            .append(tx, EventRecord::new("run_1", "run.started"))?;
        self.event_store
            .append(tx, EventRecord::new("run_1", "model_call.started"))?;
        Ok(())
    }
}

#[test]
fn event_store_preserves_sequence() {
    let runner = InMemoryTransactionRunner::default();
    let store = runner.event_store();
    let mut op = TwoEventOperation {
        event_store: store.clone(),
    };

    runner
        .run(TransactionName::new("event.sequence"), &mut op)
        .unwrap();

    let events = store.stream("run_1").unwrap();

    assert_eq!(events[0].sequence.as_u64(), 1);
    assert_eq!(events[1].sequence.as_u64(), 2);
}

struct ArchiveOnlyOperation {
    archive_store: InMemoryArchiveStore,
    archive_id: Option<ArchiveId>,
}

impl TransactionOperation for ArchiveOnlyOperation {
    fn execute(
        &mut self,
        tx: &mut UnitOfWork,
    ) -> local_ios_agent_runtime::storage::StorageResult<()> {
        self.archive_id = Some(
            self.archive_store
                .append_immutable(tx, ArchiveRecord::new("run_1", "context"))?,
        );
        Ok(())
    }
}

#[test]
fn archive_store_is_append_only() {
    let runner = InMemoryTransactionRunner::default();
    let store = runner.archive_store();
    let mut op = ArchiveOnlyOperation {
        archive_store: store.clone(),
        archive_id: None,
    };

    runner
        .run(TransactionName::new("archive.append_only"), &mut op)
        .unwrap();

    let error = store
        .replace(
            op.archive_id.expect("archive id"),
            ArchiveRecord::new("run_1", "changed"),
        )
        .unwrap_err();

    assert_eq!(error.to_string(), "archive records are append-only");
}

#[test]
fn storage_contract_does_not_define_business_outcome_enum() {
    let storage_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/storage");

    for entry in std::fs::read_dir(storage_dir).unwrap() {
        let path = entry.unwrap().path();
        if path.extension().and_then(|extension| extension.to_str()) != Some("rs") {
            continue;
        }

        let source = std::fs::read_to_string(&path).unwrap();
        assert!(
            !source.contains("TransactionOutcome"),
            "{} must not define a centralized business outcome enum",
            path.display()
        );
        assert!(
            !source.contains("fn run<"),
            "{} must keep TransactionRunner::run object-safe and non-generic",
            path.display()
        );
        for forbidden in [
            "resolver",
            "planner",
            "provider adapter",
            "ToolExecutor",
            "Swift UI",
            "Keychain",
            "InferenceBackend",
            "GenerationSession",
        ] {
            assert!(
                !source.contains(forbidden),
                "{} must not embed {} business logic",
                path.display(),
                forbidden
            );
        }
        assert!(
            !source.contains("pub fn append_immediate"),
            "{} must not expose non-transactional event writes",
            path.display()
        );
        assert!(
            !source.contains("pub fn append(&self, record: ArchiveRecord"),
            "{} must not expose non-transactional archive writes",
            path.display()
        );
    }
}
