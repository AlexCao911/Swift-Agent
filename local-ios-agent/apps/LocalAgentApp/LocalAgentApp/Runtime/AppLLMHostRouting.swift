import Foundation
import LocalAgentBridge
import LocalAgentLLMCloud
import LocalAgentLLMContracts
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

    private var selections: [Key: [AppLLMHostSelection]] = [:]

    var count: Int {
        selections.count
    }

    var only: AppLLMHostSelection? {
        selections.count == 1 ? selections.values.first?.first : nil
    }

    func hydrate(
        bindings: [ActiveAgentHostBinding],
        targets: [LLMTargetRevision],
        available: [AgentLLMTargetOption]
    ) -> [String] {
        var next: [Key: [AppLLMHostSelection]] = [:]
        var invalidKeys: Set<Key> = []
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
                  })
            else {
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
            let selection: AppLLMHostSelection
            switch target.kind {
            case .local:
                selection = .local(
                    configuration: configuration,
                    target: target,
                    binding: active.binding
                )
            case .cloud:
                selection = .cloud(
                    configuration: configuration,
                    target: target,
                    binding: active.binding
                )
            }
            if invalidKeys.contains(key) {
                continue
            }
            if let first = next[key]?.first,
               first.configuration.llmSlotID != configuration.llmSlotID
                || first.configuration.requirementsHash
                    != configuration.requirementsHash {
                next.removeValue(forKey: key)
                invalidKeys.insert(key)
                issues.append("execution.host_binding_not_configured")
                continue
            }
            next[key, default: []].append(selection)
        }
        for (key, group) in Array(next) where group.count > 1 {
            let normalizedGroupIDs = group.compactMap {
                $0.configuration.fallbackGroupID?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            }
            let groupIDs = Set(normalizedGroupIDs)
            let priorities = group.compactMap {
                $0.configuration.fallbackPriority
            }
            guard normalizedGroupIDs.count == group.count,
                  groupIDs.count == 1,
                  groupIDs.first?.isEmpty == false,
                  priorities.count == group.count,
                  Set(priorities).count == group.count
            else {
                next.removeValue(forKey: key)
                issues.append("execution.host_fallback_order_not_configured")
                continue
            }
            next[key] = group.sorted { left, right in
                guard let leftPriority = left.configuration.fallbackPriority,
                      let rightPriority = right.configuration.fallbackPriority
                else {
                    return false
                }
                return leftPriority < rightPriority
            }
        }
        selections = next
        return Array(Set(issues)).sorted()
    }

    func selection(profileID: String, revision: UInt64) -> AppLLMHostSelection? {
        selections[Key(profileID: profileID, revision: revision)]?.first
    }

    func selectionGroup(
        profileID: String,
        revision: UInt64
    ) -> [AppLLMHostSelection]? {
        selections[Key(profileID: profileID, revision: revision)]
    }

    func installGroup(
        bindings: [ActiveAgentHostBinding],
        targets: [LLMTargetRevision],
        available: [AgentLLMTargetOption]
    ) -> [String] {
        guard let configuration = bindings.first?.configuration else {
            return ["execution.host_binding_not_configured"]
        }
        let key = Key(
            profileID: configuration.agentProfileID,
            revision: configuration.agentProfileRevision
        )
        let previous = selections
        let issues = hydrate(
            bindings: bindings,
            targets: targets,
            available: available
        )
        let installed = selections[key]
        selections = previous
        if issues.isEmpty, let installed {
            selections[key] = installed
            return []
        }
        return issues.isEmpty
            ? ["execution.host_binding_not_configured"]
            : issues
    }

    func validateGroup(
        bindings: [ActiveAgentHostBinding],
        targets: [LLMTargetRevision],
        available: [AgentLLMTargetOption]
    ) -> [String] {
        let previous = selections
        let issues = hydrate(
            bindings: bindings,
            targets: targets,
            available: available
        )
        selections = previous
        return issues
    }
}

extension AppLLMHostSelection {
    var configuration: AgentHostConfiguration {
        switch self {
        case let .local(configuration, _, _),
             let .cloud(configuration, _, _):
            configuration
        }
    }

    var target: LLMTargetRevision {
        switch self {
        case let .local(_, target, _), let .cloud(_, target, _):
            target
        }
    }
}

protocol ActiveProfileBindingRebinding: Sendable {
    func prepare(
        _ request: ProfilePublishPreparationDTO
    ) async throws -> HostBindingOperationDTO
    func commit(
        _ request: HostBindingCommitDTO
    ) async throws -> HostBindingCrossLinkDTO
    func confirm(
        _ request: HostBindingActivationConfirmationDTO
    ) async throws -> HostBindingCrossLinkDTO
}

struct PortableActiveProfileBindingRebinder:
    ActiveProfileBindingRebinding,
    Sendable
{
    let client: any PortableAgentBuilderClient

    func prepare(
        _ request: ProfilePublishPreparationDTO
    ) async throws -> HostBindingOperationDTO {
        try await client.prepareProfileRebind(request)
    }

    func commit(
        _ request: HostBindingCommitDTO
    ) async throws -> HostBindingCrossLinkDTO {
        try await client.commitProfileRebind(request)
    }

    func confirm(
        _ request: HostBindingActivationConfirmationDTO
    ) async throws -> HostBindingCrossLinkDTO {
        try await client.confirmHostBindingActivation(request)
    }
}

actor ActiveAgentModelSelectionService {
    private let store: LLMStore
    private let registry: AppLLMHostSelectionRegistry
    private let rust: any ActiveProfileBindingRebinding

    init(
        store: LLMStore,
        registry: AppLLMHostSelectionRegistry,
        rust: any ActiveProfileBindingRebinding
    ) {
        self.store = store
        self.registry = registry
        self.rust = rust
    }

    func activate(
        target: LLMTargetRevision,
        profileID: String,
        profileRevision: UInt64,
        available: [AgentLLMTargetOption]
    ) async throws {
        guard let selectedOption = available.first(where: {
            $0.target == target
        }) else {
            throw routingFailure(
                "execution.target_unavailable",
                "the selected immutable target is not executable"
            )
        }
        guard let current = await registry.selectionGroup(
            profileID: profileID,
            revision: profileRevision
        ), let primary = current.first else {
            throw routingFailure(
                "execution.host_binding_not_configured",
                "the active Agent has no exact model binding to override"
            )
        }
        let orderedOptions = [
            selectedOption,
        ] + current.compactMap { selection in
            guard selection.target.reference != target.reference else {
                return nil
            }
            return available.first { $0.target == selection.target }
        }
        let groupID = "session.\(profileID).\(profileRevision).\(UUID().uuidString.lowercased())"
        let operation = try await rust.prepare(ProfilePublishPreparationDTO(
            idempotencyKey: groupID,
            agentProfileId: profileID,
            agentProfileRevision: profileRevision,
            llmSlotId: primary.configuration.llmSlotID,
            requirementsHash: primary.configuration.requirementsHash
        ))
        let saga = AgentHostBindingSaga(store: store)
        var replacements: [ActiveAgentHostBinding] = []
        var primaryStagingReceipt: HostBindingStagingReceipt?
        for (index, option) in orderedOptions.enumerated() {
            let operationToken = index == 0
                ? operation.token
                : "\(operation.token).fallback.\(index)"
            let tokenDigest = index == 0
                ? operation.tokenDigest
                : try fallbackTokenDigest(
                    primaryTokenDigest: operation.tokenDigest,
                    priority: UInt64(index)
                )
            let configuration = AgentHostConfiguration(
                bindingID: "binding.\(groupID).\(index)",
                revision: 1,
                agentProfileID: profileID,
                agentProfileRevision: profileRevision,
                llmSlotID: primary.configuration.llmSlotID,
                requirementsHash: primary.configuration.requirementsHash,
                llmTargetID: option.target.targetID,
                llmTargetRevision: option.target.revision,
                fallbackGroupID: groupID,
                fallbackPriority: UInt64(index),
                parameterOverrides: current.first {
                    $0.target.reference == option.target.reference
                }?.configuration.parameterOverrides ?? GenerationConfiguration()
            )
            let receipt = try await saga.stageHostBinding(
                HostBindingStageRequest(
                    operationToken: operationToken,
                    tokenDigest: tokenDigest,
                    llmSlotID: configuration.llmSlotID,
                    requirementsHash: configuration.requirementsHash,
                    configuration: configuration
                )
            )
            if index == 0 {
                primaryStagingReceipt = receipt
            }
            replacements.append(ActiveAgentHostBinding(
                configuration: configuration,
                binding: receipt.binding
            ))
        }
        let issues = await registry.validateGroup(
            bindings: replacements,
            targets: orderedOptions.map(\.target),
            available: orderedOptions
        )
        guard issues.isEmpty else {
            throw routingFailure(
                "execution.host_binding_not_configured",
                issues.joined(separator: ", ")
            )
        }
        guard let primaryReplacement = replacements.first,
              let primaryReceipt = primaryStagingReceipt
        else {
            throw routingFailure(
                "execution.host_binding_not_configured",
                "the replacement binding group is empty"
            )
        }
        let primaryBinding = HostBindingTupleDTO(
            bindingId: primaryReplacement.binding.bindingID,
            bindingRevision: primaryReplacement.binding.bindingRevision,
            bindingHash: primaryReplacement.binding.bindingHash
        )
        let expectedActive = current.map {
            ActiveAgentHostBinding(
                configuration: $0.configuration,
                binding: $0.binding
            )
        }
        let durable = ModelRebindOperation(
            operationID: groupID,
            profileID: profileID,
            profileRevision: profileRevision,
            llmSlotID: primary.configuration.llmSlotID,
            requirementsHash: primary.configuration.requirementsHash,
            primaryBinding: primaryReplacement.binding,
            stagingReceiptDigest: primaryReceipt.receiptDigest,
            expectedActive: expectedActive,
            replacements: replacements
        )
        try await store.beginModelRebindOperation(durable)
        do {
            _ = try await rust.commit(HostBindingCommitDTO(
                token: operation.token,
                binding: primaryBinding,
                receipt: HostBindingStagingReceiptDTO(
                    tokenDigest: primaryReceipt.tokenDigest,
                    llmSlotId: primaryReceipt.llmSlotID,
                    requirementsHash: primaryReceipt.requirementsHash,
                    binding: primaryBinding,
                    receiptDigest: primaryReceipt.receiptDigest
                )
            ))
        } catch {
            try? await store.discardPreparedModelRebindOperation(operationID: groupID)
            throw error
        }
        try await resume(durable, available: available)
    }

    /// Replays from a persisted receipt after a process interruption.  Confirmation
    /// is idempotent in Rust, so a crash after commit but before the phase write is
    /// safe to resume without retaining the bearer token that authorized commit.
    func reconcilePending(available: [AgentLLMTargetOption]) async throws {
        for operation in await store.pendingModelRebindOperations() {
            try await resume(operation, available: available)
        }
    }

    private func resume(
        _ initial: ModelRebindOperation,
        available: [AgentLLMTargetOption]
    ) async throws {
        var operation = initial
        let primary = HostBindingTupleDTO(
            bindingId: operation.primaryBinding.bindingID,
            bindingRevision: operation.primaryBinding.bindingRevision,
            bindingHash: operation.primaryBinding.bindingHash
        )
        if operation.phase == .prepared {
            let confirmed = try await rust.confirm(
                HostBindingActivationConfirmationDTO(
                    agentProfileId: operation.profileID,
                    agentProfileRevision: operation.profileRevision,
                    llmSlotId: operation.llmSlotID,
                    requirementsHash: operation.requirementsHash,
                    binding: primary,
                    stagingReceiptDigest: operation.stagingReceiptDigest
                )
            )
            guard confirmed.state == "active",
                  confirmed.kind == "profile_rebind",
                  confirmed.binding == primary
            else {
                throw routingFailure(
                    "execution.host_binding_not_configured",
                    "Rust did not confirm the exact replacement binding"
                )
            }
            try await store.advanceModelRebindOperation(
                operationID: operation.operationID,
                from: .prepared,
                to: .rustConfirmed
            )
            operation.phase = .rustConfirmed
        }
        if operation.phase == .rustConfirmed {
            let active = try await store.activeHostBindings().filter {
                $0.configuration.agentProfileID == operation.profileID
                    && $0.configuration.agentProfileRevision == operation.profileRevision
            }
            let activeIDs = active.map(\.binding.bindingID).sorted()
            let replacementIDs = operation.replacements.map(\.binding.bindingID).sorted()
            if activeIDs != replacementIDs {
                try await store.swapActiveHostBindingGroup(
                    expectedActive: operation.expectedActive,
                    replacements: operation.replacements
                )
            }
            try await store.advanceModelRebindOperation(
                operationID: operation.operationID,
                from: .rustConfirmed,
                to: .swiftSwapped
            )
            operation.phase = .swiftSwapped
        }
        if operation.phase == .swiftSwapped {
            let targets = await store.targets()
            let targetGroup = operation.replacements.compactMap { binding in
                targets.first { $0.reference == binding.targetReference }
            }
            guard targetGroup.count == operation.replacements.count else {
                throw routingFailure(
                    "execution.host_binding_not_configured",
                    "a rebound target is no longer available"
                )
            }
            let issues = await registry.installGroup(
                bindings: operation.replacements,
                targets: targetGroup,
                available: available
            )
            guard issues.isEmpty else {
                throw routingFailure(
                    "execution.host_binding_not_configured",
                    issues.joined(separator: ", ")
                )
            }
            try await store.advanceModelRebindOperation(
                operationID: operation.operationID,
                from: .swiftSwapped,
                to: .completed
            )
        }
    }

    private func fallbackTokenDigest(
        primaryTokenDigest: String,
        priority: UInt64
    ) throws -> String {
        try CanonicalDigestV1.digest(
            domain: "saga-token:v1",
            document: .object(entries: [
                .init(
                    name: "primary_token_digest",
                    value: .string(primaryTokenDigest)
                ),
                .init(
                    name: "fallback_priority",
                    value: .string(String(priority))
                ),
            ])
        ).hex
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
        guard let selection = await selections.selection(
            profileID: request.agentProfileId,
            revision: request.profileRevisionId
        ) else {
            throw LLMHostFailure(
                code: "execution.host_binding_not_configured",
                message: "no exact Swift host binding is active for this profile revision"
            )
        }
        guard let composition else {
            throw LLMHostFailure(
                code: "execution.host_runtime_unavailable",
                message: "Swift LLM host composition is not installed"
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

extension RustReActModelRoute: ProviderCandidateModelRoute {}

@MainActor
final class AppRustAgentModelRunPreparer: RustAgentModelRunPreparing {
    private let selections: AppLLMHostSelectionRegistry
    private let local: LocalLLMSubsystem
    private let cloud: CloudLLMSubsystem
    private let registry: OpenMinisModelExecutionRegistry
    private let attachmentResolver: any RustReActAttachmentResolving

    init(
        selections: AppLLMHostSelectionRegistry,
        local: LocalLLMSubsystem,
        cloud: CloudLLMSubsystem,
        registry: OpenMinisModelExecutionRegistry,
        attachmentResolver: any RustReActAttachmentResolving =
            EmptyRustReActAttachmentResolver()
    ) {
        self.selections = selections
        self.local = local
        self.cloud = cloud
        self.registry = registry
        self.attachmentResolver = attachmentResolver
    }

    func modelContextWindow(
        agentProfileID: String,
        agentProfileRevisionID: UInt64
    ) async throws -> ModelContextWindowDTO {
        let group = try await requireSelectionGroup(
            profileID: agentProfileID,
            revision: agentProfileRevisionID
        )
        var contextWindows: [UInt64] = []
        var outputBudgets: [UInt64] = []
        for selection in group {
            contextWindows.append(try await contextWindow(for: selection))
            outputBudgets.append(try configuredMaxOutputTokens(for: selection))
        }
        guard let contextTokens = contextWindows.min() else {
            throw routingFailure(
                "execution.host_binding_not_configured",
                "the active agent revision has no model candidates"
            )
        }
        let maxOutputTokens = outputBudgets.max() ?? 0
        guard maxOutputTokens < contextTokens else {
            throw routingFailure(
                "model.output_budget_invalid",
                "the configured output budget must be smaller than the model context window"
            )
        }
        return ModelContextWindowDTO(
            contextWindowTokens: contextTokens,
            maxOutputTokens: maxOutputTokens
        )
    }

    func supportsImageInput(
        agentProfileID: String,
        agentProfileRevisionID: UInt64
    ) async throws -> Bool {
        let group = try await requireSelectionGroup(
            profileID: agentProfileID,
            revision: agentProfileRevisionID
        )
        for selection in group {
            switch selection {
            case let .local(_, target, _):
                guard case let .local(installationID) = target.kind,
                      let installation = try await local.inventory().first(where: {
                          $0.installationID == installationID
                              && $0.state == .installed
                              && $0.catalogStatus == .current
                      }),
                      let manifest = local.acceptedCatalog.verified.models[
                          installation.modelRevision
                      ] else {
                    return false
                }
                let supported = manifest.declaredCapabilities.contains { declaration in
                    guard declaration.capabilityID == "image_input" else {
                        return false
                    }
                    if case .support(.supported) = declaration.value { return true }
                    return false
                }
                guard supported else { return false }
            case .cloud:
                // Cloud attachment codecs currently reject binary tool results.
                return false
            }
        }
        return true
    }

    func prepareModelRun(
        runID: String,
        agentProfileID: String,
        agentProfileRevisionID: UInt64
    ) async throws {
        let group = try await requireSelectionGroup(
            profileID: agentProfileID,
            revision: agentProfileRevisionID
        )
        let window = try await modelContextWindow(
            agentProfileID: agentProfileID,
            agentProfileRevisionID: agentProfileRevisionID
        )

        var candidates: [ProviderRunCandidate] = []
        var routes: [String: any ProviderCandidateModelRoute] = [:]
        var routeSnapshots: [String: ProviderRunRouteSnapshot] = [:]
        for selection in group {
            let prepared = try await candidateRoute(
                runID: runID,
                selection: selection
            )
            candidates.append(prepared.candidate)
            routes[prepared.candidate.id] = prepared.route
            routeSnapshots[prepared.candidate.id] = prepared.snapshot
        }
        guard let primary = candidates.first else {
            throw routingFailure(
                "model_executor.no_candidate",
                "the active model group has no executable candidates"
            )
        }
        try await registry.bind(
            runID: runID,
            plan: ProviderRunPlan(
                logicalModelID: primary.modelID,
                orderedCandidates: candidates,
                modelContextWindow: window
            ),
            routes: routes,
            routeSnapshots: routeSnapshots
        )
    }

    func finishModelRun(runID: String) async {
        await registry.finish(runID: runID)
    }

    private func requireSelectionGroup(
        profileID: String,
        revision: UInt64
    ) async throws -> [AppLLMHostSelection] {
        guard let selection = await selections.selectionGroup(
            profileID: profileID,
            revision: revision
        ), !selection.isEmpty else {
            throw routingFailure(
                "execution.host_binding_not_configured",
                "the active agent revision has no exact model binding"
            )
        }
        return selection
    }

    private func candidateRoute(
        runID: String,
        selection: AppLLMHostSelection
    ) async throws -> (
        candidate: ProviderRunCandidate,
        route: any ProviderCandidateModelRoute,
        snapshot: ProviderRunRouteSnapshot
    ) {
        switch selection {
        case let .local(configuration, target, _):
            return (
                ProviderRunCandidate(
                    id: "local:\(target.targetID.rawValue):\(target.revision)",
                    kind: .local,
                    modelID: target.modelID
                ),
                RustReActModelRoute(
                    runID: runID,
                    local: local,
                    configuration: configuration,
                    target: target,
                    attachmentResolver: attachmentResolver
                ),
                ProviderRunRouteSnapshot(
                    candidateID: "local:\(target.targetID.rawValue):\(target.revision)",
                    configuration: configuration,
                    target: target
                )
            )
        case let .cloud(configuration, target, _):
            guard case let .cloud(profileID, profileRevision) = target.kind,
                  let provider = try await cloud.providerInventory().first(where: {
                      $0.profileID == profileID && $0.revision == profileRevision
                  })
            else {
                throw routingFailure(
                    "provider_profile.not_found",
                    "the frozen cloud provider revision is unavailable"
                )
            }
            return (
                ProviderRunCandidate(
                    id: "cloud:\(profileID):\(profileRevision):\(target.modelID)",
                    kind: .cloud,
                    providerConfigurationID: "\(profileID):\(profileRevision)",
                    providerType: provider.presetID.rawValue,
                    modelID: target.modelID,
                    baseURL: provider.baseURL,
                    presetID: provider.presetID
                ),
                RustReActModelRoute(
                    runID: runID,
                    cloud: cloud,
                    configuration: configuration,
                    target: target,
                    attachmentResolver: attachmentResolver
                ),
                ProviderRunRouteSnapshot(
                    candidateID:
                        "cloud:\(profileID):\(profileRevision):\(target.modelID)",
                    configuration: configuration,
                    target: target
                )
            )
        }
    }

    private func contextWindow(
        for selection: AppLLMHostSelection
    ) async throws -> UInt64 {
        switch selection {
        case let .local(_, target, _):
            guard case let .local(installationID) = target.kind,
                  let installation = try await local.inventory().first(where: {
                      $0.installationID == installationID
                          && $0.state == .installed
                          && $0.catalogStatus == .current
                  }),
                  let manifest = local.acceptedCatalog.verified.models[
                      installation.modelRevision
                  ],
                  manifest.id.modelID == target.modelID
            else {
                throw routingFailure(
                    "model.context_window_unknown",
                    "the installed local model has no verified context window"
                )
            }
            return manifest.loadTemplate.contextTokens

        case let .cloud(_, target, _):
            guard case let .cloud(profileID, profileRevision) = target.kind,
                  let model = try await cloud.modelInventory(
                      profileID: profileID,
                      profileRevision: profileRevision,
                      manualModelID: target.modelID
                  ).first(where: { $0.modelID == target.modelID }),
                  let contextTokens = model.capabilities.verifiedUpperBound(
                      for: "context_length"
                  ),
                  contextTokens > 0
            else {
                throw routingFailure(
                    "model.context_window_unknown",
                    "the cloud model has no verified context window"
                )
            }
            return contextTokens
        }
    }

    private func configuredMaxOutputTokens(
        for selection: AppLLMHostSelection
    ) throws -> UInt64 {
        let values: [LLMParameterValue?]
        switch selection {
        case let .local(configuration, target, _),
             let .cloud(configuration, target, _):
            values = [
                configuration.parameterOverrides.value(
                    for: .generationMaxOutputTokens
                ),
                target.defaultParameters.value(
                    for: .generationMaxOutputTokens
                ),
            ]
        }
        guard let value = values.compactMap({ $0 }).first else {
            return 0
        }
        guard case let .integer(tokens) = value, tokens > 0 else {
            throw routingFailure(
                "model.output_budget_invalid",
                "the configured model output budget is invalid"
            )
        }
        return UInt64(tokens)
    }
}

private func routingFailure(
    _ code: String,
    _ message: String
) -> LLMHostFailure {
    LLMHostFailure(code: code, message: message)
}
