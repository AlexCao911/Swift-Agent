import Foundation
import LocalAgentBridge
import LocalAgentLLMCloud
import LocalAgentLLMContracts
import LocalAgentLLMCore
import LocalAgentLLMHost

enum ProviderRunCandidateKind: String, Codable, Equatable, Sendable {
    case cloud
    case local
}

struct ProviderRunCandidate: Codable, Equatable, Sendable {
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

struct ProviderRunPlan: Codable, Equatable, Sendable {
    let logicalModelID: String
    let orderedCandidates: [ProviderRunCandidate]
    let modelContextWindow: ModelContextWindowDTO
}

struct ProviderRunRouteSnapshot: Codable, Equatable, Sendable {
    let candidateID: String
    let configuration: AgentHostConfiguration
    let target: LLMTargetRevision
}

typealias ProviderRouteRestorer = @Sendable (
    _ runID: String,
    _ snapshot: ProviderRunRouteSnapshot
) async throws -> any ProviderCandidateModelRoute

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
        candidate: ProviderRunCandidate
    ) async

    func finish(
        runID: String,
        candidates: [ProviderRunCandidate]
    ) async
}

extension ProviderCandidateModelExecuting {
    func finish(
        runID _: String,
        candidate _: ProviderRunCandidate
    ) async {}
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
    private struct PersistedRun: Codable {
        let plan: ProviderRunPlan
        let routeSnapshots: [String: ProviderRunRouteSnapshot]
    }

    private let persistenceURL: URL?
    private let routeRestorer: ProviderRouteRestorer?
    private var plansByRun: [String: ProviderRunPlan] = [:]
    private var routeSnapshotsByRun: [
        String: [String: ProviderRunRouteSnapshot]
    ] = [:]
    private var routesByRun: [
        String: [String: any ProviderCandidateModelRoute]
    ] = [:]

    init(
        persistenceURL: URL? = nil,
        routeRestorer: ProviderRouteRestorer? = nil
    ) {
        self.persistenceURL = persistenceURL
        self.routeRestorer = routeRestorer
        guard let persistenceURL,
              let data = try? Data(contentsOf: persistenceURL),
              let records = try? JSONDecoder().decode(
                  [String: PersistedRun].self,
                  from: data
              )
        else {
            return
        }
        plansByRun = records.mapValues(\.plan)
        routeSnapshotsByRun = records.mapValues(\.routeSnapshots)
    }

    func bind(
        runID: String,
        plan: ProviderRunPlan,
        routes: [String: any ProviderCandidateModelRoute],
        routeSnapshots: [String: ProviderRunRouteSnapshot] = [:]
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
            guard routeSnapshotsByRun[runID] == routeSnapshots
                || routeSnapshots.isEmpty else {
                throw failure(
                    "model_executor.route_binding_conflict",
                    "the run already has different restorable provider routes"
                )
            }
            routesByRun[runID] = routes
            return
        }
        if persistenceURL != nil {
            guard Set(routeSnapshots.keys)
                == Set(plan.orderedCandidates.map(\.id)),
                routeSnapshots.allSatisfy({ key, value in
                    key == value.candidateID
                })
            else {
                throw failure(
                    "model_executor.route_snapshot_invalid",
                    "persistent run plans require one non-secret snapshot per route"
                )
            }
        }
        plansByRun[runID] = plan
        routeSnapshotsByRun[runID] = routeSnapshots
        routesByRun[runID] = routes
        do {
            try persist()
        } catch {
            plansByRun.removeValue(forKey: runID)
            routeSnapshotsByRun.removeValue(forKey: runID)
            routesByRun.removeValue(forKey: runID)
            throw failure(
                "model_executor.run_plan_persistence_failed",
                "the frozen provider plan could not be persisted"
            )
        }
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
        let route = try await route(
            runID: request.runID,
            candidateID: candidate.id
        )
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
        candidate: ProviderRunCandidate
    ) async {
        guard var routes = routesByRun[runID],
              let route = routes.removeValue(forKey: candidate.id)
        else { return }
        routesByRun[runID] = routes
        await route.finish(runID: runID)
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
        routeSnapshotsByRun.removeValue(forKey: runID)
        routesByRun.removeValue(forKey: runID)
        try? persist()
    }

    private func route(
        runID: String,
        candidateID: String
    ) async throws -> any ProviderCandidateModelRoute {
        if let route = routesByRun[runID]?[candidateID] {
            return route
        }
        guard let snapshot = routeSnapshotsByRun[runID]?[candidateID],
              let routeRestorer else {
            throw failure(
                "model_executor.route_missing",
                "the model candidate route is unavailable"
            )
        }
        let route = try await routeRestorer(runID, snapshot)
        routesByRun[runID, default: [:]][candidateID] = route
        return route
    }

    private func persist() throws {
        guard let persistenceURL else { return }
        let records = Dictionary(
            uniqueKeysWithValues: plansByRun.map { runID, plan in
                (
                    runID,
                    PersistedRun(
                        plan: plan,
                        routeSnapshots: routeSnapshotsByRun[runID] ?? [:]
                    )
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(records)
        try FileManager.default.createDirectory(
            at: persistenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: persistenceURL, options: .atomic)
    }
}

actor OpenMinisModelExecutor: ModelGenerationExecuting {
    private let plans: any ProviderRunPlanProviding
    private let runtime: any ProviderCandidateModelExecuting
    private var frozenPlans: [String: ProviderRunPlan] = [:]
    private var activeCandidates: [String: ProviderRunCandidate] = [:]
    private var candidateIndices: [String: Int] = [:]
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
        let startIndex = candidateIndices[request.runID] ?? 0
        guard startIndex < plan.orderedCandidates.count else {
            throw failure(
                "model_executor.no_candidate",
                "the run has no executable model candidate"
            )
        }
        var lastError: Error?
        for index in startIndex..<plan.orderedCandidates.count {
            let candidate = plan.orderedCandidates[index]
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
                candidateIndices[request.runID] = index
                return
            } catch {
                activeCandidates.removeValue(forKey: request.runID)
                if error is CancellationError
                    || Task.isCancelled
                    || cancelledRunIDs.contains(request.runID)
                {
                    throw CancellationError()
                }
                await runtime.finish(
                    runID: request.runID,
                    candidate: candidate
                )
                lastError = error
                if await emission.hasModelContent {
                    throw error
                }
                candidateIndices[request.runID] = index + 1
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
        candidateIndices.removeValue(forKey: runID)
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
