import Foundation
import LocalAgentLLMContracts

public enum LocalCapabilityObservationFactory {
    public static func observations(
        for id: LocalModelRevisionID,
        in catalog: VerifiedLocalModelCatalog,
        engineVersion: String,
        appBuild: String,
        observedAt: Date
    ) throws -> [CapabilityObservation] {
        guard catalog.disposition(for: id) == .available,
              let manifest = catalog.models[id]
        else { return [] }

        let subject = CapabilitySubject(
            engineID: manifest.engineID,
            modelID: id.modelID,
            modelRevision: String(id.revision),
            catalogRevision: catalog.catalogRevision
        )
        return try manifest.declaredCapabilities.map { declaration in
            let evidenceDigest = try evidenceDigest(
                declaration: declaration,
                subject: subject,
                engineVersion: engineVersion,
                appBuild: appBuild
            )
            let triggers: Set<CapabilityInvalidationTrigger> = [
                .catalogRevision, .engineVersion, .appBuild, .osCapabilities,
            ]
            let provisional = CapabilityObservation(
                capabilityID: declaration.capabilityID,
                dimension: .modelSupports,
                value: declaration.value,
                authority: .authoritative,
                source: .signedLocalCatalog,
                subject: subject,
                adapterOrEngineVersion: engineVersion,
                observedAt: observedAt,
                expiresAt: nil,
                validationScope: .signedDeclaration,
                invalidationTriggers: triggers,
                evidenceDigest: evidenceDigest
            )
            return CapabilityObservation(
                capabilityID: provisional.capabilityID,
                dimension: provisional.dimension,
                value: provisional.value,
                authority: provisional.authority,
                source: provisional.source,
                subject: provisional.subject,
                adapterOrEngineVersion: provisional.adapterOrEngineVersion,
                observedAt: provisional.observedAt,
                expiresAt: provisional.expiresAt,
                validationScope: provisional.validationScope,
                invalidationTriggers: provisional.invalidationTriggers,
                evidenceDigest: provisional.evidenceDigest,
                observationDigest: try observationDigest(provisional)
            )
        }
    }

    private static func evidenceDigest(
        declaration: LocalCapabilityDeclaration,
        subject: CapabilitySubject,
        engineVersion: String,
        appBuild: String
    ) throws -> String {
        let document = try CanonicalJSONValue.object(entries: [
            .init(name: "schema_version", value: .string("1")),
            .init(name: "source", value: .string(CapabilitySource.signedLocalCatalog.rawValue)),
            .init(name: "capability_id", value: .string(declaration.capabilityID)),
            .init(name: "value", value: try capabilityValue(declaration.value)),
            .init(name: "subject", value: try subjectDocument(subject)),
            .init(name: "engine_version", value: .string(engineVersion)),
            .init(name: "app_build", value: .string(appBuild)),
        ])
        return try CanonicalDigestV1.digest(
            domain: "capability-evidence:v1",
            document: document
        ).hex
    }

    private static func observationDigest(_ observation: CapabilityObservation) throws -> String {
        let triggers = observation.invalidationTriggers.map(\.rawValue).sorted()
        let document = try CanonicalJSONValue.object(entries: [
            .init(name: "schema_version", value: .string("1")),
            .init(name: "capability_id", value: .string(observation.capabilityID)),
            .init(name: "dimension", value: .string(observation.dimension.rawValue)),
            .init(name: "value", value: try capabilityValue(observation.value)),
            .init(name: "source", value: .string(observation.source.rawValue)),
            .init(name: "authority", value: .string(observation.authority.rawValue)),
            .init(name: "subject", value: try subjectDocument(observation.subject)),
            .init(
                name: "adapter_or_engine_version",
                value: observation.adapterOrEngineVersion.map(CanonicalJSONValue.string) ?? .null
            ),
            .init(name: "observed_at", value: .string(timestamp(observation.observedAt))),
            .init(name: "expires_at", value: observation.expiresAt.map { .string(timestamp($0)) } ?? .null),
            .init(name: "validation_scope", value: .string(observation.validationScope.rawValue)),
            .init(name: "invalidation_triggers", value: .array(triggers.map(CanonicalJSONValue.string))),
            .init(name: "evidence_digest", value: .string(observation.evidenceDigest)),
        ])
        return try CanonicalDigestV1.digest(
            domain: "capability-observation:v1",
            document: document
        ).hex
    }

    private static func subjectDocument(_ subject: CapabilitySubject) throws -> CanonicalJSONValue {
        try CanonicalJSONValue.object(entries: [
            .init(name: "adapter_id", value: optional(subject.adapterID)),
            .init(name: "engine_id", value: optional(subject.engineID)),
            .init(name: "provider_profile_id", value: optional(subject.providerProfileID)),
            .init(name: "provider_profile_revision", value: optional(subject.providerProfileRevision)),
            .init(name: "credential_generation", value: optional(subject.credentialGeneration)),
            .init(name: "llm_target_id", value: optional(subject.llmTargetID?.rawValue)),
            .init(name: "llm_target_revision", value: optional(subject.llmTargetRevision)),
            .init(name: "model_id", value: optional(subject.modelID)),
            .init(name: "model_revision", value: optional(subject.modelRevision)),
            .init(name: "catalog_revision", value: optional(subject.catalogRevision)),
        ])
    }

    private static func capabilityValue(_ value: CapabilityValue) throws -> CanonicalJSONValue {
        switch value {
        case let .support(state):
            return try .object(entries: [
                .init(name: "type", value: .string("support")),
                .init(name: "value", value: .string(state.rawValue)),
            ])
        case let .verifiedUpperBound(bound):
            return try .object(entries: [
                .init(name: "type", value: .string("verified_upper_bound")),
                .init(name: "value", value: .string(String(bound))),
            ])
        }
    }

    private static func optional(_ value: String?) -> CanonicalJSONValue {
        value.map(CanonicalJSONValue.string) ?? .null
    }

    private static func optional(_ value: UInt64?) -> CanonicalJSONValue {
        value.map { .string(String($0)) } ?? .null
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
