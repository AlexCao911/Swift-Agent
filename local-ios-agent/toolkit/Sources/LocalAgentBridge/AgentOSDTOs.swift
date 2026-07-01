import Foundation

public struct StartRunRequestDTO: Codable, Equatable, Sendable {
    public var agentProfileId: String
    public var userIntent: String

    public init(agentProfileId: String, userIntent: String) {
        self.agentProfileId = agentProfileId
        self.userIntent = userIntent
    }

    private enum CodingKeys: String, CodingKey {
        case agentProfileId = "agent_profile_id"
        case userIntent = "user_intent"
    }
}

public struct RunHandleDTO: Codable, Equatable, Sendable {
    public var runId: String

    public init(runId: String) {
        self.runId = runId
    }

    private enum CodingKeys: String, CodingKey {
        case runId = "run_id"
    }
}

public struct AgentProfileDTO: Codable, Equatable, Sendable {
    public var profileId: String
    public var displayName: String

    public init(profileId: String, displayName: String) {
        self.profileId = profileId
        self.displayName = displayName
    }

    private enum CodingKeys: String, CodingKey {
        case profileId = "profile_id"
        case displayName = "display_name"
    }
}

public struct PackageInspectReportDTO: Codable, Equatable, Sendable {
    public var packageName: String
    public var issues: [PermissionIssueDTO]

    public init(packageName: String, issues: [PermissionIssueDTO] = []) {
        self.packageName = packageName
        self.issues = issues
    }

    private enum CodingKeys: String, CodingKey {
        case packageName = "package_name"
        case issues
    }
}

public struct PackageInstallRequestDTO: Codable, Equatable, Sendable {
    public var packageURL: URL

    public init(packageURL: URL) {
        self.packageURL = packageURL
    }

    private enum CodingKeys: String, CodingKey {
        case packageURL = "package_url"
    }
}

public struct PackageInstallPreviewUIModel: Codable, Equatable, Sendable {
    public var profileName: String
    public var operations: [PackageInstallOperationUIModel]
    public var issues: [PermissionIssueDTO]

    public init(
        profileName: String,
        operations: [PackageInstallOperationUIModel],
        issues: [PermissionIssueDTO] = []
    ) {
        self.profileName = profileName
        self.operations = operations
        self.issues = issues
    }

    private enum CodingKeys: String, CodingKey {
        case profileName = "profile_name"
        case operations
        case issues
    }
}

public struct PackageInstallOperationUIModel: Codable, Equatable, Sendable {
    public var code: String
    public var title: String

    public init(code: String, title: String) {
        self.code = code
        self.title = title
    }
}

public struct RunSnapshotPreviewUIModel: Codable, Equatable, Sendable {
    public var profileId: String
    public var isReady: Bool
    public var issues: [PermissionIssueDTO]

    public init(profileId: String, isReady: Bool, issues: [PermissionIssueDTO] = []) {
        self.profileId = profileId
        self.isReady = isReady
        self.issues = issues
    }

    private enum CodingKeys: String, CodingKey {
        case profileId = "profile_id"
        case isReady = "is_ready"
        case issues
    }
}

public typealias RunSnapshotReadinessUIModel = RunSnapshotPreviewUIModel

public struct CapabilityRequirementDTO: Codable, Equatable, Sendable {
    public var code: String
    public var title: String

    public init(code: String, title: String) {
        self.code = code
        self.title = title
    }
}

public struct PermissionIssueDTO: Codable, Equatable, Sendable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct PermissionReadinessUIModel: Codable, Equatable, Sendable {
    public var issues: [PermissionIssueDTO]

    public init(issues: [PermissionIssueDTO] = []) {
        self.issues = issues
    }

    public var isReady: Bool {
        issues.isEmpty
    }
}

public struct RunDebugUIModel: Codable, Equatable, Sendable {
    public var runId: String
    public var state: RunDebugStateDTO
    public var events: [RunDebugEventDTO]
    public var archives: [DebugArchiveDTO]
    public var checkpoints: [CheckpointDTO]

    public init(
        runId: String,
        state: RunDebugStateDTO,
        events: [RunDebugEventDTO],
        archives: [DebugArchiveDTO] = [],
        checkpoints: [CheckpointDTO]
    ) {
        self.runId = runId
        self.state = state
        self.events = events
        self.archives = archives
        self.checkpoints = checkpoints
    }

    private enum CodingKeys: String, CodingKey {
        case runId = "run_id"
        case state
        case events
        case archives
        case checkpoints
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.runId = try container.decode(String.self, forKey: .runId)
        self.state = try container.decode(RunDebugStateDTO.self, forKey: .state)
        self.events = try container.decode([RunDebugEventDTO].self, forKey: .events)
        self.archives = try container.decodeIfPresent([DebugArchiveDTO].self, forKey: .archives) ?? []
        self.checkpoints = try container.decode([CheckpointDTO].self, forKey: .checkpoints)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(runId, forKey: .runId)
        try container.encode(state, forKey: .state)
        try container.encode(events, forKey: .events)
        try container.encode(archives, forKey: .archives)
        try container.encode(checkpoints, forKey: .checkpoints)
    }
}

public struct RunDebugStateDTO: RawRepresentable, Codable, Equatable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let created = Self(rawValue: "created")
    public static let running = Self(rawValue: "running")
    public static let awaitingApproval = Self(rawValue: "awaiting_approval")
    public static let awaitingTool = Self(rawValue: "awaiting_tool")
    public static let failed = Self(rawValue: "failed")
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

public struct RunDebugEventDTO: Codable, Equatable, Sendable {
    public var id: String
    public var code: String
    public var title: String

    public init(id: String, code: String, title: String) {
        self.id = id
        self.code = code
        self.title = title
    }
}

public struct DebugArchiveDTO: Codable, Equatable, Sendable {
    public var id: String
    public var kind: DebugArchiveKindDTO
    public var title: String
    public var redactedPayload: String
    public var sourceLinks: [DebugArchiveSourceLinkDTO]

    public init(
        id: String,
        kind: DebugArchiveKindDTO,
        title: String,
        redactedPayload: String,
        sourceLinks: [DebugArchiveSourceLinkDTO] = []
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.redactedPayload = redactedPayload
        self.sourceLinks = sourceLinks
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case title
        case redactedPayload = "redacted_payload"
        case sourceLinks = "source_links"
    }
}

public struct DebugArchiveKindDTO: RawRepresentable, Codable, Equatable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let prompt = Self(rawValue: "prompt")
    public static let context = Self(rawValue: "context")
    public static let runtimeEvents = Self(rawValue: "runtime_events")

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

public struct DebugArchiveSourceLinkDTO: Codable, Equatable, Sendable {
    public var kind: DebugArchiveSourceKindDTO
    public var targetId: String

    public init(kind: DebugArchiveSourceKindDTO, targetId: String) {
        self.kind = kind
        self.targetId = targetId
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case targetId = "target_id"
    }
}

public struct DebugArchiveSourceKindDTO: RawRepresentable, Codable, Equatable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let promptArchive = Self(rawValue: "prompt_archive")
    public static let contextArchive = Self(rawValue: "context_archive")
    public static let runtimeEvent = Self(rawValue: "runtime_event")

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

public struct CheckpointDTO: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var canResume: Bool

    public init(id: String, title: String, canResume: Bool) {
        self.id = id
        self.title = title
        self.canResume = canResume
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case canResume = "can_resume"
    }
}

public struct AgentBuilderDraftDTO: Codable, Equatable, Sendable {
    public var profileId: String

    public init(profileId: String) {
        self.profileId = profileId
    }

    private enum CodingKeys: String, CodingKey {
        case profileId = "profile_id"
    }
}

public struct AgentBuilderUIModel: Codable, Equatable, Sendable {
    public var profileId: String
    public var displayName: String
    public var readiness: PermissionReadinessUIModel

    public init(
        profileId: String,
        displayName: String,
        readiness: PermissionReadinessUIModel
    ) {
        self.profileId = profileId
        self.displayName = displayName
        self.readiness = readiness
    }

    private enum CodingKeys: String, CodingKey {
        case profileId = "profile_id"
        case displayName = "display_name"
        case readiness
    }
}

public typealias ReadinessUIModel = PermissionReadinessUIModel
