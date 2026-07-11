import Foundation
import LocalAgentLLMContracts

package struct SignedLocalModelCatalogPayload: Codable, Equatable, Sendable {
    package let schemaVersion: String
    package let keyID: String
    package let catalogRevision: UInt64
    package let models: [LocalModelRevisionManifest]
    package let revokedModelRevisions: [LocalModelRevisionID]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", keyID = "key_id"
        case catalogRevision = "catalog_revision", models
        case revokedModelRevisions = "revoked_model_revisions"
    }

    init(
        schemaVersion: String,
        keyID: String,
        catalogRevision: UInt64,
        models: [LocalModelRevisionManifest],
        revokedModelRevisions: [LocalModelRevisionID]
    ) {
        self.schemaVersion = schemaVersion
        self.keyID = keyID
        self.catalogRevision = catalogRevision
        self.models = models
        self.revokedModelRevisions = revokedModelRevisions
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        keyID = try container.decode(String.self, forKey: .keyID)
        catalogRevision = try container.decodeUnsignedDecimal(forKey: .catalogRevision)
        models = try container.decode([LocalModelRevisionManifest].self, forKey: .models)
        revokedModelRevisions = try container.decode([LocalModelRevisionID].self, forKey: .revokedModelRevisions)
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(keyID, forKey: .keyID)
        try container.encode(String(catalogRevision), forKey: .catalogRevision)
        try container.encode(models, forKey: .models)
        try container.encode(revokedModelRevisions, forKey: .revokedModelRevisions)
    }
}

package enum LocalModelCatalogCanonicalDocument {
    package static func canonicalSignedBytes(from payload: SignedLocalModelCatalogPayload) throws -> Data {
        let encoded = try JSONEncoder().encode(payload)
        let value = try JSONDecoder().decode(CanonicalJSONValue.self, from: encoded)
        return try CanonicalDigestV1.canonicalize(value)
    }
}

private extension KeyedDecodingContainer {
    func decodeUnsignedDecimal(forKey key: Key) throws -> UInt64 {
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
