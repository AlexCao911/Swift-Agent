import CryptoKit
import Foundation
import LocalAgentLLMContracts

public struct VerifiedLocalModelCatalog: Equatable, Sendable {
    public let catalogRevision: UInt64
    public let keyID: String
    public let models: [LocalModelRevisionID: LocalModelRevisionManifest]
    public let revokedModelRevisions: Set<LocalModelRevisionID>
    package let canonicalSignedBytes: Data
    package let signature: Data

    fileprivate init(
        catalogRevision: UInt64,
        keyID: String,
        models: [LocalModelRevisionID: LocalModelRevisionManifest],
        revokedModelRevisions: Set<LocalModelRevisionID>,
        canonicalSignedBytes: Data,
        signature: Data
    ) {
        self.catalogRevision = catalogRevision
        self.keyID = keyID
        self.models = models
        self.revokedModelRevisions = revokedModelRevisions
        self.canonicalSignedBytes = canonicalSignedBytes
        self.signature = signature
    }

    public func disposition(for id: LocalModelRevisionID) -> LocalModelCatalogDisposition {
        if revokedModelRevisions.contains(id) { return .revoked }
        if models[id] != nil { return .available }
        return .supersededOrUnknown
    }
}

public enum LocalModelCatalogDisposition: Equatable, Sendable {
    case available
    case revoked
    case supersededOrUnknown
}

public struct OfficialModelCatalogResourceSet: Sendable {
    public let envelope: Data
    public let keyRing: Data
}

public enum OfficialModelCatalogResources {
    public static func loadBundled() throws -> OfficialModelCatalogResourceSet {
        guard let envelopeURL = Bundle.module.url(
            forResource: "OfficialLocalModelCatalog.v1",
            withExtension: "json"
        ), let keysURL = Bundle.module.url(
            forResource: "OfficialLocalModelCatalogKeys.v1",
            withExtension: "json"
        ) else {
            throw failure("download.catalog_manifest_invalid", "bundled catalog resources are missing")
        }
        return try OfficialModelCatalogResourceSet(
            envelope: Data(contentsOf: envelopeURL),
            keyRing: Data(contentsOf: keysURL)
        )
    }
}

public enum OfficialLocalModelCatalogVerifier {
    public static func verify(envelope: Data, keyRing: Data) throws -> VerifiedLocalModelCatalog {
        let decodedEnvelope: CatalogEnvelope
        let decodedKeyRing: CatalogKeyRing
        let rawEnvelope: CanonicalJSONValue
        do {
            decodedEnvelope = try strictDecoder.decode(CatalogEnvelope.self, from: envelope)
            decodedKeyRing = try strictDecoder.decode(CatalogKeyRing.self, from: keyRing)
            rawEnvelope = try strictDecoder.decode(CanonicalJSONValue.self, from: envelope)
        } catch {
            throw failure("download.catalog_manifest_invalid", "catalog JSON is invalid")
        }
        guard rawEnvelope.objectKeys == ["signed", "signature"],
              let rawSigned = rawEnvelope.objectValue(forKey: "signed")
        else {
            throw failure("download.catalog_manifest_invalid", "catalog envelope shape is invalid")
        }

        guard decodedEnvelope.signed.schemaVersion == "1",
              decodedKeyRing.schemaVersion == "1"
        else {
            throw failure("download.catalog_schema_unsupported", "catalog schema version is unsupported")
        }
        guard !decodedKeyRing.keys.isEmpty,
              decodedKeyRing.keys.allSatisfy({ !$0.keyID.isEmpty }),
              Set(decodedKeyRing.keys.map(\.keyID)).count == decodedKeyRing.keys.count
        else {
            throw failure("download.catalog_manifest_invalid", "catalog key ring is invalid")
        }
        guard let key = decodedKeyRing.keys.first(where: { $0.keyID == decodedEnvelope.signed.keyID }) else {
            throw failure("download.catalog_key_unknown", "catalog signing key is unknown")
        }
        guard key.status == .active else {
            throw failure("download.catalog_key_revoked", "catalog signing key is revoked")
        }

        let signature: Data
        let publicKey: Curve25519.Signing.PublicKey
        let canonical: Data
        do {
            signature = try Base64URL.decode(decodedEnvelope.signature, expectedCount: 64)
            let publicKeyData = try Base64URL.decode(key.publicKey, expectedCount: 32)
            publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
            canonical = try LocalModelCatalogCanonicalDocument.canonicalSignedBytes(from: decodedEnvelope.signed)
            guard canonical == (try CanonicalDigestV1.canonicalize(rawSigned)) else {
                throw failure(
                    "download.catalog_manifest_invalid",
                    "catalog signed document contains unsupported or non-canonical fields"
                )
            }
        } catch let failure as LLMFailure {
            throw failure
        } catch {
            throw failure("download.catalog_signature_invalid", "catalog signature material is invalid")
        }
        guard publicKey.isValidSignature(signature, for: canonical) else {
            throw failure("download.catalog_signature_invalid", "catalog signature is invalid")
        }

        try validate(decodedEnvelope.signed)
        let models = Dictionary(uniqueKeysWithValues: decodedEnvelope.signed.models.map { ($0.id, $0) })
        return VerifiedLocalModelCatalog(
            catalogRevision: decodedEnvelope.signed.catalogRevision,
            keyID: decodedEnvelope.signed.keyID,
            models: models,
            revokedModelRevisions: Set(decodedEnvelope.signed.revokedModelRevisions),
            canonicalSignedBytes: canonical,
            signature: signature
        )
    }

    private static func validate(_ payload: SignedLocalModelCatalogPayload) throws {
        guard payload.catalogRevision > 0,
              !payload.keyID.isEmpty,
              !payload.models.isEmpty
        else { throw manifestInvalid("catalog header or model list is invalid") }

        var modelIDs = Set<LocalModelRevisionID>()
        var revocations = Set<LocalModelRevisionID>()
        for revoked in payload.revokedModelRevisions {
            guard revoked.revision > 0, !revoked.modelID.isEmpty, revocations.insert(revoked).inserted else {
                throw manifestInvalid("duplicate or invalid model revocation")
            }
        }
        for model in payload.models {
            guard modelIDs.insert(model.id).inserted else {
                throw manifestInvalid("duplicate model revision")
            }
            try validate(model)
        }
    }

    private static func validate(_ model: LocalModelRevisionManifest) throws {
        let allowedEngines = Set(["llama_cpp"])
        let allowedFormats = Set(["gguf"])
        guard !model.id.modelID.isEmpty,
              model.id.revision > 0,
              !model.displayName.isEmpty,
              !model.family.isEmpty,
              allowedEngines.contains(model.engineID),
              allowedFormats.contains(model.modelFormat),
              model.installedByteSize > 0,
              model.minimumOSMajor >= 17,
              model.minimumOSMajor <= 99,
              !model.supportedDeviceClasses.isEmpty,
              model.loadTemplate.contextTokens > 0,
              !model.artifacts.isEmpty
        else { throw manifestInvalid("model metadata is invalid") }

        var artifactIDs = Set<String>()
        var artifactRoles = Set<LocalModelArtifactRole>()
        var artifactPaths = Set<String>()
        for artifact in model.artifacts {
            guard !artifact.artifactID.isEmpty,
                  artifactIDs.insert(artifact.artifactID).inserted,
                  artifactRoles.insert(artifact.role).inserted,
                  artifactPaths.insert(artifact.relativePath).inserted,
                  isSafeRelativePath(artifact.relativePath),
                  artifact.downloadURL.scheme?.lowercased() == "https",
                  artifact.downloadURL.host != nil,
                  artifact.downloadURL.user == nil,
                  artifact.downloadURL.password == nil,
                  artifact.byteSize > 0,
                  artifact.artifactSHA256.count == 64,
                  artifact.artifactSHA256.utf8.allSatisfy({
                      ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66)
                  })
            else { throw manifestInvalid("model artifact is invalid") }
        }
        guard model.loadTemplate.requiredArtifactRoles.isSubset(of: artifactRoles),
              model.artifacts.reduce(UInt64(0), { partial, artifact in
                  let (sum, overflow) = partial.addingReportingOverflow(artifact.byteSize)
                  return overflow ? UInt64.max : sum
              }) <= model.installedByteSize,
              Set(model.declaredCapabilities.map(\.capabilityID)).count == model.declaredCapabilities.count,
              model.declaredCapabilities.allSatisfy({ !$0.capabilityID.isEmpty })
        else { throw manifestInvalid("model artifact or capability relationships are invalid") }

        let supportsImages = model.declaredCapabilities.contains {
            $0.capabilityID == "image_input" && $0.value == .support(.supported)
        }
        let hasRequiredProjection =
            artifactRoles.contains(.multimodalProjection)
            && model.loadTemplate.requiredArtifactRoles.contains(.multimodalProjection)
        guard supportsImages == hasRequiredProjection else {
            throw manifestInvalid("image capability and multimodal projection do not match")
        }
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static var strictDecoder: JSONDecoder { JSONDecoder() }
}

package struct CatalogEnvelope: Codable, Sendable {
    let signed: SignedLocalModelCatalogPayload
    let signature: String

    package init(signed: SignedLocalModelCatalogPayload, signature: String) {
        self.signed = signed
        self.signature = signature
    }
}

private struct CatalogKeyRing: Codable {
    let schemaVersion: String
    let keys: [CatalogKey]
    enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", keys }
}

private struct CatalogKey: Codable {
    enum Status: String, Codable { case active, revoked }
    let keyID: String
    let publicKey: String
    let status: Status
    enum CodingKeys: String, CodingKey {
        case keyID = "key_id", publicKey = "public_key", status
    }
}

package enum Base64URL {
    package static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    package static func decode(_ text: String, expectedCount: Int) throws -> Data {
        guard !text.isEmpty,
              !text.contains("="),
              text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { throw failure("download.catalog_signature_invalid", "base64url is not canonical") }
        let padding = String(repeating: "=", count: (4 - text.count % 4) % 4)
        let standard = text.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + padding
        guard let data = Data(base64Encoded: standard), data.count == expectedCount else {
            throw failure("download.catalog_signature_invalid", "base64url length is invalid")
        }
        return data
    }
}

private func manifestInvalid(_ message: String) -> LLMFailure {
    failure("download.catalog_manifest_invalid", message)
}

private func failure(_ code: String, _ message: String) -> LLMFailure {
    LLMFailure(code: code, message: message, retryable: false)
}
