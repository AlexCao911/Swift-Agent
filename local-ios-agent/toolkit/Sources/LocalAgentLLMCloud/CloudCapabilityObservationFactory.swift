import Foundation
import LocalAgentLLMContracts

package enum CloudCapabilityObservationFactory {
    package static func exactSubject(
        adapterID: String,
        profileID: String,
        profileRevision: UInt64,
        credentialGeneration: UInt64,
        targetID: LLMTargetID? = nil,
        targetRevision: UInt64? = nil,
        modelID: String,
        modelRevision: String?,
        catalogRevision: UInt64?,
        retentionMode: ProviderRetentionMode,
        retentionApprovalRevision: UInt64?,
        retentionApprovalDigest: String?
    ) -> CapabilitySubject {
        CapabilitySubject(
            adapterID: adapterID,
            providerProfileID: profileID,
            providerProfileRevision: profileRevision,
            credentialGeneration: credentialGeneration,
            llmTargetID: targetID,
            llmTargetRevision: targetRevision,
            modelID: modelID,
            modelRevision: modelRevision,
            catalogRevision: catalogRevision,
            retentionMode: retentionMode.rawValue,
            retentionApprovalRevision: retentionApprovalRevision,
            retentionApprovalDigest: retentionApprovalDigest
        )
    }

    package static func catalogObservations(
        entry: CloudModelCatalogEntry,
        catalog: VerifiedCloudCapabilityCatalog,
        exactSubject: CapabilitySubject,
        adapterVersion: String,
        observedAt: Date
    ) throws -> [CapabilityObservation] {
        guard entry.identity.modelID == exactSubject.modelID,
              entry.identity.modelRevision == exactSubject.modelRevision,
              entry.adapterID == exactSubject.adapterID,
              exactSubject.catalogRevision == catalog.catalogRevision,
              entry.supports(adapterVersion: adapterVersion),
              let retention = exactSubject.retentionMode.flatMap(ProviderRetentionMode.init(rawValue:)),
              entry.continuationModes.contains(retention)
        else {
            throw cloudCapabilityFailure(
                "capability.cloud_subject_incompatible",
                "cloud catalog entry does not match the exact route subject"
            )
        }
        let revoked = catalog.isRevoked(entry.identity)
        return try entry.capabilities.flatMap { declaration in
            let modelValue: CapabilityValue = revoked
                ? .support(.unsupported) : declaration.value
            return try [
                observation(
                    capabilityID: declaration.capabilityID,
                    dimension: .adapterCanEncode,
                    value: declaration.value,
                    authority: .authoritative,
                    source: .shippedCloudAdapter,
                    subject: exactSubject,
                    adapterVersion: adapterVersion,
                    observedAt: observedAt,
                    expiresAt: nil,
                    validationScope: .compiledDescriptor,
                    triggers: [
                        .adapterVersion, .appBuild, .providerProfileRevision,
                        .credentialGeneration, .modelIdentity, .catalogRevision,
                        .retentionIdentity,
                    ]
                ),
                observation(
                    capabilityID: declaration.capabilityID,
                    dimension: .endpointSupports,
                    value: declaration.value,
                    authority: .authoritative,
                    source: .signedCloudCatalog,
                    subject: exactSubject,
                    adapterVersion: adapterVersion,
                    observedAt: observedAt,
                    expiresAt: nil,
                    validationScope: .signedDeclaration,
                    triggers: [
                        .catalogRevision, .adapterVersion, .modelIdentity,
                        .providerProfileRevision, .credentialGeneration, .retentionIdentity,
                    ]
                ),
                observation(
                    capabilityID: declaration.capabilityID,
                    dimension: .modelSupports,
                    value: modelValue,
                    authority: .authoritative,
                    source: .signedCloudCatalog,
                    subject: exactSubject,
                    adapterVersion: adapterVersion,
                    observedAt: observedAt,
                    expiresAt: nil,
                    validationScope: .signedDeclaration,
                    triggers: [
                        .catalogRevision, .adapterVersion, .modelIdentity,
                        .providerProfileRevision, .credentialGeneration, .retentionIdentity,
                    ]
                ),
            ]
        }
    }

    package static func availabilityObservation(
        subject: CapabilitySubject,
        adapterVersion: String,
        observedAt: Date,
        expiresAt: Date
    ) throws -> CapabilityObservation {
        try observation(
            capabilityID: "availability",
            dimension: .availabilityValidated,
            value: .support(.supported),
            authority: .verified,
            source: .providerModelList,
            subject: subject,
            adapterVersion: adapterVersion,
            observedAt: observedAt,
            expiresAt: expiresAt,
            validationScope: .authenticatedEndpoint,
            triggers: [
                .providerProfileRevision, .credentialGeneration, .modelIdentity,
                .adapterVersion, .catalogRevision, .retentionIdentity,
            ]
        )
    }

    package static func routineProbeObservations(
        subject: CapabilitySubject,
        adapterVersion: String,
        observedAt: Date,
        expiresAt: Date
    ) throws -> [CapabilityObservation] {
        try ["text_generation", "streaming"].flatMap { capabilityID in
            try [
                observation(
                    capabilityID: capabilityID,
                    dimension: .adapterCanEncode,
                    value: .support(.supported),
                    authority: .authoritative,
                    source: .shippedCloudAdapter,
                    subject: subject,
                    adapterVersion: adapterVersion,
                    observedAt: observedAt,
                    expiresAt: nil,
                    validationScope: .compiledDescriptor,
                    triggers: [
                        .adapterVersion, .appBuild, .providerProfileRevision,
                        .credentialGeneration, .modelIdentity, .catalogRevision,
                        .retentionIdentity,
                    ]
                ),
                observation(
                    capabilityID: capabilityID,
                    dimension: .endpointSupports,
                    value: .support(.supported),
                    authority: .verified,
                    source: .connectivityProbe,
                    subject: subject,
                    adapterVersion: adapterVersion,
                    observedAt: observedAt,
                    expiresAt: expiresAt,
                    validationScope: .featureProbe,
                    triggers: [
                        .providerProfileRevision, .credentialGeneration, .modelIdentity,
                        .adapterVersion, .catalogRevision, .retentionIdentity,
                    ]
                ),
                observation(
                    capabilityID: capabilityID,
                    dimension: .modelSupports,
                    value: .support(.supported),
                    authority: .verified,
                    source: .connectivityProbe,
                    subject: subject,
                    adapterVersion: adapterVersion,
                    observedAt: observedAt,
                    expiresAt: expiresAt,
                    validationScope: .featureProbe,
                    triggers: [
                        .providerProfileRevision, .credentialGeneration, .modelIdentity,
                        .adapterVersion, .catalogRevision, .retentionIdentity,
                    ]
                ),
            ]
        }
    }

    private static func observation(
        capabilityID: String,
        dimension: CapabilityDimension,
        value: CapabilityValue,
        authority: CapabilityAuthority,
        source: CapabilitySource,
        subject: CapabilitySubject,
        adapterVersion: String,
        observedAt: Date,
        expiresAt: Date?,
        validationScope: ValidationScope,
        triggers: Set<CapabilityInvalidationTrigger>
    ) throws -> CapabilityObservation {
        let evidenceDocument = try CanonicalJSONValue.object(entries: [
            .init(name: "schema_version", value: .string("1")),
            .init(name: "source", value: .string(source.rawValue)),
            .init(name: "capability_id", value: .string(capabilityID)),
            .init(name: "dimension", value: .string(dimension.rawValue)),
            .init(name: "value", value: try capabilityValue(value)),
            .init(name: "subject", value: try subjectDocument(subject)),
            .init(name: "adapter_version", value: .string(adapterVersion)),
        ])
        let evidence = try CanonicalDigestV1.digest(
            domain: "capability-evidence:v1",
            document: evidenceDocument
        ).hex
        let provisional = CapabilityObservation(
            capabilityID: capabilityID,
            dimension: dimension,
            value: value,
            authority: authority,
            source: source,
            subject: subject,
            adapterOrEngineVersion: adapterVersion,
            observedAt: observedAt,
            expiresAt: expiresAt,
            validationScope: validationScope,
            invalidationTriggers: triggers,
            evidenceDigest: evidence
        )
        let document = try CanonicalJSONValue.object(entries: [
            .init(name: "schema_version", value: .string("1")),
            .init(name: "capability_id", value: .string(capabilityID)),
            .init(name: "dimension", value: .string(dimension.rawValue)),
            .init(name: "value", value: try capabilityValue(value)),
            .init(name: "authority", value: .string(authority.rawValue)),
            .init(name: "source", value: .string(source.rawValue)),
            .init(name: "subject", value: try subjectDocument(subject)),
            .init(name: "adapter_or_engine_version", value: .string(adapterVersion)),
            .init(name: "observed_at", value: .string(timestamp(observedAt))),
            .init(name: "expires_at", value: expiresAt.map { .string(timestamp($0)) } ?? .null),
            .init(name: "validation_scope", value: .string(validationScope.rawValue)),
            .init(name: "invalidation_triggers", value: .array(
                triggers.map(\.rawValue).sorted().map(CanonicalJSONValue.string)
            )),
            .init(name: "evidence_digest", value: .string(evidence)),
        ])
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
            evidenceDigest: evidence,
            observationDigest: try CanonicalDigestV1.digest(
                domain: "capability-observation:v1",
                document: document
            ).hex
        )
    }

    package static func subjectDocument(
        _ subject: CapabilitySubject
    ) throws -> CanonicalJSONValue {
        try .object(entries: [
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
            .init(name: "retention_mode", value: optional(subject.retentionMode)),
            .init(name: "retention_approval_revision", value: optional(subject.retentionApprovalRevision)),
            .init(name: "retention_approval_digest", value: optional(subject.retentionApprovalDigest)),
        ])
    }

    package static func capabilityValue(_ value: CapabilityValue) throws -> CanonicalJSONValue {
        switch value {
        case let .support(state):
            try .object(entries: [
                .init(name: "type", value: .string("support")),
                .init(name: "value", value: .string(state.rawValue)),
            ])
        case let .verifiedUpperBound(bound):
            try .object(entries: [
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

private func cloudCapabilityFailure(_ code: String, _ message: String) -> LLMFailure {
    LLMFailure(code: code, message: message, retryable: false)
}
