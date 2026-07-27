import LocalAgentBridge
import LocalAgentLLMCloud
import LocalAgentLLMCore
import LocalAgentLLMHost
import LocalAgentLLMLocal

enum AppLLMHostSelection: Sendable {
    case local(
        configuration: AgentHostConfiguration,
        target: LLMTargetRevision
    )
    case cloud(
        configuration: AgentHostConfiguration,
        target: LLMTargetRevision
    )
}

actor AppLLMHostSelectionRegistry {
    private struct Key: Hashable {
        let profileID: String
        let revision: UInt64
    }

    private var selections: [Key: AppLLMHostSelection] = [:]

    func register(
        _ selection: AppLLMHostSelection,
        profileID: String,
        revision: UInt64
    ) {
        selections[Key(profileID: profileID, revision: revision)] = selection
    }

    func selection(profileID: String, revision: UInt64) -> AppLLMHostSelection? {
        selections[Key(profileID: profileID, revision: revision)]
    }
}

protocol AppLLMHostExecuting: Sendable {
    func startLocal(
        _ request: StartExecutionRequestDTO,
        subsystem: LocalLLMSubsystem,
        configuration: AgentHostConfiguration,
        target: LLMTargetRevision
    ) async throws -> RunHandleDTO

    func startCloud(
        _ request: StartExecutionRequestDTO,
        subsystem: CloudLLMSubsystem,
        configuration: AgentHostConfiguration,
        target: LLMTargetRevision
    ) async throws -> RunHandleDTO
}

extension LLMHostProductRuntime: AppLLMHostExecuting {}

actor AppHostRunStarter: LLMProductRunStarting {
    private let selections: AppLLMHostSelectionRegistry
    private var composition: (
        host: any AppLLMHostExecuting,
        local: LocalLLMSubsystem,
        cloud: CloudLLMSubsystem
    )?

    init(selections: AppLLMHostSelectionRegistry) {
        self.selections = selections
    }

    func install(
        host: any AppLLMHostExecuting,
        local: LocalLLMSubsystem,
        cloud: CloudLLMSubsystem
    ) {
        composition = (host, local, cloud)
    }

    func startRun(_ request: StartExecutionRequestDTO) async throws -> RunHandleDTO {
        guard let composition else {
            throw LLMHostFailure(
                code: "execution.host_runtime_unavailable",
                message: "Swift LLM host composition is not installed"
            )
        }
        guard let selection = await selections.selection(
            profileID: request.agentProfileId,
            revision: request.profileRevisionId
        ) else {
            throw LLMHostFailure(
                code: "execution.host_binding_not_configured",
                message: "no exact Swift host binding is active for this profile revision"
            )
        }
        switch selection {
        case .local(let configuration, let target):
            return try await composition.host.startLocal(
                request,
                subsystem: composition.local,
                configuration: configuration,
                target: target
            )
        case .cloud(let configuration, let target):
            return try await composition.host.startCloud(
                request,
                subsystem: composition.cloud,
                configuration: configuration,
                target: target
            )
        }
    }
}
