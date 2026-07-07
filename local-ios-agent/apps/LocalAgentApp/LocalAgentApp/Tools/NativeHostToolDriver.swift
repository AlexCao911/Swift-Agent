import Foundation
import LocalAgentBridge
import LocalNativeToolkit

protocol HostToolDriving: Sendable {
    func schemas() async -> [ToolSchemaDTO]
    func execute(_ request: ToolExecutionRequestDTO, continuationIndex: Int) async -> ToolResultDTO?
}

actor NativeHostToolDriver: HostToolDriving {
    private let toolkit: any NativeToolkitClientProtocol
    private let maxContinuations: Int
    private var completedToolCallIds: Set<String> = []

    init(toolkit: any NativeToolkitClientProtocol, maxContinuations: Int = 8) {
        self.toolkit = toolkit
        self.maxContinuations = maxContinuations
    }

    func schemas() async -> [ToolSchemaDTO] {
        await toolkit.registrationSnapshot().schemas
    }

    func execute(_ request: ToolExecutionRequestDTO, continuationIndex: Int) async -> ToolResultDTO? {
        guard continuationIndex < maxContinuations else {
            return NativeToolResultBuilder.error(
                manifestId: "native.host_tool_driver.v1",
                toolName: request.toolName,
                toolCallId: request.toolCallId,
                code: "continuation_limit_exceeded",
                displayText: "Tool stopped: continuation limit exceeded.",
                auditSummary: "Stopped \(request.toolName): continuation limit exceeded."
            )
        }

        guard completedToolCallIds.insert(request.toolCallId).inserted else {
            return nil
        }

        return await toolkit.execute(request)
    }
}
