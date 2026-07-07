import Foundation
import LocalAgentBridge

public enum NativeToolSchemaExport {
    public static func exportSchemas(from catalog: NativeToolCatalog) -> [ToolSchemaDTO] {
        catalog.schemas.compactMap { export($0) }
    }

    public static func export(_ schema: NativeToolSchema) -> ToolSchemaDTO? {
        guard schema.availability == .available,
              let manifest = schema.manifest
        else {
            return nil
        }
        let effectiveRisk = effectiveRiskLevel(schema.riskLevel, manifest.riskLevel)
        guard let metadataJson = metadataJSON(for: schema) else {
            return nil
        }

        return ToolSchemaDTO(
            name: schema.name,
            description: schema.description,
            parametersJsonSchema: schema.inputSchema.jsonString,
            riskLevel: bridgeRiskLevel(for: effectiveRisk),
            metadataJson: metadataJson
        )
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

    private static func metadataJSON(for schema: NativeToolSchema) -> String? {
        guard let manifest = schema.manifest else {
            return nil
        }
        let riskLevel = effectiveRiskLevel(schema.riskLevel, manifest.riskLevel)
        let metadata = NativeToolSchemaMetadataV1(
            schemaVersion: 1,
            manifestId: manifest.manifestId,
            capabilityId: manifest.capabilityId,
            toolMode: manifest.mode,
            permissionScope: manifest.permissionScope?.name,
            approvalPolicy: manifest.approvalPolicy,
            riskLevel: bridgeRiskLevel(for: riskLevel),
            contextTrustLevel: manifest.trustLevel,
            availability: NativeToolSchemaMetadataV1.Availability(
                state: availabilityState(schema.availability),
                osMinimum: manifest.minimumOS,
                regionPolicy: manifest.regionPolicy
            ),
            fallback: manifest.fallback,
            audit: manifest.audit
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(metadata) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func effectiveRiskLevel(
        _ schemaRisk: NativeToolRiskLevel,
        _ manifestRisk: NativeToolRiskLevel
    ) -> NativeToolRiskLevel {
        rank(manifestRisk) >= rank(schemaRisk) ? manifestRisk : schemaRisk
    }

    private static func rank(_ risk: NativeToolRiskLevel) -> Int {
        switch risk {
        case .readOnly:
            0
        case .confirm:
            1
        case .destructive:
            2
        }
    }

    private static func availabilityState(_ availability: NativeToolAvailability) -> String {
        switch availability {
        case .available:
            "available"
        case .unavailable:
            "unavailable"
        }
    }
}
