import Foundation
import LocalAgentBridge
import LocalNativeToolkit

struct AgentBuilderToolCard: Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var title: String
    var description: String
    var riskLevel: String
    var approvalPolicy: String
    var trustLevel: String
    var permissionScope: String?
    var fallbackText: String
    var statusText: String
    var isAvailable: Bool

    static func unavailable(id: String, name: String, reason: String) -> AgentBuilderToolCard {
        AgentBuilderToolCard(
            id: id,
            name: name,
            title: name,
            description: reason,
            riskLevel: "unavailable",
            approvalPolicy: NativeToolApprovalPolicy.alwaysDenyUntilConfigured.rawValue,
            trustLevel: NativeToolTrustLevel.trustedToolResult.rawValue,
            permissionScope: nil,
            fallbackText: reason,
            statusText: reason,
            isAvailable: false
        )
    }
}

protocol AgentBuilderToolCatalogClient: Sendable {
    func loadToolCards() async throws -> [AgentBuilderToolCard]
}

struct NativeManifestToolCatalogClient: AgentBuilderToolCatalogClient {
    private let catalogProvider: @Sendable () throws -> NativeToolCatalog

    init(catalogProvider: @escaping @Sendable () throws -> NativeToolCatalog) {
        self.catalogProvider = catalogProvider
    }

    func loadToolCards() async throws -> [AgentBuilderToolCard] {
        let catalog = try catalogProvider()
        return catalog.schemas
            .map(Self.card(from:))
            .sorted { $0.name < $1.name }
    }

    private static func card(from schema: NativeToolSchema) -> AgentBuilderToolCard {
        guard let manifest = schema.manifest else {
            return AgentBuilderToolCard.unavailable(
                id: schema.name,
                name: schema.name,
                reason: "Missing stable NativeToolManifest metadata."
            )
        }

        let exportedRisk = NativeToolSchemaExport.bridgeRiskLevel(for: effectiveRiskLevel(
            schema.riskLevel,
            manifest.riskLevel
        ))
        return AgentBuilderToolCard(
            id: schema.name,
            name: schema.name,
            title: manifest.title,
            description: manifest.description,
            riskLevel: exportedRisk.rawValue,
            approvalPolicy: manifest.approvalPolicy.rawValue,
            trustLevel: manifest.trustLevel.rawValue,
            permissionScope: manifest.permissionScope?.name,
            fallbackText: manifest.fallback.message,
            statusText: statusText(for: schema.availability),
            isAvailable: schema.availability == .available
        )
    }

    private static func statusText(for availability: NativeToolAvailability) -> String {
        switch availability {
        case .available:
            "Available"
        case .unavailable(let reason):
            reason
        }
    }

    private static func effectiveRiskLevel(
        _ schemaRisk: NativeToolRiskLevel,
        _ manifestRisk: NativeToolRiskLevel
    ) -> NativeToolRiskLevel {
        riskRank(manifestRisk) >= riskRank(schemaRisk) ? manifestRisk : schemaRisk
    }

    private static func riskRank(_ risk: NativeToolRiskLevel) -> Int {
        switch risk {
        case .readOnly:
            0
        case .confirm:
            1
        case .destructive:
            2
        }
    }
}

struct StaticAgentBuilderToolCatalogClient: AgentBuilderToolCatalogClient {
    var cards: [AgentBuilderToolCard]

    func loadToolCards() async throws -> [AgentBuilderToolCard] {
        cards.sorted { $0.name < $1.name }
    }
}
