import Foundation
import LocalAgentBridge
import LocalNativeToolkit

struct NativeToolkitRegistrationSnapshot: Equatable, Sendable {
    var schemas: [ToolSchemaDTO]
    var toolNames: [String]
}

protocol NativeToolkitClientProtocol: Sendable {
    func registrationSnapshot() async -> NativeToolkitRegistrationSnapshot
    func execute(_ request: ToolExecutionRequestDTO) async -> ToolResultDTO
}

actor NativeToolkitClient: NativeToolkitClientProtocol {
    private let catalog: NativeToolCatalog
    private let executor: NativeToolExecutor

    init(catalog: NativeToolCatalog) {
        self.catalog = catalog
        self.executor = NativeToolExecutor(catalog: catalog)
    }

    func registrationSnapshot() async -> NativeToolkitRegistrationSnapshot {
        let schemas = exportedSchemas()
        return NativeToolkitRegistrationSnapshot(
            schemas: schemas,
            toolNames: schemas.map(\.name)
        )
    }

    func execute(_ request: ToolExecutionRequestDTO) async -> ToolResultDTO {
        let exportedToolNames = Set(exportedSchemas().map(\.name))
        guard exportedToolNames.contains(request.toolName) else {
            return NativeToolResultBuilder.error(
                manifestId: "native.toolkit.client.v1",
                toolName: request.toolName,
                toolCallId: request.toolCallId,
                code: "native_tool_unavailable",
                displayText: "Native tool is not available.",
                auditSummary: "Rejected unavailable native tool: \(request.toolName)"
            )
        }

        return await executor.execute(request)
    }

    private func exportedSchemas() -> [ToolSchemaDTO] {
        catalog.schemas
            .compactMap { NativeToolSchemaExport.export($0) }
            .sorted { $0.name < $1.name }
    }
}
