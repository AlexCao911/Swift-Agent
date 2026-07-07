import LocalAgentBridge
import Observation

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

    init(
        activeModel: ActiveModelSummary? = nil,
        rows: [ModelCenterRowState] = []
    ) {
        self.activeModel = activeModel
        self.rows = rows
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
            )
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

    func select(rowId: String, shell: AppShellViewModel) {
        guard let row = rows.first(where: { $0.id == rowId }),
              row.readiness == .ready
        else {
            return
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

    private static func routeKind(for profile: ProviderProfileDTO) -> ModelRouteKind {
        switch profile.kind {
        case .localLLM:
            .localCpp(engineId: profile.id)
        default:
            .cloud(providerId: profile.id)
        }
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
