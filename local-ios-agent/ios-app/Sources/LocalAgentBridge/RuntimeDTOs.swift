import Foundation

public enum RuntimeEventKindDTO: String, Codable, Sendable {
    case sessionCreated = "session_created"
    case providerChanged = "provider_changed"
    case toolRegistered = "tool_registered"
    case userMessage = "user_message"
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

public enum RunStateDTO: String, Codable, Sendable {
    case running
    case waitingTool = "waiting_tool"
    case suspended
    case failed
    case cancelled
    case completed
}

public enum SensitivityDTO: String, Codable, Sendable {
    case `public` = "public"
    case `private` = "private"
    case secret
}

public enum RetentionPolicyDTO: String, Codable, Sendable {
    case runOnly = "run_only"
    case session
    case memoryCandidate = "memory_candidate"
    case auditOnly = "audit_only"
}

public enum RiskLevelDTO: String, Codable, Sendable {
    case readOnly = "read_only"
    case confirm
    case destructive
}

public struct RuntimeEventDTO: Codable, Equatable, Sendable {
    public var id: String
    public var sessionId: String
    public var parentId: String?
    public var runId: String?
    public var sequence: UInt64
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
        case depth
        case kind
        case payload
        case blobRefs = "blob_refs"
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

    public init(
        name: String,
        description: String,
        parametersJsonSchema: String,
        riskLevel: RiskLevelDTO
    ) {
        self.name = name
        self.description = description
        self.parametersJsonSchema = parametersJsonSchema
        self.riskLevel = riskLevel
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case description
        case parametersJsonSchema = "parameters_json_schema"
        case riskLevel = "risk_level"
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

public struct ApprovalProtocolRequestDTO: Codable, Equatable, Sendable {
    public var approvalId: String
    public var message: String
    public var requiresLocalAuthentication: Bool

    public init(
        approvalId: String,
        message: String,
        requiresLocalAuthentication: Bool
    ) {
        self.approvalId = approvalId
        self.message = message
        self.requiresLocalAuthentication = requiresLocalAuthentication
    }

    private enum CodingKeys: String, CodingKey {
        case approvalId = "approval_id"
        case message
        case requiresLocalAuthentication = "requires_local_authentication"
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
