import Foundation
import LocalAgentBridge

public struct NativeVoiceShortcut: Codable, Equatable, Sendable {
    public var name: String
    public var phrase: String

    public init(name: String, phrase: String) {
        self.name = name
        self.phrase = phrase
    }
}

public protocol ShortcutsFacade: Sendable {
    func listVoiceShortcuts() async throws -> [NativeVoiceShortcut]
}

public struct ShortcutsListVoiceShortcutsTool: NativeTool {
    public let schema: NativeToolSchema

    private let shortcuts: any ShortcutsFacade

    public init(shortcuts: any ShortcutsFacade) {
        self.schema = Self.makeSchema()
        self.shortcuts = shortcuts
    }

    public func execute(argumentsJson: String) async -> ToolResultDTO {
        do {
            let shortcuts = try await shortcuts.listVoiceShortcuts()

            return NativeToolResultBuilder.success(
                manifestId: Self.manifest.manifestId,
                toolName: schema.name,
                toolCallId: "unknown",
                displayText: "\(shortcuts.count) voice shortcuts found.",
                modelText: "Voice shortcuts: \(shortcuts.map(\.name).joined(separator: ", "))",
                resultKind: "voice_shortcuts",
                resultPayload: [
                    "count": .number(Double(shortcuts.count)),
                    "shortcuts": .array(shortcuts.map(Self.shortcutJSONValue)),
                ],
                sourceKind: "shortcuts",
                sourceId: "shortcuts.list_voice_shortcuts",
                displayName: Self.manifest.title,
                attachmentIds: [],
                trustLevel: Self.manifest.trustLevel,
                sensitivity: .private,
                retention: Self.manifest.retention,
                modelTextPolicy: "tool_status",
                sourceLabel: "Shortcuts",
                auditSummary: "Listed \(shortcuts.count) voice shortcuts.",
                auditRedaction: Self.manifest.audit.resultSummaryPolicy.rawValue
            )
        } catch {
            return Self.errorResult("Unable to list voice shortcuts: \(error)")
        }
    }

    private static func shortcutJSONValue(_ shortcut: NativeVoiceShortcut) -> JSONValue {
        .object([
            "name": .string(shortcut.name),
            "phrase": .string(shortcut.phrase),
        ])
    }

    private static func errorResult(_ message: String) -> ToolResultDTO {
        NativeToolResultBuilder.error(
            manifestId: manifest.manifestId,
            toolName: "shortcuts.list_voice_shortcuts",
            toolCallId: "unknown",
            code: "shortcuts_list_failed",
            displayText: message,
            auditSummary: message,
            sensitivity: .private,
            retention: manifest.retention
        )
    }

    private static var manifest: NativeToolManifest {
        NativeToolManifest(
            manifestId: "native.shortcuts.list_voice_shortcuts.v1",
            capabilityId: "shortcuts.list_voice_shortcuts",
            title: "List Voice Shortcuts",
            description: "List local voice shortcuts.",
            mode: .systemActionAdapter,
            permissionScope: NativePermissionScope("shortcuts"),
            requiredPrivacyKeys: [],
            requiresForegroundUI: false,
            minimumOS: "iOS 17.0",
            regionPolicy: "available_with_service_fallback",
            fallback: NativeToolFallback(kind: .unavailable, message: "Shortcuts are unavailable."),
            riskLevel: .readOnly,
            approvalPolicy: .perCall,
            trustLevel: .trustedToolResult,
            retention: .session,
            audit: NativeToolAudit(label: "List Voice Shortcuts", resultSummaryPolicy: .metadataOnly)
        )
    }

    private static func makeSchema() -> NativeToolSchema {
        NativeToolSchema(
            name: "shortcuts.list_voice_shortcuts",
            description: manifest.description,
            inputSchema: .object(),
            riskLevel: manifest.riskLevel,
            permissionScope: manifest.permissionScope,
            availability: .available,
            manifest: manifest
        )
    }
}
