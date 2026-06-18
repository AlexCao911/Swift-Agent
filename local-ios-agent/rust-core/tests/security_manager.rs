use local_ios_agent_runtime::security::{PermissionScope, PermissionState};

#[test]
fn permission_scope_models_ios_permission_state() {
    let scope = PermissionScope {
        name: "calendar.read".into(),
        state: PermissionState::NotDetermined,
    };

    assert_eq!(scope.name, "calendar.read");
    assert_eq!(scope.state, PermissionState::NotDetermined);
}
