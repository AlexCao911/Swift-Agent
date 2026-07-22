import Foundation
import LocalAgentLLMContracts

package struct DiscoveredCloudModel: Equatable, Sendable {
    package enum Source: String, Hashable, Sendable {
        case liveProviderList = "live_provider_list"
        case signedCatalog = "signed_catalog"
        case manual
    }

    package let modelID: String
    package let modelRevision: String?
    package let sources: Set<Source>
    package let observations: [CapabilityObservation]
    package let catalogEntry: CloudModelCatalogEntry?
}

package struct CloudModelDiscoveryService: Sendable {
    private let clock: @Sendable () -> Date
    private let validity: TimeInterval

    package init(
        clock: @escaping @Sendable () -> Date = Date.init,
        validity: TimeInterval = 24 * 60 * 60
    ) {
        self.clock = clock
        self.validity = validity
    }

    package func merge(
        liveModelIDs: [String],
        manualModelID: String? = nil,
        presetID: ProviderPresetID,
        adapterID: String,
        adapterVersion: String,
        catalog: VerifiedCloudCapabilityCatalog,
        routeSubject: CapabilitySubject
    ) throws -> [DiscoveredCloudModel] {
        guard validity > 0,
              routeSubject.adapterID == adapterID,
              !adapterID.isEmpty,
              !liveModelIDs.contains(where: \.isEmpty)
        else {
            throw discoveryFailure("cloud_discovery.context_invalid", "cloud discovery context is invalid")
        }
        let now = clock()
        let expires = now.addingTimeInterval(validity)
        var identities = Set(liveModelIDs)
        if let manualModelID, !manualModelID.isEmpty { identities.insert(manualModelID) }
        for entry in catalog.models.values where entry.identity.presetID == presetID {
            identities.insert(entry.identity.modelID)
        }

        return try identities.sorted().map { modelID in
            let entry = catalog.entry(presetID: presetID, modelID: modelID)
            let modelRevision = entry?.identity.modelRevision
            let subject = replacingModel(
                routeSubject,
                modelID: modelID,
                modelRevision: modelRevision,
                catalogRevision: entry == nil ? nil : catalog.catalogRevision
            )
            var sources: Set<DiscoveredCloudModel.Source> = []
            var observations: [CapabilityObservation] = []
            if liveModelIDs.contains(modelID) {
                sources.insert(.liveProviderList)
                observations.append(try CloudCapabilityObservationFactory.availabilityObservation(
                    subject: subject,
                    adapterVersion: adapterVersion,
                    observedAt: now,
                    expiresAt: expires
                ))
            }
            if manualModelID == modelID { sources.insert(.manual) }
            if let entry {
                guard entry.adapterID == adapterID else {
                    throw discoveryFailure(
                        "cloud_discovery.catalog_adapter_mismatch",
                        "cloud catalog model uses a different semantic adapter"
                    )
                }
                sources.insert(.signedCatalog)
                observations.append(contentsOf: try CloudCapabilityObservationFactory.catalogObservations(
                    entry: entry,
                    catalog: catalog,
                    exactSubject: subject,
                    adapterVersion: adapterVersion,
                    observedAt: now
                ))
            }
            return DiscoveredCloudModel(
                modelID: modelID,
                modelRevision: modelRevision,
                sources: sources,
                observations: observations,
                catalogEntry: entry
            )
        }
    }

    package func decodeLiveModelIDs(_ data: Data, presetID: ProviderPresetID) throws -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw discoveryFailure("cloud_discovery.response_invalid", "provider model list is invalid")
        }
        let values: [Any]
        if let data = root["data"] as? [Any] {
            values = data
        } else if let models = root["models"] as? [Any] {
            values = models
        } else {
            throw discoveryFailure("cloud_discovery.response_invalid", "provider model list is missing")
        }
        let ids = values.compactMap { value -> String? in
            guard let object = value as? [String: Any] else { return nil }
            let raw = object["id"] as? String ?? object["name"] as? String
            guard var raw, !raw.isEmpty else { return nil }
            if presetID == .gemini, raw.hasPrefix("models/") {
                raw.removeFirst("models/".count)
            }
            return raw
        }
        guard ids.count == values.count, Set(ids).count == ids.count else {
            throw discoveryFailure("cloud_discovery.response_invalid", "provider model identities are invalid")
        }
        return ids
    }

    private func replacingModel(
        _ subject: CapabilitySubject,
        modelID: String,
        modelRevision: String?,
        catalogRevision: UInt64?
    ) -> CapabilitySubject {
        CapabilitySubject(
            adapterID: subject.adapterID,
            engineID: subject.engineID,
            providerProfileID: subject.providerProfileID,
            providerProfileRevision: subject.providerProfileRevision,
            credentialGeneration: subject.credentialGeneration,
            llmTargetID: subject.llmTargetID,
            llmTargetRevision: subject.llmTargetRevision,
            modelID: modelID,
            modelRevision: modelRevision,
            catalogRevision: catalogRevision,
            retentionMode: subject.retentionMode,
            retentionApprovalRevision: subject.retentionApprovalRevision,
            retentionApprovalDigest: subject.retentionApprovalDigest
        )
    }
}

private func discoveryFailure(_ code: String, _ message: String) -> LLMFailure {
    LLMFailure(code: code, message: message, retryable: false)
}
