import LocalAgentLLMContracts

package struct ToolBatchCommandHandler: Sendable {
    private let executor: any ToolBatchExecuting

    package init(executor: any ToolBatchExecuting) {
        self.executor = executor
    }

    package func execute(
        _ batch: HostToolBatch,
        generationTurnID: String? = nil,
        sequencer: LLMEventSequencer
    ) async {
        do {
            _ = try await sequencer.submit(
                kind: .toolBatchStarted,
                payload: LLMEventPayload(),
                generationTurnID: generationTurnID
            )
            let completion = await executor.execute(batch)
            guard completion.batchID == batch.batchID,
                  completion.runID == batch.runID
            else {
                _ = try await sequencer.submit(
                    kind: .toolBatchFailed,
                    payload: LLMEventPayload(
                        failureCode: "llm.tool_batch.identity_mismatch"
                    ),
                    generationTurnID: generationTurnID
                )
                return
            }
            let payload = LLMEventPayload(toolBatchCompletion: completion)
            try payload.validate(
                for: .toolBatchCompleted,
                envelopeRunID: batch.runID,
                expectedBatchID: batch.batchID
            )
            _ = try await sequencer.submit(
                kind: .toolBatchCompleted,
                payload: payload,
                generationTurnID: generationTurnID
            )
        } catch {
            _ = try? await sequencer.submit(
                kind: .toolBatchFailed,
                payload: LLMEventPayload(
                    failureCode: "llm.tool_batch.execution_failed"
                ),
                generationTurnID: generationTurnID
            )
        }
    }

    package func cancel(batchID: String) async {
        await executor.cancel(batchID: batchID)
    }
}
