#if canImport(EventKit) && os(iOS)
import EventKit
#endif

public struct EventKitPermissionAdapter: NativePermissionGateway {
#if canImport(EventKit) && os(iOS)
    private let eventStore: EKEventStore

    public init(eventStore: EKEventStore) {
        self.eventStore = eventStore
    }
#else
    public init() {}
#endif

    public func readiness(for scope: NativePermissionScope?) async -> NativePermissionReadiness {
        guard let scope else {
            return .ready
        }

        switch scope.name {
        case "calendar.events.user_confirmed_create":
            return .ready
        case "calendar.events.read_full", "calendar.events.write_only":
            return eventReadiness(for: scope)
        case "reminders", "reminders.create_reminder":
            return reminderReadiness(for: scope)
        default:
            return .unavailable(scope: scope, reason: "unsupported_scope")
        }
    }

    public func requestPermission(for scope: NativePermissionScope) async -> NativePermissionReadiness {
#if canImport(EventKit) && os(iOS)
        switch scope.name {
        case "calendar.events.read_full":
            if #available(iOS 17.0, *) {
                _ = await requestFullCalendarAccess()
            } else {
                _ = await requestLegacyAccess(to: .event)
            }
        case "calendar.events.write_only":
            if #available(iOS 17.0, *) {
                _ = await requestWriteOnlyCalendarAccess()
            } else {
                _ = await requestLegacyAccess(to: .event)
            }
        case "reminders", "reminders.create_reminder":
            if #available(iOS 17.0, *) {
                _ = await requestFullReminderAccess()
            } else {
                _ = await requestLegacyAccess(to: .reminder)
            }
        default:
            break
        }
#endif
        return await readiness(for: scope)
    }

    private func eventReadiness(for scope: NativePermissionScope) -> NativePermissionReadiness {
#if canImport(EventKit) && os(iOS)
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(iOS 17.0, *) {
            switch (scope.name, status) {
            case ("calendar.events.read_full", .fullAccess):
                return .ready
            case ("calendar.events.write_only", .fullAccess), ("calendar.events.write_only", .writeOnly):
                return .ready
            case (_, .notDetermined):
                return .needsUserGrant(scope: scope, repair: grantRepair(for: scope))
            case (_, .denied):
                return .denied(scope: scope, repair: deniedRepair(for: scope))
            case (_, .restricted):
                return .unavailable(scope: scope, reason: "restricted")
            default:
                return .needsUserGrant(scope: scope, repair: grantRepair(for: scope))
            }
        } else {
            switch status {
            case .authorized:
                return .ready
            case .notDetermined:
                return .needsUserGrant(scope: scope, repair: grantRepair(for: scope))
            case .denied:
                return .denied(scope: scope, repair: deniedRepair(for: scope))
            case .restricted:
                return .unavailable(scope: scope, reason: "restricted")
            @unknown default:
                return .unavailable(scope: scope, reason: "unknown_authorization_status")
            }
        }
#else
        return .unavailable(scope: scope, reason: "eventkit_unavailable")
#endif
    }

    private func reminderReadiness(for scope: NativePermissionScope) -> NativePermissionReadiness {
#if canImport(EventKit) && os(iOS)
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if #available(iOS 17.0, *) {
            switch status {
            case .fullAccess:
                return .ready
            case .notDetermined:
                return .needsUserGrant(scope: scope, repair: grantRepair(for: NativePermissionScope("reminders")))
            case .denied:
                return .denied(scope: scope, repair: deniedRepair(for: NativePermissionScope("reminders")))
            case .restricted:
                return .unavailable(scope: scope, reason: "restricted")
            default:
                return .needsUserGrant(scope: scope, repair: grantRepair(for: NativePermissionScope("reminders")))
            }
        } else {
            switch status {
            case .authorized:
                return .ready
            case .notDetermined:
                return .needsUserGrant(scope: scope, repair: grantRepair(for: NativePermissionScope("reminders")))
            case .denied:
                return .denied(scope: scope, repair: deniedRepair(for: NativePermissionScope("reminders")))
            case .restricted:
                return .unavailable(scope: scope, reason: "restricted")
            @unknown default:
                return .unavailable(scope: scope, reason: "unknown_authorization_status")
            }
        }
#else
        return .unavailable(scope: scope, reason: "eventkit_unavailable")
#endif
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

#if canImport(EventKit) && os(iOS)
    @available(iOS 17.0, *)
    private func requestFullCalendarAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            eventStore.requestFullAccessToEvents { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    @available(iOS 17.0, *)
    private func requestWriteOnlyCalendarAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            eventStore.requestWriteOnlyAccessToEvents { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    @available(iOS 17.0, *)
    private func requestFullReminderAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            eventStore.requestFullAccessToReminders { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    private func requestLegacyAccess(to entityType: EKEntityType) async -> Bool {
        await withCheckedContinuation { continuation in
            eventStore.requestAccess(to: entityType) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }
#endif
}
