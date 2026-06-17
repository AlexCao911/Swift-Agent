use crate::core::{EntryId, RuntimeEvent, SessionId};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SessionCursor {
    pub session_id: SessionId,
    pub active_leaf: Option<EntryId>,
    pub next_sequence: u64,
}

impl SessionCursor {
    pub fn new(session_id: SessionId) -> Self {
        Self {
            session_id,
            active_leaf: None,
            next_sequence: 1,
        }
    }

    pub fn from_last_event(session_id: SessionId, last_event: Option<RuntimeEvent>) -> Self {
        match last_event {
            Some(event) => Self {
                session_id,
                active_leaf: Some(event.id),
                next_sequence: event.sequence + 1,
            },
            None => Self::new(session_id),
        }
    }
}
