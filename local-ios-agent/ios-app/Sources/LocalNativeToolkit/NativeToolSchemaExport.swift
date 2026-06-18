import Foundation
import LocalAgentBridge

public enum NativeToolSchemaExport {
    public static func exportSchemas(from catalog: NativeToolCatalog) -> [ToolSchemaDTO] {
        catalog.schemas.compactMap { schema in
            guard schema.availability == .available else {
                return nil
            }

            return ToolSchemaDTO(
                name: schema.name,
                description: schema.description,
                parametersJsonSchema: schema.inputSchema.jsonString,
                riskLevel: bridgeRiskLevel(for: schema.riskLevel),
                metadataJson: metadataJSON(for: schema.permissionScope)
            )
        }
    }

    public static func bridgeRiskLevel(for riskLevel: NativeToolRiskLevel) -> RiskLevelDTO {
        switch riskLevel {
        case .readOnly:
            .readOnly
        case .confirm:
            .confirm
        case .destructive:
            .destructive
        }
    }

    private static func metadataJSON(for scope: NativePermissionScope?) -> String? {
        guard let scope else {
            return nil
        }

        let metadata = NativeToolSchemaMetadata(nativePermissionScope: scope.name)
        let data = try! JSONEncoder().encode(metadata)
        return String(decoding: data, as: UTF8.self)
    }
}

private struct NativeToolSchemaMetadata: Encodable {
    var nativePermissionScope: String

    private enum CodingKeys: String, CodingKey {
        case nativePermissionScope = "native_permission_scope"
    }
}
