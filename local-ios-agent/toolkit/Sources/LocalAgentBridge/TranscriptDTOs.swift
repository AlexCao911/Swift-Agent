import Foundation
import LocalAgentLLMContracts

public struct PromptDocumentSnapshotDTO: Codable, Equatable, Sendable {
    public let id: String
    public let source: String
    public let markdown: String

    public init(id: String, source: String, markdown: String) {
        self.id = id
        self.source = source
        self.markdown = markdown
    }
}

public struct RustSkillDescriptorDTO: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let location: String
    public let enabled: Bool

    public init(
        id: String,
        name: String,
        description: String,
        location: String,
        enabled: Bool
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.location = location
        self.enabled = enabled
    }
}

public struct ToolDefinitionSnapshotDTO: Codable, Equatable, Sendable {
    public let name: String
    public let description: String
    public let inputSchema: CanonicalJSONValue

    public init(
        name: String,
        description: String,
        inputSchema: CanonicalJSONValue
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case description
        case inputSchema = "input_schema"
    }
}

public struct ModelContextWindowDTO: Codable, Equatable, Sendable {
    public let contextWindowTokens: UInt64
    public let maxOutputTokens: UInt64

    public init(contextWindowTokens: UInt64, maxOutputTokens: UInt64) {
        self.contextWindowTokens = contextWindowTokens
        self.maxOutputTokens = maxOutputTokens
    }

    private enum CodingKeys: String, CodingKey {
        case contextWindowTokens = "context_window_tokens"
        case maxOutputTokens = "max_output_tokens"
    }
}

public struct RunStartSnapshotDTO: Codable, Equatable, Sendable {
    public static let maximumSkillDescriptors = 20

    public let orderedPromptDocuments: [PromptDocumentSnapshotDTO]
    public let skillDescriptors: [RustSkillDescriptorDTO]
    public let orderedToolDefinitions: [ToolDefinitionSnapshotDTO]
    public let modelContextWindow: ModelContextWindowDTO
    public let snapshotDigest: String

    public init(
        orderedPromptDocuments: [PromptDocumentSnapshotDTO],
        skillDescriptors: [RustSkillDescriptorDTO],
        orderedToolDefinitions: [ToolDefinitionSnapshotDTO],
        modelContextWindow: ModelContextWindowDTO,
        snapshotDigest: String
    ) {
        self.orderedPromptDocuments = orderedPromptDocuments
        self.skillDescriptors = skillDescriptors
        self.orderedToolDefinitions = orderedToolDefinitions
        self.modelContextWindow = modelContextWindow
        self.snapshotDigest = snapshotDigest
    }

    public static func make(
        orderedPromptDocuments: [PromptDocumentSnapshotDTO],
        skillDescriptors: [RustSkillDescriptorDTO],
        orderedToolDefinitions: [ToolDefinitionSnapshotDTO],
        modelContextWindow: ModelContextWindowDTO
    ) throws -> Self {
        let unsigned = Self(
            orderedPromptDocuments: orderedPromptDocuments,
            skillDescriptors: skillDescriptors,
            orderedToolDefinitions: orderedToolDefinitions,
            modelContextWindow: modelContextWindow,
            snapshotDigest: ""
        )
        try unsigned.validateFields()
        return Self(
            orderedPromptDocuments: orderedPromptDocuments,
            skillDescriptors: skillDescriptors,
            orderedToolDefinitions: orderedToolDefinitions,
            modelContextWindow: modelContextWindow,
            snapshotDigest: try unsigned.recomputedDigest()
        )
    }

    public func validate() throws {
        try validateFields()
        guard snapshotDigest.count == 64,
              snapshotDigest.utf8.allSatisfy({
                  ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66)
              }),
              snapshotDigest == (try recomputedDigest()) else {
            throw RunStartSnapshotValidationError(
                code: "run_start_snapshot.digest_mismatch"
            )
        }
    }

    public func recomputedDigest() throws -> String {
        let document = SnapshotDigestDocument(
            orderedPromptDocuments: orderedPromptDocuments,
            skillDescriptors: skillDescriptors,
            orderedToolDefinitions: orderedToolDefinitions,
            modelContextWindow: modelContextWindow
        )
        let data = try JSONEncoder().encode(document)
        let canonical = try JSONDecoder().decode(
            CanonicalJSONValue.self,
            from: data
        )
        return try CanonicalDigestV1.digest(
            domain: "run-start-snapshot:v1",
            document: canonical
        ).hex
    }

    private func validateFields() throws {
        guard modelContextWindow.contextWindowTokens > 0,
              modelContextWindow.maxOutputTokens
                < modelContextWindow.contextWindowTokens else {
            throw RunStartSnapshotValidationError(
                code: "run_start_snapshot.model_context_window_invalid"
            )
        }
        guard skillDescriptors.count <= Self.maximumSkillDescriptors else {
            throw RunStartSnapshotValidationError(
                code: "run_start_snapshot.too_many_skills"
            )
        }
        try requireUnique(
            orderedPromptDocuments.map(\.id),
            code: "run_start_snapshot.duplicate_prompt_document_id"
        )
        try requireUnique(
            skillDescriptors.map(\.id),
            code: "run_start_snapshot.duplicate_skill_id"
        )
        try requireUnique(
            orderedToolDefinitions.map(\.name),
            code: "run_start_snapshot.duplicate_tool_name"
        )

        for document in orderedPromptDocuments {
            guard !document.id.isEmpty,
                  !document.source.isEmpty,
                  !document.source.hasPrefix("/") else {
                throw RunStartSnapshotValidationError(
                    code: "run_start_snapshot.prompt_document_invalid"
                )
            }
        }
        for descriptor in skillDescriptors {
            guard descriptor.enabled,
                  !descriptor.id.isEmpty,
                  !descriptor.name.isEmpty,
                  isValidSkillLocation(
                      descriptor.location,
                      id: descriptor.id
                  ) else {
                throw RunStartSnapshotValidationError(
                    code: "run_start_snapshot.skill_location_invalid"
                )
            }
        }
        for tool in orderedToolDefinitions {
            guard !tool.name.isEmpty,
                  tool.inputSchema.objectValue(forKey: "type")
                    == .string("object") else {
                throw RunStartSnapshotValidationError(
                    code: "run_start_snapshot.tool_schema_not_object"
                )
            }
        }
    }

    private func isValidSkillLocation(_ location: String, id: String) -> Bool {
        let prefix = "/var/localagent/skills/"
        let suffix = "/SKILL.md"
        guard location.hasPrefix(prefix),
              location.hasSuffix(suffix) else {
            return false
        }
        let start = location.index(location.startIndex, offsetBy: prefix.count)
        let end = location.index(location.endIndex, offsetBy: -suffix.count)
        let component = String(location[start..<end])
        guard component == id,
              component != ".",
              component != "..",
              !component.isEmpty else {
            return false
        }
        return component.utf8.allSatisfy {
            ($0 >= 0x41 && $0 <= 0x5A)
                || ($0 >= 0x61 && $0 <= 0x7A)
                || ($0 >= 0x30 && $0 <= 0x39)
                || $0 == 0x2D
                || $0 == 0x2E
                || $0 == 0x5F
        }
    }

    private func requireUnique(
        _ values: [String],
        code: String
    ) throws {
        guard Set(values).count == values.count else {
            throw RunStartSnapshotValidationError(code: code)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case orderedPromptDocuments = "ordered_prompt_documents"
        case skillDescriptors = "skill_descriptors"
        case orderedToolDefinitions = "ordered_tool_definitions"
        case modelContextWindow = "model_context_window"
        case snapshotDigest = "snapshot_digest"
    }
}

public struct RunStartSnapshotValidationError: Error, Equatable, Sendable {
    public let code: String

    public init(code: String) {
        self.code = code
    }
}

private struct SnapshotDigestDocument: Codable {
    let orderedPromptDocuments: [PromptDocumentSnapshotDTO]
    let skillDescriptors: [RustSkillDescriptorDTO]
    let orderedToolDefinitions: [ToolDefinitionSnapshotDTO]
    let modelContextWindow: ModelContextWindowDTO

    private enum CodingKeys: String, CodingKey {
        case orderedPromptDocuments = "ordered_prompt_documents"
        case skillDescriptors = "skill_descriptors"
        case orderedToolDefinitions = "ordered_tool_definitions"
        case modelContextWindow = "model_context_window"
    }
}

public struct TranscriptAttachmentReferenceDTO: Codable, Equatable, Sendable {
    public let attachmentID: String
    public let displayName: String
    public let mediaType: String
    public let modality: String
    public let contentDigest: String

    public init(
        attachmentID: String,
        displayName: String,
        mediaType: String,
        modality: String,
        contentDigest: String
    ) {
        self.attachmentID = attachmentID
        self.displayName = displayName
        self.mediaType = mediaType
        self.modality = modality
        self.contentDigest = contentDigest
    }

    private enum CodingKeys: String, CodingKey {
        case attachmentID = "attachment_id"
        case displayName = "display_name"
        case mediaType = "media_type"
        case modality
        case contentDigest = "content_digest"
    }
}

public enum TranscriptCommandDTO: Codable, Equatable, Sendable {
    case send(
        requestID: String,
        conversationStreamID: String,
        clientMessageID: String,
        text: String,
        attachments: [TranscriptAttachmentReferenceDTO],
        runStartSnapshot: RunStartSnapshotDTO
    )
    case retryFrom(
        requestID: String,
        conversationStreamID: String,
        anchorEventID: String,
        runStartSnapshot: RunStartSnapshotDTO
    )
    case editMessage(
        requestID: String,
        conversationStreamID: String,
        targetEventID: String,
        replacementText: String,
        replacementAttachments: [TranscriptAttachmentReferenceDTO],
        runStartSnapshot: RunStartSnapshotDTO
    )
    case deleteMessage(
        requestID: String,
        conversationStreamID: String,
        targetEventID: String
    )
    case clearConversation(requestID: String, conversationStreamID: String)
    case createBranch(
        requestID: String,
        conversationStreamID: String,
        anchorEventID: String,
        newConversationStreamID: String
    )
    case archiveConversation(requestID: String, conversationStreamID: String)
    case deleteConversation(requestID: String, conversationStreamID: String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let requestID = try container.decode(String.self, forKey: .requestID)
        let streamID = try container.decode(String.self, forKey: .conversationStreamID)
        switch kind {
        case .send:
            self = .send(
                requestID: requestID,
                conversationStreamID: streamID,
                clientMessageID: try container.decode(String.self, forKey: .clientMessageID),
                text: try container.decode(String.self, forKey: .text),
                attachments: try container.decode(
                    [TranscriptAttachmentReferenceDTO].self,
                    forKey: .attachments
                ),
                runStartSnapshot: try container.decode(
                    RunStartSnapshotDTO.self,
                    forKey: .runStartSnapshot
                )
            )
        case .retryFrom:
            self = .retryFrom(
                requestID: requestID,
                conversationStreamID: streamID,
                anchorEventID: try container.decode(String.self, forKey: .anchorEventID),
                runStartSnapshot: try container.decode(
                    RunStartSnapshotDTO.self,
                    forKey: .runStartSnapshot
                )
            )
        case .editMessage:
            self = .editMessage(
                requestID: requestID,
                conversationStreamID: streamID,
                targetEventID: try container.decode(String.self, forKey: .targetEventID),
                replacementText: try container.decode(String.self, forKey: .replacementText),
                replacementAttachments: try container.decode(
                    [TranscriptAttachmentReferenceDTO].self,
                    forKey: .replacementAttachments
                ),
                runStartSnapshot: try container.decode(
                    RunStartSnapshotDTO.self,
                    forKey: .runStartSnapshot
                )
            )
        case .deleteMessage:
            self = .deleteMessage(
                requestID: requestID,
                conversationStreamID: streamID,
                targetEventID: try container.decode(String.self, forKey: .targetEventID)
            )
        case .clearConversation:
            self = .clearConversation(
                requestID: requestID,
                conversationStreamID: streamID
            )
        case .createBranch:
            self = .createBranch(
                requestID: requestID,
                conversationStreamID: streamID,
                anchorEventID: try container.decode(String.self, forKey: .anchorEventID),
                newConversationStreamID: try container.decode(
                    String.self,
                    forKey: .newConversationStreamID
                )
            )
        case .archiveConversation:
            self = .archiveConversation(
                requestID: requestID,
                conversationStreamID: streamID
            )
        case .deleteConversation:
            self = .deleteConversation(
                requestID: requestID,
                conversationStreamID: streamID
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .send(requestID, streamID, clientMessageID, text, attachments, snapshot):
            try container.encode(Kind.send, forKey: .kind)
            try container.encode(requestID, forKey: .requestID)
            try container.encode(streamID, forKey: .conversationStreamID)
            try container.encode(clientMessageID, forKey: .clientMessageID)
            try container.encode(text, forKey: .text)
            try container.encode(attachments, forKey: .attachments)
            try container.encode(snapshot, forKey: .runStartSnapshot)
        case let .retryFrom(requestID, streamID, anchorEventID, snapshot):
            try container.encode(Kind.retryFrom, forKey: .kind)
            try container.encode(requestID, forKey: .requestID)
            try container.encode(streamID, forKey: .conversationStreamID)
            try container.encode(anchorEventID, forKey: .anchorEventID)
            try container.encode(snapshot, forKey: .runStartSnapshot)
        case let .editMessage(
            requestID,
            streamID,
            targetEventID,
            replacementText,
            replacementAttachments,
            snapshot
        ):
            try container.encode(Kind.editMessage, forKey: .kind)
            try container.encode(requestID, forKey: .requestID)
            try container.encode(streamID, forKey: .conversationStreamID)
            try container.encode(targetEventID, forKey: .targetEventID)
            try container.encode(replacementText, forKey: .replacementText)
            try container.encode(replacementAttachments, forKey: .replacementAttachments)
            try container.encode(snapshot, forKey: .runStartSnapshot)
        case let .deleteMessage(requestID, streamID, targetEventID):
            try container.encode(Kind.deleteMessage, forKey: .kind)
            try container.encode(requestID, forKey: .requestID)
            try container.encode(streamID, forKey: .conversationStreamID)
            try container.encode(targetEventID, forKey: .targetEventID)
        case let .clearConversation(requestID, streamID):
            try container.encode(Kind.clearConversation, forKey: .kind)
            try container.encode(requestID, forKey: .requestID)
            try container.encode(streamID, forKey: .conversationStreamID)
        case let .createBranch(requestID, streamID, anchorEventID, newStreamID):
            try container.encode(Kind.createBranch, forKey: .kind)
            try container.encode(requestID, forKey: .requestID)
            try container.encode(streamID, forKey: .conversationStreamID)
            try container.encode(anchorEventID, forKey: .anchorEventID)
            try container.encode(newStreamID, forKey: .newConversationStreamID)
        case let .archiveConversation(requestID, streamID):
            try container.encode(Kind.archiveConversation, forKey: .kind)
            try container.encode(requestID, forKey: .requestID)
            try container.encode(streamID, forKey: .conversationStreamID)
        case let .deleteConversation(requestID, streamID):
            try container.encode(Kind.deleteConversation, forKey: .kind)
            try container.encode(requestID, forKey: .requestID)
            try container.encode(streamID, forKey: .conversationStreamID)
        }
    }

    private enum Kind: String, Codable {
        case send
        case retryFrom = "retry_from"
        case editMessage = "edit_message"
        case deleteMessage = "delete_message"
        case clearConversation = "clear_conversation"
        case createBranch = "create_branch"
        case archiveConversation = "archive_conversation"
        case deleteConversation = "delete_conversation"
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case requestID = "request_id"
        case conversationStreamID = "conversation_stream_id"
        case clientMessageID = "client_message_id"
        case text
        case attachments
        case runStartSnapshot = "run_start_snapshot"
        case anchorEventID = "anchor_event_id"
        case targetEventID = "target_event_id"
        case replacementText = "replacement_text"
        case replacementAttachments = "replacement_attachments"
        case newConversationStreamID = "new_conversation_stream_id"
    }
}

public struct TranscriptCommandResultDTO: Codable, Equatable, Sendable {
    public let conversationStreamID: String
    public let acceptedSequence: UInt64
    public let runID: String?

    public init(
        conversationStreamID: String,
        acceptedSequence: UInt64,
        runID: String?
    ) {
        self.conversationStreamID = conversationStreamID
        self.acceptedSequence = acceptedSequence
        self.runID = runID
    }

    private enum CodingKeys: String, CodingKey {
        case conversationStreamID = "conversation_stream_id"
        case acceptedSequence = "accepted_sequence"
        case runID = "run_id"
    }
}

public enum TranscriptProjectionKindDTO: String, Codable, Equatable, Sendable {
    case sessionCreated = "session_created"
    case providerChanged = "provider_changed"
    case toolRegistered = "tool_registered"
    case userMessage = "user_message"
    case transcriptRetryRequested = "transcript_retry_requested"
    case messageEdited = "message_edited"
    case messageDeleted = "message_deleted"
    case conversationCleared = "conversation_cleared"
    case branchCreated = "branch_created"
    case conversationArchived = "conversation_archived"
    case conversationDeleted = "conversation_deleted"
    case assistantMessageStarted = "assistant_message_started"
    case assistantTextDelta = "assistant_text_delta"
    case assistantMessageCompleted = "assistant_message_completed"
    case toolCallRequested = "tool_call_requested"
    case toolCallApproved = "tool_call_approved"
    case toolCallRejected = "tool_call_rejected"
    case toolExecutionStarted = "tool_execution_started"
    case toolExecutionUpdate = "tool_execution_update"
    case toolExecutionCompleted = "tool_execution_completed"
    case toolExecutionFailed = "tool_execution_failed"
    case toolResultMessage = "tool_result_message"
    case runSuspended = "run_suspended"
    case runResumed = "run_resumed"
    case compactionCreated = "compaction_created"
    case branchSummaryCreated = "branch_summary_created"
    case runCancelled = "run_cancelled"
    case runFailed = "run_failed"
}

public struct TranscriptProjectionEventDTO: Codable, Equatable, Sendable {
    public let conversationStreamID: String
    public let sequence: UInt64
    public let eventID: String
    public let runID: String?
    public let kind: TranscriptProjectionKindDTO
    public let payload: CanonicalJSONValue

    public init(
        conversationStreamID: String,
        sequence: UInt64,
        eventID: String,
        runID: String?,
        kind: TranscriptProjectionKindDTO,
        payload: CanonicalJSONValue
    ) {
        self.conversationStreamID = conversationStreamID
        self.sequence = sequence
        self.eventID = eventID
        self.runID = runID
        self.kind = kind
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey {
        case conversationStreamID = "conversation_stream_id"
        case sequence
        case eventID = "event_id"
        case runID = "run_id"
        case kind
        case payload
    }
}

public struct ObserveTranscriptProjectionsRequestDTO: Codable, Equatable, Sendable {
    public let subscriptionID: String
    public let conversationStreamID: String
    public let afterSequence: UInt64

    public init(
        subscriptionID: String,
        conversationStreamID: String,
        afterSequence: UInt64
    ) {
        self.subscriptionID = subscriptionID
        self.conversationStreamID = conversationStreamID
        self.afterSequence = afterSequence
    }

    private enum CodingKeys: String, CodingKey {
        case subscriptionID = "subscription_id"
        case conversationStreamID = "conversation_stream_id"
        case afterSequence = "after_sequence"
    }
}

public struct CancelTranscriptProjectionSubscriptionDTO: Codable, Equatable, Sendable {
    public let subscriptionID: String

    public init(subscriptionID: String) {
        self.subscriptionID = subscriptionID
    }

    private enum CodingKeys: String, CodingKey {
        case subscriptionID = "subscription_id"
    }
}
