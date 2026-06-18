#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PermissionState {
    NotDetermined,
    Granted,
    Denied,
    Restricted,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PermissionScope {
    pub name: String,
    pub state: PermissionState,
}
