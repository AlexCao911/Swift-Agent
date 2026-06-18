public actor PermissionStore {
    private var storedStates: [NativePermissionScope: NativePermissionState] = [:]

    public init() {}

    public func state(for scope: NativePermissionScope) -> NativePermissionState {
        storedStates[scope, default: .unknown]
    }

    public func setState(_ state: NativePermissionState, for scope: NativePermissionScope) {
        storedStates[scope] = state
    }

    public func states() -> [NativePermissionScope: NativePermissionState] {
        storedStates
    }
}
