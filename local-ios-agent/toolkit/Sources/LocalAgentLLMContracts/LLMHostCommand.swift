import Foundation

public enum HostCommandKind: String, Codable, Sendable {
    case startGeneration = "start_generation"
    case resumeGeneration = "resume_generation"
    case cancelGeneration = "cancel_generation"
    case closeSession = "close_session"
    case capacityAvailable = "capacity_available"
}

public enum HostSemanticContentKind: String, Codable, Sendable { case text, attachment }

public struct HostSemanticContent: Codable, Equatable, Sendable {
    public let kind: HostSemanticContentKind
    public let text: String?
    public let modality: String?
    public let attachmentID: String?
    public let mediaType: String?

    private enum CodingKeys: String, CodingKey {
        case kind, text, modality
        case attachmentID = "attachment_id"
        case mediaType = "media_type"
    }
}

public struct HostSemanticMessage: Codable, Equatable, Sendable {
    public let role: String
    public let content: [HostSemanticContent]
}

public struct HostSourceRevision: Codable, Equatable, Sendable {
    public let sourceID: String
    public let revision: String
    public let digest: String
    private enum CodingKeys: String, CodingKey {
        case sourceID = "source_id"
        case revision, digest
    }
}

public struct HostAttachmentReference: Codable, Equatable, Sendable {
    public let attachmentID: String
    public let revision: String
    public let modality: String
    public let mediaType: String
    public let contentDigest: String
    private enum CodingKeys: String, CodingKey {
        case attachmentID = "attachment_id"
        case revision, modality
        case mediaType = "media_type"
        case contentDigest = "content_digest"
    }
}

public struct HostToolResult: Codable, Equatable, Sendable {
    public let callID: String
    public let toolName: String
    public let result: CanonicalJSONValue
    public let isError: Bool
    public let dataClasses: [String]
    public let highestSensitivity: String
    private enum CodingKeys: String, CodingKey {
        case callID = "call_id"
        case toolName = "tool_name"
        case result
        case isError = "is_error"
        case dataClasses = "data_classes"
        case highestSensitivity = "highest_sensitivity"
    }
}

public struct HostCommandPayload: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let modelInputID: String
    public let messages: [HostSemanticMessage]
    public let toolSchemaJSON: String
    public let toolSchemaDigest: String
    public let sourceRevisions: [HostSourceRevision]
    public let sourceRevisionsDigest: String
    public let attachments: [HostAttachmentReference]
    public let semanticHistory: [HostSemanticMessage]
    public let toolResults: [HostToolResult]

    public func computedDigest() throws -> CanonicalDigest {
        try CanonicalDigestV1.digest(
            domain: "host-command-payload:v1",
            document: try canonicalValue(self)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case modelInputID = "model_input_id"
        case messages
        case toolSchemaJSON = "tool_schema_json"
        case toolSchemaDigest = "tool_schema_digest"
        case sourceRevisions = "source_revisions"
        case sourceRevisionsDigest = "source_revisions_digest"
        case attachments
        case semanticHistory = "semantic_history"
        case toolResults = "tool_results"
    }
}

public struct HostCommandEnvelope: Codable, Equatable, Sendable {
    public let schemaVersion: UInt32
    public let commandID: String
    public let runID: String
    public let sessionHandle: String
    public let hostProcessEpoch: String
    public let commandSequence: UInt64
    public let generationTurnID: String?
    public let kind: HostCommandKind
    public let payloadDigest: String
    public let disclosureDigest: String?
    public let commandEnvelopeDigest: String
    public let disclosure: GenerationDisclosure?
    public let payload: HostCommandPayload

    public func recomputedDigest() throws -> CanonicalDigest {
        guard try payload.computedDigest().hex == payloadDigest else {
            throw CanonicalDigestError(code: "host_command.payload_digest_mismatch", message: "host command payload digest does not match payload")
        }
        if let disclosure {
            guard try disclosure.computedDigest().hex == disclosureDigest else {
                throw CanonicalDigestError(code: "host_command.disclosure_digest_mismatch", message: "host command disclosure digest does not match disclosure")
            }
        } else if disclosureDigest != nil {
            throw CanonicalDigestError(code: "host_command.disclosure_missing", message: "host command disclosure is missing")
        }
        return try CanonicalDigestV1.digest(
            domain: "host-command-envelope:v1",
            document: try canonicalValue(DigestDocument(self))
        )
    }

    public func replacing(commandSequence: UInt64) -> Self {
        Self(
            schemaVersion: schemaVersion, commandID: commandID, runID: runID,
            sessionHandle: sessionHandle, hostProcessEpoch: hostProcessEpoch,
            commandSequence: commandSequence, generationTurnID: generationTurnID,
            kind: kind, payloadDigest: payloadDigest, disclosureDigest: disclosureDigest,
            commandEnvelopeDigest: commandEnvelopeDigest, disclosure: disclosure, payload: payload
        )
    }

    public init(
        schemaVersion: UInt32, commandID: String, runID: String, sessionHandle: String,
        hostProcessEpoch: String, commandSequence: UInt64, generationTurnID: String?,
        kind: HostCommandKind, payloadDigest: String, disclosureDigest: String?,
        commandEnvelopeDigest: String, disclosure: GenerationDisclosure?, payload: HostCommandPayload
    ) {
        self.schemaVersion = schemaVersion; self.commandID = commandID; self.runID = runID
        self.sessionHandle = sessionHandle; self.hostProcessEpoch = hostProcessEpoch
        self.commandSequence = commandSequence; self.generationTurnID = generationTurnID
        self.kind = kind; self.payloadDigest = payloadDigest; self.disclosureDigest = disclosureDigest
        self.commandEnvelopeDigest = commandEnvelopeDigest; self.disclosure = disclosure; self.payload = payload
    }

    private struct DigestDocument: Encodable {
        let schemaVersion: UInt32; let commandID: String; let runID: String; let sessionHandle: String
        let hostProcessEpoch: String; let commandSequence: UInt64; let generationTurnID: String?
        let kind: HostCommandKind; let payloadDigest: String; let disclosureDigest: String?
        let disclosure: GenerationDisclosure?; let payload: HostCommandPayload
        init(_ value: HostCommandEnvelope) {
            schemaVersion = value.schemaVersion; commandID = value.commandID; runID = value.runID
            sessionHandle = value.sessionHandle; hostProcessEpoch = value.hostProcessEpoch
            commandSequence = value.commandSequence; generationTurnID = value.generationTurnID
            kind = value.kind; payloadDigest = value.payloadDigest; disclosureDigest = value.disclosureDigest
            disclosure = value.disclosure; payload = value.payload
        }
        private enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version", commandID = "command_id", runID = "run_id"
            case sessionHandle = "session_handle", hostProcessEpoch = "host_process_epoch"
            case commandSequence = "command_sequence", generationTurnID = "generation_turn_id"
            case kind, payloadDigest = "payload_digest", disclosureDigest = "disclosure_digest"
            case disclosure, payload
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", commandID = "command_id", runID = "run_id"
        case sessionHandle = "session_handle", hostProcessEpoch = "host_process_epoch"
        case commandSequence = "command_sequence", generationTurnID = "generation_turn_id"
        case kind, payloadDigest = "payload_digest", disclosureDigest = "disclosure_digest"
        case commandEnvelopeDigest = "command_envelope_digest", disclosure, payload
    }
}

public enum HostCommandCopyReceipt: String, Codable, Sendable { case copied, backpressure, hostUnavailable = "host_unavailable" }
public enum HostCommandAcknowledgementDisposition: String, Codable, Sendable { case accepted, rejected }

public struct HostCommandAcknowledgement: Codable, Equatable, Sendable {
    public let commandID: String
    public let sessionHandle: String
    public let commandSequence: UInt64
    public let commandEnvelopeDigest: String
    public let disposition: HostCommandAcknowledgementDisposition
    public let rejectionCode: String?

    public init(
        commandID: String,
        sessionHandle: String,
        commandSequence: UInt64,
        commandEnvelopeDigest: String,
        disposition: HostCommandAcknowledgementDisposition,
        rejectionCode: String? = nil
    ) {
        self.commandID = commandID
        self.sessionHandle = sessionHandle
        self.commandSequence = commandSequence
        self.commandEnvelopeDigest = commandEnvelopeDigest
        self.disposition = disposition
        self.rejectionCode = rejectionCode
    }
    private enum CodingKeys: String, CodingKey {
        case commandID = "command_id", sessionHandle = "session_handle"
        case commandSequence = "command_sequence", commandEnvelopeDigest = "command_envelope_digest"
        case disposition, rejectionCode = "rejection_code"
    }
}

public enum HostDispatchKind: String, Codable, Sendable {
    case command
    case preparedSessionCleanup = "prepared_session_cleanup"
}

public struct HostPreparedSessionCleanupCommand: Codable, Equatable, Sendable {
    public let cleanupCommandID: String
    public let preparationID: String
    public let proposedRunID: String
    public let sessionHandle: String
    public let hostProcessEpoch: String
    public let preparationCleanupSequence: UInt64
    public let reason: String
    public let preparedSessionRegistrationDigest: String
    public let cleanupCommandDigest: String
    private enum CodingKeys: String, CodingKey {
        case cleanupCommandID = "cleanup_command_id", preparationID = "preparation_id"
        case proposedRunID = "proposed_run_id", sessionHandle = "session_handle"
        case hostProcessEpoch = "host_process_epoch"
        case preparationCleanupSequence = "preparation_cleanup_sequence", reason
        case preparedSessionRegistrationDigest = "prepared_session_registration_digest"
        case cleanupCommandDigest = "cleanup_command_digest"
    }
}

public struct HostDispatchEnvelope: Codable, Equatable, Sendable {
    public let schemaVersion: UInt32
    public let dispatchKind: HostDispatchKind
    public let command: HostCommandEnvelope?
    public let preparedSessionCleanup: HostPreparedSessionCleanupCommand?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(UInt32.self, forKey: .schemaVersion)
        dispatchKind = try container.decode(HostDispatchKind.self, forKey: .dispatchKind)
        command = try container.decodeIfPresent(HostCommandEnvelope.self, forKey: .command)
        preparedSessionCleanup = try container.decodeIfPresent(HostPreparedSessionCleanupCommand.self, forKey: .preparedSessionCleanup)
        let valid = switch dispatchKind {
        case .command: command != nil && preparedSessionCleanup == nil
        case .preparedSessionCleanup: command == nil && preparedSessionCleanup != nil
        }
        guard schemaVersion == 1, valid else {
            throw DecodingError.dataCorruptedError(forKey: .dispatchKind, in: container, debugDescription: "dispatch payload does not match dispatch kind")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(dispatchKind, forKey: .dispatchKind)
        try container.encodeIfPresent(command, forKey: .command)
        try container.encodeIfPresent(preparedSessionCleanup, forKey: .preparedSessionCleanup)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", dispatchKind = "dispatch_kind", command
        case preparedSessionCleanup = "prepared_session_cleanup"
    }
}

private func canonicalValue<T: Encodable>(_ value: T) throws -> CanonicalJSONValue {
    try JSONDecoder().decode(CanonicalJSONValue.self, from: JSONEncoder().encode(value))
}
