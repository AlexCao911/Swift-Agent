import LocalAgentBridge
import Testing
@testable import LocalAgentApp

@Suite("Runtime projection model")
@MainActor
struct RuntimeProjectionModelTests {
    @Test("runtime projection maps run state and debug archive without Rust domain objects")
    func runtimeProjectionMapsRunStateAndDebugArchiveWithoutRustDomainObjects() {
        let archive = RunDebugUIModel(
            runId: "run_1",
            state: .awaitingApproval,
            events: [
                RunDebugEventDTO(id: "event_1", code: "run.started", title: "Run started"),
                RunDebugEventDTO(id: "event_2", code: "approval.required", title: "Approval required"),
            ],
            archives: [
                DebugArchiveDTO(
                    id: "archive_1",
                    kind: .prompt,
                    title: "Prompt archive",
                    redactedPayload: "system prompt",
                    sourceLinks: [
                        DebugArchiveSourceLinkDTO(
                            kind: .promptArchive,
                            targetId: "prompt_archive:run_1"
                        ),
                    ]
                ),
                DebugArchiveDTO(
                    id: "archive_2",
                    kind: .context,
                    title: "Context archive",
                    redactedPayload: "context payload",
                    sourceLinks: [
                        DebugArchiveSourceLinkDTO(
                            kind: .contextArchive,
                            targetId: "context_archive:run_1"
                        ),
                    ]
                ),
            ],
            checkpoints: [
                CheckpointDTO(id: "checkpoint_1", title: "Before approval", canResume: true),
            ]
        )

        let projection = RuntimeProjectionModel(archive: archive)

        #expect(projection.runId == "run_1")
        #expect(projection.stateBadge.title == "Awaiting Approval")
        #expect(projection.timeline.map(\.code) == ["run.started", "approval.required"])
        #expect(projection.archiveItems.map(\.kind.rawValue) == ["prompt", "context"])
        #expect(projection.archiveItems.first?.previewText == "system prompt")
        #expect(projection.archiveItems.first?.sourceLinks.first?.targetId == "prompt_archive:run_1")
        #expect(projection.resumeCheckpoint?.id == "checkpoint_1")
    }
}
