public protocol ExecutionBridgeClient: Sendable {
    func listAgentProfiles() async throws -> [AgentProfileDTO]
    func buildAgent(templateId: String) async throws -> AgentProfileDTO
    func startRun(_ request: StartExecutionRequestDTO) async throws -> RunHandleDTO
    func observeEvents(runId: String, fromSequence: UInt64) -> AsyncThrowingStream<RuntimeEventDTO, Error>
    func approveTool(id: String, decision: ApprovalDecisionDTO) async throws
    func submitToolResult(runId: String, result: ToolResultDTO) async throws -> AgentTurnResultDTO
    func cancelRun(runId: String) async throws -> RuntimeEventDTO
    func loadDebugArchive(_ runId: String) async throws -> RunDebugUIModel
    func updateRuntimeOptions(_ options: RuntimeOptionsDTO) async throws
}

public struct RustExecutionBridgeClient: ExecutionBridgeClient {
    private let gateway: any RustAgentOSBridgeGateway
    private let legacyClient: any RuntimeClient

    public init(
        gateway: any RustAgentOSBridgeGateway,
        legacyClient: any RuntimeClient
    ) {
        self.gateway = gateway
        self.legacyClient = legacyClient
    }

    public func listAgentProfiles() async throws -> [AgentProfileDTO] {
        try await gateway.request(
            .listAgentProfiles,
            EmptyAgentOSRequestDTO(),
            as: [AgentProfileDTO].self
        )
    }

    public func buildAgent(templateId: String) async throws -> AgentProfileDTO {
        try await gateway.request(
            .buildAgent,
            BuildAgentRequestDTO(templateId: templateId),
            as: AgentProfileDTO.self
        )
    }

    public func startRun(_ request: StartExecutionRequestDTO) async throws -> RunHandleDTO {
        try await gateway.request(.startRun, request, as: RunHandleDTO.self)
    }

    public func observeEvents(runId: String, fromSequence: UInt64) -> AsyncThrowingStream<RuntimeEventDTO, Error> {
        gateway.stream(
            .observeEvents,
            ObserveExecutionEventsRequestDTO(runId: runId, fromSequence: fromSequence)
        )
    }

    public func approveTool(id: String, decision: ApprovalDecisionDTO) async throws {
        _ = try await gateway.request(
            .approveTool,
            ApproveToolRequestDTO(id: id, decision: decision),
            as: EmptyAgentOSResponseDTO.self
        )
    }

    public func submitToolResult(runId: String, result: ToolResultDTO) async throws -> AgentTurnResultDTO {
        try await gateway.request(
            .submitToolResult,
            SubmitToolResultRequestDTO(runId: runId, result: result),
            as: AgentTurnResultDTO.self
        )
    }

    public func cancelRun(runId: String) async throws -> RuntimeEventDTO {
        try await gateway.request(
            .cancelRun,
            CancelRunRequestDTO(runId: runId),
            as: RuntimeEventDTO.self
        )
    }

    public func loadDebugArchive(_ runId: String) async throws -> RunDebugUIModel {
        try await legacyClient.loadDebugArchive(runId)
    }

    public func updateRuntimeOptions(_ options: RuntimeOptionsDTO) async throws {
        _ = try await gateway.request(
            .updateRuntimeOptions,
            options,
            as: EmptyAgentOSResponseDTO.self
        )
    }
}
