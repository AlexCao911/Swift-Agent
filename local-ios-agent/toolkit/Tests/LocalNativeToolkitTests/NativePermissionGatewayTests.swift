import Testing
@testable import LocalNativeToolkit

@Suite("Native permission gateway")
struct NativePermissionGatewayTests {
    @Test
    func nilScopeIsReady() async {
        let gateway = StoreBackedNativePermissionGateway(store: PermissionStore())

        let readiness = await gateway.readiness(for: nil)

        #expect(readiness == .ready)
    }

    @Test
    func calendarReadFullNeedsExplicitUserGrantWhenUnknown() async {
        let scope = NativePermissionScope("calendar.events.read_full")
        let gateway = StoreBackedNativePermissionGateway(store: PermissionStore())

        let readiness = await gateway.readiness(for: scope)

        #expect(readiness == .needsUserGrant(
            scope: scope,
            repair: NativePermissionRepair(
                title: "Calendar Access Needed",
                message: "Grant calendar access to use this tool.",
                action: .requestPermission(scope: scope)
            )
        ))
    }

    @Test
    func deniedScopeReturnsOpenSettingsRepair() async {
        let scope = NativePermissionScope("calendar.events.read_full")
        let store = PermissionStore()
        await store.setState(.denied, for: scope)
        let gateway = StoreBackedNativePermissionGateway(store: store)

        let readiness = await gateway.readiness(for: scope)

        #expect(readiness == .denied(
            scope: scope,
            repair: NativePermissionRepair(
                title: "Calendar Access Denied",
                message: "Enable calendar access in Settings to use this tool.",
                action: .openSettings
            )
        ))
    }

    @Test
    func calendarWriteOnlyDoesNotSatisfyReadFullAccess() async {
        let store = PermissionStore()
        await store.setState(.granted, for: NativePermissionScope("calendar.events.write_only"))
        let readScope = NativePermissionScope("calendar.events.read_full")
        let gateway = StoreBackedNativePermissionGateway(store: store)

        let readiness = await gateway.readiness(for: readScope)

        #expect(readiness == .needsUserGrant(
            scope: readScope,
            repair: NativePermissionRepair(
                title: "Calendar Access Needed",
                message: "Grant calendar access to use this tool.",
                action: .requestPermission(scope: readScope)
            )
        ))
    }

    @Test
    func remindersDeniedDoesNotSatisfyCreateReminder() async {
        let baseScope = NativePermissionScope("reminders")
        let createScope = NativePermissionScope("reminders.create_reminder")
        let store = PermissionStore()
        await store.setState(.denied, for: baseScope)
        let gateway = StoreBackedNativePermissionGateway(store: store)

        let readiness = await gateway.readiness(for: createScope)

        #expect(readiness == .denied(
            scope: createScope,
            repair: NativePermissionRepair(
                title: "Reminders Access Denied",
                message: "Enable reminders access in Settings to use this tool.",
                action: .openSettings
            )
        ))
    }

    @Test
    func requestPermissionReturnsRefreshedReadiness() async {
        let scope = NativePermissionScope("reminders.create_reminder")
        let store = PermissionStore()
        let gateway = StoreBackedNativePermissionGateway(
            store: store,
            requestHandler: { requestedScope in
                #expect(requestedScope == NativePermissionScope("reminders"))
                return .granted
            }
        )

        let readiness = await gateway.requestPermission(for: scope)

        #expect(readiness == .ready)
        #expect(await store.state(for: NativePermissionScope("reminders")) == .granted)
    }
}
