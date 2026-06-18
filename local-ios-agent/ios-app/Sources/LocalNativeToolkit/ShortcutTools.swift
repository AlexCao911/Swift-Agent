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
    public let schema = NativeToolSchema(
        name: "shortcuts.list_voice_shortcuts",
        description: "List local voice shortcuts.",
        inputSchema: .object(),
        riskLevel: .readOnly,
        permissionScope: NativePermissionScope("shortcuts"),
        availability: .available
    )

    private let shortcuts: any ShortcutsFacade

    public init(shortcuts: any ShortcutsFacade) {
        self.shortcuts = shortcuts
    }

    public func execute(argumentsJson: String) async -> ToolResultDTO {
        do {
            let shortcuts = try await shortcuts.listVoiceShortcuts()
            let structuredJson = Self.encode(NativeVoiceShortcutsPayload(shortcuts: shortcuts))

            return ToolResultDTO(
                displayText: "\(shortcuts.count) voice shortcuts found.",
                modelText: structuredJson,
                structuredJson: structuredJson,
                auditText: "Listed \(shortcuts.count) voice shortcuts.",
                sensitivity: .private,
                retention: .session,
                isError: false
            )
        } catch {
            return Self.errorResult("Unable to list voice shortcuts: \(error)")
        }
    }

    private static func encode<T: Encodable>(_ value: T) -> String {
        let data = try! JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private static func errorResult(_ message: String) -> ToolResultDTO {
        ToolResultDTO(
            displayText: message,
            modelText: message,
            structuredJson: #"{"error":"shortcuts_list_failed"}"#,
            auditText: message,
            sensitivity: .private,
            retention: .session,
            isError: true
        )
    }
}

private struct NativeVoiceShortcutsPayload: Encodable {
    var shortcuts: [NativeVoiceShortcut]
}
