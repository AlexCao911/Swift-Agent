import CryptoKit
import Foundation
import LocalAgentLLMContracts
import Testing
@testable import LocalAgentLLMLocal

@Suite("Official local model catalog")
struct OfficialModelCatalogTests {
    @Test
    func bundledProductionCatalogHasAValidSignatureAndReleaseModel() throws {
        let verified = try bundledCatalog()
        #expect(verified.catalogRevision > 0)
        #expect(!verified.models.isEmpty)
        #expect(!verified.keyID.hasPrefix("test-"))
        #expect(verified.models.values.flatMap(\.artifacts).allSatisfy {
            $0.downloadURL.scheme == "https"
                && $0.downloadURL.host == "huggingface.co"
                && !$0.downloadURL.absoluteString.contains(".invalid")
        })

        let releaseManifest = try JSONDecoder().decode(
            ReleaseEngineManifest.self,
            from: Data(contentsOf: repositoryRoot.appending(path: "inference/release-engines.json"))
        )
        #expect(Set(verified.models.values.map(\.engineID)) == Set(releaseManifest.engineIDs))
    }

    @Test
    func validTestSignatureVerifiesButProductionKeyRingCannotAcceptIt() throws {
        let production = try bundledCatalog()
        let payload = payload(from: production, keyID: "test-catalog-key")
        let fixture = try sign(payload)
        let verified = try OfficialLocalModelCatalogVerifier.verify(
            envelope: fixture.envelope,
            keyRing: fixture.keyRing
        )
        #expect(verified.keyID == "test-catalog-key")

        let productionResources = try OfficialModelCatalogResources.loadBundled()
        try expectFailure("download.catalog_key_unknown") {
            try OfficialLocalModelCatalogVerifier.verify(
                envelope: fixture.envelope,
                keyRing: productionResources.keyRing
            )
        }
    }

    @Test
    func staticTestFixturesUseOneDistinctKeyAndPreserveRollbackRevision() throws {
        let publicKeyURL = try #require(Bundle.module.url(
            forResource: "catalog-test-public-key",
            withExtension: "txt"
        ))
        let publicKey = try String(contentsOf: publicKeyURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let keyRing = try JSONSerialization.data(withJSONObject: [
            "schema_version": "1",
            "keys": [[
                "key_id": "test-local-catalog-key",
                "public_key": publicKey,
                "status": "active",
            ]],
        ])
        let validURL = try #require(Bundle.module.url(forResource: "catalog-valid", withExtension: "json"))
        let rollbackURL = try #require(Bundle.module.url(forResource: "catalog-rollback", withExtension: "json"))
        let valid = try OfficialLocalModelCatalogVerifier.verify(
            envelope: Data(contentsOf: validURL),
            keyRing: keyRing
        )
        let rollback = try OfficialLocalModelCatalogVerifier.verify(
            envelope: Data(contentsOf: rollbackURL),
            keyRing: keyRing
        )
        #expect(valid.catalogRevision == 2)
        #expect(rollback.catalogRevision == 1)
        #expect(valid.keyID.hasPrefix("test-"))

        let production = try OfficialModelCatalogResources.loadBundled()
        try expectFailure("download.catalog_key_unknown") {
            try OfficialLocalModelCatalogVerifier.verify(
                envelope: Data(contentsOf: validURL),
                keyRing: production.keyRing
            )
        }
    }

    @Test
    func unknownAndRevokedKeysFailWithStableCodes() throws {
        let payload = payload(from: try bundledCatalog(), keyID: "test-key")
        let unknown = try sign(payload, ringKeyID: "different-key")
        try expectFailure("download.catalog_key_unknown") {
            try OfficialLocalModelCatalogVerifier.verify(envelope: unknown.envelope, keyRing: unknown.keyRing)
        }

        let revoked = try sign(payload, status: "revoked")
        try expectFailure("download.catalog_key_revoked") {
            try OfficialLocalModelCatalogVerifier.verify(envelope: revoked.envelope, keyRing: revoked.keyRing)
        }
    }

    @Test
    func everySignedSecurityFieldDetectsPostSignatureMutation() throws {
        let fixture = try sign(payload(from: try bundledCatalog(), keyID: "test-key"))
        let mutations: [(inout [String: Any]) -> Void] = [
            { root in
                var signed = root["signed"] as! [String: Any]
                var models = signed["models"] as! [[String: Any]]
                var artifacts = models[0]["artifacts"] as! [[String: Any]]
                artifacts[0]["download_url"] = "https://attacker.invalid/model.gguf"
                models[0]["artifacts"] = artifacts
                signed["models"] = models
                root["signed"] = signed
            },
            { root in
                var signed = root["signed"] as! [String: Any]
                var models = signed["models"] as! [[String: Any]]
                var artifacts = models[0]["artifacts"] as! [[String: Any]]
                artifacts[0]["artifact_sha256"] = String(repeating: "f", count: 64)
                models[0]["artifacts"] = artifacts
                signed["models"] = models
                root["signed"] = signed
            },
            { root in
                var signed = root["signed"] as! [String: Any]
                var models = signed["models"] as! [[String: Any]]
                var artifacts = models[0]["artifacts"] as! [[String: Any]]
                artifacts[0]["byte_size"] = "1"
                models[0]["artifacts"] = artifacts
                signed["models"] = models
                root["signed"] = signed
            },
            { root in
                var signed = root["signed"] as! [String: Any]
                signed["revoked_model_revisions"] = [["model_id": "changed", "revision": "1"]]
                root["signed"] = signed
            },
        ]
        for mutation in mutations {
            let changed = try mutate(fixture.envelope, mutation)
            try expectFailure("download.catalog_signature_invalid") {
                try OfficialLocalModelCatalogVerifier.verify(envelope: changed, keyRing: fixture.keyRing)
            }
        }
    }

    @Test
    func unknownEnvelopeOrSignedFieldsAreNeverDroppedBeforeVerification() throws {
        let fixture = try sign(payload(from: try bundledCatalog(), keyID: "test-key"))
        let unknownSigned = try mutate(fixture.envelope) { root in
            var signed = root["signed"] as! [String: Any]
            signed["future_download_policy"] = ["allow_unverified": true]
            root["signed"] = signed
        }
        try expectFailure("download.catalog_manifest_invalid") {
            try OfficialLocalModelCatalogVerifier.verify(
                envelope: unknownSigned,
                keyRing: fixture.keyRing
            )
        }

        let unknownEnvelope = try mutate(fixture.envelope) { root in
            root["unsigned_metadata"] = "ignored"
        }
        try expectFailure("download.catalog_manifest_invalid") {
            try OfficialLocalModelCatalogVerifier.verify(
                envelope: unknownEnvelope,
                keyRing: fixture.keyRing
            )
        }
    }

    @Test
    func schemaAndManifestInvariantsFailClosed() throws {
        let production = try bundledCatalog()
        let model = try #require(production.models.values.first)

        let unsupported = SignedLocalModelCatalogPayload(
            schemaVersion: "2",
            keyID: "test-key",
            catalogRevision: 1,
            models: [model],
            revokedModelRevisions: []
        )
        let unsupportedFixture = try sign(unsupported)
        try expectFailure("download.catalog_schema_unsupported") {
            try OfficialLocalModelCatalogVerifier.verify(
                envelope: unsupportedFixture.envelope,
                keyRing: unsupportedFixture.keyRing
            )
        }

        let invalidModels = [
            [model, model],
            [copy(model, engineID: "unknown_engine")],
            [copy(model, minimumOSMajor: 16)],
            [copy(model, supportedDeviceClasses: [])],
            [copy(model, artifacts: [copy(model.artifacts[0], downloadURL: URL(string: "http://example.com/m")!)])],
            [copy(model, artifacts: [copy(model.artifacts[0], relativePath: "../model.gguf")])],
            [copy(model, artifacts: [copy(model.artifacts[0], byteSize: 0)])],
            [copy(model, installedByteSize: 0)],
            [copy(model, artifacts: [model.artifacts[0], copy(model.artifacts[0], artifactID: "other")])],
            [copy(model, artifacts: [model.artifacts[0], copy(model.artifacts[0], artifactID: "other", relativePath: "other.gguf")])],
            [copy(model, artifacts: [model.artifacts[0], copy(model.artifacts[0], artifactID: "other", role: .tokenizer)])],
        ]
        for models in invalidModels {
            let invalid = SignedLocalModelCatalogPayload(
                schemaVersion: "1",
                keyID: "test-key",
                catalogRevision: 1,
                models: models,
                revokedModelRevisions: []
            )
            let fixture = try sign(invalid)
            try expectFailure("download.catalog_manifest_invalid") {
                try OfficialLocalModelCatalogVerifier.verify(envelope: fixture.envelope, keyRing: fixture.keyRing)
            }
        }
    }

    @Test
    func unsignedDecimalStringsPreserveValuesAboveTwoToTheFiftyThird() throws {
        let production = try bundledCatalog()
        let model = try #require(production.models.values.first)
        let exact: UInt64 = 9_007_199_254_740_993
        let large = copy(
            model,
            artifacts: [copy(model.artifacts[0], byteSize: exact)],
            installedByteSize: exact
        )
        let fixture = try sign(SignedLocalModelCatalogPayload(
            schemaVersion: "1",
            keyID: "test-key",
            catalogRevision: exact,
            models: [large],
            revokedModelRevisions: []
        ))
        let verified = try OfficialLocalModelCatalogVerifier.verify(
            envelope: fixture.envelope,
            keyRing: fixture.keyRing
        )
        #expect(verified.catalogRevision == exact)
        #expect(verified.models[large.id]?.artifacts[0].byteSize == exact)
    }

    @Test
    func explicitRevocationInvalidatesObservationsButMissingEntryDoesNotImplyRevocation() throws {
        let production = try bundledCatalog()
        let model = try #require(production.models.values.first)
        let revokedPayload = SignedLocalModelCatalogPayload(
            schemaVersion: "1",
            keyID: "test-key",
            catalogRevision: production.catalogRevision + 1,
            models: [model],
            revokedModelRevisions: [model.id]
        )
        let fixture = try sign(revokedPayload)
        let revoked = try OfficialLocalModelCatalogVerifier.verify(
            envelope: fixture.envelope,
            keyRing: fixture.keyRing
        )
        #expect(revoked.disposition(for: model.id) == .revoked)
        #expect(try LocalCapabilityObservationFactory.observations(
            for: model.id,
            in: revoked,
            engineVersion: "1",
            appBuild: "1",
            observedAt: Date(timeIntervalSince1970: 0)
        ).isEmpty)
        #expect(revoked.disposition(for: LocalModelRevisionID(modelID: "missing", revision: 1)) == .supersededOrUnknown)
    }

    @Test
    func repositoryContainsNoProductionPrivateSigningMaterial() throws {
        let forbiddenNames = ["private-key", "private_key", "signing-seed", "signing_seed"]
        let enumerator = try #require(FileManager.default.enumerator(
            at: repositoryRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ))
        for case let url as URL in enumerator {
            let relative = url.path.replacingOccurrences(of: repositoryRoot.path, with: "")
            guard !relative.contains("/.build/") else { continue }
            #expect(!forbiddenNames.contains { url.lastPathComponent.lowercased().contains($0) })
            if ["pem", "key"].contains(url.pathExtension.lowercased()),
               let text = try? String(contentsOf: url, encoding: .utf8) {
                #expect(!text.contains("PRIVATE KEY"))
            }
        }
    }
}

private struct ReleaseEngineManifest: Decodable {
    let engineIDs: [String]
    enum CodingKeys: String, CodingKey { case engineIDs = "engine_ids" }
}

private struct SignedFixture {
    let envelope: Data
    let keyRing: Data
}

private func bundledCatalog() throws -> VerifiedLocalModelCatalog {
    let resources = try OfficialModelCatalogResources.loadBundled()
    return try OfficialLocalModelCatalogVerifier.verify(
        envelope: resources.envelope,
        keyRing: resources.keyRing
    )
}

private func payload(
    from catalog: VerifiedLocalModelCatalog,
    keyID: String
) -> SignedLocalModelCatalogPayload {
    SignedLocalModelCatalogPayload(
        schemaVersion: "1",
        keyID: keyID,
        catalogRevision: catalog.catalogRevision,
        models: catalog.models.values.sorted {
            ($0.id.modelID, $0.id.revision) < ($1.id.modelID, $1.id.revision)
        },
        revokedModelRevisions: catalog.revokedModelRevisions.sorted {
            ($0.modelID, $0.revision) < ($1.modelID, $1.revision)
        }
    )
}

private func sign(
    _ payload: SignedLocalModelCatalogPayload,
    ringKeyID: String? = nil,
    status: String = "active"
) throws -> SignedFixture {
    let key = Curve25519.Signing.PrivateKey()
    let canonical = try LocalModelCatalogCanonicalDocument.canonicalSignedBytes(from: payload)
    let envelope = CatalogEnvelope(
        signed: payload,
        signature: Base64URL.encode(try key.signature(for: canonical))
    )
    let encoder = JSONEncoder()
    let keyRing = try JSONSerialization.data(withJSONObject: [
        "schema_version": "1",
        "keys": [[
            "key_id": ringKeyID ?? payload.keyID,
            "public_key": Base64URL.encode(key.publicKey.rawRepresentation),
            "status": status,
        ]],
    ])
    return SignedFixture(envelope: try encoder.encode(envelope), keyRing: keyRing)
}

private func mutate(
    _ data: Data,
    _ change: (inout [String: Any]) -> Void
) throws -> Data {
    var root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    change(&root)
    return try JSONSerialization.data(withJSONObject: root)
}

private func expectFailure<T>(
    _ code: String,
    _ operation: () throws -> T
) throws {
    do {
        _ = try operation()
        Issue.record("expected LLMFailure \(code)")
    } catch let error as LLMFailure {
        #expect(error.code == code)
    }
}

private func copy(
    _ artifact: LocalModelArtifactManifest,
    artifactID: String? = nil,
    role: LocalModelArtifactRole? = nil,
    relativePath: String? = nil,
    downloadURL: URL? = nil,
    byteSize: UInt64? = nil
) -> LocalModelArtifactManifest {
    LocalModelArtifactManifest(
        artifactID: artifactID ?? artifact.artifactID,
        role: role ?? artifact.role,
        relativePath: relativePath ?? artifact.relativePath,
        downloadURL: downloadURL ?? artifact.downloadURL,
        byteSize: byteSize ?? artifact.byteSize,
        artifactSHA256: artifact.artifactSHA256
    )
}

private func copy(
    _ model: LocalModelRevisionManifest,
    engineID: String? = nil,
    artifacts: [LocalModelArtifactManifest]? = nil,
    installedByteSize: UInt64? = nil,
    minimumOSMajor: Int? = nil,
    supportedDeviceClasses: Set<LocalDeviceClass>? = nil
) -> LocalModelRevisionManifest {
    LocalModelRevisionManifest(
        id: model.id,
        displayName: model.displayName,
        family: model.family,
        engineID: engineID ?? model.engineID,
        modelFormat: model.modelFormat,
        artifacts: artifacts ?? model.artifacts,
        installedByteSize: installedByteSize ?? model.installedByteSize,
        minimumOSMajor: minimumOSMajor ?? model.minimumOSMajor,
        supportedDeviceClasses: supportedDeviceClasses ?? model.supportedDeviceClasses,
        estimatedMemoryClass: model.estimatedMemoryClass,
        declaredCapabilities: model.declaredCapabilities,
        parameterSchema: model.parameterSchema,
        parameterDefaults: model.parameterDefaults,
        loadTemplate: model.loadTemplate,
        chatTemplate: model.chatTemplate,
        toolCallCodecID: model.toolCallCodecID
    )
}

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
