import Foundation
import LocalAgentBridge
import LocalNativeToolkit
import Observation

struct ToolCenterRowState: Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var title: String
    var mode: NativeToolMode
    var riskLevel: RiskLevelDTO
    var permissionScope: String?
    var approvalPolicy: NativeToolApprovalPolicy
    var readiness: NativePermissionReadiness

    var interactionLabel: String {
        switch mode {
        case .background:
            "Background"
        case .userMediated:
            "Picker required"
        case .systemActionAdapter:
            "System action"
        }
    }
}

enum ToolCenterModeFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case background
    case userMediated
    case systemActionAdapter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            "All"
        case .background:
            "Background"
        case .userMediated:
            "Pickers"
        case .systemActionAdapter:
            "System"
        }
    }

    func includes(_ mode: NativeToolMode) -> Bool {
        switch (self, mode) {
        case (.all, _), (.background, .background), (.userMediated, .userMediated), (.systemActionAdapter, .systemActionAdapter):
            true
        default:
            false
        }
    }
}

@MainActor
@Observable
final class ToolCenterViewModel {
    var rows: [ToolCenterRowState] = []
    var searchText = ""
    var modeFilter: ToolCenterModeFilter = .all

    private let client: any NativeToolkitClientProtocol
    private let permissionGateway: any NativePermissionGateway

    init(
        client: any NativeToolkitClientProtocol,
        permissionGateway: any NativePermissionGateway
    ) {
        self.client = client
        self.permissionGateway = permissionGateway
    }

    var filteredRows: [ToolCenterRowState] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return rows.filter { row in
            modeFilter.includes(row.mode)
                && (
                    query.isEmpty
                    || row.name.lowercased().contains(query)
                    || row.title.lowercased().contains(query)
                )
        }
    }

    func reload() async {
        let snapshot = await client.registrationSnapshot()
        let nativeRows = await ToolCenterProjection.project(
            schemas: snapshot.schemas,
            permissionGateway: permissionGateway
        )
        let nativeNames = Set(snapshot.schemas.map(\.name))
        let coreRows = (try? OpenMinisToolDefinitionSnapshotProvider
            .productDefaults()
            .orderedDefinitions
            .filter { !nativeNames.contains($0.name) }
            .map(ToolCenterProjection.project)) ?? []
        rows = (coreRows + nativeRows).sorted(by: ToolCenterProjection.sort)
    }
}

enum ToolCenterProjection {
    static func project(
        _ definition: OpenMinisToolDefinitionSnapshot
    ) -> ToolCenterRowState {
        ToolCenterRowState(
            id: definition.name,
            name: definition.name,
            title: definition.displayTitle,
            mode: definition.mode,
            riskLevel: definition.riskLevel,
            permissionScope: nil,
            approvalPolicy: definition.approvalPolicy,
            readiness: .ready
        )
    }

    static func project(
        schemas: [ToolSchemaDTO],
        permissionGateway: any NativePermissionGateway
    ) async -> [ToolCenterRowState] {
        var rows: [ToolCenterRowState] = []

        for schema in schemas {
            guard let metadata = decodeMetadata(schema.metadataJson) else {
                rows.append(ToolCenterRowState(
                    id: schema.name,
                    name: schema.name,
                    title: schema.name,
                    mode: .background,
                    riskLevel: schema.riskLevel,
                    permissionScope: nil,
                    approvalPolicy: .alwaysDenyUntilConfigured,
                    readiness: .unavailable(
                        scope: NativePermissionScope(schema.name),
                        reason: "missing_manifest_metadata"
                    )
                ))
                continue
            }

            let scope = metadata.permissionScope.map { NativePermissionScope($0) }
            let readiness = await permissionGateway.readiness(for: scope)
            rows.append(ToolCenterRowState(
                id: schema.name,
                name: schema.name,
                title: metadata.audit.label.isEmpty ? schema.name : metadata.audit.label,
                mode: metadata.toolMode,
                riskLevel: metadata.riskLevel,
                permissionScope: metadata.permissionScope,
                approvalPolicy: metadata.approvalPolicy,
                readiness: readiness
            ))
        }

        return rows.sorted(by: sort)
    }

    static func sort(_ lhs: ToolCenterRowState, _ rhs: ToolCenterRowState) -> Bool {
        let lhsKey = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
        if lhsKey == .orderedSame {
            return lhs.name < rhs.name
        }
        return lhsKey == .orderedAscending
    }

    private static func decodeMetadata(_ metadataJson: String?) -> NativeToolSchemaMetadataV1? {
        guard let metadataJson,
              let data = metadataJson.data(using: .utf8)
        else {
            return nil
        }
        return try? JSONDecoder().decode(NativeToolSchemaMetadataV1.self, from: data)
    }
}
