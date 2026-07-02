import LocalAgentBridge

struct ExecutionDomainAdapter: ExecutionDomain {
    private let profiles: AgentProfileService
    private let composition: AgentCompositionService
    private let lifecycle: RunLifecycleService
    private let events: RunEventStreamService
    private let tools: ToolApprovalService
    private let debug: RunDebugService
    private let inference: InferenceSettingsService

    init(
        profiles: AgentProfileService,
        composition: AgentCompositionService,
        lifecycle: RunLifecycleService,
        events: RunEventStreamService,
        tools: ToolApprovalService,
        debug: RunDebugService,
        inference: InferenceSettingsService
    ) {
        self.profiles = profiles
        self.composition = composition
        self.lifecycle = lifecycle
        self.events = events
        self.tools = tools
        self.debug = debug
        self.inference = inference
    }

    func listAgentProfiles() async throws -> [AgentProfileDTO] {
        try await profiles.listAgentProfiles()
    }

    func buildAgent(templateId: String) async throws -> AgentProfileDTO {
        try await composition.buildAgent(templateId: templateId)
    }

    func startRun(_ request: StartExecutionRequestDTO) async throws -> RunHandleDTO {
        try await lifecycle.startRun(request)
    }

    func observeEvents(runId: String, fromSequence: UInt64) -> AsyncThrowingStream<RuntimeEventDTO, Error> {
        events.observeEvents(runId: runId, fromSequence: fromSequence)
    }

    func approveTool(id: String, decision: ApprovalDecisionDTO) async throws {
        try await tools.approveTool(id: id, decision: decision)
    }

    func cancelRun(runId: String) async throws -> RuntimeEventDTO {
        try await lifecycle.cancelRun(runId: runId)
    }

    func loadDebugArchive(_ runId: String) async throws -> RunDebugUIModel {
        try await debug.loadDebugArchive(runId)
    }

    func updateRuntimeOptions(_ options: RuntimeOptionsDTO) async throws {
        try await inference.updateRuntimeOptions(options)
    }
}
