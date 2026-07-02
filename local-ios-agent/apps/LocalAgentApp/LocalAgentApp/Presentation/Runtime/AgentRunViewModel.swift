import Foundation
import LocalAgentBridge
import Observation

enum AgentRunPhase: Equatable, Sendable {
    case idle
    case running(runId: String)
    case waitingTool(runId: String)
    case completed(runId: String?)
    case cancelled(runId: String?)
    case failed(String)
}

@MainActor
@Observable
final class AgentRunViewModel {
    private(set) var runState: AgentRunPhase = .idle
    private(set) var events: [RuntimeEventDTO] = []
    private(set) var toolCalls: [ToolExecutionRequestDTO] = []
    private(set) var approval: ApprovalProtocolRequestDTO?
    private(set) var streamBuffer = ""
    private(set) var lastAppliedSequence: UInt64 = 0

    func begin(runId: String, replayFromSequence: UInt64) {
        runState = .running(runId: runId)
        events = []
        toolCalls = []
        approval = nil
        streamBuffer = ""
        lastAppliedSequence = replayFromSequence
    }

    func apply(_ event: RuntimeEventDTO) {
        if event.sequence > 0 {
            guard event.sequence > lastAppliedSequence else {
                return
            }
            lastAppliedSequence = event.sequence
        }

        events.append(event)
        switch event.kind {
        case .assistantTextDelta:
            streamBuffer += payloadString("text", from: event.payload) ?? event.payload
            if let runId = event.runId {
                runState = .running(runId: runId)
            }
        case .assistantMessageCompleted:
            streamBuffer = payloadString("text", from: event.payload) ?? event.payload
            runState = .completed(runId: event.runId)
        case .toolCallRequested:
            runState = .waitingTool(runId: event.runId ?? "")
        case .runCancelled:
            runState = .cancelled(runId: event.runId)
        case .runFailed:
            runState = .failed(payloadString("message", from: event.payload) ?? event.payload)
        default:
            if let runId = event.runId {
                runState = .running(runId: runId)
            }
        }
    }

    private func payloadString(_ key: String, from payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        return object[key] as? String
    }
}
