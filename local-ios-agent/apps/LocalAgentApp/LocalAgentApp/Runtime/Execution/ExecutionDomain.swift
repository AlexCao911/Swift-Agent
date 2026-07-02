import LocalAgentBridge

protocol ExecutionDomain: Sendable {
    func listAgentProfiles() async throws -> [AgentProfileDTO]
    func buildAgent(templateId: String) async throws -> AgentProfileDTO
    func startRun(_ request: StartExecutionRequestDTO) async throws -> RunHandleDTO
    func observeEvents(runId: String, fromSequence: UInt64) -> AsyncThrowingStream<RuntimeEventDTO, Error>
    func approveTool(id: String, decision: ApprovalDecisionDTO) async throws
    func cancelRun(runId: String) async throws -> RuntimeEventDTO
    func loadDebugArchive(_ runId: String) async throws -> RunDebugUIModel
    func updateRuntimeOptions(_ options: RuntimeOptionsDTO) async throws
}
