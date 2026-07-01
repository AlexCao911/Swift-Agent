import LocalAgentBridge

@MainActor
struct RuntimeProjectionModel: Equatable {
    let runId: String
    let stateBadge: RuntimeStateBadge
    let timeline: [RuntimeTimelineItem]
    let archiveItems: [RuntimeArchiveItem]
    let resumeCheckpoint: RuntimeCheckpointItem?

    init(archive: RunDebugUIModel) {
        self.runId = archive.runId
        self.stateBadge = RuntimeStateBadge(state: archive.state)
        self.timeline = archive.events.map(RuntimeTimelineItem.init(event:))
        self.archiveItems = archive.archives.map(RuntimeArchiveItem.init(archive:))
        self.resumeCheckpoint = archive.checkpoints
            .first(where: \.canResume)
            .map(RuntimeCheckpointItem.init(checkpoint:))
    }
}

struct RuntimeStateBadge: Equatable {
    let title: String

    init(state: RunDebugStateDTO) {
        if state == .awaitingApproval {
            self.title = "Awaiting Approval"
        } else if state == .awaitingTool {
            self.title = "Awaiting Tool"
        } else if state == .completed {
            self.title = "Completed"
        } else if state == .failed {
            self.title = "Failed"
        } else if state == .running {
            self.title = "Running"
        } else {
            self.title = state.rawValue
                .split(separator: "_")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }
}

struct RuntimeTimelineItem: Equatable {
    let id: String
    let code: String
    let title: String

    init(event: RunDebugEventDTO) {
        self.id = event.id
        self.code = event.code
        self.title = event.title
    }
}

struct RuntimeArchiveItem: Equatable {
    let id: String
    let kind: DebugArchiveKindDTO
    let title: String
    let previewText: String
    let sourceLinks: [RuntimeArchiveSourceLinkItem]

    init(archive: DebugArchiveDTO) {
        self.id = archive.id
        self.kind = archive.kind
        self.title = archive.title
        self.previewText = archive.redactedPayload
        self.sourceLinks = archive.sourceLinks.map(RuntimeArchiveSourceLinkItem.init(sourceLink:))
    }
}

struct RuntimeArchiveSourceLinkItem: Equatable {
    let kind: DebugArchiveSourceKindDTO
    let targetId: String

    init(sourceLink: DebugArchiveSourceLinkDTO) {
        self.kind = sourceLink.kind
        self.targetId = sourceLink.targetId
    }
}

struct RuntimeCheckpointItem: Equatable {
    let id: String
    let title: String

    init(checkpoint: CheckpointDTO) {
        self.id = checkpoint.id
        self.title = checkpoint.title
    }
}
