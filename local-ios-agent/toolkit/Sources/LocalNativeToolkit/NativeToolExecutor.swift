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
                displayText: "Unknown native tool: \(request.toolName)",
                modelText: "Unknown native tool `\(request.toolName)`.",
                structuredJson: Self.errorPayload("unknown_tool", toolName: request.toolName),
                auditText: "Unknown native tool: \(request.toolName)"
            )
        }

        guard Self.argumentsAreJSONObject(request.argumentsJson) else {
            return Self.errorResult(
                displayText: "Invalid arguments for native tool: \(request.toolName)",
                modelText: "Invalid arguments for native tool `\(request.toolName)`: expected a JSON object.",
                structuredJson: Self.errorPayload("invalid_arguments", toolName: request.toolName),
                auditText: "Invalid arguments for native tool: \(request.toolName)"
            )
        }

        return await tool.execute(argumentsJson: request.argumentsJson)
    }

    private static func argumentsAreJSONObject(_ argumentsJson: String) -> Bool {
        guard let data = argumentsJson.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data)
        else {
            return false
        }

        return value is [String: Any]
    }

    private static func errorPayload(_ error: String, toolName: String) -> String {
        #"{"error":\#(jsonStringLiteral(error)),"tool_name":\#(jsonStringLiteral(toolName))}"#
    }

    private static func jsonStringLiteral(_ value: String) -> String {
        let data = try! JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private static func errorResult(
        displayText: String,
        modelText: String,
        structuredJson: String,
        auditText: String
    ) -> ToolResultDTO {
        ToolResultDTO(
            displayText: displayText,
            modelText: modelText,
            structuredJson: structuredJson,
            auditText: auditText,
            sensitivity: .public,
            retention: .runOnly,
            isError: true
        )
    }
}
