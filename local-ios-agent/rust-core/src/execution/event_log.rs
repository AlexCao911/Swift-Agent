use std::collections::BTreeMap;
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex};

#[derive(Clone, Debug, Default)]
pub struct InMemoryExecutionEventRepository {
    inner: Arc<Mutex<BTreeMap<String, Vec<ExecutionEvent>>>>,
    subscribers: Arc<Mutex<BTreeMap<String, Vec<Sender<ExecutionEvent>>>>>,
}

pub trait ExecutionEventRepository: Clone + Send + Sync + 'static {
    fn append(&self, run_id: String, code: String, payload: String) -> ExecutionEvent;
    fn replay_after(&self, run_id: &str, from_sequence: u64) -> Vec<ExecutionEvent>;
    fn subscribe_live(&self, run_id: &str) -> Receiver<ExecutionEvent>;
}

#[derive(Clone, Debug)]
pub struct ExecutionEventLog<R: ExecutionEventRepository = InMemoryExecutionEventRepository> {
    repository: R,
}

#[derive(Debug)]
pub struct ExecutionEventStream {
    replay: Vec<ExecutionEvent>,
    live: Receiver<ExecutionEvent>,
    next_live_after_sequence: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ExecutionEvent {
    run_id: String,
    sequence: u64,
    code: String,
    payload: String,
}

impl Default for ExecutionEventLog<InMemoryExecutionEventRepository> {
    fn default() -> Self {
        Self::new(InMemoryExecutionEventRepository::default())
    }
}

impl<R: ExecutionEventRepository> ExecutionEventLog<R> {
    pub fn new(repository: R) -> Self {
        Self { repository }
    }

    pub fn append(&self, run_id: impl Into<String>, code: impl Into<String>) -> ExecutionEvent {
        let code = code.into();
        self.repository.append(run_id.into(), code.clone(), code)
    }

    pub fn append_with_payload(
        &self,
        run_id: impl Into<String>,
        code: impl Into<String>,
        payload: impl Into<String>,
    ) -> ExecutionEvent {
        self.repository
            .append(run_id.into(), code.into(), payload.into())
    }

    pub fn replay(&self, run_id: &str, from_sequence: Option<u64>) -> Vec<ExecutionEvent> {
        self.repository
            .replay_after(run_id, from_sequence.unwrap_or(0))
    }

    pub fn subscribe(&self, run_id: &str, from_sequence: Option<u64>) -> ExecutionEventStream {
        let live = self.repository.subscribe_live(run_id);
        let replay = self.replay(run_id, from_sequence);
        ExecutionEventStream::new(replay, live)
    }
}

impl ExecutionEventRepository for InMemoryExecutionEventRepository {
    fn append(&self, run_id: String, code: String, payload: String) -> ExecutionEvent {
        let event = {
            let mut inner = self
                .inner
                .lock()
                .expect("execution event repository poisoned");
            let events = inner.entry(run_id.clone()).or_default();
            let sequence = events.last().map(|event| event.sequence + 1).unwrap_or(1);
            let event = ExecutionEvent {
                run_id: run_id.clone(),
                sequence,
                code,
                payload,
            };
            events.push(event.clone());
            event
        };

        self.subscribers
            .lock()
            .expect("execution event subscriber registry poisoned")
            .entry(run_id)
            .or_default()
            .retain(|sender| sender.send(event.clone()).is_ok());
        event
    }

    fn replay_after(&self, run_id: &str, from_sequence: u64) -> Vec<ExecutionEvent> {
        self.inner
            .lock()
            .expect("execution event repository poisoned")
            .get(run_id)
            .cloned()
            .unwrap_or_default()
            .into_iter()
            .filter(|event| event.sequence > from_sequence)
            .collect()
    }

    fn subscribe_live(&self, run_id: &str) -> Receiver<ExecutionEvent> {
        let (sender, receiver) = mpsc::channel();
        self.subscribers
            .lock()
            .expect("execution event subscriber registry poisoned")
            .entry(run_id.to_string())
            .or_default()
            .push(sender);
        receiver
    }
}

impl ExecutionEventStream {
    fn new(replay: Vec<ExecutionEvent>, live: Receiver<ExecutionEvent>) -> Self {
        let next_live_after_sequence = replay
            .iter()
            .map(ExecutionEvent::sequence)
            .max()
            .unwrap_or(0);
        Self {
            replay,
            live,
            next_live_after_sequence,
        }
    }

    pub fn replay(&self) -> &[ExecutionEvent] {
        &self.replay
    }

    pub fn next_live(&mut self) -> Option<ExecutionEvent> {
        while let Ok(event) = self.live.recv() {
            if event.sequence() <= self.next_live_after_sequence {
                continue;
            }
            self.next_live_after_sequence = event.sequence();
            return Some(event);
        }
        None
    }
}

impl ExecutionEvent {
    pub fn sequence(&self) -> u64 {
        self.sequence
    }

    pub fn code(&self) -> &str {
        &self.code
    }

    pub fn payload(&self) -> &str {
        &self.payload
    }

    pub fn run_id(&self) -> &str {
        &self.run_id
    }
}
