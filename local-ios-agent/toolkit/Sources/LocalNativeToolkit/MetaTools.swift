import Foundation
import LocalAgentBridge

public struct NativeListToolsTool: NativeTool {
    public let schema: NativeToolSchema

    private let catalogProvider: @Sendable () -> NativeToolCatalog

    public init(catalog: NativeToolCatalog) {
        self.schema = Self.makeSchema()
        self.catalogProvider = { catalog }
    }

    public init(catalogProvider: @escaping @Sendable () -> NativeToolCatalog) {
        self.schema = Self.makeSchema()
        self.catalogProvider = catalogProvider
    }

    public func execute(argumentsJson: String) async -> ToolResultDTO {
        let toolSummaries = catalogProvider().schemas
            .compactMap { schema -> ToolSummary? in
                guard let exported = NativeToolSchemaExport.export(schema),
                      let metadataJson = exported.metadataJson,
                      let metadata = Self.decodeMetadata(metadataJson)
                else {
                    return nil
                }
                return ToolSummary(
                    name: exported.name,
                    riskLevel: exported.riskLevel,
                    permissionScope: metadata.permissionScope
                )
            }
            .sorted { $0.name < $1.name }
        let displayText = "\(toolSummaries.count) native tools available."
        let modelText = "Available native tools: \(toolSummaries.map(\.name).joined(separator: ", "))"

        return NativeToolResultBuilder.success(
            manifestId: Self.manifest.manifestId,
            toolName: schema.name,
            toolCallId: "unknown",
            displayText: displayText,
            modelText: modelText,
            resultKind: "native_tool_status",
            resultPayload: [
                "count": .number(Double(toolSummaries.count)),
                "tools": .array(toolSummaries.map { summary in
                    .object([
                        "name": .string(summary.name),
                        "risk_level": .string(riskLevelString(summary.riskLevel)),
                        "permission_scope": summary.permissionScope.map(JSONValue.string) ?? .string(""),
                    ])
                }),
            ],
            sourceKind: "tool",
            sourceId: schema.name,
            displayName: Self.manifest.title,
            attachmentIds: [],
            trustLevel: Self.manifest.trustLevel,
            sensitivity: .public,
            retention: Self.manifest.retention,
            modelTextPolicy: "tool_status",
            sourceLabel: "Tool",
            auditSummary: Self.manifest.audit.label,
            auditRedaction: Self.manifest.audit.resultSummaryPolicy.rawValue
        )
    }

    private static var manifest: NativeToolManifest {
        NativeToolManifest(
            manifestId: "native.native.list_tools.v1",
            capabilityId: "native.list_tools",
            title: "List Tools",
            description: "List available native tools.",
            mode: .background,
            permissionScope: nil,
            requiredPrivacyKeys: [],
            requiresForegroundUI: false,
            minimumOS: "iOS 17.0",
            regionPolicy: "available_with_service_fallback",
            fallback: NativeToolFallback(kind: .none, message: ""),
            riskLevel: .readOnly,
            approvalPolicy: .never,
            trustLevel: .trustedToolResult,
            retention: .runOnly,
            audit: NativeToolAudit(label: "List Tools", resultSummaryPolicy: .metadataOnly)
        )
    }

    private static func makeSchema() -> NativeToolSchema {
        NativeToolSchema(
            name: "native.list_tools",
            description: manifest.description,
            inputSchema: .object(),
            riskLevel: manifest.riskLevel,
            permissionScope: manifest.permissionScope,
            availability: .available,
            manifest: manifest
        )
    }

    private static func decodeMetadata(_ json: String) -> NativeToolSchemaMetadataV1? {
        guard let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(NativeToolSchemaMetadataV1.self, from: data)
    }
}

public struct NativePermissionStatusTool: NativeTool {
    public let schema: NativeToolSchema

    private let permissionStore: PermissionStore

    public init(permissionStore: PermissionStore) {
        self.schema = Self.makeSchema()
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
        let displayText = "\(permissions.count) native permissions listed."

        return NativeToolResultBuilder.success(
            manifestId: Self.manifest.manifestId,
            toolName: schema.name,
            toolCallId: "unknown",
            displayText: displayText,
            modelText: "Native permissions: \(permissions.map { "\($0.scope)=\($0.state)" }.joined(separator: ", "))",
            resultKind: "native_permission_status",
            resultPayload: [
                "count": .number(Double(permissions.count)),
                "permissions": .array(permissions.map { permission in
                    .object([
                        "scope": .string(permission.scope),
                        "state": .string(permission.state),
                    ])
                }),
            ],
            sourceKind: "tool",
            sourceId: schema.name,
            displayName: Self.manifest.title,
            attachmentIds: [],
            trustLevel: Self.manifest.trustLevel,
            sensitivity: .public,
            retention: Self.manifest.retention,
            modelTextPolicy: "tool_status",
            sourceLabel: "Tool",
            auditSummary: Self.manifest.audit.label,
            auditRedaction: Self.manifest.audit.resultSummaryPolicy.rawValue
        )
    }

    private static var manifest: NativeToolManifest {
        NativeToolManifest(
            manifestId: "native.native.permission_status.v1",
            capabilityId: "native.permission_status",
            title: "Permission Status",
            description: "List native permission states.",
            mode: .background,
            permissionScope: nil,
            requiredPrivacyKeys: [],
            requiresForegroundUI: false,
            minimumOS: "iOS 17.0",
            regionPolicy: "available_with_service_fallback",
            fallback: NativeToolFallback(kind: .none, message: ""),
            riskLevel: .readOnly,
            approvalPolicy: .never,
            trustLevel: .trustedToolResult,
            retention: .runOnly,
            audit: NativeToolAudit(label: "Permission Status", resultSummaryPolicy: .metadataOnly)
        )
    }

    private static func makeSchema() -> NativeToolSchema {
        NativeToolSchema(
            name: "native.permission_status",
            description: manifest.description,
            inputSchema: .object(),
            riskLevel: manifest.riskLevel,
            permissionScope: manifest.permissionScope,
            availability: .available,
            manifest: manifest
        )
    }
}

private struct ToolSummary {
    var name: String
    var riskLevel: RiskLevelDTO
    var permissionScope: String?
}

private struct NativePermissionStatusEntry {
    var scope: String
    var state: String
}

private func riskLevelString(_ riskLevel: RiskLevelDTO) -> String {
    switch riskLevel {
    case .readOnly:
        "read_only"
    case .confirm:
        "confirm"
    case .destructive:
        "destructive"
    default:
        "destructive"
    }
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
