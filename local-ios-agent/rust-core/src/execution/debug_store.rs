#[derive(Clone, Debug, Default)]
pub struct RunDebugStore;

impl RunDebugStore {
    pub fn archive_count(&self) -> usize {
        0
    }
}
