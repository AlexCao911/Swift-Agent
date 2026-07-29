import CryptoKit
import Foundation
import LocalAgentLLMContracts
import Testing
@testable import LocalAgentLLMCloud

@Suite("Signed cloud capability catalog")
struct CloudCapabilityCatalogTests {
    @Test
    func bundledCatalogHasProductionTrustAndEveryShippedPreset() throws {
        let resources = try CloudCapabilityCatalogResources.loadBundled()
        let catalog = try CloudCapabilityCatalogVerifier.verify(
            envelope: resources.envelope,
            keyRing: resources.keyRing
        )
        #expect(catalog.catalogRevision > 0)
        #expect(!catalog.keyID.hasPrefix("test-"))
        let catalogPresets = Set(
            catalog.models.values.map(\.identity.presetID)
        )
        let shippedPresets = Set(ProviderPreset.shipped.map(\.id))
        #expect(catalogPresets.isSubset(of: shippedPresets))
        #expect(catalogPresets == [
            .openAI, .anthropic, .gemini, .xAI, .deepSeek, .miniMax, .glm,
        ])
        #expect(catalog.models.values.allSatisfy {
            $0.capabilities.first {
                $0.capabilityID == "tool_calling"
            }?.value == .support(.supported)
        })
    }

    @Test
    func bundledEnvelopeMatchesReviewedSourcePayloadAndContainsPublicTrustOnly() throws {
        let resources = try CloudCapabilityCatalogResources.loadBundled()
        let envelopeRoot = try #require(
            JSONSerialization.jsonObject(with: resources.envelope) as? [String: Any]
        )
        let bundledSigned = try #require(envelopeRoot["signed"])
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("contracts/cloud-capability-catalog-v1/official-signed-payload.json")
        let sourceSigned = try JSONSerialization.jsonObject(with: Data(contentsOf: sourceURL))
        #expect(
            try JSONSerialization.data(withJSONObject: bundledSigned, options: [.sortedKeys])
                == JSONSerialization.data(withJSONObject: sourceSigned, options: [.sortedKeys])
        )

        let keyRing = try #require(
            JSONSerialization.jsonObject(with: resources.keyRing) as? [String: Any]
        )
        let keys = try #require(keyRing["keys"] as? [[String: Any]])
        #expect(!keys.isEmpty)
        #expect(keys.allSatisfy {
            Set($0.keys) == ["key_id", "public_key", "status"]
                && $0["public_key"] as? String != nil
        })
    }

    @Test
    func verifiesSignatureAndRejectsUnknownRevokedOrMutatedTrust() throws {
        let fixture = try signedCloudCatalog(revision: 1)
        #expect(try CloudCapabilityCatalogVerifier.verify(
            envelope: fixture.envelope,
            keyRing: fixture.keyRing
        ).catalogRevision == 1)

        try expectCloudCatalogFailure("cloud_catalog.key_unknown") {
            try CloudCapabilityCatalogVerifier.verify(
                envelope: fixture.envelope,
                keyRing: signedCloudKeyRing(
                    keyID: "different-key",
                    publicKey: fixture.publicKey,
                    status: "active"
                )
            )
        }
        try expectCloudCatalogFailure("cloud_catalog.key_revoked") {
            try CloudCapabilityCatalogVerifier.verify(
                envelope: fixture.envelope,
                keyRing: signedCloudKeyRing(
                    keyID: "test-cloud-key",
                    publicKey: fixture.publicKey,
                    status: "revoked"
                )
            )
        }
        let mutated = try mutateCloudEnvelope(fixture.envelope) { signed in
            signed["catalog_revision"] = "2"
        }
        try expectCloudCatalogFailure("cloud_catalog.signature_invalid") {
            try CloudCapabilityCatalogVerifier.verify(envelope: mutated, keyRing: fixture.keyRing)
        }

        var keyRing = try #require(
            JSONSerialization.jsonObject(with: fixture.keyRing) as? [String: Any]
        )
        keyRing["private_key"] = "must-never-be-ignored"
        let keyRingWithUnknownSecurityField = try JSONSerialization.data(
            withJSONObject: keyRing
        )
        try expectCloudCatalogFailure("cloud_catalog.key_ring_invalid") {
            try CloudCapabilityCatalogVerifier.verify(
                envelope: fixture.envelope,
                keyRing: keyRingWithUnknownSecurityField
            )
        }
    }

    @Test
    func persistentStoreRejectsRollbackAndEqualRevisionConflictAndReopens() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("state.sqlite")
        let signingKey = Curve25519.Signing.PrivateKey()
        let first = try signedCloudCatalog(revision: 2, signingKey: signingKey)
        let store = try CloudCapabilityCatalogStore(
            fileURL: url,
            trustedKeyRing: first.keyRing
        )
        _ = try await store.accept(envelope: first.envelope)

        let rollback = try signedCloudCatalog(revision: 1, signingKey: signingKey)
        await expectCloudCatalogFailureAsync("cloud_catalog.revision_rollback") {
            try await store.accept(envelope: rollback.envelope)
        }
        let conflict = try signedCloudCatalog(
            revision: 2,
            modelID: "changed-model",
            signingKey: signingKey
        )
        await expectCloudCatalogFailureAsync("cloud_catalog.revision_conflict") {
            try await store.accept(envelope: conflict.envelope)
        }

        let reopened = try CloudCapabilityCatalogStore(
            fileURL: url,
            trustedKeyRing: first.keyRing
        )
        #expect(try await reopened.current()?.catalogRevision == 2)
        #expect(try await reopened.current()?.entry(presetID: .openAI, modelID: "fixture-model") != nil)

        let revokedTrust = try CloudCapabilityCatalogStore(
            fileURL: url,
            trustedKeyRing: signedCloudKeyRing(
                keyID: "test-cloud-key",
                publicKey: signingKey.publicKey.rawRepresentation,
                status: "revoked"
            )
        )
        await expectCloudCatalogFailureAsync("cloud_catalog.key_revoked") {
            try await revokedTrust.current()
        }
    }

    @Test
    func presetAdapterMismatchAndExplicitModelRevocationFailClosed() throws {
        let mismatch = try signedCloudCatalog(revision: 1, adapterID: "anthropic.messages")
        try expectCloudCatalogFailure("cloud_catalog.manifest_invalid") {
            try CloudCapabilityCatalogVerifier.verify(envelope: mismatch.envelope, keyRing: mismatch.keyRing)
        }

        let fixture = try signedCloudCatalog(revision: 1, revokeModel: true)
        let catalog = try CloudCapabilityCatalogVerifier.verify(
            envelope: fixture.envelope,
            keyRing: fixture.keyRing
        )
        let identity = CloudModelCatalogIdentity(
            presetID: .openAI,
            modelID: "fixture-model",
            modelRevision: "2026-01"
        )
        #expect(catalog.isRevoked(identity))

        let unmapped = try signedCloudCatalog(
            revision: 1,
            parameterDefinitions: [
                .init(id: .samplingMinP, valueType: .decimal, minimum: 0, maximum: 1),
            ],
            parameterDefaults: GenerationConfiguration()
        )
        try expectCloudCatalogFailure("cloud_catalog.manifest_invalid") {
            try CloudCapabilityCatalogVerifier.verify(
                envelope: unmapped.envelope,
                keyRing: unmapped.keyRing
            )
        }


        let duplicateModelID = try signedCloudCatalog(
            revision: 1,
            additionalModels: [CloudModelCatalogEntry(
                identity: .init(
                    presetID: .openAI,
                    modelID: "fixture-model",
                    modelRevision: "2026-02"
                ),
                adapterID: "openai.responses",
                minimumAdapterVersion: 1,
                maximumAdapterVersion: 1,
                capabilities: [
                    .init(capabilityID: "text_generation", value: .support(.supported)),
                ],
                parameterDefinitions: cloudTestParameterDefinitions,
                parameterDefaults: GenerationConfiguration(),
                continuationModes: [.statelessRequired]
            )]
        )
        try expectCloudCatalogFailure("cloud_catalog.manifest_invalid") {
            try CloudCapabilityCatalogVerifier.verify(
                envelope: duplicateModelID.envelope,
                keyRing: duplicateModelID.keyRing
            )
        }
    }
}

struct SignedCloudCatalogFixture {
    let envelope: Data
    let keyRing: Data
    let publicKey: Data
}

private struct TestCloudEnvelope: Encodable {
    let signed: SignedCloudCapabilityCatalogPayload
    let signature: String
}

func signedCloudCatalog(
    revision: UInt64,
    modelID: String = "fixture-model",
    adapterID: String = "openai.responses",
    revokeModel: Bool = false,
    capabilities: [CloudCatalogCapabilityDeclaration] = [
        .init(capabilityID: "text_generation", value: .support(.supported)),
        .init(capabilityID: "streaming", value: .support(.supported)),
        .init(capabilityID: "tool_calling", value: .support(.supported)),
        .init(capabilityID: "context_length", value: .verifiedUpperBound(128_000)),
    ],
    parameterDefinitions: [CloudCatalogParameterDefinition] = cloudTestParameterDefinitions,
    parameterDefaults: GenerationConfiguration = GenerationConfiguration()
        .setting(.samplingTemperature, to: .decimal(0.2))
        .setting(.generationMaxOutputTokens, to: .integer(256)),
    continuationModes: [ProviderRetentionMode] = [.statelessRequired],
    additionalModels: [CloudModelCatalogEntry] = [],
    signingKey: Curve25519.Signing.PrivateKey? = nil
) throws -> SignedCloudCatalogFixture {
    let identity = CloudModelCatalogIdentity(
        presetID: .openAI,
        modelID: modelID,
        modelRevision: "2026-01"
    )
    let entry = CloudModelCatalogEntry(
        identity: identity,
        adapterID: adapterID,
        minimumAdapterVersion: 1,
        maximumAdapterVersion: 1,
        capabilities: capabilities,
        parameterDefinitions: parameterDefinitions,
        parameterDefaults: parameterDefaults,
        continuationModes: continuationModes
    )
    let payload = SignedCloudCapabilityCatalogPayload(
        keyID: "test-cloud-key",
        catalogRevision: revision,
        models: [entry] + additionalModels,
        revokedModels: revokeModel ? [identity] : []
    )
    let key = signingKey ?? Curve25519.Signing.PrivateKey()
    let signature = try key.signature(
        for: CloudCapabilityCatalogVerifier.canonicalSignedBytes(payload)
    )
    let envelope = try JSONEncoder().encode(TestCloudEnvelope(
        signed: payload,
        signature: CloudBase64URL.encode(signature)
    ))
    return SignedCloudCatalogFixture(
        envelope: envelope,
        keyRing: signedCloudKeyRing(
            keyID: payload.keyID,
            publicKey: key.publicKey.rawRepresentation,
            status: "active"
        ),
        publicKey: key.publicKey.rawRepresentation
    )
}

let cloudTestParameterDefinitions: [CloudCatalogParameterDefinition] = [
    .init(
        id: .samplingTemperature,
        valueType: .decimal,
        minimum: 0,
        maximum: 2,
        mutuallyExclusiveWith: [.reasoningEffort]
    ),
    .init(id: .samplingTopP, valueType: .decimal, minimum: 0, maximum: 1),
    .init(id: .generationMaxOutputTokens, valueType: .integer, minimum: 1, maximum: 8_192),
    .init(
        id: .reasoningEffort,
        valueType: .text,
        choices: ["high", "low", "medium"],
        mutuallyExclusiveWith: [.samplingTemperature]
    ),
]

func signedCloudKeyRing(keyID: String, publicKey: Data, status: String) -> Data {
    try! JSONSerialization.data(withJSONObject: [
        "schema_version": "1",
        "keys": [[
            "key_id": keyID,
            "public_key": CloudBase64URL.encode(publicKey),
            "status": status,
        ]],
    ])
}

private func mutateCloudEnvelope(
    _ data: Data,
    change: (inout [String: Any]) -> Void
) throws -> Data {
    var root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var signed = try #require(root["signed"] as? [String: Any])
    change(&signed)
    root["signed"] = signed
    return try JSONSerialization.data(withJSONObject: root)
}

func expectCloudCatalogFailure<T>(_ code: String, operation: () throws -> T) throws {
    do {
        _ = try operation()
        Issue.record("expected \(code)")
    } catch let failure as LLMFailure {
        #expect(failure.code == code)
    }
}

func expectCloudCatalogFailureAsync<T: Sendable>(
    _ code: String,
    operation: () async throws -> T
) async {
    do {
        _ = try await operation()
        Issue.record("expected \(code)")
    } catch let failure as LLMFailure {
        #expect(failure.code == code)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}
