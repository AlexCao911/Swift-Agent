use super::{BindingId, InstanceId};

#[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd, Hash)]
pub struct SlotKey(String);

impl SlotKey {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ComponentBinding {
    id: BindingId,
    slot_key: SlotKey,
    instance_id: InstanceId,
}

impl ComponentBinding {
    pub fn new(id: BindingId, slot_key: SlotKey, instance_id: InstanceId) -> Self {
        Self {
            id,
            slot_key,
            instance_id,
        }
    }

    pub fn id(&self) -> &BindingId {
        &self.id
    }

    pub fn slot_key(&self) -> &SlotKey {
        &self.slot_key
    }

    pub fn instance_id(&self) -> &InstanceId {
        &self.instance_id
    }
}
