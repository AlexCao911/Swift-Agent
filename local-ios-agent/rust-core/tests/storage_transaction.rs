use local_ios_agent_runtime::storage::{
    ArchiveRecord, EventRecord, InMemoryArchiveStore, InMemoryEventStore,
    InMemoryTransactionRunner, TransactionName, TransactionOperation, TransactionRunner,
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
fn event_store_preserves_sequence() {
    let store = InMemoryEventStore::default();
    store
        .append(EventRecord::new("run_1", "run.started"))
        .unwrap();
    store
        .append(EventRecord::new("run_1", "model_call.started"))
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
