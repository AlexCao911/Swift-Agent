use std::sync::atomic::{AtomicU64, Ordering};

#[derive(Debug, Default)]
pub struct IdGenerator {
    next: AtomicU64,
}

impl IdGenerator {
    pub fn new() -> Self {
        Self {
            next: AtomicU64::new(1),
        }
    }

    pub fn starting_at(next: u64) -> Self {
        Self {
            next: AtomicU64::new(next.max(1)),
        }
    }

    pub fn next_id(&self, prefix: &str) -> String {
        let value = self.next.fetch_add(1, Ordering::Relaxed);
        format!("{prefix}_{value}")
    }
}
