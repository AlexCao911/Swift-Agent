import Foundation
import LocalAgentBridge
import LocalAgentLLMCloud
import LocalAgentLLMContracts
import LocalAgentLLMHost

enum ProviderRunCandidateKind: String, Equatable, Sendable {
    case cloud
    case local
}

struct ProviderRunCandidate: Equatable, Sendable {
    let id: String
    let kind: ProviderRunCandidateKind
    let providerConfigurationID: String?
    let providerType: String?
    let modelID: String
    let baseURL: URL?
    let presetID: ProviderPresetID?

    init(
        id: String,
        kind: ProviderRunCandidateKind,
        providerConfigurationID: String? = nil,
        providerType: String? = nil,
        modelID: String,
        baseURL: URL? = nil,
        presetID: ProviderPresetID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.providerConfigurationID = providerConfigurationID
        self.providerType = providerType
        self.modelID = modelID
        self.baseURL = baseURL
        self.presetID = presetID
    }
}

struct ProviderRunPlan: Equatable, Sendable {
    let logicalModelID: String
    let orderedCandidates: [ProviderRunCandidate]
    let modelContextWindow: ModelContextWindowDTO
}

protocol ProviderRunPlanProviding: Sendable {
    func plan(for runID: String) async throws -> ProviderRunPlan
    func finish(runID: String) async
}

protocol ProviderCandidateModelExecuting: Sendable {
    func generate(
        _ request: HostModelRequest,
        candidate: ProviderRunCandidate,
        emit: @escaping @Sendable (HostModelEvent) async throws -> Void
    ) async throws

    func cancel(
        runID: String,
        candidate: ProviderRunCandidate
    ) async

    func finish(
        runID: String,
        candidates: [ProviderRunCandidate]
    ) async
}

protocol ProviderCandidateModelRoute: Sendable {
    func generate(
        _ request: HostModelRequest,
        emit: @escaping @Sendable (HostModelEvent) async throws -> Void
    ) async throws

    func cancel(runID: String) async
    func finish(runID: String) async
}

struct OpenMinisModelExecutionError: Error, Equatable, LocalizedError {
    let code: String
    let message: String

    var errorDescription: String? { message }
}

actor OpenMinisModelExecutionRegistry:
    ProviderRunPlanProviding,
    ProviderCandidateModelExecuting
{
    private var plansByRun: [String: ProviderRunPlan] = [:]
    private var routesByRun: [
        String: [String: any ProviderCandidateModelRoute]
    ] = [:]

    func bind(
        runID: String,
        plan: ProviderRunPlan,
        routes: [String: any ProviderCandidateModelRoute]
    ) throws {
        guard !runID.isEmpty,
              Set(plan.orderedCandidates.map(\.id)) == Set(routes.keys)
        else {
            throw failure(
                "model_executor.route_binding_invalid",
                "the run plan and executable routes do not match"
            )
        }
        if let existing = plansByRun[runID] {
            guard existing == plan else {
                throw failure(
                    "model_executor.route_binding_conflict",
                    "the run already has a different provider plan"
                )
            }
            return
        }
        plansByRun[runID] = plan
        routesByRun[runID] = routes
    }

    func plan(for runID: String) async throws -> ProviderRunPlan {
        guard let plan = plansByRun[runID] else {
            throw failure(
                "model_executor.run_plan_missing",
                "the run has no frozen provider plan"
            )
        }
        return plan
    }

    func generate(
        _ request: HostModelRequest,
        candidate: ProviderRunCandidate,
        emit: @escaping @Sendable (HostModelEvent) async throws -> Void
    ) async throws {
        guard let route = routesByRun[request.runID]?[candidate.id] else {
            throw failure(
                "model_executor.route_missing",
                "the model candidate route is unavailable"
            )
        }
        try await route.generate(request, emit: emit)
    }

    func cancel(
        runID: String,
        candidate: ProviderRunCandidate
    ) async {
        await routesByRun[runID]?[candidate.id]?.cancel(runID: runID)
    }

    func finish(
        runID: String,
        candidates: [ProviderRunCandidate]
    ) async {
        let routes = routesByRun.removeValue(forKey: runID) ?? [:]
        for candidate in candidates {
            await routes[candidate.id]?.finish(runID: runID)
        }
    }

    func finish(runID: String) async {
        plansByRun.removeValue(forKey: runID)
        routesByRun.removeValue(forKey: runID)
    }
}

actor OpenMinisModelExecutor: ModelGenerationExecuting {
    private let plans: any ProviderRunPlanProviding
    private let runtime: any ProviderCandidateModelExecuting
    private var frozenPlans: [String: ProviderRunPlan] = [:]
    private var activeCandidates: [String: ProviderRunCandidate] = [:]
    private var cancelledRunIDs: Set<String> = []

    init(
        plans: any ProviderRunPlanProviding,
        runtime: any ProviderCandidateModelExecuting
    ) {
        self.plans = plans
        self.runtime = runtime
    }

    func generate(
        _ request: HostModelRequest,
        emit: @escaping @Sendable (HostModelEvent) async throws -> Void
    ) async throws {
        guard activeCandidates[request.runID] == nil else {
            throw failure(
                "model_executor.run_busy",
                "the run already has an active model generation"
            )
        }
        guard !cancelledRunIDs.contains(request.runID) else {
            throw CancellationError()
        }

        let plan = try await frozenPlan(for: request.runID)
        var lastError: Error?
        for candidate in plan.orderedCandidates {
            try Task.checkCancellation()
            guard !cancelledRunIDs.contains(request.runID) else {
                throw CancellationError()
            }

            let emission = ModelGenerationEmission()
            activeCandidates[request.runID] = candidate
            do {
                try await runtime.generate(
                    request,
                    candidate: candidate
                ) { event in
                    await emission.record(event)
                    try await emit(event)
                }
                activeCandidates.removeValue(forKey: request.runID)
                guard !cancelledRunIDs.contains(request.runID),
                      !Task.isCancelled else {
                    throw CancellationError()
                }
                return
            } catch {
                activeCandidates.removeValue(forKey: request.runID)
                if error is CancellationError
                    || Task.isCancelled
                    || cancelledRunIDs.contains(request.runID)
                {
                    throw CancellationError()
                }
                lastError = error
                if await emission.hasModelContent {
                    throw error
                }
            }
        }
        throw lastError ?? failure(
            "model_executor.no_candidate",
            "the run has no executable model candidate"
        )
    }

    func cancel(runID: String) async {
        cancelledRunIDs.insert(runID)
        guard let candidate = activeCandidates[runID] else { return }
        await runtime.cancel(runID: runID, candidate: candidate)
    }

    func finish(runID: String) async {
        let plan = frozenPlans.removeValue(forKey: runID)
        activeCandidates.removeValue(forKey: runID)
        cancelledRunIDs.remove(runID)
        if let plan {
            await runtime.finish(
                runID: runID,
                candidates: plan.orderedCandidates
            )
        }
        await plans.finish(runID: runID)
    }

    private func frozenPlan(for runID: String) async throws -> ProviderRunPlan {
        if let plan = frozenPlans[runID] {
            return plan
        }
        let plan = try await plans.plan(for: runID)
        try validate(plan)
        frozenPlans[runID] = plan
        return plan
    }

    private func validate(_ plan: ProviderRunPlan) throws {
        guard !plan.logicalModelID.isEmpty,
              !plan.orderedCandidates.isEmpty,
              plan.modelContextWindow.contextWindowTokens > 0,
              plan.modelContextWindow.maxOutputTokens
                < plan.modelContextWindow.contextWindowTokens,
              Set(plan.orderedCandidates.map(\.id)).count
                == plan.orderedCandidates.count,
              plan.orderedCandidates.allSatisfy({
                  !$0.id.isEmpty && !$0.modelID.isEmpty
              })
        else {
            throw failure(
                "model_executor.plan_invalid",
                "the provider run plan is empty or ambiguous"
            )
        }
        for candidate in plan.orderedCandidates where candidate.kind == .cloud {
            guard candidate.providerConfigurationID?.isEmpty == false,
                  candidate.providerType?.isEmpty == false,
                  candidate.baseURL != nil,
                  candidate.presetID != nil
            else {
                throw failure(
                    "model_executor.cloud_candidate_invalid",
                    "a cloud candidate is missing its non-secret route"
                )
            }
        }
    }
}

private actor ModelGenerationEmission {
    private(set) var hasModelContent = false

    func record(_ event: HostModelEvent) {
        switch event {
        case .textDelta, .reasoningDelta, .toolCallDelta:
            hasModelContent = true
        case .usage:
            break
        }
    }
}

private func failure(
    _ code: String,
    _ message: String
) -> OpenMinisModelExecutionError {
    OpenMinisModelExecutionError(code: code, message: message)
}
