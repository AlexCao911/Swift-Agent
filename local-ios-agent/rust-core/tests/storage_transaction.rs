use local_ios_agent_runtime::storage::{
    ArchiveId, ArchiveRecord, ArchiveStore, EventRecord, EventStore, InMemoryArchiveStore,
    InMemoryEventStore, InMemoryTransactionRunner, TransactionName, TransactionOperation,
    TransactionRunner, UnitOfWork,
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

#[test]
fn event_store_preserves_sequence() {
    let store = InMemoryEventStore::default();
    store
        .append_immediate(EventRecord::new("run_1", "run.started"))
        .unwrap();
    store
        .append_immediate(EventRecord::new("run_1", "model_call.started"))
        .unwrap();

    let events = store.stream("run_1").unwrap();

    assert_eq!(events[0].sequence.as_u64(), 1);
    assert_eq!(events[1].sequence.as_u64(), 2);
}

#[test]
fn archive_store_is_append_only() {
    let store = InMemoryArchiveStore::default();
    let id = store
        .append(ArchiveRecord::new("run_1", "context"))
        .unwrap();

    let error = store
        .replace(id, ArchiveRecord::new("run_1", "changed"))
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
    }
}
