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
            activeModel: ActiveModelSummary(
                providerId: "mock",
                modelId: "mock",
                displayName: "Mock Model",
                route: .cloud(providerId: "mock"),
                readiness: .ready
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
        #expect(snapshot.modelProviderSummary == "Mock Model ready")
        #expect(snapshot.activeAgentSummary == "Research Agent revision 3")
        #expect(snapshot.advancedDebugEnabled == true)
        #expect(snapshot.entryPoints.map(\.id) == ["export", "reset", "debug"])
    }

    @Test("settings snapshot marks missing model honestly")
    func settingsSnapshotMarksMissingModelHonestly() {
        let snapshot = PrivacySettingsProjection.project(
            activeAgent: nil,
            activeModel: nil,
            toolRows: [],
            advancedDebugEnabled: false
        )

        #expect(snapshot.modelProviderSummary == "No active model selected")
        #expect(snapshot.activeAgentSummary == "No active agent selected")
        #expect(snapshot.toolPermissionSummary == "No native tools registered")
    }
}
