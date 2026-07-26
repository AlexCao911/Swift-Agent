import Foundation
import LocalAgentBridge
import LocalAgentLLMHost
import LocalNativeToolkit

protocol HostToolDriving: Sendable {
    func schemas() async -> [ToolSchemaDTO]
    func execute(_ request: ToolExecutionRequestDTO, continuationIndex: Int) async -> ToolResultDTO?
}

actor NativeHostToolDriver: HostToolDriving {
    private let toolkit: any NativeToolkitClientProtocol
    private let effectLedger: HostToolEffectLedger
    private let maxContinuations: Int

    init(
        toolkit: any NativeToolkitClientProtocol,
        effectLedger: HostToolEffectLedger? = nil,
        maxContinuations: Int = 8
    ) {
        self.toolkit = toolkit
        self.effectLedger = effectLedger
            ?? (try! HostToolEffectLedger(fileURL: nil))
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

        let preparation: HostToolEffectPreparation
        do {
            preparation = try await effectLedger.prepare(
                request,
                generationTurnID: request.toolCallEntryId
            )
        } catch {
            return NativeToolResultBuilder.error(
                manifestId: "native.host_tool_driver.v1",
                toolName: request.toolName,
                toolCallId: request.toolCallId,
                code: "tool_effect_outcome_unknown",
                displayText: "Tool result needs review before it can be retried.",
                auditSummary: "Blocked duplicate effect for \(request.toolName)."
            )
        }
        if let replay = preparation.replayResult { return replay }

        let result = await toolkit.execute(request)
        do {
            try await effectLedger.commit(preparation, result: result)
            return result
        } catch {
            return NativeToolResultBuilder.error(
                manifestId: "native.host_tool_driver.v1",
                toolName: request.toolName,
                toolCallId: request.toolCallId,
                code: "tool_effect_commit_failed",
                displayText: "Tool completed, but its durable result could not be saved.",
                auditSummary: "Failed to commit effect result for \(request.toolName)."
            )
        }
    }
}
