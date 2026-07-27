import CryptoKit
import Foundation
import LocalAgentLLMContracts
import LocalAgentLLMCore

package struct CloudModelCatalogIdentity: Codable, Hashable, Sendable {
    package let presetID: ProviderPresetID
    package let modelID: String
    package let modelRevision: String

    enum CodingKeys: String, CodingKey {
        case presetID = "preset_id"
        case modelID = "model_id"
        case modelRevision = "model_revision"
    }

    package init(presetID: ProviderPresetID, modelID: String, modelRevision: String) {
        self.presetID = presetID
        self.modelID = modelID
        self.modelRevision = modelRevision
    }
}

package struct CloudCatalogCapabilityDeclaration: Codable, Equatable, Sendable {
    package let capabilityID: String
    package let value: CapabilityValue

    enum CodingKeys: String, CodingKey {
        case capabilityID = "capability_id"
        case value
    }

    package init(capabilityID: String, value: CapabilityValue) {
        self.capabilityID = capabilityID
        self.value = value
    }
}

package struct CloudCatalogParameterDefinition: Codable, Equatable, Sendable {
    package let id: String
    package let valueType: LLMParameterValueType
    package let support: SupportState
    package let minimum: Double?
    package let maximum: Double?
    package let choices: [String]
    package let mutuallyExclusiveWith: [String]
    package let disabledWhenID: String?
    package let disabledWhenValue: LLMParameterValue?

    enum CodingKeys: String, CodingKey {
        case id
        case valueType = "value_type"
        case support, minimum, maximum, choices
        case mutuallyExclusiveWith = "mutually_exclusive_with"
        case disabledWhenID = "disabled_when_id"
        case disabledWhenValue = "disabled_when_value"
    }

    package init(
        id: LLMParameterID,
        valueType: LLMParameterValueType,
        support: SupportState = .supported,
        minimum: Double? = nil,
        maximum: Double? = nil,
        choices: [String] = [],
        mutuallyExclusiveWith: [LLMParameterID] = [],
        disabledWhenID: LLMParameterID? = nil,
        disabledWhenValue: LLMParameterValue? = nil
    ) {
        self.id = id.rawValue
        self.valueType = valueType
        self.support = support
        self.minimum = minimum
        self.maximum = maximum
        self.choices = choices
        self.mutuallyExclusiveWith = mutuallyExclusiveWith.map(\.rawValue)
        self.disabledWhenID = disabledWhenID?.rawValue
        self.disabledWhenValue = disabledWhenValue
    }

    package func coreDefinition() -> LLMParameterDefinition {
        LLMParameterDefinition(
            id: LLMParameterID(rawValue: id),
            valueType: valueType,
            support: support,
            minimum: minimum,
            maximum: maximum,
            choices: Set(choices),
            mutuallyExclusiveWith: Set(mutuallyExclusiveWith.map(LLMParameterID.init(rawValue:))),
            disabledWhen: disabledWhenID.flatMap { identifier in
                disabledWhenValue.map {
                    .equals(LLMParameterID(rawValue: identifier), $0)
                }
            }
        )
    }
}

package struct CloudModelCatalogEntry: Codable, Equatable, Sendable {
    package let identity: CloudModelCatalogIdentity
    package let adapterID: String
    package let minimumAdapterVersion: UInt64
    package let maximumAdapterVersion: UInt64
    package let capabilities: [CloudCatalogCapabilityDeclaration]
    package let parameterDefinitions: [CloudCatalogParameterDefinition]
    package let parameterDefaults: GenerationConfiguration
    package let continuationModes: [ProviderRetentionMode]

    enum CodingKeys: String, CodingKey {
        case identity
        case adapterID = "adapter_id"
        case minimumAdapterVersion = "minimum_adapter_version"
        case maximumAdapterVersion = "maximum_adapter_version"
        case capabilities
        case parameterDefinitions = "parameter_definitions"
        case parameterDefaults = "parameter_defaults"
        case continuationModes = "continuation_modes"
    }

    package init(
        identity: CloudModelCatalogIdentity,
        adapterID: String,
        minimumAdapterVersion: UInt64,
        maximumAdapterVersion: UInt64,
        capabilities: [CloudCatalogCapabilityDeclaration],
        parameterDefinitions: [CloudCatalogParameterDefinition],
        parameterDefaults: GenerationConfiguration,
        continuationModes: [ProviderRetentionMode]
    ) {
        self.identity = identity
        self.adapterID = adapterID
        self.minimumAdapterVersion = minimumAdapterVersion
        self.maximumAdapterVersion = maximumAdapterVersion
        self.capabilities = capabilities
        self.parameterDefinitions = parameterDefinitions
        self.parameterDefaults = parameterDefaults
        self.continuationModes = continuationModes
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identity = try container.decode(CloudModelCatalogIdentity.self, forKey: .identity)
        adapterID = try container.decode(String.self, forKey: .adapterID)
        minimumAdapterVersion = try container.decodeCanonicalUInt64(forKey: .minimumAdapterVersion)
        maximumAdapterVersion = try container.decodeCanonicalUInt64(forKey: .maximumAdapterVersion)
        capabilities = try container.decode([CloudCatalogCapabilityDeclaration].self, forKey: .capabilities)
        parameterDefinitions = try container.decode(
            [CloudCatalogParameterDefinition].self,
            forKey: .parameterDefinitions
        )
        parameterDefaults = try container.decode(GenerationConfiguration.self, forKey: .parameterDefaults)
        continuationModes = try container.decode([ProviderRetentionMode].self, forKey: .continuationModes)
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(identity, forKey: .identity)
        try container.encode(adapterID, forKey: .adapterID)
        try container.encode(String(minimumAdapterVersion), forKey: .minimumAdapterVersion)
        try container.encode(String(maximumAdapterVersion), forKey: .maximumAdapterVersion)
        try container.encode(capabilities, forKey: .capabilities)
        try container.encode(parameterDefinitions, forKey: .parameterDefinitions)
        try container.encode(parameterDefaults, forKey: .parameterDefaults)
        try container.encode(continuationModes, forKey: .continuationModes)
    }

    package var parameterSchema: LLMParameterSchema {
        LLMParameterSchema(definitions: parameterDefinitions.map { $0.coreDefinition() })
    }

    package func supports(adapterVersion: String) -> Bool {
        guard let value = UInt64(adapterVersion) else { return false }
        return minimumAdapterVersion...maximumAdapterVersion ~= value
    }
}

package struct SignedCloudCapabilityCatalogPayload: Codable, Equatable, Sendable {
    package let schemaVersion: String
    package let keyID: String
    package let catalogRevision: UInt64
    package let models: [CloudModelCatalogEntry]
    package let revokedModels: [CloudModelCatalogIdentity]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case keyID = "key_id"
        case catalogRevision = "catalog_revision"
        case models
        case revokedModels = "revoked_models"
    }

    package init(
        schemaVersion: String = "1",
        keyID: String,
        catalogRevision: UInt64,
        models: [CloudModelCatalogEntry],
        revokedModels: [CloudModelCatalogIdentity]
    ) {
        self.schemaVersion = schemaVersion
        self.keyID = keyID
        self.catalogRevision = catalogRevision
        self.models = models
        self.revokedModels = revokedModels
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        keyID = try container.decode(String.self, forKey: .keyID)
        catalogRevision = try container.decodeCanonicalUInt64(forKey: .catalogRevision)
        models = try container.decode([CloudModelCatalogEntry].self, forKey: .models)
        revokedModels = try container.decode([CloudModelCatalogIdentity].self, forKey: .revokedModels)
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(keyID, forKey: .keyID)
        try container.encode(String(catalogRevision), forKey: .catalogRevision)
        try container.encode(models, forKey: .models)
        try container.encode(revokedModels, forKey: .revokedModels)
    }
}

package struct VerifiedCloudCapabilityCatalog: Equatable, Sendable {
    package let catalogRevision: UInt64
    package let keyID: String
    package let models: [CloudModelCatalogIdentity: CloudModelCatalogEntry]
    package let revokedModels: Set<CloudModelCatalogIdentity>
    package let canonicalSignedBytes: Data
    package let signature: Data

    package func entry(
        presetID: ProviderPresetID,
        modelID: String
    ) -> CloudModelCatalogEntry? {
        models.values.first { entry in
            entry.identity.presetID == presetID && entry.identity.modelID == modelID
        }
    }

    package func isRevoked(_ identity: CloudModelCatalogIdentity) -> Bool {
        revokedModels.contains(identity)
    }
}

package struct CloudCapabilityCatalogResourceSet: Sendable {
    package let envelope: Data
    package let keyRing: Data
}

package enum CloudCapabilityCatalogResources {
    package static func loadBundled() throws -> CloudCapabilityCatalogResourceSet {
        guard let envelope = Bundle.module.url(
            forResource: "OfficialCloudCapabilityCatalog.v1",
            withExtension: "json"
        ), let keys = Bundle.module.url(
            forResource: "OfficialCloudCapabilityCatalogKeys.v1",
            withExtension: "json"
        ) else {
            throw cloudCatalogFailure("cloud_catalog.resources_missing", "bundled cloud catalog is missing")
        }
        return try CloudCapabilityCatalogResourceSet(
            envelope: Data(contentsOf: envelope),
            keyRing: Data(contentsOf: keys)
        )
    }
}

package enum CloudCapabilityCatalogVerifier {
    package static func canonicalSignedBytes(
        _ payload: SignedCloudCapabilityCatalogPayload
    ) throws -> Data {
        let encoded = try JSONEncoder().encode(payload)
        let value = try JSONDecoder().decode(CanonicalJSONValue.self, from: encoded)
        return try CanonicalDigestV1.canonicalize(value)
    }

    package static func verify(
        envelope: Data,
        keyRing: Data
    ) throws -> VerifiedCloudCapabilityCatalog {
        let decodedEnvelope: CloudCatalogEnvelope
        let decodedKeys: CloudCatalogKeyRing
        let rawEnvelope: CanonicalJSONValue
        let rawKeyRing: CanonicalJSONValue
        do {
            decodedEnvelope = try JSONDecoder().decode(CloudCatalogEnvelope.self, from: envelope)
            decodedKeys = try JSONDecoder().decode(CloudCatalogKeyRing.self, from: keyRing)
            rawEnvelope = try JSONDecoder().decode(CanonicalJSONValue.self, from: envelope)
            rawKeyRing = try JSONDecoder().decode(CanonicalJSONValue.self, from: keyRing)
        } catch {
            throw cloudCatalogFailure("cloud_catalog.manifest_invalid", "cloud catalog JSON is invalid")
        }
        guard rawEnvelope.objectKeys == ["signed", "signature"],
              let rawSigned = rawEnvelope.objectValue(forKey: "signed"),
              decodedEnvelope.signed.schemaVersion == "1",
              decodedKeys.schemaVersion == "1"
        else {
            throw cloudCatalogFailure("cloud_catalog.schema_unsupported", "cloud catalog schema is unsupported")
        }
        guard rawKeyRing.objectKeys == ["schema_version", "keys"],
              case let .array(rawKeys)? = rawKeyRing.objectValue(forKey: "keys"),
              rawKeys.allSatisfy({ $0.objectKeys == ["key_id", "public_key", "status"] }),
              !decodedKeys.keys.isEmpty,
              Set(decodedKeys.keys.map(\.keyID)).count == decodedKeys.keys.count,
              decodedKeys.keys.allSatisfy({ !$0.keyID.isEmpty && !$0.publicKey.isEmpty })
        else {
            throw cloudCatalogFailure("cloud_catalog.key_ring_invalid", "cloud catalog key ring is invalid")
        }
        guard let key = decodedKeys.keys.first(where: {
            $0.keyID == decodedEnvelope.signed.keyID
        }) else {
            throw cloudCatalogFailure("cloud_catalog.key_unknown", "cloud catalog signing key is unknown")
        }
        guard key.status == .active else {
            throw cloudCatalogFailure("cloud_catalog.key_revoked", "cloud catalog signing key is revoked")
        }
        let canonical = try canonicalSignedBytes(decodedEnvelope.signed)
        guard canonical == (try CanonicalDigestV1.canonicalize(rawSigned)) else {
            throw cloudCatalogFailure("cloud_catalog.manifest_invalid", "cloud catalog contains unknown signed fields")
        }
        let signature: Data
        let publicKey: Curve25519.Signing.PublicKey
        do {
            signature = try CloudBase64URL.decode(decodedEnvelope.signature, expectedCount: 64)
            publicKey = try Curve25519.Signing.PublicKey(
                rawRepresentation: CloudBase64URL.decode(key.publicKey, expectedCount: 32)
            )
        } catch {
            throw cloudCatalogFailure("cloud_catalog.signature_invalid", "cloud catalog signature material is invalid")
        }
        guard publicKey.isValidSignature(signature, for: canonical) else {
            throw cloudCatalogFailure("cloud_catalog.signature_invalid", "cloud catalog signature is invalid")
        }
        try validate(decodedEnvelope.signed)
        return VerifiedCloudCapabilityCatalog(
            catalogRevision: decodedEnvelope.signed.catalogRevision,
            keyID: decodedEnvelope.signed.keyID,
            models: Dictionary(uniqueKeysWithValues: decodedEnvelope.signed.models.map {
                ($0.identity, $0)
            }),
            revokedModels: Set(decodedEnvelope.signed.revokedModels),
            canonicalSignedBytes: canonical,
            signature: signature
        )
    }

    private static func validate(_ payload: SignedCloudCapabilityCatalogPayload) throws {
        guard payload.catalogRevision > 0,
              !payload.keyID.isEmpty,
              !payload.models.isEmpty,
              Set(payload.models.map(\.identity)).count == payload.models.count,
              Set(payload.models.map {
                  CloudCatalogModelRoute(
                      presetID: $0.identity.presetID,
                      modelID: $0.identity.modelID
                  )
              }).count == payload.models.count,
              Set(payload.revokedModels).count == payload.revokedModels.count
        else {
            throw cloudCatalogFailure("cloud_catalog.manifest_invalid", "cloud catalog identity list is invalid")
        }
        let shipped = Dictionary(uniqueKeysWithValues: ProviderPreset.shipped.map { ($0.id, $0) })
        guard payload.revokedModels.allSatisfy({ identity in
            shipped[identity.presetID] != nil
                && !identity.modelID.isEmpty
                && !identity.modelRevision.isEmpty
        }) else {
            throw cloudCatalogFailure("cloud_catalog.manifest_invalid", "cloud model revocation is invalid")
        }
        for model in payload.models {
            guard let preset = shipped[model.identity.presetID],
                  preset.semanticAdapterID == model.adapterID,
                  !model.identity.modelID.isEmpty,
                  !model.identity.modelRevision.isEmpty,
                  model.minimumAdapterVersion > 0,
                  model.minimumAdapterVersion <= model.maximumAdapterVersion,
                  !model.capabilities.isEmpty,
                  Set(model.capabilities.map(\.capabilityID)).count == model.capabilities.count,
                  model.capabilities.allSatisfy({ declaration in
                      guard !declaration.capabilityID.isEmpty else { return false }
                      if case let .verifiedUpperBound(value) = declaration.value {
                          return value > 0
                      }
                      return true
                  }),
                  Set(model.parameterDefinitions.map(\.id)).count == model.parameterDefinitions.count,
                  !model.continuationModes.isEmpty,
                  Set(model.continuationModes).count == model.continuationModes.count
            else {
                throw cloudCatalogFailure("cloud_catalog.manifest_invalid", "cloud model declaration is invalid")
            }
            let definitions = Dictionary(
                uniqueKeysWithValues: model.parameterDefinitions.map { ($0.id, $0) }
            )
            for definition in model.parameterDefinitions {
                let rangeIsOrdered = definition.minimum.map { minimum in
                    definition.maximum.map { minimum <= $0 } ?? true
                } ?? true
                let disabledTargetIsValid = definition.disabledWhenID.map { target in
                    target != definition.id && definitions[target] != nil
                } ?? true
                guard definition.choices == definition.choices.sorted(),
                      Set(definition.choices).count == definition.choices.count,
                      definition.mutuallyExclusiveWith == definition.mutuallyExclusiveWith.sorted(),
                      Set(definition.mutuallyExclusiveWith).count == definition.mutuallyExclusiveWith.count,
                      (definition.disabledWhenID == nil) == (definition.disabledWhenValue == nil),
                      rangeIsOrdered,
                      definition.valueType == .text || definition.choices.isEmpty,
                      !definition.mutuallyExclusiveWith.contains(definition.id),
                      definition.mutuallyExclusiveWith.allSatisfy({ other in
                          definitions[other]?.mutuallyExclusiveWith.contains(definition.id) == true
                      }),
                      disabledTargetIsValid
                else {
                    throw cloudCatalogFailure("cloud_catalog.manifest_invalid", "cloud parameter schema is non-canonical")
                }
            }
            do {
                try CloudGenerationConfigurationResolver.validateCatalogEntry(model)
            } catch {
                throw cloudCatalogFailure(
                    "cloud_catalog.manifest_invalid",
                    "cloud parameter declaration is incompatible with its adapter"
                )
            }
        }
    }
}

package enum CloudBase64URL {
    package static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    package static func decode(_ value: String, expectedCount: Int) throws -> Data {
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy({
                  ("A"..."Z").contains(String($0))
                      || ("a"..."z").contains(String($0))
                      || ("0"..."9").contains(String($0))
                      || $0 == "-" || $0 == "_"
              })
        else {
            throw cloudCatalogFailure("cloud_catalog.signature_invalid", "base64url value is invalid")
        }
        let padding = String(repeating: "=", count: (4 - value.count % 4) % 4)
        let standard = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            + padding
        guard let decoded = Data(base64Encoded: standard), decoded.count == expectedCount else {
            throw cloudCatalogFailure("cloud_catalog.signature_invalid", "base64url value has an invalid length")
        }
        return decoded
    }
}

package actor CloudCapabilityCatalogStore {
    private struct Stored: Codable {
        let recordSchemaVersion: Int
        let envelope: Data
        let acceptedAt: Date

        enum CodingKeys: String, CodingKey {
            case recordSchemaVersion = "record_schema_version"
            case envelope, acceptedAt = "accepted_at"
        }
    }

    private struct ValidationRecordProjection: Codable {
        let recordSchemaVersion: Int
        let subject: CapabilitySubject

        enum CodingKeys: String, CodingKey {
            case recordSchemaVersion = "record_schema_version"
            case subject
        }
    }

    private let database: SQLiteConnection
    private let trustedKeyRing: Data

    package init(fileURL: URL, trustedKeyRing: Data? = nil) throws {
        database = try SQLiteConnection(path: fileURL.path)
        try LLMStoreSchema.migrateToCurrent(database)
        self.trustedKeyRing = try trustedKeyRing
            ?? CloudCapabilityCatalogResources.loadBundled().keyRing
    }

    @discardableResult
    package func accept(envelope: Data) throws -> VerifiedCloudCapabilityCatalog {
        let candidate = try CloudCapabilityCatalogVerifier.verify(
            envelope: envelope,
            keyRing: trustedKeyRing
        )
        return try database.transaction {
            let current = try readStored()
            if let current {
                let verified = try CloudCapabilityCatalogVerifier.verify(
                    envelope: current.envelope,
                    keyRing: trustedKeyRing
                )
                if candidate.catalogRevision < verified.catalogRevision {
                    throw cloudCatalogFailure("cloud_catalog.revision_rollback", "cloud catalog revision rolled back")
                }
                if candidate.catalogRevision == verified.catalogRevision {
                    guard candidate.canonicalSignedBytes == verified.canonicalSignedBytes,
                          candidate.signature == verified.signature,
                          candidate.keyID == verified.keyID
                    else {
                        throw cloudCatalogFailure("cloud_catalog.revision_conflict", "equal cloud catalog revision changed")
                    }
                    return verified
                }
            }
            let stored = Stored(
                recordSchemaVersion: 2,
                envelope: envelope,
                acceptedAt: Date()
            )
            let json = String(decoding: try JSONEncoder().encode(stored), as: UTF8.self)
            let digest = SHA256.hash(data: candidate.canonicalSignedBytes)
                .map { String(format: "%02x", $0) }.joined()
            try database.execute(
                """
                INSERT INTO cloud_catalog_state(
                  catalog_id, catalog_revision, key_id, payload_digest,
                  record_schema_version, record_json
                ) VALUES ('official', ?1, ?2, ?3, 2, ?4)
                ON CONFLICT(catalog_id) DO UPDATE SET
                  catalog_revision = excluded.catalog_revision,
                  key_id = excluded.key_id,
                  payload_digest = excluded.payload_digest,
                  record_json = excluded.record_json
                """,
                bindings: [
                    .text(String(candidate.catalogRevision)), .text(candidate.keyID),
                    .text(digest), .text(json),
                ]
            )
            if current != nil {
                try invalidateValidationStateForCatalogAdvance()
            }
            return candidate
        }
    }

    package func current() throws -> VerifiedCloudCapabilityCatalog? {
        guard let stored = try readStored() else { return nil }
        return try CloudCapabilityCatalogVerifier.verify(
            envelope: stored.envelope,
            keyRing: trustedKeyRing
        )
    }

    package func modelEntries(
        presetID: ProviderPresetID
    ) throws -> [CloudModelCatalogEntry] {
        guard let catalog = try current() else { return [] }
        return catalog.models.values
            .filter { $0.identity.presetID == presetID && !catalog.isRevoked($0.identity) }
            .sorted { $0.identity.modelID < $1.identity.modelID }
    }

    private func readStored() throws -> Stored? {
        let rows = try database.queryRows(
            "SELECT record_schema_version, record_json FROM cloud_catalog_state WHERE catalog_id = 'official'"
        )
        guard let row = rows.first else { return nil }
        guard rows.count == 1,
              row.integer("record_schema_version") == 2,
              let json = row.text("record_json"),
              let data = json.data(using: .utf8)
        else {
            throw cloudCatalogFailure("cloud_catalog.persisted_corrupt", "persisted cloud catalog is corrupt")
        }
        let value = try JSONDecoder().decode(Stored.self, from: data)
        guard value.recordSchemaVersion == 2 else {
            throw cloudCatalogFailure("cloud_catalog.persisted_corrupt", "persisted cloud catalog schema is invalid")
        }
        return value
    }

    private func invalidateValidationStateForCatalogAdvance() throws {
        let rows = try database.queryRows(
            """
            SELECT profile_id, profile_revision, catalog_revision, state_revision,
              record_schema_version, record_json
            FROM provider_profile_state
            WHERE catalog_revision IS NOT NULL
            """
        )
        for row in rows {
            guard row.integer("record_schema_version") == 2,
                  let profileID = row.text("profile_id"),
                  let profileRevision = row.text("profile_revision"),
                  let catalogRevision = row.text("catalog_revision"),
                  let stateRevision = row.text("state_revision"),
                  let json = row.text("record_json"),
                  let data = json.data(using: .utf8)
            else {
                throw cloudCatalogFailure(
                    "cloud_catalog.persisted_corrupt",
                    "provider validation state is corrupt"
                )
            }
            var persisted = try JSONDecoder().decode(PersistedProfileState.self, from: data)
            guard persisted.state.profileID == profileID,
                  String(persisted.state.profileRevision) == profileRevision,
                  persisted.state.catalogRevision.map(String.init) == catalogRevision,
                  String(persisted.state.stateRevision) == stateRevision,
                  persisted.state.stateRevision < UInt64.max,
                  case let .validated(evidence) = persisted.state.validationState,
                  evidence.catalogRevision.map(String.init) == catalogRevision,
                  !evidence.modelID.isEmpty
            else {
                throw cloudCatalogFailure(
                    "cloud_catalog.persisted_corrupt",
                    "provider validation state index is corrupt"
                )
            }
            persisted.state.validationState = .invalidated(
                reasonCode: "cloud_catalog.revision_changed"
            )
            persisted.state.catalogRevision = nil
            persisted.state.stateRevision += 1
            let changed = try database.executeChanges(
                """
                UPDATE provider_profile_state SET catalog_revision = NULL,
                  state_revision = ?1, record_json = ?2
                WHERE profile_id = ?3 AND profile_revision = ?4 AND state_revision = ?5
                """,
                bindings: [
                    .text(String(persisted.state.stateRevision)),
                    .text(String(decoding: try JSONEncoder().encode(persisted), as: UTF8.self)),
                    .text(profileID), .text(profileRevision), .text(stateRevision),
                ]
            )
            guard changed == 1 else {
                throw cloudCatalogFailure(
                    "cloud_catalog.state_conflict",
                    "provider validation state changed during catalog acceptance"
                )
            }
        }

        let validationRows = try database.queryRows(
            """
            SELECT profile_id, profile_revision, model_id,
              record_schema_version, record_json
            FROM provider_validation_records
            """
        )
        for row in validationRows {
            guard row.integer("record_schema_version") == 2,
                  let profileID = row.text("profile_id"),
                  let profileRevision = row.text("profile_revision"),
                  let modelID = row.text("model_id"),
                  let json = row.text("record_json"),
                  let data = json.data(using: .utf8),
                  let validation = try? JSONDecoder().decode(
                      ValidationRecordProjection.self,
                      from: data
                  ),
                  validation.recordSchemaVersion == 2,
                  validation.subject.providerProfileID == profileID,
                  validation.subject.providerProfileRevision.map(String.init) == profileRevision,
                  validation.subject.modelID == modelID
            else {
                throw cloudCatalogFailure(
                    "cloud_catalog.persisted_corrupt",
                    "provider validation record index is corrupt"
                )
            }
            guard validation.subject.catalogRevision != nil else { continue }
            let bindings: [SQLiteValue] = [
                .text(profileID), .text(profileRevision), .text(modelID),
            ]
            try database.execute(
                "DELETE FROM cloud_capability_observations WHERE profile_id = ?1 AND profile_revision = ?2 AND model_id = ?3",
                bindings: bindings
            )
            try database.execute(
                "DELETE FROM provider_validation_records WHERE profile_id = ?1 AND profile_revision = ?2 AND model_id = ?3",
                bindings: bindings
            )
        }
    }
}

private struct CloudCatalogEnvelope: Codable {
    let signed: SignedCloudCapabilityCatalogPayload
    let signature: String
}

private struct CloudCatalogModelRoute: Hashable {
    let presetID: ProviderPresetID
    let modelID: String
}

private struct CloudCatalogKeyRing: Codable {
    let schemaVersion: String
    let keys: [CloudCatalogKey]
    enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", keys }
}

private struct CloudCatalogKey: Codable {
    enum Status: String, Codable { case active, revoked }
    let keyID: String
    let publicKey: String
    let status: Status
    enum CodingKeys: String, CodingKey {
        case keyID = "key_id", publicKey = "public_key", status
    }
}

private extension KeyedDecodingContainer {
    func decodeCanonicalUInt64(forKey key: Key) throws -> UInt64 {
        let raw = try decode(String.self, forKey: key)
        guard !raw.isEmpty,
              raw == "0" || raw.first != "0",
              raw.allSatisfy(\.isNumber),
              let value = UInt64(raw)
        else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: self,
                debugDescription: "expected canonical UInt64 decimal string"
            )
        }
        return value
    }
}

private func cloudCatalogFailure(_ code: String, _ message: String) -> LLMFailure {
    LLMFailure(code: code, message: message, retryable: false)
}
