import Foundation
import LocalAgentLLMContracts
import LocalAgentLLMCore

public struct ProviderValidationResult: Sendable {
    public let validationID: String
    public let subject: CapabilitySubject
    public let observations: [CapabilityObservation]
    public let snapshot: CapabilitySnapshot
    public let evidenceDigest: String
    public let expiresAt: Date
}

public actor ProviderValidationService {
    private struct StoredObservation: Codable {
        let recordSchemaVersion = 2
        let observation: CapabilityObservation
        enum CodingKeys: String, CodingKey {
            case recordSchemaVersion = "record_schema_version"
            case observation
        }
    }

    private struct StoredValidation: Codable {
        let recordSchemaVersion = 2
        let validationID: String
        let subject: CapabilitySubject
        let observationDigests: [String]
        let evidenceDigest: String
        let expiresAt: Date
        enum CodingKeys: String, CodingKey {
            case recordSchemaVersion = "record_schema_version"
            case validationID = "validation_id"
            case subject
            case observationDigests = "observation_digests"
            case evidenceDigest = "evidence_digest"
            case expiresAt = "expires_at"
        }
    }

    private let database: SQLiteConnection
    private let profileStore: ProviderProfileStore
    private let catalogStore: CloudCapabilityCatalogStore
    private let credentialStore: ProviderCredentialStore
    private let egressPolicy: ProviderEgressPolicy
    private let transport: any CloudHTTPTransport
    private let hostProcessEpoch: HostProcessEpoch
    private let clock: @Sendable () -> Date
    private let validity: TimeInterval
    private let idGenerator: @Sendable () throws -> String

    package init(
        fileURL: URL,
        profileStore: ProviderProfileStore,
        catalogStore: CloudCapabilityCatalogStore,
        credentialStore: ProviderCredentialStore,
        egressPolicy: ProviderEgressPolicy,
        transport: any CloudHTTPTransport,
        hostProcessEpoch: HostProcessEpoch,
        clock: @escaping @Sendable () -> Date = Date.init,
        validity: TimeInterval = 24 * 60 * 60,
        idGenerator: @escaping @Sendable () throws -> String = { UUID().uuidString.lowercased() }
    ) throws {
        guard validity > 0 else {
            throw validationFailure("provider_validation.validity_invalid", "validation validity must be positive")
        }
        database = try SQLiteConnection(path: fileURL.path)
        try LLMStoreSchema.migrateToCurrent(database)
        self.profileStore = profileStore
        self.catalogStore = catalogStore
        self.credentialStore = credentialStore
        self.egressPolicy = egressPolicy
        self.transport = transport
        self.hostProcessEpoch = hostProcessEpoch
        self.clock = clock
        self.validity = validity
        self.idGenerator = idGenerator
    }

    public func validate(
        profileID: String,
        profileRevision: UInt64,
        modelID: String,
        adapterVersion: String
    ) async throws -> ProviderValidationResult {
        guard let catalog = try await catalogStore.current() else {
            throw validationFailure(
                "provider_validation.catalog_unavailable",
                "no trusted cloud capability catalog is active"
            )
        }
        guard !profileID.isEmpty, profileRevision > 0, !modelID.isEmpty,
              !adapterVersion.isEmpty,
              let profile = await profileStore.profile(
                  profileID: profileID,
                  revision: profileRevision
              ),
              profile.lifecycle == .active,
              let preset = ProviderPreset.shipped.first(where: {
                  $0.id == profile.revision.presetID
              }),
              preset.id == profile.revision.presetID
        else {
            throw validationFailure("provider_validation.route_invalid", "provider validation route is invalid")
        }
        let state = try requireState(
            await profileStore.state(profileID: profileID, profileRevision: profileRevision)
        )
        let retention = try retentionIdentity(profile: profile, state: state)
        let adapter = try validationAdapter(presetID: preset.id)
        guard adapter.adapterID == preset.semanticAdapterID,
              adapter.adapterVersion == adapterVersion
        else {
            throw validationFailure(
                "provider_validation.adapter_mismatch",
                "validation adapter identity or version is not installed"
            )
        }
        let entry = catalog.entry(presetID: preset.id, modelID: modelID)
        if let entry {
            guard entry.adapterID == preset.semanticAdapterID else {
                throw validationFailure("provider_validation.adapter_mismatch", "provider adapter does not match catalog")
            }
            guard !catalog.isRevoked(entry.identity),
                  entry.supports(adapterVersion: adapterVersion)
            else {
                throw validationFailure("provider_validation.model_unavailable", "catalog model is revoked or adapter-incompatible")
            }
            guard entry.continuationModes.contains(profile.revision.retentionMode) else {
                throw validationFailure(
                    "provider_validation.retention_incompatible",
                    "catalog model cannot use the selected retention mode"
                )
            }
        }

        let originApprovalRevision = try await egressPolicy.approveOrigin(
            profileID: profileID,
            profileRevision: profileRevision
        )
        let lease = try await credentialStore.acquireUseLease(
            credentialRef: profile.revision.credentialRef,
            purpose: .validation,
            preparationID: nil,
            hostProcessEpoch: hostProcessEpoch
        )
        do {
            let result = try await performValidation(
                profile: profile,
                preset: preset,
                adapter: adapter,
                modelID: modelID,
                adapterVersion: adapterVersion,
                catalog: catalog,
                entry: entry,
                retention: retention,
                originApprovalRevision: originApprovalRevision,
                lease: lease
            )
            try await credentialStore.releaseValidationLease(lease.leaseID)
            try await publish(result: result, profile: profile, expectedState: state, lease: lease)
            return result
        } catch {
            try? await credentialStore.releaseValidationLease(lease.leaseID)
            throw error
        }
    }

    package func currentValidation(
        profileID: String,
        profileRevision: UInt64,
        modelID: String,
        adapterVersion: String,
        targetID: LLMTargetID,
        targetRevision: UInt64
    ) async throws -> ProviderValidationResult {
        let now = clock()
        guard !profileID.isEmpty, profileRevision > 0, !modelID.isEmpty,
              !adapterVersion.isEmpty, !targetID.rawValue.isEmpty, targetRevision > 0,
              let profile = await profileStore.profile(
                  profileID: profileID,
                  revision: profileRevision
              ),
              profile.lifecycle == .active,
              let state = await profileStore.state(
                  profileID: profileID,
                  profileRevision: profileRevision
              ),
              case let .validated(evidence) = state.validationState,
              let preset = ProviderPreset.shipped.first(where: {
                  $0.id == profile.revision.presetID
              }),
              preset.semanticAdapterID == evidence.adapterID,
              evidence.modelID == modelID,
              evidence.origin == profile.origin,
              state.catalogRevision == evidence.catalogRevision,
              evidence.adapterVersion == adapterVersion,
              evidence.expiresAt > now,
              evidence.retentionMode == profile.revision.retentionMode,
              evidence.retentionApprovalRevision == state.retentionApprovalRevision,
              evidence.retentionApprovalDigest == state.retentionApprovalDigest,
              let slot = try await credentialStore.slot(profile.revision.credentialRef),
              slot.lifecycle == .active,
              slot.currentGeneration == evidence.credentialGeneration
        else {
            throw validationFailure(
                "provider_validation.current_unavailable",
                "no current exact provider validation is available"
            )
        }
        let catalogEntry: CloudModelCatalogEntry?
        if let catalogRevision = evidence.catalogRevision {
            guard let catalog = try await catalogStore.current(),
                  catalog.catalogRevision == catalogRevision,
                  let entry = catalog.entry(
                      presetID: profile.revision.presetID,
                      modelID: modelID
                  ),
                  !catalog.isRevoked(entry.identity),
                  entry.supports(adapterVersion: adapterVersion),
                  entry.adapterID == evidence.adapterID,
                  entry.continuationModes.contains(profile.revision.retentionMode)
            else {
                throw validationFailure(
                    "provider_validation.current_unavailable",
                    "no current exact provider validation is available"
                )
            }
            catalogEntry = entry
        } else {
            catalogEntry = nil
        }

        let rows = try database.queryRows(
            """
            SELECT validation_id, credential_generation, expires_at,
              record_schema_version, record_json
            FROM provider_validation_records
            WHERE profile_id = ?1 AND profile_revision = ?2 AND model_id = ?3
            """,
            bindings: [
                .text(profileID), .text(String(profileRevision)), .text(modelID),
            ]
        )
        guard rows.count == 1,
              rows[0].integer("record_schema_version") == 2,
              rows[0].text("credential_generation") == String(evidence.credentialGeneration),
              let validationJSON = rows[0].text("record_json"),
              let validation = try? decodeValidation(StoredValidation.self, validationJSON),
              validation.validationID == rows[0].text("validation_id"),
              validation.expiresAt == evidence.expiresAt,
              validation.expiresAt > now,
              validation.evidenceDigest == evidence.evidenceDigest,
              validation.subject.adapterID == evidence.adapterID,
              validation.subject.providerProfileID == profileID,
              validation.subject.providerProfileRevision == profileRevision,
              validation.subject.credentialGeneration == evidence.credentialGeneration,
              validation.subject.llmTargetID == nil,
              validation.subject.llmTargetRevision == nil,
              validation.subject.modelID == modelID,
              validation.subject.catalogRevision == evidence.catalogRevision,
              validation.subject.retentionMode == evidence.retentionMode.rawValue,
              validation.subject.retentionApprovalRevision == evidence.retentionApprovalRevision,
              validation.subject.retentionApprovalDigest == evidence.retentionApprovalDigest
        else {
            throw validationFailure(
                "provider_validation.current_corrupt",
                "current provider validation record is missing or inconsistent"
            )
        }
        if let catalogEntry {
            guard validation.subject.modelRevision == catalogEntry.identity.modelRevision else {
                throw validationFailure(
                    "provider_validation.current_corrupt",
                    "catalog-backed validation model revision is inconsistent"
                )
            }
        } else {
            guard validation.subject.modelRevision == nil else {
                throw validationFailure(
                    "provider_validation.current_corrupt",
                    "manual validation unexpectedly contains a catalog model revision"
                )
            }
        }

        let observationRows = try database.queryRows(
            """
            SELECT observation_digest, credential_generation, expires_at,
              record_schema_version, record_json
            FROM cloud_capability_observations
            WHERE profile_id = ?1 AND profile_revision = ?2 AND model_id = ?3
            ORDER BY observation_digest
            """,
            bindings: [
                .text(profileID), .text(String(profileRevision)), .text(modelID),
            ]
        )
        var observations: [CapabilityObservation] = []
        for row in observationRows {
            guard row.integer("record_schema_version") == 2,
                  row.text("credential_generation") == String(evidence.credentialGeneration),
                  let json = row.text("record_json"),
                  let stored = try? decodeValidation(StoredObservation.self, json),
                  stored.observation.observationDigest == row.text("observation_digest"),
                  validation.observationDigests.contains(stored.observation.observationDigest)
            else {
                throw validationFailure(
                    "provider_validation.current_corrupt",
                    "current capability observation is inconsistent"
                )
            }
            observations.append(stored.observation)
        }
        guard observations.count == validation.observationDigests.count,
              Set(observations.map(\.observationDigest)) == Set(validation.observationDigests)
        else {
            throw validationFailure(
                "provider_validation.current_corrupt",
                "current capability observations are incomplete"
            )
        }

        let persistedSnapshot = CapabilityMatrix.resolve(
            observations: observations,
            subject: validation.subject,
            policy: .cloud,
            now: now
        )
        guard try validationEvidenceDigest(persistedSnapshot) == validation.evidenceDigest else {
            throw validationFailure(
                "provider_validation.current_corrupt",
                "current capability snapshot evidence does not recompute"
            )
        }

        let exactSubject = CapabilitySubject(
            adapterID: validation.subject.adapterID,
            providerProfileID: profileID,
            providerProfileRevision: profileRevision,
            credentialGeneration: evidence.credentialGeneration,
            llmTargetID: targetID,
            llmTargetRevision: targetRevision,
            modelID: modelID,
            modelRevision: validation.subject.modelRevision,
            catalogRevision: validation.subject.catalogRevision,
            retentionMode: profile.revision.retentionMode.rawValue,
            retentionApprovalRevision: state.retentionApprovalRevision,
            retentionApprovalDigest: state.retentionApprovalDigest
        )
        let snapshot = CapabilityMatrix.resolve(
            observations: observations,
            subject: exactSubject,
            policy: .cloud,
            now: now
        )
        return ProviderValidationResult(
            validationID: validation.validationID,
            subject: exactSubject,
            observations: observations,
            snapshot: snapshot,
            evidenceDigest: try validationEvidenceDigest(snapshot),
            expiresAt: validation.expiresAt
        )
    }

    private func performValidation(
        profile: PublishedProviderProfileRevision,
        preset: ProviderPreset,
        adapter: any CloudProviderAdapter,
        modelID: String,
        adapterVersion: String,
        catalog: VerifiedCloudCapabilityCatalog,
        entry: CloudModelCatalogEntry?,
        retention: (revision: UInt64?, digest: String?),
        originApprovalRevision: UInt64,
        lease: CredentialUseLease
    ) async throws -> ProviderValidationResult {
        let discovery = CloudModelDiscoveryService(clock: clock, validity: validity)
        let discoveryRequest = try await egressPolicy.sealValidationRequest(
            try adapter.makeDiscoveryRequest(),
            profileID: profile.revision.profileID,
            profileRevision: profile.revision.revision,
            originApprovalRevision: originApprovalRevision,
            lease: lease,
            requestClass: .discovery
        )
        let discoveryData = try await transport.json(discoveryRequest)
        let liveModelIDs = try discovery.decodeLiveModelIDs(discoveryData, presetID: preset.id)

        let accountRequest = try await egressPolicy.sealValidationRequest(
            try adapter.makeAccountValidationRequest(),
            profileID: profile.revision.profileID,
            profileRevision: profile.revision.revision,
            originApprovalRevision: originApprovalRevision,
            lease: lease,
            requestClass: .accountValidation
        )
        _ = try await transport.json(accountRequest)

        let probeRequest = try await egressPolicy.sealValidationRequest(
            try adapter.makeModelValidationRequest(modelID: modelID),
            profileID: profile.revision.profileID,
            profileRevision: profile.revision.revision,
            originApprovalRevision: originApprovalRevision,
            lease: lease,
            requestClass: .modelValidation
        )
        try await requireCompleteProbe(
            try await transport.stream(probeRequest),
            adapter: adapter,
            profile: profile,
            modelID: modelID,
            retention: retention,
            hostProcessEpoch: hostProcessEpoch
        )

        let now = millisecondDate(clock())
        let expiresAt = now.addingTimeInterval(validity)
        let subject = CloudCapabilityObservationFactory.exactSubject(
            adapterID: preset.semanticAdapterID,
            profileID: profile.revision.profileID,
            profileRevision: profile.revision.revision,
            credentialGeneration: lease.generation,
            modelID: modelID,
            modelRevision: entry?.identity.modelRevision,
            catalogRevision: entry == nil ? nil : catalog.catalogRevision,
            retentionMode: profile.revision.retentionMode,
            retentionApprovalRevision: retention.revision,
            retentionApprovalDigest: retention.digest
        )
        let discovered = try discovery.merge(
            liveModelIDs: liveModelIDs,
            manualModelID: modelID,
            presetID: preset.id,
            adapterID: preset.semanticAdapterID,
            adapterVersion: adapterVersion,
            catalog: catalog,
            routeSubject: subject
        )
        var observations = discovered.first(where: { $0.modelID == modelID })?.observations ?? []
        observations.append(contentsOf: try CloudCapabilityObservationFactory.routineProbeObservations(
            subject: subject,
            adapterVersion: adapterVersion,
            observedAt: now,
            expiresAt: expiresAt
        ))
        var uniqueObservations: [String: CapabilityObservation] = [:]
        for observation in observations {
            uniqueObservations[observation.observationDigest] = observation
        }
        observations = uniqueObservations.values.sorted {
            $0.observationDigest < $1.observationDigest
        }
        let snapshot = CapabilityMatrix.resolve(
            observations: observations,
            subject: subject,
            policy: .cloud,
            now: now
        )
        let validationID = try idGenerator()
        guard !validationID.isEmpty else {
            throw validationFailure("provider_validation.id_invalid", "validation ID is empty")
        }
        let evidenceDigest = try validationEvidenceDigest(
            snapshot
        )
        return ProviderValidationResult(
            validationID: validationID,
            subject: subject,
            observations: observations,
            snapshot: snapshot,
            evidenceDigest: evidenceDigest,
            expiresAt: expiresAt
        )
    }

    private func publish(
        result: ProviderValidationResult,
        profile: PublishedProviderProfileRevision,
        expectedState: ProviderProfileState,
        lease: CredentialUseLease
    ) async throws {
        let validation = StoredValidation(
            validationID: result.validationID,
            subject: result.subject,
            observationDigests: result.observations.map(\.observationDigest).sorted(),
            evidenceDigest: result.evidenceDigest,
            expiresAt: result.expiresAt
        )
        try database.transaction {
                let profileRows = try database.queryRows(
                    """
                    SELECT lifecycle, record_schema_version, record_json
                    FROM provider_profile_revisions
                    WHERE profile_id = ?1 AND revision = ?2
                    """,
                    bindings: [
                        .text(profile.revision.profileID),
                        .text(String(profile.revision.revision)),
                    ]
                )
                guard profileRows.count == 1,
                      profileRows[0].text("lifecycle") == ProviderRevisionLifecycle.active.rawValue,
                      profileRows[0].integer("record_schema_version") == 3,
                      let profileJSON = profileRows[0].text("record_json"),
                      let profileData = profileJSON.data(using: .utf8),
                      try JSONDecoder().decode(
                          PersistedProfileRevision.self,
                          from: profileData
                      ).published == profile
                else {
                    throw validationFailure(
                        "provider_validation.route_changed",
                        "provider profile changed during validation"
                    )
                }
                var updatedState = expectedState
                guard updatedState.stateRevision < UInt64.max else {
                    throw validationFailure(
                        "provider_validation.state_changed",
                        "provider profile state revision overflowed"
                    )
                }
                updatedState.stateRevision += 1
                updatedState.catalogRevision = result.subject.catalogRevision
                updatedState.validationState = .validated(ProviderValidationEvidenceIdentity(
                    modelID: result.subject.modelID ?? "",
                    origin: profile.origin,
                    credentialGeneration: lease.generation,
                    retentionMode: profile.revision.retentionMode,
                    retentionApprovalRevision: result.subject.retentionApprovalRevision,
                    retentionApprovalDigest: result.subject.retentionApprovalDigest,
                    catalogRevision: result.subject.catalogRevision,
                    adapterID: result.subject.adapterID ?? "",
                    adapterVersion: result.observations.first?.adapterOrEngineVersion ?? "",
                    evidenceDigest: result.evidenceDigest,
                    expiresAt: result.expiresAt
                ))
                try database.execute(
                    "DELETE FROM cloud_capability_observations WHERE profile_id = ?1 AND profile_revision = ?2 AND model_id = ?3",
                    bindings: [
                        .text(profile.revision.profileID),
                        .text(String(profile.revision.revision)),
                        .text(result.subject.modelID ?? ""),
                    ]
                )
                for observation in result.observations {
                    try database.execute(
                        """
                        INSERT INTO cloud_capability_observations(
                          observation_digest, profile_id, profile_revision, model_id,
                          credential_generation, expires_at, record_schema_version, record_json
                        ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, 2, ?7)
                        """,
                        bindings: [
                            .text(observation.observationDigest),
                            .text(profile.revision.profileID),
                            .text(String(profile.revision.revision)),
                            .text(result.subject.modelID ?? ""),
                            .text(String(lease.generation)),
                            .text(validationTimestamp(result.expiresAt)),
                            .text(try validationJSON(StoredObservation(observation: observation))),
                        ]
                    )
                }
                try database.execute(
                    "DELETE FROM provider_validation_records WHERE profile_id = ?1 AND profile_revision = ?2 AND model_id = ?3",
                    bindings: [
                        .text(profile.revision.profileID),
                        .text(String(profile.revision.revision)),
                        .text(result.subject.modelID ?? ""),
                    ]
                )
                try database.execute(
                    """
                    INSERT INTO provider_validation_records(
                      validation_id, profile_id, profile_revision, model_id,
                      credential_generation, expires_at, record_schema_version, record_json
                    ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, 2, ?7)
                    """,
                    bindings: [
                        .text(result.validationID),
                        .text(profile.revision.profileID),
                        .text(String(profile.revision.revision)),
                        .text(result.subject.modelID ?? ""),
                        .text(String(lease.generation)),
                        .text(validationTimestamp(result.expiresAt)),
                        .text(try validationJSON(validation)),
                    ]
                )
                let changed = try database.executeChanges(
                    """
                    UPDATE provider_profile_state SET
                      catalog_revision = ?1, state_revision = ?2, record_json = ?3
                    WHERE profile_id = ?4 AND profile_revision = ?5 AND state_revision = ?6
                    """,
                    bindings: [
                        updatedState.catalogRevision.map { .text(String($0)) } ?? .null,
                        .text(String(updatedState.stateRevision)),
                        .text(try profileStateJSON(PersistedProfileState(state: updatedState))),
                        .text(profile.revision.profileID),
                        .text(String(profile.revision.revision)),
                        .text(String(expectedState.stateRevision)),
                    ]
                )
                guard changed == 1 else {
                    throw validationFailure(
                        "provider_validation.state_changed",
                        "provider profile state changed during validation"
                    )
                }
            }
        _ = await profileStore.state(
            profileID: profile.revision.profileID,
            profileRevision: profile.revision.revision
        )
    }

    private func retentionIdentity(
        profile: PublishedProviderProfileRevision,
        state: ProviderProfileState
    ) throws -> (revision: UInt64?, digest: String?) {
        switch profile.revision.retentionMode {
        case .statelessRequired:
            guard state.retentionApprovalRevision == nil, state.retentionApprovalDigest == nil else {
                throw validationFailure("provider_validation.retention_invalid", "stateless profile has retention approval")
            }
            return (nil, nil)
        case .providerStateApproved:
            guard let revision = state.retentionApprovalRevision,
                  let digest = state.retentionApprovalDigest,
                  revision > 0,
                  digest.count == 64
            else {
                throw validationFailure("provider_validation.retention_unapproved", "provider state retention is not approved")
            }
            return (revision, digest)
        }
    }
}

private func requireCompleteProbe(
    _ stream: AsyncThrowingStream<SSEEvent, Error>,
    adapter: any CloudProviderAdapter,
    profile: PublishedProviderProfileRevision,
    modelID: String,
    retention: (revision: UInt64?, digest: String?),
    hostProcessEpoch: HostProcessEpoch
) async throws {
    let session: any CloudProviderSession
    do {
        session = try adapter.makeSession(CloudProviderSessionContext(
            targetID: LLMTargetID(rawValue: "provider-validation"),
            targetRevision: 1,
            providerProfileID: profile.revision.profileID,
            providerProfileRevision: profile.revision.revision,
            modelID: modelID,
            retentionMode: profile.revision.retentionMode,
            retentionApprovalRevision: retention.revision,
            retentionApprovalDigest: retention.digest,
            hostProcessEpoch: hostProcessEpoch
        ))
    } catch {
        throw validationFailure(
            "provider_validation.probe_incomplete",
            "model validation session could not be created"
        )
    }
    var produced = false
    var terminal = false
    do {
        for try await event in session.decode(stream) {
            switch event {
            case .generationStarted, .sessionClosed:
                throw validationFailure(
                    "provider_validation.probe_incomplete",
                    "model validation adapter emitted a host lifecycle event"
                )
            case let .textDelta(text), let .reasoningSummaryDelta(text):
                produced = produced || !text.isEmpty
            case .toolCallStarted, .toolCallArgumentsDelta, .toolCallCompleted:
                produced = true
            case .generationCompleted:
                terminal = true
            case .usageUpdated:
                break
            case .cancelled:
                throw validationFailure(
                    "provider_validation.probe_incomplete",
                    "model validation probe was cancelled"
                )
            case .failed:
                throw validationFailure(
                    "provider_validation.probe_incomplete",
                    "model validation probe failed"
                )
            }
        }
        await session.close()
    } catch {
        await session.close()
        throw validationFailure(
            "provider_validation.probe_incomplete",
            "model validation stream did not pass the installed adapter decoder"
        )
    }
    guard produced, terminal else {
        throw validationFailure(
            "provider_validation.probe_incomplete",
            "model validation stream did not produce content and a normal terminal event"
        )
    }
}

private func validationAdapter(
    presetID: ProviderPresetID
) throws -> any CloudProviderAdapter {
    switch presetID {
    case .openAI: return OpenAIResponsesAdapter()
    case .anthropic: return AnthropicMessagesAdapter()
    case .gemini: return GeminiInteractionsAdapter()
    case .xAI: return XAIAdapter()
    case .deepSeek: return DeepSeekAdapter()
    case .miniMax: return MiniMaxAdapter()
    case .glm: return GLMAdapter()
    default:
        throw validationFailure(
            "provider_validation.adapter_mismatch",
            "provider preset has no installed validation adapter"
        )
    }
}

package func validationEvidenceDigest(
    _ snapshot: CapabilitySnapshot
) throws -> String {
    let capabilities = try CanonicalJSONValue.object(entries: snapshot.capabilities.map {
        .init(name: $0.key, value: try .object(entries: [
            .init(name: "support", value: .string($0.value.support.rawValue)),
            .init(
                name: "verified_upper_bound",
                value: $0.value.verifiedUpperBound.map { .string(String($0)) } ?? .null
            ),
        ]))
    })
    let document = try CanonicalJSONValue.object(entries: [
        .init(name: "schema_version", value: .string("1")),
        .init(name: "subject", value: try CloudCapabilityObservationFactory.subjectDocument(snapshot.subject)),
        .init(name: "capabilities", value: capabilities),
        .init(name: "contributing_observation_digests", value: .array(
            snapshot.contributingObservationDigests.map(CanonicalJSONValue.string)
        )),
        .init(
            name: "nearest_expiry",
            value: snapshot.nearestExpiry.map {
                .string(validationTimestamp($0))
            } ?? .null
        ),
    ])
    return try CanonicalDigestV1.digest(
        domain: "capability-snapshot:v1",
        document: document
    ).hex
}

private func validationJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

private func decodeValidation<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    guard let data = json.data(using: .utf8) else {
        throw validationFailure("provider_validation.current_corrupt", "validation record is not UTF-8")
    }
    return try decoder.decode(type, from: data)
}

private func profileStateJSON<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
}

private func validationTimestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
}

private func requireState(_ state: ProviderProfileState?) throws -> ProviderProfileState {
    guard let state else {
        throw validationFailure("provider_validation.route_invalid", "provider profile state is missing")
    }
    return state
}

private func validationFailure(_ code: String, _ message: String) -> LLMFailure {
    LLMFailure(code: code, message: message, retryable: false)
}
