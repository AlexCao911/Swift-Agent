import LocalAgentBridge
import LocalNativeToolkit
import Testing
@testable import LocalAgentApp

@Suite("State badge descriptors")
struct StateBadgeDescriptorTests {
    @Test("model readiness badge does not rely on color alone")
    func modelReadinessBadgeDoesNotRelyOnColorAlone() {
        let descriptor = StateBadgeDescriptor.modelReadiness(.missingConfiguration(reason: "weights_missing"))

        #expect(descriptor.label == "weights_missing")
        #expect(descriptor.systemImageName == "exclamationmark.circle")
        #expect(descriptor.accessibilityLabel == "Model readiness: weights_missing")
    }

    @Test("permission badge describes denied repair state")
    func permissionBadgeDescribesDeniedRepairState() {
        let descriptor = StateBadgeDescriptor.permission(.denied(
            scope: NativePermissionScope("calendar.events.read_full"),
            repair: NativePermissionRepair(
                title: "Calendar denied",
                message: "Open Settings",
                action: .openSettings
            )
        ))

        #expect(descriptor.label == "Permission denied")
        #expect(descriptor.systemImageName == "lock")
        #expect(descriptor.accessibilityLabel == "Permission: Permission denied")
    }

    @Test("revision badge includes exact revision")
    func revisionBadgeIncludesExactRevision() {
        let descriptor = StateBadgeDescriptor.revision(profileId: "profile_1", revisionId: 7)

        #expect(descriptor.label == "Rev 7")
        #expect(descriptor.accessibilityLabel == "Profile profile_1 revision 7")
    }
}
