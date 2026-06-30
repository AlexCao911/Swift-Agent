use crate::user_customization::ComponentContent;

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct UserComponentId(pub u64);

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct UserComponentDraft {
    pub id: UserComponentId,
    pub content: ComponentContent,
}
