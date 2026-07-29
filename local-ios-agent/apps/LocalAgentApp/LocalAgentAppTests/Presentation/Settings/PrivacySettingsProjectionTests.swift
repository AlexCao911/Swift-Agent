import LocalAgentBridge
import LocalNativeToolkit
import Testing
@testable import LocalAgentApp

@Suite("Privacy settings projection")
@MainActor
struct PrivacySettingsProjectionTests {
    @Test("settings snapshot summarizes product privacy surfaces")
    func settingsSnapshotSummarizesProductPrivacySurfaces() {
        let snapshot = PrivacySettingsProjection.project(
            activeAgent: ActiveAgentRevisionSelection(
                profileId: "profile_1",
                profileRevisionId: 3,
                displayName: "Research Agent"
            ),
            toolRows: [
                ToolCenterRowState(
                    id: "calendar.search_events",
                    name: "calendar.search_events",
                    title: "Search Calendar",
                    mode: .background,
                    riskLevel: .readOnly,
                    permissionScope: "calendar.events.read_full",
                    approvalPolicy: .perCall,
                    readiness: .ready
                ),
                ToolCenterRowState(
                    id: "photos.pick_images",
                    name: "photos.pick_images",
                    title: "Pick Photos",
                    mode: .userMediated,
                    riskLevel: .confirm,
                    permissionScope: "photos.library.user_selected",
                    approvalPolicy: .perCall,
                    readiness: .needsUserGrant(
                        scope: NativePermissionScope("photos.library.user_selected"),
                        repair: NativePermissionRepair(
                            title: "Photos Access",
                            message: "Grant selected photo access",
                            action: .requestPermission(scope: NativePermissionScope("photos.library.user_selected"))
                        )
                    )
                ),
            ],
            advancedDebugEnabled: true
        )

        #expect(snapshot.toolPermissionSummary == "1 ready, 1 needs attention")
        #expect(snapshot.attachmentStorageSummary == "Attachments stay in the app sandbox and are referenced by opaque IDs.")
        #expect(snapshot.memoryRetentionSummary == "Run-only by default; memory candidates require explicit review.")
        #expect(snapshot.modelProviderSummary == "Host target is selected by Research Agent revision 3")
        #expect(snapshot.linuxGuestNetworkSummary.contains("independent network path"))
        #expect(snapshot.linuxGuestNetworkSummary.contains("does not pass through"))
        #expect(snapshot.activeAgentSummary == "Research Agent revision 3")
        #expect(snapshot.advancedDebugEnabled == true)
        #expect(snapshot.entryPoints.map(\.id) == ["export", "reset", "debug"])
    }

    @Test("settings snapshot marks missing agent host target honestly")
    func settingsSnapshotMarksMissingAgentHostTargetHonestly() {
        let snapshot = PrivacySettingsProjection.project(
            activeAgent: nil,
            toolRows: [],
            advancedDebugEnabled: false
        )

        #expect(snapshot.modelProviderSummary == "Select an Agent to inspect its host target")
        #expect(snapshot.activeAgentSummary == "No active agent selected")
        #expect(snapshot.toolPermissionSummary == "No native tools registered")
    }
}
