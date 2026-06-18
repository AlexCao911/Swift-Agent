import Testing
@testable import LocalNativeToolkit

@Suite("Native tool model")
struct NativeToolTests {
    @Test
    func permissionStoreDefaultsToUnknownAndRecordsStateByScope() async {
        let store = PermissionStore()
        let calendar = NativePermissionScope("calendar.events")
        let reminders = NativePermissionScope("reminders")

        #expect(await store.state(for: calendar) == .unknown)

        await store.setState(.granted, for: calendar)
        await store.setState(.denied, for: reminders)

        #expect(await store.state(for: calendar) == .granted)
        #expect(await store.state(for: reminders) == .denied)
        #expect(await store.states() == [
            calendar: .granted,
            reminders: .denied,
        ])
    }

    @Test
    func nativeToolSchemaCarriesExecutionOnlyMetadata() {
        let schema = NativeToolSchema(
            name: "calendar.search_events",
            description: "Search calendar events",
            inputSchema: .object(properties: [
                "query": .string(),
            ]),
            riskLevel: .confirm,
            permissionScope: NativePermissionScope("calendar.events"),
            availability: .unavailable(reason: "Calendar access disabled")
        )

        #expect(schema.name == "calendar.search_events")
        #expect(schema.riskLevel == .confirm)
        #expect(schema.permissionScope == NativePermissionScope("calendar.events"))
        #expect(schema.availability == .unavailable(reason: "Calendar access disabled"))
    }

    @Test
    func jsonSchemaObjectRendersPropertiesDeterministically() {
        let schema = JSONSchemaDTO.object(properties: [
            "query": .string(),
        ])

        #expect(schema.jsonString == #"{"type":"object","properties":{"query":{"type":"string"}}}"#)
    }
}
