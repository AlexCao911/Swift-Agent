import Foundation

public enum HostCommandKind: String, Codable, Sendable {
    case startGeneration = "start_generation"
    case resumeGeneration = "resume_generation"
    case cancelGeneration = "cancel_generation"
    case executeToolBatch = "execute_tool_batch"
    case cancelToolBatch = "cancel_tool_batch"
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

    public init(
        kind: HostSemanticContentKind,
        text: String? = nil,
        modality: String? = nil,
        attachmentID: String? = nil,
        mediaType: String? = nil
    ) {
        self.kind = kind
        self.text = text
        self.modality = modality
        self.attachmentID = attachmentID
        self.mediaType = mediaType
    }

    private enum CodingKeys: String, CodingKey {
        case kind, text, modality
        case attachmentID = "attachment_id"
        case mediaType = "media_type"
    }
}

public struct HostSemanticMessage: Codable, Equatable, Sendable {
    public let role: String
    public let content: [HostSemanticContent]

    public init(role: String, content: [HostSemanticContent]) {
        self.role = role
        self.content = content
    }
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

public struct LegacyHostAttachmentReference: Codable, Equatable, Sendable {
    public let attachmentID: String
    public let revision: String
    public let modality: String
    public let mediaType: String
    public let contentDigest: String

    public init(
        attachmentID: String,
        revision: String,
        modality: String,
        mediaType: String,
        contentDigest: String
    ) {
        self.attachmentID = attachmentID
        self.revision = revision
        self.modality = modality
        self.mediaType = mediaType
        self.contentDigest = contentDigest
    }

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

    public init(
        callID: String,
        toolName: String,
        result: CanonicalJSONValue,
        isError: Bool,
        dataClasses: [String],
        highestSensitivity: String
    ) {
        self.callID = callID
        self.toolName = toolName
        self.result = result
        self.isError = isError
        self.dataClasses = dataClasses
        self.highestSensitivity = highestSensitivity
    }

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
    public let attachments: [LegacyHostAttachmentReference]
    public let semanticHistory: [HostSemanticMessage]
    public let toolResults: [HostToolResult]
    public let systemPrompt: String?
    public let conversationStreamID: String?
    public let orderedMessages: [HostModelMessage]
    public let attachmentReferences: [HostAttachmentReference]
    public let orderedToolDefinitions: [HostToolDefinition]
    public let toolBatch: HostToolBatch?
    public let targetBatchID: String?

    public init(
        schemaVersion: String,
        modelInputID: String,
        messages: [HostSemanticMessage],
        toolSchemaJSON: String,
        toolSchemaDigest: String,
        sourceRevisions: [HostSourceRevision],
        sourceRevisionsDigest: String,
        attachments: [LegacyHostAttachmentReference],
        semanticHistory: [HostSemanticMessage],
        toolResults: [HostToolResult],
        systemPrompt: String? = nil,
        conversationStreamID: String? = nil,
        orderedMessages: [HostModelMessage] = [],
        attachmentReferences: [HostAttachmentReference] = [],
        orderedToolDefinitions: [HostToolDefinition] = [],
        toolBatch: HostToolBatch? = nil,
        targetBatchID: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.modelInputID = modelInputID
        self.messages = messages
        self.toolSchemaJSON = toolSchemaJSON
        self.toolSchemaDigest = toolSchemaDigest
        self.sourceRevisions = sourceRevisions
        self.sourceRevisionsDigest = sourceRevisionsDigest
        self.attachments = attachments
        self.semanticHistory = semanticHistory
        self.toolResults = toolResults
        self.systemPrompt = systemPrompt
        self.conversationStreamID = conversationStreamID
        self.orderedMessages = orderedMessages
        self.attachmentReferences = attachmentReferences
        self.orderedToolDefinitions = orderedToolDefinitions
        self.toolBatch = toolBatch
        self.targetBatchID = targetBatchID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        modelInputID = try container.decode(String.self, forKey: .modelInputID)
        messages = try container.decode([HostSemanticMessage].self, forKey: .messages)
        toolSchemaJSON = try container.decode(String.self, forKey: .toolSchemaJSON)
        toolSchemaDigest = try container.decode(String.self, forKey: .toolSchemaDigest)
        sourceRevisions = try container.decode(
            [HostSourceRevision].self,
            forKey: .sourceRevisions
        )
        sourceRevisionsDigest = try container.decode(
            String.self,
            forKey: .sourceRevisionsDigest
        )
        attachments = try container.decode(
            [LegacyHostAttachmentReference].self,
            forKey: .attachments
        )
        semanticHistory = try container.decode(
            [HostSemanticMessage].self,
            forKey: .semanticHistory
        )
        toolResults = try container.decode([HostToolResult].self, forKey: .toolResults)
        systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt)
        conversationStreamID = try container.decodeIfPresent(
            String.self,
            forKey: .conversationStreamID
        )
        orderedMessages = try container.decodeIfPresent(
            [HostModelMessage].self,
            forKey: .orderedMessages
        ) ?? []
        attachmentReferences = try container.decodeIfPresent(
            [HostAttachmentReference].self,
            forKey: .attachmentReferences
        ) ?? []
        orderedToolDefinitions = try container.decodeIfPresent(
            [HostToolDefinition].self,
            forKey: .orderedToolDefinitions
        ) ?? []
        toolBatch = try container.decodeIfPresent(HostToolBatch.self, forKey: .toolBatch)
        targetBatchID = try container.decodeIfPresent(String.self, forKey: .targetBatchID)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(modelInputID, forKey: .modelInputID)
        try container.encode(messages, forKey: .messages)
        try container.encode(toolSchemaJSON, forKey: .toolSchemaJSON)
        try container.encode(toolSchemaDigest, forKey: .toolSchemaDigest)
        try container.encode(sourceRevisions, forKey: .sourceRevisions)
        try container.encode(sourceRevisionsDigest, forKey: .sourceRevisionsDigest)
        try container.encode(attachments, forKey: .attachments)
        try container.encode(semanticHistory, forKey: .semanticHistory)
        try container.encode(toolResults, forKey: .toolResults)
        try container.encodeIfPresent(systemPrompt, forKey: .systemPrompt)
        try container.encodeIfPresent(conversationStreamID, forKey: .conversationStreamID)
        if !orderedMessages.isEmpty {
            try container.encode(orderedMessages, forKey: .orderedMessages)
        }
        if !attachmentReferences.isEmpty {
            try container.encode(attachmentReferences, forKey: .attachmentReferences)
        }
        if !orderedToolDefinitions.isEmpty {
            try container.encode(orderedToolDefinitions, forKey: .orderedToolDefinitions)
        }
        try container.encodeIfPresent(toolBatch, forKey: .toolBatch)
        try container.encodeIfPresent(targetBatchID, forKey: .targetBatchID)
    }

    public static func generationV2(_ request: HostModelRequest) -> Self {
        emptyV2(
            modelInputID: request.runID,
            systemPrompt: request.systemPrompt,
            conversationStreamID: request.conversationStreamID,
            orderedMessages: request.orderedMessages,
            attachmentReferences: request.attachmentReferences,
            orderedToolDefinitions: request.orderedToolDefinitions
        )
    }

    public static func toolBatchV2(_ batch: HostToolBatch) -> Self {
        emptyV2(toolBatch: batch)
    }

    public static func cancelToolBatchV2(_ batchID: String) -> Self {
        emptyV2(targetBatchID: batchID)
    }

    public static func lifecycleV2() -> Self {
        emptyV2()
    }

    public func modelRequest(
        for kind: HostCommandKind,
        envelopeRunID: String
    ) throws -> HostModelRequest {
        try validate(for: kind, envelopeRunID: envelopeRunID)
        guard let systemPrompt, let conversationStreamID else {
            throw commandPayloadMismatch()
        }
        return HostModelRequest(
            runID: envelopeRunID,
            conversationStreamID: conversationStreamID,
            systemPrompt: systemPrompt,
            orderedMessages: orderedMessages,
            attachmentReferences: attachmentReferences,
            orderedToolDefinitions: orderedToolDefinitions
        )
    }

    public func validate(
        for kind: HostCommandKind,
        envelopeRunID: String
    ) throws {
        if schemaVersion == "1" {
            guard v2BodyIsEmpty,
                  kind != .executeToolBatch,
                  kind != .cancelToolBatch
            else {
                throw commandPayloadMismatch()
            }
            return
        }
        guard schemaVersion == "2",
              messages.isEmpty,
              sourceRevisions.isEmpty,
              attachments.isEmpty,
              semanticHistory.isEmpty,
              toolResults.isEmpty,
              toolSchemaJSON == "{}",
              toolSchemaDigest
                  == "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a",
              sourceRevisionsDigest
                  == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        else {
            throw commandPayloadMismatch()
        }

        let generationBodyIsEmpty = systemPrompt == nil
            && conversationStreamID == nil
            && orderedMessages.isEmpty
            && attachmentReferences.isEmpty
            && orderedToolDefinitions.isEmpty
        let valid: Bool
        switch kind {
        case .startGeneration, .resumeGeneration:
            valid = modelInputID == envelopeRunID
                && systemPrompt != nil
                && conversationStreamID?.isEmpty == false
                && toolBatch == nil
                && targetBatchID == nil
        case .executeToolBatch:
            valid = generationBodyIsEmpty
                && toolBatch?.runID == envelopeRunID
                && targetBatchID == nil
        case .cancelToolBatch:
            valid = generationBodyIsEmpty
                && toolBatch == nil
                && targetBatchID?.isEmpty == false
        case .cancelGeneration, .closeSession, .capacityAvailable:
            valid = generationBodyIsEmpty
                && toolBatch == nil
                && targetBatchID == nil
        }
        guard valid else {
            throw commandPayloadMismatch()
        }
    }

    private var v2BodyIsEmpty: Bool {
        systemPrompt == nil
            && conversationStreamID == nil
            && orderedMessages.isEmpty
            && attachmentReferences.isEmpty
            && orderedToolDefinitions.isEmpty
            && toolBatch == nil
            && targetBatchID == nil
    }

    public func computedDigest() throws -> CanonicalDigest {
        let domain = switch schemaVersion {
        case "1": "host-command-payload:v1"
        case "2": "host-command-payload:v2"
        default: throw commandPayloadMismatch()
        }
        return try CanonicalDigestV1.digest(
            domain: domain,
            document: try canonicalValue(self)
        )
    }

    private static func emptyV2(
        modelInputID: String = "lifecycle",
        systemPrompt: String? = nil,
        conversationStreamID: String? = nil,
        orderedMessages: [HostModelMessage] = [],
        attachmentReferences: [HostAttachmentReference] = [],
        orderedToolDefinitions: [HostToolDefinition] = [],
        toolBatch: HostToolBatch? = nil,
        targetBatchID: String? = nil
    ) -> Self {
        Self(
            schemaVersion: "2",
            modelInputID: modelInputID,
            messages: [],
            toolSchemaJSON: "{}",
            toolSchemaDigest: "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a",
            sourceRevisions: [],
            sourceRevisionsDigest: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            attachments: [],
            semanticHistory: [],
            toolResults: [],
            systemPrompt: systemPrompt,
            conversationStreamID: conversationStreamID,
            orderedMessages: orderedMessages,
            attachmentReferences: attachmentReferences,
            orderedToolDefinitions: orderedToolDefinitions,
            toolBatch: toolBatch,
            targetBatchID: targetBatchID
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
        case systemPrompt = "system_prompt"
        case conversationStreamID = "conversation_stream_id"
        case orderedMessages = "ordered_messages"
        case attachmentReferences = "attachment_references"
        case orderedToolDefinitions = "ordered_tool_definitions"
        case toolBatch = "tool_batch"
        case targetBatchID = "target_batch_id"
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
        try payload.validate(for: kind, envelopeRunID: runID)
        let domain: String
        switch (schemaVersion, payload.schemaVersion) {
        case (1, "1"):
            domain = "host-command-envelope:v1"
        case (2, "2"):
            domain = "host-command-envelope:v2"
        default:
            throw commandPayloadMismatch()
        }
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
            domain: domain,
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

public struct HostContractValidationError: Error, Equatable, Sendable {
    public let code: String

    public init(code: String) {
        self.code = code
    }
}

private func commandPayloadMismatch() -> HostContractValidationError {
    HostContractValidationError(code: "llm.contract.command_payload_mismatch")
}
