import LocalAgentBridge
import SwiftUI

struct DebugTraceSnapshot: Equatable, Sendable {
    var runId: String
    var profileRevisionLabel: String
    var stateTitle: String
    var timeline: [RuntimeTimelineItem]
    var archiveItems: [RuntimeArchiveItem]
    var resumeCheckpoint: RuntimeCheckpointItem?
}

enum DebugTraceProjection {
    static func project(
        routeRunId: String?,
        activeAgent: ActiveAgentRevisionSelection?,
        archive: RunDebugUIModel?
    ) -> DebugTraceSnapshot {
        let profileRevisionLabel: String
        if let activeAgent {
            profileRevisionLabel = "\(activeAgent.profileId)@\(activeAgent.profileRevisionId)"
        } else {
            profileRevisionLabel = "No active revision"
        }

        guard let archive else {
            return DebugTraceSnapshot(
                runId: routeRunId ?? "No run selected",
                profileRevisionLabel: profileRevisionLabel,
                stateTitle: "No archive loaded",
                timeline: [],
                archiveItems: [],
                resumeCheckpoint: nil
            )
        }

        let projection = RuntimeProjectionModel(archive: archive)
        return DebugTraceSnapshot(
            runId: archive.runId,
            profileRevisionLabel: profileRevisionLabel,
            stateTitle: projection.stateBadge.title,
            timeline: projection.timeline,
            archiveItems: projection.archiveItems,
            resumeCheckpoint: projection.resumeCheckpoint
        )
    }
}

struct DebugTraceView: View {
    var routeRunId: String?
    var activeAgent: ActiveAgentRevisionSelection?
    var debugService: RunDebugService?

    @State private var archive: RunDebugUIModel?
    @State private var errorMessage: String?

    private var snapshot: DebugTraceSnapshot {
        DebugTraceProjection.project(
            routeRunId: routeRunId,
            activeAgent: activeAgent,
            archive: archive
        )
    }

    var body: some View {
        List {
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            Section("Run") {
                LabeledContent("Run ID", value: snapshot.runId)
                LabeledContent("Profile Revision", value: snapshot.profileRevisionLabel)
                LabeledContent("State", value: snapshot.stateTitle)
            }

            Section("Runtime Events") {
                if snapshot.timeline.isEmpty {
                    ProductEmptyState(
                        title: "No Runtime Events",
                        systemImageName: "timeline.selection",
                        message: "Run events will appear here after a debug archive is loaded."
                    )
                } else {
                    ForEach(snapshot.timeline, id: \.id) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title)
                                .font(.subheadline.weight(.semibold))
                            Text(item.code)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            Section("Archives") {
                if snapshot.archiveItems.isEmpty {
                    ProductEmptyState(
                        title: "No Archives",
                        systemImageName: "archivebox",
                        message: "Prompt and context archives stay here when available."
                    )
                } else {
                    ForEach(snapshot.archiveItems, id: \.id) { item in
                        DebugArchiveRow(item: item)
                    }
                }
            }

            if let checkpoint = snapshot.resumeCheckpoint {
                Section("Checkpoint") {
                    LabeledContent(checkpoint.title, value: checkpoint.id)
                }
            }
        }
        .navigationTitle("Debug")
        .task(id: routeRunId) {
            await loadArchiveIfNeeded()
        }
    }

    @MainActor
    private func loadArchiveIfNeeded() async {
        archive = nil
        errorMessage = nil

        guard let routeRunId else {
            return
        }
        guard let debugService else {
            errorMessage = "Debug archive service is unavailable."
            return
        }

        do {
            archive = try await debugService.loadDebugArchive(routeRunId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct DebugArchiveRow: View {
    var item: RuntimeArchiveItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Text(item.kind.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text(item.previewText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(3)

            ForEach(item.sourceLinks, id: \.targetId) { link in
                Label("\(link.kind.rawValue): \(link.targetId)", systemImage: "link")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
