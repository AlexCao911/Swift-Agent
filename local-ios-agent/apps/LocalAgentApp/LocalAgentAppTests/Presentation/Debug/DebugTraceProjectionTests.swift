import LocalAgentBridge
import Testing
@testable import LocalAgentApp

@Suite("Debug trace projection")
@MainActor
struct DebugTraceProjectionTests {
    @Test("debug trace preserves run id revision events archives and checkpoints")
    func debugTracePreservesRunIdRevisionEventsArchivesAndCheckpoints() {
        let archive = RunDebugUIModel(
            runId: "run_1",
            state: .running,
            events: [
                RunDebugEventDTO(id: "event_1", code: "run.started", title: "Run started"),
                RunDebugEventDTO(id: "event_2", code: "tool.call", title: "Tool call"),
            ],
            archives: [
                DebugArchiveDTO(
                    id: "archive_1",
                    kind: .context,
                    title: "Context",
                    redactedPayload: "conversation + tools",
                    sourceLinks: [
                        DebugArchiveSourceLinkDTO(kind: .runtimeEvent, targetId: "event_2"),
                    ]
                ),
            ],
            checkpoints: [
                CheckpointDTO(id: "checkpoint_1", title: "Before tool", canResume: true),
            ]
        )

        let trace = DebugTraceProjection.project(
            routeRunId: "run_1",
            activeAgent: ActiveAgentRevisionSelection(
                profileId: "profile_1",
                profileRevisionId: 9,
                displayName: "Tool Agent"
            ),
            archive: archive
        )

        #expect(trace.runId == "run_1")
        #expect(trace.profileRevisionLabel == "profile_1@9")
        #expect(trace.stateTitle == "Running")
        #expect(trace.timeline.map(\.code) == ["run.started", "tool.call"])
        #expect(trace.archiveItems.first?.sourceLinks.first?.targetId == "event_2")
        #expect(trace.resumeCheckpoint?.title == "Before tool")
    }

    @Test("debug trace handles missing archive")
    func debugTraceHandlesMissingArchive() {
        let trace = DebugTraceProjection.project(
            routeRunId: nil,
            activeAgent: nil,
            archive: nil
        )

        #expect(trace.runId == "No run selected")
        #expect(trace.profileRevisionLabel == "No active revision")
        #expect(trace.timeline.isEmpty)
        #expect(trace.archiveItems.isEmpty)
    }
}
