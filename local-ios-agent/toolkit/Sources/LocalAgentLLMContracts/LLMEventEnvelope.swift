import Foundation

public enum LLMEventKind: String, Codable, Sendable {
    case generationStarted = "generation_started", textDelta = "text_delta"
    case reasoningSummaryDelta = "reasoning_summary_delta"
    case toolCallStarted = "tool_call_started", toolCallArgumentsDelta = "tool_call_arguments_delta"
    case toolCallCompleted = "tool_call_completed", usageUpdated = "usage_updated"
    case generationCompleted = "generation_completed", failed, cancelled
    case sessionClosed = "session_closed"
}

public struct LLMEventPayload: Codable, Equatable, Sendable {
    public let text: String?
    public let callID: String?
    public let name: String?
    public let argumentsJSON: String?
    public let inputTokens: UInt64?
    public let outputTokens: UInt64?
    public let completion: LLMBackendCompletionWire?
    public let failureCode: String?
    public let commandID: String?
    public let opaqueOperationID: String?
    public let closeDisposition: String?

    public init(
        text: String? = nil,
        callID: String? = nil,
        name: String? = nil,
        argumentsJSON: String? = nil,
        inputTokens: UInt64? = nil,
        outputTokens: UInt64? = nil,
        completion: LLMBackendCompletionWire? = nil,
        failureCode: String? = nil,
        commandID: String? = nil,
        opaqueOperationID: String? = nil,
        closeDisposition: String? = nil
    ) {
        self.text = text
        self.callID = callID
        self.name = name
        self.argumentsJSON = argumentsJSON
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.completion = completion
        self.failureCode = failureCode
        self.commandID = commandID
        self.opaqueOperationID = opaqueOperationID
        self.closeDisposition = closeDisposition
    }

    private enum CodingKeys: String, CodingKey {
        case text, name, completion
        case callID = "call_id", argumentsJSON = "arguments_json"
        case inputTokens = "input_tokens", outputTokens = "output_tokens"
        case failureCode = "failure_code", commandID = "command_id"
        case opaqueOperationID = "opaque_operation_id", closeDisposition = "close_disposition"
    }
}

public struct LLMBackendCompletionWire: Codable, Equatable, Sendable {
    public let outcome: String
    public let orderedCallIDs: [String]
    public let finishReason: String

    public init(outcome: String, orderedCallIDs: [String], finishReason: String) {
        self.outcome = outcome
        self.orderedCallIDs = orderedCallIDs
        self.finishReason = finishReason
    }
    private enum CodingKeys: String, CodingKey {
        case outcome, orderedCallIDs = "ordered_call_ids", finishReason = "finish_reason"
    }
}

public struct LLMEventEnvelope: Codable, Equatable, Sendable {
    public let schemaVersion: UInt32
    public let eventID: String
    public let runID: String
    public let sessionHandle: String
    public let hostProcessEpoch: String
    public let generationTurnID: String?
    public let eventSequence: UInt64
    public let kind: LLMEventKind
    public let payload: LLMEventPayload
    public let eventEnvelopeDigest: String

    public func recomputedDigest() throws -> CanonicalDigest {
        try CanonicalDigestV1.digest(domain: "llm-event-envelope:v1", document: try eventCanonicalValue(DigestDocument(self)))
    }

    public func replacing(eventSequence: UInt64) -> Self {
        Self(schemaVersion: schemaVersion, eventID: eventID, runID: runID, sessionHandle: sessionHandle,
             hostProcessEpoch: hostProcessEpoch, generationTurnID: generationTurnID, eventSequence: eventSequence,
             kind: kind, payload: payload, eventEnvelopeDigest: eventEnvelopeDigest)
    }

    public init(schemaVersion: UInt32, eventID: String, runID: String, sessionHandle: String,
                hostProcessEpoch: String, generationTurnID: String?, eventSequence: UInt64,
                kind: LLMEventKind, payload: LLMEventPayload, eventEnvelopeDigest: String) {
        self.schemaVersion = schemaVersion; self.eventID = eventID; self.runID = runID
        self.sessionHandle = sessionHandle; self.hostProcessEpoch = hostProcessEpoch
        self.generationTurnID = generationTurnID; self.eventSequence = eventSequence
        self.kind = kind; self.payload = payload; self.eventEnvelopeDigest = eventEnvelopeDigest
    }

    private struct DigestDocument: Encodable {
        let schemaVersion: UInt32; let eventID: String; let runID: String; let sessionHandle: String
        let hostProcessEpoch: String; let generationTurnID: String?; let eventSequence: UInt64
        let kind: LLMEventKind; let payload: LLMEventPayload
        init(_ value: LLMEventEnvelope) {
            schemaVersion = value.schemaVersion; eventID = value.eventID; runID = value.runID
            sessionHandle = value.sessionHandle; hostProcessEpoch = value.hostProcessEpoch
            generationTurnID = value.generationTurnID; eventSequence = value.eventSequence
            kind = value.kind; payload = value.payload
        }
        private enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version", eventID = "event_id", runID = "run_id"
            case sessionHandle = "session_handle", hostProcessEpoch = "host_process_epoch"
            case generationTurnID = "generation_turn_id", eventSequence = "event_sequence", kind, payload
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", eventID = "event_id", runID = "run_id"
        case sessionHandle = "session_handle", hostProcessEpoch = "host_process_epoch"
        case generationTurnID = "generation_turn_id", eventSequence = "event_sequence", kind, payload
        case eventEnvelopeDigest = "event_envelope_digest"
    }
}

public enum LLMEventReceiptDisposition: String, Codable, Sendable { case accepted, terminallyIgnored = "terminally_ignored", closed }

public struct LLMEventReceipt: Codable, Equatable, Sendable {
    public let schemaVersion: UInt32; public let runID: String; public let sessionHandle: String
    public let hostProcessEpoch: String; public let eventSequence: UInt64; public let eventID: String
    public let eventEnvelopeDigest: String; public let disposition: LLMEventReceiptDisposition
    public let receiptDigest: String

    public init(
        schemaVersion: UInt32,
        runID: String,
        sessionHandle: String,
        hostProcessEpoch: String,
        eventSequence: UInt64,
        eventID: String,
        eventEnvelopeDigest: String,
        disposition: LLMEventReceiptDisposition,
        receiptDigest: String
    ) {
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.sessionHandle = sessionHandle
        self.hostProcessEpoch = hostProcessEpoch
        self.eventSequence = eventSequence
        self.eventID = eventID
        self.eventEnvelopeDigest = eventEnvelopeDigest
        self.disposition = disposition
        self.receiptDigest = receiptDigest
    }

    public func recomputedDigest() throws -> CanonicalDigest {
        try CanonicalDigestV1.digest(domain: "llm-event-receipt:v1", document: try eventCanonicalValue(DigestDocument(self)))
    }

    private struct DigestDocument: Encodable {
        let schemaVersion: UInt32; let runID: String; let sessionHandle: String; let hostProcessEpoch: String
        let eventSequence: UInt64; let eventID: String; let eventEnvelopeDigest: String
        let disposition: LLMEventReceiptDisposition
        init(_ value: LLMEventReceipt) {
            schemaVersion = value.schemaVersion; runID = value.runID; sessionHandle = value.sessionHandle
            hostProcessEpoch = value.hostProcessEpoch; eventSequence = value.eventSequence
            eventID = value.eventID; eventEnvelopeDigest = value.eventEnvelopeDigest; disposition = value.disposition
        }
        private enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version", runID = "run_id", sessionHandle = "session_handle"
            case hostProcessEpoch = "host_process_epoch", eventSequence = "event_sequence"
            case eventID = "event_id", eventEnvelopeDigest = "event_envelope_digest", disposition
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", runID = "run_id", sessionHandle = "session_handle"
        case hostProcessEpoch = "host_process_epoch", eventSequence = "event_sequence"
        case eventID = "event_id", eventEnvelopeDigest = "event_envelope_digest", disposition
        case receiptDigest = "receipt_digest"
    }
}

public enum LLMEventSequenceEffect: String, Codable, Sendable { case consumeNew = "consume_new", alreadyConsumed = "already_consumed", doNotConsume = "do_not_consume" }

public enum LLMEventSubmissionResult: String, Codable, Sendable {
    case accepted, duplicate, backpressure, staleSession = "stale_session"
    case turnTerminal = "turn_terminal", generationTerminal = "generation_terminal"
    case closedSession = "closed_session", sequenceGap = "sequence_gap"
    case sequenceConflict = "sequence_conflict", identityConflict = "identity_conflict"
    case invalidEnvelope = "invalid_envelope", payloadTooLarge = "payload_too_large"

    public var sequenceEffect: LLMEventSequenceEffect {
        switch self {
        case .duplicate: .alreadyConsumed
        case .backpressure, .staleSession, .closedSession, .sequenceGap, .sequenceConflict,
             .identityConflict, .invalidEnvelope, .payloadTooLarge: .doNotConsume
        case .accepted, .turnTerminal, .generationTerminal: .consumeNew
        }
    }
    public var retrySameEnvelope: Bool { self == .backpressure }
}

private func eventCanonicalValue<T: Encodable>(_ value: T) throws -> CanonicalJSONValue {
    try JSONDecoder().decode(CanonicalJSONValue.self, from: JSONEncoder().encode(value))
}
