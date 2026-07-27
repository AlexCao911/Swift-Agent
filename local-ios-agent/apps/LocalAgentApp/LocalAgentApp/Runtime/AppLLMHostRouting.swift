import LocalAgentBridge
import LocalAgentLLMCloud
import LocalAgentLLMCore
import LocalAgentLLMHost
import LocalAgentLLMLocal

enum AppLLMHostSelection: Sendable {
    case local(
        configuration: AgentHostConfiguration,
        target: LLMTargetRevision,
        binding: HostBindingTuple
    )
    case cloud(
        configuration: AgentHostConfiguration,
        target: LLMTargetRevision,
        binding: HostBindingTuple
    )

    var binding: HostBindingTuple {
        switch self {
        case let .local(_, _, binding), let .cloud(_, _, binding):
            binding
        }
    }
}

actor AppLLMHostSelectionRegistry {
    private struct Key: Hashable {
        let profileID: String
        let revision: UInt64
    }

    private var selections: [Key: AppLLMHostSelection] = [:]

    var count: Int {
        selections.count
    }

    var only: AppLLMHostSelection? {
        selections.count == 1 ? selections.values.first : nil
    }

    func hydrate(
        bindings: [ActiveAgentHostBinding],
        targets: [LLMTargetRevision],
        available: [AgentLLMTargetOption]
    ) -> [String] {
        var next: [Key: AppLLMHostSelection] = [:]
        var issues: [String] = []
        for active in bindings {
            let configuration = active.configuration
            let key = Key(
                profileID: configuration.agentProfileID,
                revision: configuration.agentProfileRevision
            )
            guard active.binding.bindingID == configuration.bindingID,
                  active.binding.bindingRevision == configuration.revision,
                  let target = targets.first(where: {
                      $0.reference == configuration.selectedTarget
                  }),
                  let option = available.first(where: {
                      $0.target == target
                  }),
                  next[key] == nil
            else {
                next.removeValue(forKey: key)
                issues.append("execution.host_binding_not_configured")
                continue
            }
            guard (try? LLMParameterSystem.resolve(
                targetDefaults: target.defaultParameters,
                hostOverrides: configuration.parameterOverrides,
                schema: option.parameterSchema
            )) == configuration.parameterOverrides else {
                issues.append("execution.host_binding_not_configured")
                continue
            }
            switch target.kind {
            case .local:
                next[key] = .local(
                    configuration: configuration,
                    target: target,
                    binding: active.binding
                )
            case .cloud:
                next[key] = .cloud(
                    configuration: configuration,
                    target: target,
                    binding: active.binding
                )
            }
        }
        selections = next
        return Array(Set(issues)).sorted()
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

    var canStart: Bool {
        composition != nil
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
        case .local(let configuration, let target, _):
            return try await composition.host.startLocal(
                request,
                subsystem: composition.local,
                configuration: configuration,
                target: target
            )
        case .cloud(let configuration, let target, _):
            return try await composition.host.startCloud(
                request,
                subsystem: composition.cloud,
                configuration: configuration,
                target: target
            )
        }
    }
}
