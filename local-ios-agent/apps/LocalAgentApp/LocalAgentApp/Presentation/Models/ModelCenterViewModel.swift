import LocalAgentBridge
import Observation

protocol ModelRoutingClient: Sendable {
    func providerProfiles() async throws -> [ProviderProfileDTO]
    func activeProvider() async throws -> ProviderProfileDTO
    func selectProvider(_ providerId: String) async throws
}

struct ModelCenterRowState: Equatable, Sendable, Identifiable {
    var id: String
    var displayName: String
    var route: ModelRouteKind
    var readiness: ModelReadiness
    var isActive: Bool
}

@MainActor
@Observable
final class ModelCenterViewModel {
    var activeModel: ActiveModelSummary?
    var rows: [ModelCenterRowState]
    var errorMessage: String?

    private let routingClient: (any ModelRoutingClient)?

    init(
        activeModel: ActiveModelSummary? = nil,
        rows: [ModelCenterRowState] = [],
        routingClient: (any ModelRoutingClient)? = nil
    ) {
        self.activeModel = activeModel
        self.rows = rows
        self.routingClient = routingClient
    }

    convenience init(
        routingClient: any ModelRoutingClient
    ) {
        self.init(activeModel: nil, rows: [], routingClient: routingClient)
    }

    convenience init(
        profiles: [ProviderProfileDTO],
        activeModel: ActiveModelSummary? = nil,
        localModelAvailability: [String: Bool] = [:],
        cloudCredentialAvailability: [String: Bool] = [:]
    ) {
        self.init(
            activeModel: activeModel,
            rows: ModelCenterProjection.project(
                profiles: profiles,
                activeModel: activeModel,
                localModelAvailability: localModelAvailability,
                cloudCredentialAvailability: cloudCredentialAvailability
            ),
            routingClient: nil
        )
    }

    func missingModelBanner() -> GlobalReadinessBanner? {
        guard activeModel == nil else {
            return nil
        }
        return GlobalReadinessBanner(
            id: "missing_model",
            kind: .missingModel,
            title: "Choose a model",
            message: "Select a ready local or cloud model before starting a run.",
            route: .models
        )
    }

    func reload(shell: AppShellViewModel? = nil) async {
        guard let routingClient else {
            return
        }

        do {
            let profiles = try await routingClient.providerProfiles()
            let activeProvider = try await routingClient.activeProvider()
            let activeRoute = ModelCenterProjection.routeKind(for: activeProvider)
            let activeReadiness = ModelCenterProjection.runtimeReadyReadiness(for: activeProvider)
            let activeSummary = ActiveModelSummary(
                providerId: activeProvider.id,
                modelId: activeProvider.id,
                displayName: activeProvider.displayName,
                route: activeRoute,
                readiness: activeReadiness
            )
            activeModel = activeSummary
            shell?.activeModel = activeSummary
            shell?.readinessBanners.removeAll { $0.kind == .missingModel }
            rows = ModelCenterProjection.projectRuntimeProviders(
                profiles: profiles,
                activeModel: activeSummary
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func select(rowId: String, shell: AppShellViewModel) async {
        guard let row = rows.first(where: { $0.id == rowId }),
              row.readiness == .ready
        else {
            return
        }

        if let routingClient {
            do {
                try await routingClient.selectProvider(row.id)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }

        let summary = ActiveModelSummary(
            providerId: row.id,
            modelId: row.id,
            displayName: row.displayName,
            route: row.route,
            readiness: row.readiness
        )
        activeModel = summary
        shell.activeModel = summary
        shell.readinessBanners.removeAll { $0.kind == .missingModel }
        rows = rows.map { existing in
            var updated = existing
            updated.isActive = existing.id == row.id
            return updated
        }
    }
}

enum ModelCenterProjection {
    static func projectRuntimeProviders(
        profiles: [ProviderProfileDTO],
        activeModel: ActiveModelSummary?
    ) -> [ModelCenterRowState] {
        profiles.map { profile in
            let route = routeKind(for: profile)
            let readiness = runtimeReadyReadiness(for: profile)
            return ModelCenterRowState(
                id: profile.id,
                displayName: profile.displayName,
                route: route,
                readiness: readiness,
                isActive: activeModel?.providerId == profile.id
            )
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    static func project(
        profiles: [ProviderProfileDTO],
        activeModel: ActiveModelSummary? = nil,
        localModelAvailability: [String: Bool] = [:],
        cloudCredentialAvailability: [String: Bool] = [:]
    ) -> [ModelCenterRowState] {
        profiles.map { profile in
            let route = routeKind(for: profile)
            let readiness = readiness(
                for: profile,
                route: route,
                localModelAvailability: localModelAvailability,
                cloudCredentialAvailability: cloudCredentialAvailability
            )
            return ModelCenterRowState(
                id: profile.id,
                displayName: profile.displayName,
                route: route,
                readiness: readiness,
                isActive: activeModel?.providerId == profile.id
            )
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    static func routeKind(for profile: ProviderProfileDTO) -> ModelRouteKind {
        switch profile.kind {
        case .localLLM:
            .localCpp(engineId: profile.id)
        default:
            .cloud(providerId: profile.id)
        }
    }

    static func runtimeReadyReadiness(for profile: ProviderProfileDTO) -> ModelReadiness {
        .ready
    }

    private static func readiness(
        for profile: ProviderProfileDTO,
        route: ModelRouteKind,
        localModelAvailability: [String: Bool],
        cloudCredentialAvailability: [String: Bool]
    ) -> ModelReadiness {
        if profile.kind == .mock {
            return .ready
        }

        switch route {
        case .localCpp:
            return localModelAvailability[profile.id] == true
                ? .ready
                : .missingConfiguration(reason: "weights_missing")
        case .cloud:
            return cloudCredentialAvailability[profile.id] == true
                ? .ready
                : .missingConfiguration(reason: "api_key_missing")
        case .unset:
            return .missingConfiguration(reason: "model_unset")
        }
    }
}

actor RuntimeModelRoutingClient: ModelRoutingClient {
    private let runtimeClient: any RuntimeClient & ProviderControllingRuntimeClient

    init(runtimeClient: any RuntimeClient & ProviderControllingRuntimeClient) {
        self.runtimeClient = runtimeClient
    }

    func providerProfiles() async throws -> [ProviderProfileDTO] {
        try await runtimeClient.providerProfiles()
    }

    func activeProvider() async throws -> ProviderProfileDTO {
        try await runtimeClient.activeProvider()
    }

    func selectProvider(_ providerId: String) async throws {
        let sessionId: String
        if let existing = try await runtimeClient.sessionIds().last {
            sessionId = existing
        } else {
            sessionId = try await runtimeClient.createSession()
        }
        _ = try await runtimeClient.setProvider(sessionId: sessionId, providerId: providerId)
    }
}
