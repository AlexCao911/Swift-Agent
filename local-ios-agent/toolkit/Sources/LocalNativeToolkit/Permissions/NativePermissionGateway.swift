public enum NativePermissionReadiness: Equatable, Sendable {
    case ready
    case needsUserGrant(scope: NativePermissionScope, repair: NativePermissionRepair)
    case denied(scope: NativePermissionScope, repair: NativePermissionRepair)
    case unavailable(scope: NativePermissionScope, reason: String)
}

public enum NativePermissionRepairAction: Equatable, Sendable {
    case none
    case openSettings
    case requestPermission(scope: NativePermissionScope)
}

public struct NativePermissionRepair: Equatable, Sendable {
    public var title: String
    public var message: String
    public var action: NativePermissionRepairAction

    public init(title: String, message: String, action: NativePermissionRepairAction) {
        self.title = title
        self.message = message
        self.action = action
    }
}

public protocol NativePermissionGateway: Sendable {
    func readiness(for scope: NativePermissionScope?) async -> NativePermissionReadiness
    func requestPermission(for scope: NativePermissionScope) async -> NativePermissionReadiness
}

public struct StoreBackedNativePermissionGateway: NativePermissionGateway {
    public typealias RequestHandler = @Sendable (NativePermissionScope) async -> NativePermissionState

    private let store: PermissionStore
    private let requestHandler: RequestHandler

    public init(
        store: PermissionStore,
        requestHandler: @escaping RequestHandler = { _ in .unknown }
    ) {
        self.store = store
        self.requestHandler = requestHandler
    }

    public func readiness(for scope: NativePermissionScope?) async -> NativePermissionReadiness {
        guard let scope else {
            return .ready
        }
        if scope.name == "calendar.events.user_confirmed_create" {
            return .ready
        }

        let permissionScope = Self.permissionScope(for: scope)
        let state = await store.state(for: permissionScope)
        switch state {
        case .granted:
            return .ready
        case .unknown:
            return .needsUserGrant(
                scope: scope,
                repair: grantRepair(for: permissionScope)
            )
        case .denied:
            return .denied(
                scope: scope,
                repair: deniedRepair(for: permissionScope)
            )
        case .restricted:
            return .unavailable(scope: scope, reason: "restricted")
        }
    }

    public func requestPermission(for scope: NativePermissionScope) async -> NativePermissionReadiness {
        let permissionScope = Self.permissionScope(for: scope)
        let state = await requestHandler(permissionScope)
        await store.setState(state, for: permissionScope)
        return await readiness(for: scope)
    }

    private static func permissionScope(for scope: NativePermissionScope) -> NativePermissionScope {
        switch scope.name {
        case "reminders.create_reminder":
            return NativePermissionScope("reminders")
        default:
            return scope
        }
    }

    private func grantRepair(for scope: NativePermissionScope) -> NativePermissionRepair {
        NativePermissionRepair(
            title: "\(displayName(for: scope)) Access Needed",
            message: "Grant \(displayName(for: scope).lowercased()) access to use this tool.",
            action: .requestPermission(scope: scope)
        )
    }

    private func deniedRepair(for scope: NativePermissionScope) -> NativePermissionRepair {
        NativePermissionRepair(
            title: "\(displayName(for: scope)) Access Denied",
            message: "Enable \(displayName(for: scope).lowercased()) access in Settings to use this tool.",
            action: .openSettings
        )
    }

    private func displayName(for scope: NativePermissionScope) -> String {
        if scope.name.hasPrefix("calendar.") {
            return "Calendar"
        }
        if scope.name.hasPrefix("reminders") {
            return "Reminders"
        }
        return "Native Tool"
    }
}
