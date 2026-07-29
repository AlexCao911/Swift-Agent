import LocalAgentLLMContracts
import Testing
@testable import LocalAgentLLMHost

@Suite("LLM host event sequencer")
struct LLMHostEventSequencerTests {
    @Test
    func backpressureRetriesTheExactImmutableEnvelope() async throws {
        let gate = LLMEventCapacityGate()
        let submitter = RecordingEventSubmitter(
            results: [.backpressure, .accepted],
            onBackpressure: { await gate.signal() }
        )
        let sequencer = LLMEventSequencer(
            runID: "run-1",
            sessionHandle: "session-1",
            hostProcessEpoch: HostRuntimeHarnessEpoch.value,
            submitter: submitter,
            capacityGate: gate
        )

        #expect(try await sequencer.submit(
            kind: .textDelta,
            payload: .init(text: "hello"),
            generationTurnID: "turn-1"
        ) == .accepted)

        let submitted = await submitter.envelopes()
        #expect(submitted.count == 2)
        #expect(submitted[0] == submitted[1])
        #expect(await sequencer.nextSequence() == 2)
    }

    @Test
    func terminalRawCallbacksAreFilteredBeforeAllocatingAnotherSequence() async throws {
        let submitter = RecordingEventSubmitter(results: [.accepted, .accepted])
        let sequencer = LLMEventSequencer(
            runID: "run-1",
            sessionHandle: "session-1",
            hostProcessEpoch: HostRuntimeHarnessEpoch.value,
            submitter: submitter
        )

        #expect(try await sequencer.submit(
            kind: .generationCompleted,
            payload: .init(completion: .init(
                outcome: "final_response",
                orderedCallIDs: [],
                finishReason: "stop"
            )),
            generationTurnID: "turn-1"
        ) == .accepted)
        #expect(try await sequencer.submit(
            kind: .textDelta,
            payload: .init(text: "late"),
            generationTurnID: "turn-1"
        ) == nil)
        #expect(try await sequencer.submit(
            kind: .sessionClosed,
            payload: .init(commandID: "close-1", closeDisposition: "closed"),
            generationTurnID: nil
        ) == .accepted)

        let submitted = await submitter.envelopes()
        #expect(submitted.map(\.eventSequence) == [1, 2])
        #expect(submitted.map(\.kind) == [.generationCompleted, .sessionClosed])
    }

    @Test
    func payloadTooLargeConsumesItsSequenceButStaleSessionDoesNot() async throws {
        let oversizedSubmitter = RecordingEventSubmitter(results: [.payloadTooLarge])
        let oversizedSequencer = LLMEventSequencer(
            runID: "run-1",
            sessionHandle: "session-1",
            hostProcessEpoch: HostRuntimeHarnessEpoch.value,
            submitter: oversizedSubmitter
        )

        #expect(try await oversizedSequencer.submit(
            kind: .textDelta,
            payload: .init(text: "oversized"),
            generationTurnID: "turn-1"
        ) == .payloadTooLarge)
        #expect(await oversizedSequencer.nextSequence() == 2)

        let staleSubmitter = RecordingEventSubmitter(results: [.staleSession, .accepted])
        let staleSequencer = LLMEventSequencer(
            runID: "run-1",
            sessionHandle: "session-1",
            hostProcessEpoch: HostRuntimeHarnessEpoch.value,
            submitter: staleSubmitter
        )
        #expect(try await staleSequencer.submit(
            kind: .textDelta,
            payload: .init(text: "stale"),
            generationTurnID: "turn-1"
        ) == .staleSession)
        #expect(try await staleSequencer.submit(
            kind: .textDelta,
            payload: .init(text: "next"),
            generationTurnID: "turn-1"
        ) == .accepted)

        #expect(await staleSubmitter.envelopes().map(\.eventSequence) == [1, 1])
        #expect(await staleSequencer.nextSequence() == 2)
    }

    @Test
    func protocolRejectionDoesNotGuessSequenceConsumption() async throws {
        let submitter = RecordingEventSubmitter(results: [.sequenceGap])
        let sequencer = LLMEventSequencer(
            runID: "run-1",
            sessionHandle: "session-1",
            hostProcessEpoch: HostRuntimeHarnessEpoch.value,
            submitter: submitter
        )

        await #expect(throws: LLMEventSequencerError.self) {
            try await sequencer.submit(
                kind: .textDelta,
                payload: .init(text: "gap"),
                generationTurnID: "turn-1"
            )
        }
        #expect(await sequencer.nextSequence() == 1)
    }

    @Test
    func toolBatchCompletionMayFollowItsTerminalModelTurn() async throws {
        let submitter = RecordingEventSubmitter(results: [.accepted, .accepted])
        let sequencer = LLMEventSequencer(
            runID: "run-1",
            sessionHandle: "session-1",
            hostProcessEpoch: HostRuntimeHarnessEpoch.value,
            submitter: submitter
        )
        let turnID = "turn-1"
        _ = try await sequencer.submit(
            kind: .generationCompleted,
            payload: .init(completion: .init(
                outcome: "tool_calls_ready",
                orderedCallIDs: ["call-1"],
                finishReason: "tool_calls"
            )),
            generationTurnID: turnID
        )
        _ = try await sequencer.submit(
            kind: .toolBatchCompleted,
            payload: .init(toolBatchCompletion: .init(
                batchID: "batch-1",
                runID: "run-1",
                orderedResults: []
            )),
            generationTurnID: turnID
        )

        #expect(await submitter.envelopes().map(\.kind) == [
            .generationCompleted,
            .toolBatchCompleted,
        ])
    }
}

private enum HostRuntimeHarnessEpoch {
    static let value = HostProcessEpoch(
        rawValue: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    )!
}

private actor RecordingEventSubmitter: LLMEventSubmitting {
    private var results: [LLMEventSubmissionResult]
    private var submitted: [LLMEventEnvelope] = []
    private let onBackpressure: (@Sendable () async -> Void)?

    init(
        results: [LLMEventSubmissionResult],
        onBackpressure: (@Sendable () async -> Void)? = nil
    ) {
        self.results = results
        self.onBackpressure = onBackpressure
    }

    func submit(_ envelope: LLMEventEnvelope) async throws -> LLMEventSubmissionResult {
        submitted.append(envelope)
        let result = results.removeFirst()
        if result == .backpressure {
            await onBackpressure?()
        }
        return result
    }

    func envelopes() -> [LLMEventEnvelope] { submitted }
}
