import Foundation

public struct RuntimeEventKindDTO: RawRepresentable, Codable, Equatable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let sessionCreated = Self(rawValue: "session_created")
    public static let providerChanged = Self(rawValue: "provider_changed")
    public static let toolRegistered = Self(rawValue: "tool_registered")
    public static let userMessage = Self(rawValue: "user_message")
    public static let assistantMessageStarted = Self(rawValue: "assistant_message_started")
    public static let assistantTextDelta = Self(rawValue: "assistant_text_delta")
    public static let assistantMessageCompleted = Self(rawValue: "assistant_message_completed")
    public static let toolCallRequested = Self(rawValue: "tool_call_requested")
    public static let toolCallApproved = Self(rawValue: "tool_call_approved")
    public static let toolCallRejected = Self(rawValue: "tool_call_rejected")
    public static let toolExecutionStarted = Self(rawValue: "tool_execution_started")
    public static let toolExecutionUpdate = Self(rawValue: "tool_execution_update")
    public static let toolExecutionCompleted = Self(rawValue: "tool_execution_completed")
    public static let toolExecutionFailed = Self(rawValue: "tool_execution_failed")
    public static let toolResultMessage = Self(rawValue: "tool_result_message")
    public static let runSuspended = Self(rawValue: "run_suspended")
    public static let runResumed = Self(rawValue: "run_resumed")
    public static let compactionCreated = Self(rawValue: "compaction_created")
    public static let branchSummaryCreated = Self(rawValue: "branch_summary_created")
    public static let runCancelled = Self(rawValue: "run_cancelled")
    public static let runFailed = Self(rawValue: "run_failed")

    public static func unknown(raw: String) -> Self {
        Self(rawValue: raw)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct RunStateDTO: RawRepresentable, Codable, Equatable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let running = Self(rawValue: "running")
    public static let waitingTool = Self(rawValue: "waiting_tool")
    public static let suspended = Self(rawValue: "suspended")
    public static let failed = Self(rawValue: "failed")
    public static let cancelled = Self(rawValue: "cancelled")
    public static let completed = Self(rawValue: "completed")

    public static func unknown(raw: String) -> Self {
        Self(rawValue: raw)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct SensitivityDTO: RawRepresentable, Codable, Equatable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let `public` = Self(rawValue: "public")
    public static let `private` = Self(rawValue: "private")
    public static let secret = Self(rawValue: "secret")

    public static func unknown(raw: String) -> Self {
        Self(rawValue: raw)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct RetentionPolicyDTO: RawRepresentable, Codable, Equatable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let runOnly = Self(rawValue: "run_only")
    public static let session = Self(rawValue: "session")
    public static let memoryCandidate = Self(rawValue: "memory_candidate")
    public static let auditOnly = Self(rawValue: "audit_only")

    public static func unknown(raw: String) -> Self {
        Self(rawValue: raw)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct RiskLevelDTO: RawRepresentable, Codable, Equatable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let readOnly = Self(rawValue: "read_only")
    public static let confirm = Self(rawValue: "confirm")
    public static let destructive = Self(rawValue: "destructive")

    public static func unknown(raw: String) -> Self {
        Self(rawValue: raw)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct PermissionStateDTO: RawRepresentable, Codable, Equatable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let notDetermined = Self(rawValue: "not_determined")
    public static let granted = Self(rawValue: "granted")
    public static let denied = Self(rawValue: "denied")
    public static let restricted = Self(rawValue: "restricted")

    public static func unknown(raw: String) -> Self {
        Self(rawValue: raw)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct RuntimeEventDTO: Codable, Equatable, Sendable {
    public var id: String
    public var sessionId: String
    public var parentId: String?
    public var runId: String?
    public var sequence: UInt64
    public var createdAtMillis: UInt64?
    public var depth: UInt32
    public var kind: RuntimeEventKindDTO
    public var payload: String
    public var blobRefs: [String]

    public init(
        id: String,
        sessionId: String,
        parentId: String?,
        runId: String?,
        sequence: UInt64,
        createdAtMillis: UInt64? = nil,
        depth: UInt32,
        kind: RuntimeEventKindDTO,
        payload: String,
        blobRefs: [String]
    ) {
        self.id = id
        self.sessionId = sessionId
        self.parentId = parentId
        self.runId = runId
        self.sequence = sequence
        self.createdAtMillis = createdAtMillis
        self.depth = depth
        self.kind = kind
        self.payload = payload
        self.blobRefs = blobRefs
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case parentId = "parent_id"
        case runId = "run_id"
        case sequence
        case createdAtMillis = "created_at_millis"
        case depth
        case kind
        case payload
        case blobRefs = "blob_refs"
    }
}

public struct ConversationSummaryDTO: Codable, Equatable, Sendable {
    public var sessionId: String
    public var title: String
    public var activeLeafId: String?
    public var lastEventId: String?
    public var lastUpdatedSequence: UInt64
    public var lastUpdatedAtMillis: UInt64?
    public var searchText: String?

    public init(
        sessionId: String,
        title: String,
        activeLeafId: String?,
        lastEventId: String?,
        lastUpdatedSequence: UInt64,
        lastUpdatedAtMillis: UInt64? = nil,
        searchText: String? = nil
    ) {
        self.sessionId = sessionId
        self.title = title
        self.activeLeafId = activeLeafId
        self.lastEventId = lastEventId
        self.lastUpdatedSequence = lastUpdatedSequence
        self.lastUpdatedAtMillis = lastUpdatedAtMillis
        self.searchText = searchText
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case title
        case activeLeafId = "active_leaf_id"
        case lastEventId = "last_event_id"
        case lastUpdatedSequence = "last_updated_sequence"
        case lastUpdatedAtMillis = "last_updated_at_millis"
        case searchText = "search_text"
    }
}

public struct AgentTurnResultDTO: Codable, Equatable, Sendable {
    public var runId: String
    public var state: RunStateDTO
    public var events: [RuntimeEventDTO]
    public var pendingToolCallId: String?

    public init(
        runId: String,
        state: RunStateDTO,
        events: [RuntimeEventDTO],
        pendingToolCallId: String?
    ) {
        self.runId = runId
        self.state = state
        self.events = events
        self.pendingToolCallId = pendingToolCallId
    }

    private enum CodingKeys: String, CodingKey {
        case runId = "run_id"
        case state
        case events
        case pendingToolCallId = "pending_tool_call_id"
    }
}

public struct ToolSchemaDTO: Codable, Equatable, Sendable {
    public var name: String
    public var description: String
    public var parametersJsonSchema: String
    public var riskLevel: RiskLevelDTO
    public var metadataJson: String?

    public init(
        name: String,
        description: String,
        parametersJsonSchema: String,
        riskLevel: RiskLevelDTO,
        metadataJson: String? = nil
    ) {
        self.name = name
        self.description = description
        self.parametersJsonSchema = parametersJsonSchema
        self.riskLevel = riskLevel
        self.metadataJson = metadataJson
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case description
        case parametersJsonSchema = "parameters_json_schema"
        case riskLevel = "risk_level"
        case metadataJson = "metadata_json"
    }
}

public struct ToolExecutionRequestDTO: Codable, Equatable, Sendable {
    public var runId: String
    public var sessionId: String
    public var toolCallEntryId: String
    public var toolCallId: String
    public var toolName: String
    public var argumentsJson: String

    public init(
        runId: String,
        sessionId: String,
        toolCallEntryId: String,
        toolCallId: String,
        toolName: String,
        argumentsJson: String
    ) {
        self.runId = runId
        self.sessionId = sessionId
        self.toolCallEntryId = toolCallEntryId
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.argumentsJson = argumentsJson
    }

    private enum CodingKeys: String, CodingKey {
        case runId = "run_id"
        case sessionId = "session_id"
        case toolCallEntryId = "tool_call_entry_id"
        case toolCallId = "tool_call_id"
        case toolName = "tool_name"
        case argumentsJson = "arguments_json"
    }
}

public struct ToolResultDTO: Codable, Equatable, Sendable {
    public var displayText: String
    public var modelText: String
    public var structuredJson: String
    public var auditText: String
    public var sensitivity: SensitivityDTO
    public var retention: RetentionPolicyDTO
    public var isError: Bool

    public init(
        displayText: String,
        modelText: String,
        structuredJson: String,
        auditText: String,
        sensitivity: SensitivityDTO,
        retention: RetentionPolicyDTO,
        isError: Bool
    ) {
        self.displayText = displayText
        self.modelText = modelText
        self.structuredJson = structuredJson
        self.auditText = auditText
        self.sensitivity = sensitivity
        self.retention = retention
        self.isError = isError
    }

    private enum CodingKeys: String, CodingKey {
        case displayText = "display_text"
        case modelText = "model_text"
        case structuredJson = "structured_json"
        case auditText = "audit_text"
        case sensitivity
        case retention
        case isError = "is_error"
    }
}

public enum ApprovalProtocolScopeDTO: Codable, Equatable, Sendable {
    case operation(operation: String)
    case egress(
        operation: String,
        disclosureId: String,
        destination: String,
        dataClasses: [String]
    )
    case unknown(kind: String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "operation":
            self = .operation(operation: try container.decode(String.self, forKey: .operation))
        case "egress":
            self = .egress(
                operation: try container.decode(String.self, forKey: .operation),
                disclosureId: try container.decode(String.self, forKey: .disclosureId),
                destination: try container.decode(String.self, forKey: .destination),
                dataClasses: try container.decode([String].self, forKey: .dataClasses)
            )
        default:
            self = .unknown(kind: kind)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .operation(let operation):
            try container.encode("operation", forKey: .kind)
            try container.encode(operation, forKey: .operation)
        case .egress(let operation, let disclosureId, let destination, let dataClasses):
            try container.encode("egress", forKey: .kind)
            try container.encode(operation, forKey: .operation)
            try container.encode(disclosureId, forKey: .disclosureId)
            try container.encode(destination, forKey: .destination)
            try container.encode(dataClasses, forKey: .dataClasses)
        case .unknown(let kind):
            try container.encode(kind, forKey: .kind)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case operation
        case disclosureId = "disclosure_id"
        case destination
        case dataClasses = "data_classes"
    }
}

public struct ApprovalProtocolRequestDTO: Codable, Equatable, Sendable {
    public var approvalId: String
    public var runId: String
    public var toolCallEntryId: String
    public var message: String
    public var requiresLocalAuthentication: Bool
    public var scope: ApprovalProtocolScopeDTO

    public init(
        approvalId: String,
        runId: String,
        toolCallEntryId: String,
        message: String,
        requiresLocalAuthentication: Bool,
        scope: ApprovalProtocolScopeDTO
    ) {
        self.approvalId = approvalId
        self.runId = runId
        self.toolCallEntryId = toolCallEntryId
        self.message = message
        self.requiresLocalAuthentication = requiresLocalAuthentication
        self.scope = scope
    }

    private enum CodingKeys: String, CodingKey {
        case approvalId = "approval_id"
        case runId = "run_id"
        case toolCallEntryId = "tool_call_entry_id"
        case message
        case requiresLocalAuthentication = "requires_local_authentication"
        case scope
    }
}

public struct ApprovalProtocolResponseDTO: Codable, Equatable, Sendable {
    public var approvalId: String
    public var approved: Bool
    public var reason: String?

    public init(
        approvalId: String,
        approved: Bool,
        reason: String?
    ) {
        self.approvalId = approvalId
        self.approved = approved
        self.reason = reason
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(approvalId, forKey: .approvalId)
        try container.encode(approved, forKey: .approved)
        if let reason {
            try container.encode(reason, forKey: .reason)
        } else {
            try container.encodeNil(forKey: .reason)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case approvalId = "approval_id"
        case approved
        case reason
    }
}

public struct PromptDebugSnapshotDTO: Codable, Equatable, Sendable {
    public var renderedText: String

    public init(renderedText: String) {
        self.renderedText = renderedText
    }

    private enum CodingKeys: String, CodingKey {
        case renderedText = "rendered_text"
    }
}

public struct ProviderKindDTO: RawRepresentable, Codable, Equatable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let mock = Self(rawValue: "mock")
    public static let desktopMiniCpm = Self(rawValue: "desktop_mini_cpm")
    public static let onDeviceMiniCpm = Self(rawValue: "on_device_mini_cpm")
    public static let openAiCompatibleLocal = Self(rawValue: "open_ai_compatible_local")
    public static let localLLM = Self(rawValue: "local_llm")

    public static func unknown(raw: String) -> Self {
        Self(rawValue: raw)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct ProviderProfileDTO: Codable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var kind: ProviderKindDTO
    public var maxContextTokens: Int

    public init(
        id: String,
        displayName: String,
        kind: ProviderKindDTO,
        maxContextTokens: Int
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.maxContextTokens = maxContextTokens
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case kind
        case maxContextTokens = "max_context_tokens"
    }
}
