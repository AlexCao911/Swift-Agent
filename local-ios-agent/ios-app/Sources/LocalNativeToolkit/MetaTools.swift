import Foundation
import LocalAgentBridge

public struct NativeListToolsTool: NativeTool {
    public let schema = NativeToolSchema(
        name: "native.list_tools",
        description: "List available native tools.",
        inputSchema: .object(),
        riskLevel: .readOnly,
        permissionScope: nil,
        availability: .available
    )

    private let catalogProvider: @Sendable () -> NativeToolCatalog

    public init(catalog: NativeToolCatalog) {
        self.catalogProvider = { catalog }
    }

    public init(catalogProvider: @escaping @Sendable () -> NativeToolCatalog) {
        self.catalogProvider = catalogProvider
    }

    public func execute(argumentsJson: String) async -> ToolResultDTO {
        let tools = catalogProvider().schemas
            .filter { $0.availability == .available }
            .map { schema in
                NativeToolListEntry(
                    name: schema.name,
                    description: schema.description,
                    riskLevel: NativeToolSchemaExport.bridgeRiskLevel(for: schema.riskLevel).rawValue,
                    permissionScope: schema.permissionScope?.name
                )
            }
        let payload = NativeToolListPayload(tools: tools)
        let structuredJson = Self.encode(payload)

        return ToolResultDTO(
            displayText: "\(tools.count) native tools available.",
            modelText: structuredJson,
            structuredJson: structuredJson,
            auditText: "Listed \(tools.count) native tools.",
            sensitivity: .public,
            retention: .runOnly,
            isError: false
        )
    }

    private static func encode<T: Encodable>(_ value: T) -> String {
        let data = try! JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}

public struct NativePermissionStatusTool: NativeTool {
    public let schema = NativeToolSchema(
        name: "native.permission_status",
        description: "List native permission states.",
        inputSchema: .object(),
        riskLevel: .readOnly,
        permissionScope: nil,
        availability: .available
    )

    private let permissionStore: PermissionStore

    public init(permissionStore: PermissionStore) {
        self.permissionStore = permissionStore
    }

    public func execute(argumentsJson: String) async -> ToolResultDTO {
        let states = await permissionStore.states()
        let permissions = states
            .map { scope, state in
                NativePermissionStatusEntry(
                    scope: scope.name,
                    state: state.statusString
                )
            }
            .sorted { $0.scope < $1.scope }
        let payload = NativePermissionStatusPayload(permissions: permissions)
        let structuredJson = Self.encode(payload)

        return ToolResultDTO(
            displayText: "\(permissions.count) native permissions listed.",
            modelText: structuredJson,
            structuredJson: structuredJson,
            auditText: "Listed \(permissions.count) native permissions.",
            sensitivity: .public,
            retention: .runOnly,
            isError: false
        )
    }

    private static func encode<T: Encodable>(_ value: T) -> String {
        let data = try! JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}

private struct NativeToolListPayload: Encodable {
    var tools: [NativeToolListEntry]
}

private struct NativeToolListEntry: Encodable {
    var name: String
    var description: String
    var riskLevel: String
    var permissionScope: String?

    private enum CodingKeys: String, CodingKey {
        case name
        case description
        case riskLevel = "risk_level"
        case permissionScope = "permission_scope"
    }
}

private struct NativePermissionStatusPayload: Encodable {
    var permissions: [NativePermissionStatusEntry]
}

private struct NativePermissionStatusEntry: Encodable {
    var scope: String
    var state: String
}

private extension NativePermissionState {
    var statusString: String {
        switch self {
        case .unknown:
            "unknown"
        case .granted:
            "granted"
        case .denied:
            "denied"
        case .restricted:
            "restricted"
        }
    }
}
