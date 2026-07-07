import Foundation
import LocalAgentBridge

actor MinimalHostToolDriver: HostToolDriving {
    nonisolated static let debugEchoSchema = ToolSchemaDTO(
        name: "debug.echo",
        description: "Echo text back to the model.",
        parametersJsonSchema: #"{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}"#,
        riskLevel: .readOnly
    )

    private let maxContinuations: Int
    private var completedToolCallIds: Set<String> = []

    init(maxContinuations: Int = 4) {
        self.maxContinuations = maxContinuations
    }

    nonisolated var schema: ToolSchemaDTO {
        Self.debugEchoSchema
    }

    func schemas() async -> [ToolSchemaDTO] {
        [schema]
    }

    func execute(_ request: ToolExecutionRequestDTO, continuationIndex: Int) async -> ToolResultDTO? {
        guard continuationIndex < maxContinuations else {
            return errorResult(
                displayText: "Tool stopped: continuation limit exceeded.",
                modelText: "\(request.toolName) stopped: continuation limit exceeded.",
                structuredJson: errorPayload("continuation_limit_exceeded", toolName: request.toolName),
                auditText: "Stopped \(request.toolName): continuation limit exceeded."
            )
        }
        guard request.toolName == Self.debugEchoSchema.name else {
            return errorResult(
                displayText: "Unsupported tool: \(request.toolName)",
                modelText: "Unsupported tool `\(request.toolName)`.",
                structuredJson: errorPayload("unsupported_tool", toolName: request.toolName),
                auditText: "Unsupported tool: \(request.toolName)"
            )
        }
        guard completedToolCallIds.insert(request.toolCallId).inserted else {
            return nil
        }

        let text = Self.argumentText(from: request.argumentsJson) ?? ""
        let structuredJson = Self.encode(["text": text])
        return ToolResultDTO(
            displayText: "Echo: \(text)",
            modelText: "debug.echo: \(text)",
            structuredJson: structuredJson,
            auditText: "debug.echo executed",
            sensitivity: .public,
            retention: .runOnly,
            isError: false
        )
    }

    private func errorResult(
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

    private func errorPayload(_ error: String, toolName: String) -> String {
        Self.encode(["error": error, "tool_name": toolName])
    }

    private static func argumentText(from argumentsJson: String) -> String? {
        guard let data = argumentsJson.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object["text"] as? String
    }

    private static func encode(_ object: [String: String]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object.sortedDictionary())
        return String(decoding: data, as: UTF8.self)
    }
}

private extension Dictionary where Key == String, Value == String {
    func sortedDictionary() -> [String: String] {
        keys.sorted().reduce(into: [String: String]()) { result, key in
            result[key] = self[key]
        }
    }
}
