import LocalAgentBridge
import Testing
@testable import LocalAgentApp

@Suite("Agent run view model")
@MainActor
struct AgentRunViewModelTests {
    @Test("applies replayed events once by sequence")
    func appliesEventsOnceBySequence() {
        let viewModel = AgentRunViewModel()
        let event = runtimeEvent(id: "event_1", runId: "run_1", sequence: 1)

        viewModel.apply(event)
        viewModel.apply(event)

        #expect(viewModel.events.map(\.id) == ["event_1"])
        #expect(viewModel.lastAppliedSequence == 1)
    }

    @Test("begin pins replay floor")
    func beginPinsReplayFloor() {
        let viewModel = AgentRunViewModel()

        viewModel.begin(runId: "run_1", replayFromSequence: 4)
        viewModel.apply(runtimeEvent(id: "event_4", runId: "run_1", sequence: 4))
        viewModel.apply(runtimeEvent(id: "event_5", runId: "run_1", sequence: 5))

        #expect(viewModel.runState == .running(runId: "run_1"))
        #expect(viewModel.events.map(\.id) == ["event_5"])
        #expect(viewModel.lastAppliedSequence == 5)
    }
}

private func runtimeEvent(id: String, runId: String, sequence: UInt64) -> RuntimeEventDTO {
    RuntimeEventDTO(
        id: id,
        sessionId: "session_1",
        parentId: nil,
        runId: runId,
        sequence: sequence,
        depth: 0,
        kind: .unknown(raw: "execution.event"),
        payload: "run.started",
        blobRefs: []
    )
}
