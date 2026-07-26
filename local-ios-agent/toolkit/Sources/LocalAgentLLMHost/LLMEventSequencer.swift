import Foundation
import LocalAgentBridge
import LocalAgentLLMContracts

package struct LLMEventSequencerError: Error, Equatable, Sendable {
    package let code: String

    package init(code: String) {
        self.code = code
    }
}

package protocol LLMEventSubmitting: Sendable {
    func submit(_ envelope: LLMEventEnvelope) async throws -> LLMEventSubmissionResult
}

package struct RustLLMEventSubmitter: LLMEventSubmitting {
    private let port: RustLLMHostPort

    package init(port: RustLLMHostPort) {
        self.port = port
    }

    package func submit(
        _ envelope: LLMEventEnvelope
    ) async throws -> LLMEventSubmissionResult {
        let response = try port.submitEventJSON(JSONEncoder().encode(envelope))
        return try JSONDecoder().decode(LLMEventSubmissionResult.self, from: response)
    }
}

package actor LLMEventCapacityGate {
    private var permit = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    package init() {}

    package func wait() async {
        if permit {
            permit = false
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    package func signal() {
        if waiters.isEmpty {
            permit = true
        } else {
            waiters.removeFirst().resume()
        }
    }
}

package actor LLMEventSequencer {
    private let runID: String
    private let sessionHandle: String
    private let hostProcessEpoch: HostProcessEpoch
    private let submitter: any LLMEventSubmitting
    private let capacityGate: LLMEventCapacityGate
    private var sequence: UInt64 = 1
    private var terminalTurns: Set<String> = []
    private var generationTerminal = false
    private var closed = false

    package init(
        runID: String,
        sessionHandle: String,
        hostProcessEpoch: HostProcessEpoch,
        submitter: any LLMEventSubmitting,
        capacityGate: LLMEventCapacityGate = LLMEventCapacityGate()
    ) {
        self.runID = runID
        self.sessionHandle = sessionHandle
        self.hostProcessEpoch = hostProcessEpoch
        self.submitter = submitter
        self.capacityGate = capacityGate
    }

    @discardableResult
    package func submit(
        kind: LLMEventKind,
        payload: LLMEventPayload,
        generationTurnID: String?
    ) async throws -> LLMEventSubmissionResult? {
        guard shouldAllocate(kind: kind, generationTurnID: generationTurnID) else {
            return nil
        }

        let eventID = try HostSessionHandleGenerator.generate()
        let draft = LLMEventEnvelope(
            schemaVersion: 1,
            eventID: eventID,
            runID: runID,
            sessionHandle: sessionHandle,
            hostProcessEpoch: hostProcessEpoch.rawValue,
            generationTurnID: generationTurnID,
            eventSequence: sequence,
            kind: kind,
            payload: payload,
            eventEnvelopeDigest: ""
        )
        let envelope = LLMEventEnvelope(
            schemaVersion: draft.schemaVersion,
            eventID: draft.eventID,
            runID: draft.runID,
            sessionHandle: draft.sessionHandle,
            hostProcessEpoch: draft.hostProcessEpoch,
            generationTurnID: draft.generationTurnID,
            eventSequence: draft.eventSequence,
            kind: draft.kind,
            payload: draft.payload,
            eventEnvelopeDigest: try draft.recomputedDigest().hex
        )

        while true {
            let result = try await submitter.submit(envelope)
            switch result {
            case .backpressure:
                await capacityGate.wait()

            case .accepted, .duplicate, .turnTerminal, .generationTerminal,
                 .payloadTooLarge:
                sequence = max(sequence, envelope.eventSequence + 1)
                applyTerminalState(
                    result: result,
                    kind: kind,
                    payload: payload,
                    generationTurnID: generationTurnID
                )
                return result

            case .staleSession:
                return result

            case .closedSession:
                closed = true
                return result

            case .sequenceGap, .sequenceConflict, .identityConflict, .invalidEnvelope:
                throw LLMEventSequencerError(code: "llm.event.\(result.rawValue)")
            }
        }
    }

    package func notifyCapacityAvailable() async {
        await capacityGate.signal()
    }

    package func nextSequence() -> UInt64 {
        sequence
    }

    private func shouldAllocate(
        kind: LLMEventKind,
        generationTurnID: String?
    ) -> Bool {
        if closed {
            return false
        }
        if kind == .sessionClosed {
            return true
        }
        if generationTerminal {
            return false
        }
        return generationTurnID.map { !terminalTurns.contains($0) } ?? true
    }

    private func applyTerminalState(
        result: LLMEventSubmissionResult,
        kind: LLMEventKind,
        payload: LLMEventPayload,
        generationTurnID: String?
    ) {
        switch result {
        case .generationTerminal, .payloadTooLarge:
            generationTerminal = true
        case .turnTerminal:
            if let generationTurnID {
                terminalTurns.insert(generationTurnID)
            }
        default:
            break
        }

        switch kind {
        case .generationCompleted:
            if payload.completion?.outcome == "final_response" {
                generationTerminal = true
            } else if let generationTurnID {
                terminalTurns.insert(generationTurnID)
            }
        case .failed, .cancelled:
            generationTerminal = true
        case .sessionClosed:
            closed = true
        default:
            break
        }
    }
}
