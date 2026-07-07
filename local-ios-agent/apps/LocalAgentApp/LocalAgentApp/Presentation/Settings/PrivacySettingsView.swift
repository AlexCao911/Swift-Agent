import SwiftUI

struct PrivacySettingsSnapshot: Equatable, Sendable {
    var activeAgentSummary: String
    var toolPermissionSummary: String
    var attachmentStorageSummary: String
    var memoryRetentionSummary: String
    var modelProviderSummary: String
    var advancedDebugEnabled: Bool
    var entryPoints: [PrivacySettingsEntryPoint]
}

struct PrivacySettingsEntryPoint: Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var systemImageName: String
}

enum PrivacySettingsProjection {
    static func project(
        activeAgent: ActiveAgentRevisionSelection?,
        activeModel: ActiveModelSummary?,
        toolRows: [ToolCenterRowState],
        advancedDebugEnabled: Bool
    ) -> PrivacySettingsSnapshot {
        PrivacySettingsSnapshot(
            activeAgentSummary: agentSummary(activeAgent),
            toolPermissionSummary: toolPermissionSummary(toolRows),
            attachmentStorageSummary: "Attachments stay in the app sandbox and are referenced by opaque IDs.",
            memoryRetentionSummary: "Run-only by default; memory candidates require explicit review.",
            modelProviderSummary: modelSummary(activeModel),
            advancedDebugEnabled: advancedDebugEnabled,
            entryPoints: [
                PrivacySettingsEntryPoint(id: "export", title: "Export Data", systemImageName: "square.and.arrow.up"),
                PrivacySettingsEntryPoint(id: "reset", title: "Reset Local Data", systemImageName: "trash"),
                PrivacySettingsEntryPoint(id: "debug", title: "Advanced Debug", systemImageName: "ladybug"),
            ]
        )
    }

    private static func agentSummary(_ activeAgent: ActiveAgentRevisionSelection?) -> String {
        guard let activeAgent else {
            return "No active agent selected"
        }
        return "\(activeAgent.displayName) revision \(activeAgent.profileRevisionId)"
    }

    private static func modelSummary(_ activeModel: ActiveModelSummary?) -> String {
        guard let activeModel else {
            return "No active model selected"
        }

        switch activeModel.readiness {
        case .ready:
            return "\(activeModel.displayName) ready"
        case .missingConfiguration(let reason), .unavailable(let reason):
            return "\(activeModel.displayName): \(reason)"
        }
    }

    private static func toolPermissionSummary(_ toolRows: [ToolCenterRowState]) -> String {
        guard !toolRows.isEmpty else {
            return "No native tools registered"
        }

        let readyCount = toolRows.filter { $0.readiness == .ready }.count
        let attentionCount = toolRows.count - readyCount
        return "\(readyCount) ready, \(attentionCount) needs attention"
    }
}

struct PrivacySettingsView: View {
    @Bindable var shellViewModel: AppShellViewModel
    @Bindable var toolCenterViewModel: ToolCenterViewModel

    private var snapshot: PrivacySettingsSnapshot {
        PrivacySettingsProjection.project(
            activeAgent: shellViewModel.activeAgent,
            activeModel: shellViewModel.activeModel,
            toolRows: toolCenterViewModel.rows,
            advancedDebugEnabled: shellViewModel.advancedDebugEnabled
        )
    }

    var body: some View {
        List {
            Section("Agent") {
                SettingsSummaryRow(title: "Active Agent", value: snapshot.activeAgentSummary, systemImageName: "rectangle.3.group")
                if let activeAgent = shellViewModel.activeAgent {
                    RevisionBadge(profileId: activeAgent.profileId, revisionId: activeAgent.profileRevisionId)
                }
            }

            Section("Privacy") {
                SettingsSummaryRow(title: "Tools", value: snapshot.toolPermissionSummary, systemImageName: "wrench.and.screwdriver")
                SettingsSummaryRow(title: "Attachments", value: snapshot.attachmentStorageSummary, systemImageName: "paperclip")
                SettingsSummaryRow(title: "Memory", value: snapshot.memoryRetentionSummary, systemImageName: "brain")
                SettingsSummaryRow(title: "Model", value: snapshot.modelProviderSummary, systemImageName: "cpu")
            }

            Section("Data") {
                ForEach(snapshot.entryPoints.filter { $0.id != "debug" }) { entry in
                    SettingsEntryRow(entry: entry, status: "Coming soon")
                }
            }

            Section("Advanced") {
                Toggle("Show Debug", isOn: $shellViewModel.advancedDebugEnabled)
                Button {
                    shellViewModel.openDebug(runId: nil)
                } label: {
                    Label("Open Debug", systemImage: "ladybug")
                }
                .disabled(!shellViewModel.advancedDebugEnabled)
            }
        }
        .navigationTitle("Settings")
        .task {
            await toolCenterViewModel.reload()
        }
    }
}

private struct SettingsSummaryRow: View {
    var title: String
    var value: String
    var systemImageName: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: systemImageName)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(value)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct SettingsEntryRow: View {
    var entry: PrivacySettingsEntryPoint
    var status: String

    var body: some View {
        HStack {
            Label(entry.title, systemImage: entry.systemImageName)
            Spacer(minLength: 8)
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
