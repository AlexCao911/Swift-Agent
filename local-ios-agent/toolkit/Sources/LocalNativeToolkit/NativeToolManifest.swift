import Foundation
import LocalAgentBridge

public enum NativeToolMode: String, Codable, Sendable, Equatable {
    case background
    case userMediated = "user_mediated"
    case systemActionAdapter = "system_action_adapter"
}

public enum NativeToolApprovalPolicy: String, Codable, Sendable, Equatable {
    case never
    case perCall = "per_call"
    case perSession = "per_session"
    case alwaysDenyUntilConfigured = "always_deny_until_configured"
}

public enum NativeToolTrustLevel: String, Codable, Sendable, Equatable {
    case trustedAppPolicy = "trusted_app_policy"
    case userInstruction = "user_instruction"
    case trustedToolResult = "trusted_tool_result"
    case untrustedExternalContent = "untrusted_external_content"
}

public enum NativeToolFallbackKind: String, Codable, Sendable, Equatable {
    case none
    case openSettings = "open_settings"
    case userMediated = "user_mediated"
    case unavailable
}

public enum NativeToolResultSummaryPolicy: String, Codable, Sendable, Equatable {
    case metadataOnly = "metadata_only"
    case excerptOnly = "excerpt_only"
    case fullText = "full_text"
}

public struct NativeToolFallback: Codable, Sendable, Equatable {
    public var kind: NativeToolFallbackKind
    public var message: String

    public init(kind: NativeToolFallbackKind, message: String) {
        self.kind = kind
        self.message = message
    }
}

public struct NativeToolAudit: Codable, Sendable, Equatable {
    public var label: String
    public var resultSummaryPolicy: NativeToolResultSummaryPolicy

    public init(label: String, resultSummaryPolicy: NativeToolResultSummaryPolicy) {
        self.label = label
        self.resultSummaryPolicy = resultSummaryPolicy
    }

    private enum CodingKeys: String, CodingKey {
        case label
        case resultSummaryPolicy = "result_summary_policy"
    }
}

public struct NativeToolManifest: Sendable, Equatable {
    public var manifestId: String
    public var capabilityId: String
    public var title: String
    public var description: String
    public var mode: NativeToolMode
    public var permissionScope: NativePermissionScope?
    public var requiredPrivacyKeys: [String]
    public var requiresForegroundUI: Bool
    public var minimumOS: String
    public var regionPolicy: String
    public var fallback: NativeToolFallback
    public var riskLevel: NativeToolRiskLevel
    public var approvalPolicy: NativeToolApprovalPolicy
    public var trustLevel: NativeToolTrustLevel
    public var retention: RetentionPolicyDTO
    public var audit: NativeToolAudit

    public init(
        manifestId: String,
        capabilityId: String,
        title: String,
        description: String,
        mode: NativeToolMode,
        permissionScope: NativePermissionScope?,
        requiredPrivacyKeys: [String],
        requiresForegroundUI: Bool,
        minimumOS: String,
        regionPolicy: String,
        fallback: NativeToolFallback,
        riskLevel: NativeToolRiskLevel,
        approvalPolicy: NativeToolApprovalPolicy,
        trustLevel: NativeToolTrustLevel,
        retention: RetentionPolicyDTO,
        audit: NativeToolAudit
    ) {
        self.manifestId = manifestId
        self.capabilityId = capabilityId
        self.title = title
        self.description = description
        self.mode = mode
        self.permissionScope = permissionScope
        self.requiredPrivacyKeys = requiredPrivacyKeys
        self.requiresForegroundUI = requiresForegroundUI
        self.minimumOS = minimumOS
        self.regionPolicy = regionPolicy
        self.fallback = fallback
        self.riskLevel = riskLevel
        self.approvalPolicy = approvalPolicy
        self.trustLevel = trustLevel
        self.retention = retention
        self.audit = audit
    }
}

public struct NativeToolSchemaMetadataV1: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var manifestId: String
    public var capabilityId: String
    public var toolMode: NativeToolMode
    public var permissionScope: String?
    public var approvalPolicy: NativeToolApprovalPolicy
    public var riskLevel: RiskLevelDTO
    public var contextTrustLevel: NativeToolTrustLevel
    public var availability: Availability
    public var fallback: NativeToolFallback
    public var audit: NativeToolAudit

    public init(
        schemaVersion: Int,
        manifestId: String,
        capabilityId: String,
        toolMode: NativeToolMode,
        permissionScope: String?,
        approvalPolicy: NativeToolApprovalPolicy,
        riskLevel: RiskLevelDTO,
        contextTrustLevel: NativeToolTrustLevel,
        availability: Availability,
        fallback: NativeToolFallback,
        audit: NativeToolAudit
    ) {
        self.schemaVersion = schemaVersion
        self.manifestId = manifestId
        self.capabilityId = capabilityId
        self.toolMode = toolMode
        self.permissionScope = permissionScope
        self.approvalPolicy = approvalPolicy
        self.riskLevel = riskLevel
        self.contextTrustLevel = contextTrustLevel
        self.availability = availability
        self.fallback = fallback
        self.audit = audit
    }

    public struct Availability: Codable, Sendable, Equatable {
        public var state: String
        public var osMinimum: String
        public var regionPolicy: String

        public init(state: String, osMinimum: String, regionPolicy: String) {
            self.state = state
            self.osMinimum = osMinimum
            self.regionPolicy = regionPolicy
        }

        private enum CodingKeys: String, CodingKey {
            case state
            case osMinimum = "os_minimum"
            case regionPolicy = "region_policy"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case manifestId = "manifest_id"
        case capabilityId = "capability_id"
        case toolMode = "tool_mode"
        case permissionScope = "permission_scope"
        case approvalPolicy = "approval_policy"
        case riskLevel = "risk_level"
        case contextTrustLevel = "context_trust_level"
        case availability
        case fallback
        case audit
    }
}
