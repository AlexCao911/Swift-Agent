#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StreamBatcher {
    byte_threshold: usize,
    buffer: String,
}

impl StreamBatcher {
    pub fn new(byte_threshold: usize) -> Self {
        Self {
            byte_threshold,
            buffer: String::new(),
        }
    }

    pub fn push(&mut self, delta: &str) -> Option<String> {
        self.buffer.push_str(delta);
        if self.buffer.len() >= self.byte_threshold {
            return self.flush();
        }
        None
    }

    pub fn flush(&mut self) -> Option<String> {
        if self.buffer.is_empty() {
            return None;
        }
        Some(std::mem::take(&mut self.buffer))
    }
}
