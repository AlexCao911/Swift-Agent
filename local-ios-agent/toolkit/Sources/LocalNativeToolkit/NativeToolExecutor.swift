import Foundation
import LocalAgentBridge

public struct NativeToolExecutor: Sendable {
    private let catalog: NativeToolCatalog

    public init(catalog: NativeToolCatalog) {
        self.catalog = catalog
    }

    public func execute(_ request: ToolExecutionRequestDTO) async -> ToolResultDTO {
        guard let tool = catalog.tools.first(where: { $0.schema.name == request.toolName }) else {
            return Self.errorResult(
                code: "unknown_tool",
                toolName: request.toolName,
                toolCallId: request.toolCallId,
                displayText: "Unknown native tool: \(request.toolName)",
                auditText: "Unknown native tool: \(request.toolName)"
            )
        }

        guard Self.argumentsAreJSONObject(request.argumentsJson) else {
            return Self.errorResult(
                code: "invalid_arguments",
                toolName: request.toolName,
                toolCallId: request.toolCallId,
                displayText: "Invalid arguments for native tool: \(request.toolName)",
                auditText: "Invalid arguments for native tool: \(request.toolName)"
            )
        }

        let result = await tool.execute(argumentsJson: request.argumentsJson)
        return NativeToolResultEnvelopeValidator.replacingToolCallId(
            result,
            with: request.toolCallId
        )
    }

    private static func argumentsAreJSONObject(_ argumentsJson: String) -> Bool {
        guard let data = argumentsJson.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data)
        else {
            return false
        }

        return value is [String: Any]
    }

    private static func errorResult(
        code: String,
        toolName: String,
        toolCallId: String,
        displayText: String,
        auditText: String
    ) -> ToolResultDTO {
        NativeToolResultBuilder.error(
            manifestId: "native.executor.v1",
            toolName: toolName,
            toolCallId: toolCallId,
            code: code,
            displayText: displayText,
            auditSummary: auditText
        )
    }
}
