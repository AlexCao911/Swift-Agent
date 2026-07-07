import LocalAgentBridge
import LocalNativeToolkit
import SwiftUI

struct StateBadgeDescriptor: Equatable, Sendable {
    enum Tone: Equatable, Sendable {
        case neutral
        case success
        case warning
        case critical
        case accent
    }

    var label: String
    var systemImageName: String
    var tone: Tone
    var accessibilityLabel: String

    static func revision(profileId: String, revisionId: UInt64) -> Self {
        Self(
            label: "Rev \(revisionId)",
            systemImageName: "number",
            tone: .neutral,
            accessibilityLabel: "Profile \(profileId) revision \(revisionId)"
        )
    }

    static func modelReadiness(_ readiness: ModelReadiness) -> Self {
        let label: String
        let icon: String
        let tone: Tone

        switch readiness {
        case .ready:
            label = "Ready"
            icon = "checkmark.circle"
            tone = .success
        case .missingConfiguration(let reason):
            label = reason
            icon = "exclamationmark.circle"
            tone = .warning
        case .unavailable(let reason):
            label = reason
            icon = "xmark.octagon"
            tone = .critical
        }

        return Self(
            label: label,
            systemImageName: icon,
            tone: tone,
            accessibilityLabel: "Model readiness: \(label)"
        )
    }

    static func permission(_ readiness: NativePermissionReadiness) -> Self {
        let label: String
        let icon: String
        let tone: Tone

        switch readiness {
        case .ready:
            label = "Permission ready"
            icon = "checkmark.circle"
            tone = .success
        case .needsUserGrant:
            label = "Needs permission"
            icon = "questionmark.circle"
            tone = .warning
        case .denied:
            label = "Permission denied"
            icon = "lock"
            tone = .critical
        case .unavailable(_, let reason):
            label = reason
            icon = "exclamationmark.triangle"
            tone = .warning
        }

        return Self(
            label: label,
            systemImageName: icon,
            tone: tone,
            accessibilityLabel: "Permission: \(label)"
        )
    }

    static func toolApproval(_ policy: NativeToolApprovalPolicy) -> Self {
        let label: String
        let tone: Tone

        switch policy {
        case .never:
            label = "No approval"
            tone = .neutral
        case .perCall:
            label = "Approve each call"
            tone = .warning
        case .perSession:
            label = "Approve session"
            tone = .accent
        case .alwaysDenyUntilConfigured:
            label = "Configuration required"
            tone = .critical
        }

        return Self(
            label: label,
            systemImageName: "checkmark.shield",
            tone: tone,
            accessibilityLabel: "Tool approval: \(label)"
        )
    }

    static func trustLevel(_ trustLevel: NativeToolTrustLevel) -> Self {
        let label: String
        let tone: Tone

        switch trustLevel {
        case .trustedAppPolicy:
            label = "App policy"
            tone = .success
        case .userInstruction:
            label = "User instruction"
            tone = .accent
        case .trustedToolResult:
            label = "Tool result"
            tone = .neutral
        case .untrustedExternalContent:
            label = "External content"
            tone = .warning
        }

        return Self(
            label: label,
            systemImageName: "tag",
            tone: tone,
            accessibilityLabel: "Context trust: \(label)"
        )
    }
}

struct StateBadge: View {
    var descriptor: StateBadgeDescriptor

    var body: some View {
        Label(descriptor.label, systemImage: descriptor.systemImageName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(foregroundStyle)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(backgroundStyle, in: Capsule())
            .accessibilityLabel(descriptor.accessibilityLabel)
    }

    private var foregroundStyle: Color {
        switch descriptor.tone {
        case .neutral:
            .secondary
        case .success:
            .green
        case .warning:
            .orange
        case .critical:
            .red
        case .accent:
            .accentColor
        }
    }

    private var backgroundStyle: Color {
        switch descriptor.tone {
        case .neutral:
            Color(.secondarySystemBackground)
        case .success:
            Color.green.opacity(0.12)
        case .warning:
            Color.orange.opacity(0.12)
        case .critical:
            Color.red.opacity(0.12)
        case .accent:
            Color.accentColor.opacity(0.12)
        }
    }
}

struct RevisionBadge: View {
    var profileId: String
    var revisionId: UInt64

    var body: some View {
        StateBadge(descriptor: .revision(profileId: profileId, revisionId: revisionId))
    }
}

struct ModelReadinessBadge: View {
    var readiness: ModelReadiness

    var body: some View {
        StateBadge(descriptor: .modelReadiness(readiness))
    }
}

struct PermissionBadge: View {
    var readiness: NativePermissionReadiness

    var body: some View {
        StateBadge(descriptor: .permission(readiness))
    }
}

struct ToolApprovalBadge: View {
    var policy: NativeToolApprovalPolicy

    var body: some View {
        StateBadge(descriptor: .toolApproval(policy))
    }
}

struct TrustLevelBadge: View {
    var trustLevel: NativeToolTrustLevel

    var body: some View {
        StateBadge(descriptor: .trustLevel(trustLevel))
    }
}
