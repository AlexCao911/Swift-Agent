import CryptoKit
import Foundation
import LocalAgentLLMContracts
@testable import LocalAgentLLMCore
import Testing
@testable import LocalAgentLLMCloud

@Suite("Provider validation service")
struct ProviderValidationServiceTests {
    @Test
    func everyShippedPresetUsesFixedSyntheticMinimalValidationWire() throws {
        let expectedPaths: [ProviderPresetID: String] = [
            .openAI: "/responses",
            .anthropic: "/messages",
            .gemini: "/interactions",
            .xAI: "/responses",
            .deepSeek: "/chat/completions",
            .miniMax: "/messages",
            .glm: "/chat/completions",
        ]

        #expect(ProviderPreset.shipped.count == 7)
        for preset in ProviderPreset.shipped {
            let wire = try ProviderValidationWireFactory.modelProbe(
                preset: preset,
                modelID: "fixture-model"
            )
            #expect(wire.method == "POST")
            #expect(wire.path == expectedPaths[preset.id])
            #expect(wire.queryItems.isEmpty)
            #expect(wire.headers.keys.allSatisfy {
                !["authorization", "x-api-key", "x-goog-api-key"].contains($0.lowercased())
            })
            guard case let .noUserData(encoderID, requestClass) = wire.dataProvenance else {
                Issue.record("validation wire was not tagged as no-user-data")
                continue
            }
            #expect(encoderID == preset.codecID)
            #expect(requestClass == .modelValidation)

            let body = try #require(wire.body)
            let json = try #require(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            #expect(json["model"] as? String == "fixture-model")
            #expect(validationPrompt(in: json) == "Reply with OK.")
            #expect(validationOutputLimit(in: json) == 8)
            #expect(json["stream"] as? Bool == true)
            #expect(!String(decoding: body, as: UTF8.self).localizedCaseInsensitiveContains("secret"))

            if preset.id == .openAI || preset.id == .xAI || preset.id == .gemini {
                #expect(json["store"] as? Bool == false)
            }
        }
    }

    @Test
    func validatesWithTaggedNoUserDataRequestsAndPersistsExactEvidence() async throws {
        let harness = try await ValidationHarness.make()
        defer { harness.cleanup() }
        let transport = ValidationTransport()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let service = try ProviderValidationService(
            fileURL: harness.databaseURL,
            profileStore: harness.profiles,
            catalogStore: harness.catalog,
            credentialStore: harness.credentials,
            egressPolicy: harness.egress,
            transport: transport,
            hostProcessEpoch: harness.epoch,
            clock: { now },
            idGenerator: { "validation-fixed" }
        )
        let result = try await service.validate(
            profileID: "profile-main",
            profileRevision: 1,
            modelID: "fixture-model",
            adapterVersion: "1"
        )

        #expect(result.expiresAt == now.addingTimeInterval(24 * 60 * 60))
        #expect(result.subject.retentionMode == ProviderRetentionMode.statelessRequired.rawValue)
        #expect(result.subject.retentionApprovalRevision == nil)
        #expect(result.snapshot.support(for: "text_generation") == .supported)
        #expect(result.snapshot.support(for: "tool_calling") == .supported)
        let requests = await transport.requests
        #expect(requests.count == 3)
        #expect(requests.map(\.authorization) == [
            .discovery(.init(
                originApprovalRevision: 1,
                presetEncoderID: "openai_responses",
                requestClass: .discovery
            )),
            .validation(.init(
                originApprovalRevision: 1,
                presetEncoderID: "openai_responses",
                requestClass: .accountValidation
            )),
            .validation(.init(
                originApprovalRevision: 1,
                presetEncoderID: "openai_responses",
                requestClass: .modelValidation
            )),
        ])
        #expect(requests.allSatisfy {
            if case .noUserData = $0.wire.dataProvenance { return true }
            return false
        })
        let probeBody = try #require(requests.last?.wire.body)
        let probeJSON = try #require(JSONSerialization.jsonObject(with: probeBody) as? [String: Any])
        #expect(probeJSON["input"] as? String == "Reply with OK.")
        #expect(probeJSON["max_output_tokens"] as? Int == 8)
        #expect(probeJSON["store"] as? Bool == false)

        let leaseID = try #require(requests.first?.credentialUseLeaseID)
        #expect(try await harness.credentials.lease(leaseID) == nil)
        let state = try #require(await harness.profiles.state(
            profileID: "profile-main",
            profileRevision: 1
        ))
        guard case let .validated(evidence) = state.validationState else {
            Issue.record("profile was not marked validated")
            return
        }
        #expect(evidence.modelID == "fixture-model")
        #expect(evidence.credentialGeneration == 1)
        #expect(evidence.catalogRevision == 1)
        #expect(evidence.adapterID == "openai.responses")
        #expect(evidence.evidenceDigest == result.evidenceDigest)
    }

    @Test
    func releasesValidationLeaseAndDoesNotPublishEvidenceOnEveryFailure() async throws {
        let harness = try await ValidationHarness.make()
        defer { harness.cleanup() }
        let transport = ValidationTransport(failModelProbe: true)
        let service = try ProviderValidationService(
            fileURL: harness.databaseURL,
            profileStore: harness.profiles,
            catalogStore: harness.catalog,
            credentialStore: harness.credentials,
            egressPolicy: harness.egress,
            transport: transport,
            hostProcessEpoch: harness.epoch
        )
        do {
            _ = try await service.validate(
                profileID: "profile-main",
                profileRevision: 1,
                modelID: "fixture-model",
                adapterVersion: "1"
            )
            Issue.record("expected probe failure")
        } catch let failure as LLMFailure {
            #expect(failure.code == "provider_validation.probe_incomplete")
        }
        let requests = await transport.requests
        let leaseID = try #require(requests.first?.credentialUseLeaseID)
        #expect(try await harness.credentials.lease(leaseID) == nil)
        let state = try #require(await harness.profiles.state(
            profileID: "profile-main",
            profileRevision: 1
        ))
        #expect(state.validationState == .unvalidated)
    }

    @Test
    func rejectsRetentionContinuationMismatchBeforeNetworkOrCredentialUse() async throws {
        let harness = try await ValidationHarness.make(retentionMode: .providerStateApproved)
        defer { harness.cleanup() }
        let transport = ValidationTransport()
        let service = try ProviderValidationService(
            fileURL: harness.databaseURL,
            profileStore: harness.profiles,
            catalogStore: harness.catalog,
            credentialStore: harness.credentials,
            egressPolicy: harness.egress,
            transport: transport,
            hostProcessEpoch: harness.epoch
        )
        do {
            _ = try await service.validate(
                profileID: "profile-main",
                profileRevision: 1,
                modelID: "fixture-model",
                adapterVersion: "1"
            )
            Issue.record("expected retention mismatch")
        } catch let failure as LLMFailure {
            #expect(failure.code == "provider_validation.retention_incompatible")
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test
    func stateChangeDuringProbeRollsBackAllEvidenceAndReleasesLease() async throws {
        let harness = try await ValidationHarness.make()
        defer { harness.cleanup() }
        let transport = ValidationTransport(beforeStream: {
            _ = try await harness.profiles.updateState(
                profileID: "profile-main",
                profileRevision: 1,
                expectedStateRevision: 1
            ) { state in
                state.validationState = .invalidated(reasonCode: "test.concurrent_change")
            }
        })
        let service = try ProviderValidationService(
            fileURL: harness.databaseURL,
            profileStore: harness.profiles,
            catalogStore: harness.catalog,
            credentialStore: harness.credentials,
            egressPolicy: harness.egress,
            transport: transport,
            hostProcessEpoch: harness.epoch
        )
        do {
            _ = try await service.validate(
                profileID: "profile-main",
                profileRevision: 1,
                modelID: "fixture-model",
                adapterVersion: "1"
            )
            Issue.record("expected state CAS failure")
        } catch let failure as LLMFailure {
            #expect(failure.code == "provider_validation.state_changed")
        }
        let requests = await transport.requests
        let leaseID = try #require(requests.first?.credentialUseLeaseID)
        #expect(try await harness.credentials.lease(leaseID) == nil)
        let database = try SQLiteConnection(path: harness.databaseURL.path)
        #expect(try database.queryRows(
            "SELECT COUNT(*) AS value FROM provider_validation_records"
        ).first?.integer("value") == 0)
        #expect(try database.queryRows(
            "SELECT COUNT(*) AS value FROM cloud_capability_observations"
        ).first?.integer("value") == 0)
    }

    @Test
    func catalogAdvanceAtomicallyInvalidatesPublishedEvidence() async throws {
        let harness = try await ValidationHarness.make()
        defer { harness.cleanup() }
        let service = try ProviderValidationService(
            fileURL: harness.databaseURL,
            profileStore: harness.profiles,
            catalogStore: harness.catalog,
            credentialStore: harness.credentials,
            egressPolicy: harness.egress,
            transport: ValidationTransport(),
            hostProcessEpoch: harness.epoch
        )
        _ = try await service.validate(
            profileID: "profile-main",
            profileRevision: 1,
            modelID: "fixture-model",
            adapterVersion: "1"
        )

        let next = try signedCloudCatalog(
            revision: 2,
            signingKey: harness.catalogSigningKey
        )
        _ = try await harness.catalog.accept(envelope: next.envelope)

        let state = try #require(await harness.profiles.state(
            profileID: "profile-main",
            profileRevision: 1
        ))
        #expect(state.validationState == .invalidated(
            reasonCode: "cloud_catalog.revision_changed"
        ))
        #expect(state.catalogRevision == nil)
        let database = try SQLiteConnection(path: harness.databaseURL.path)
        #expect(try database.queryRows(
            "SELECT COUNT(*) AS value FROM provider_validation_records"
        ).first?.integer("value") == 0)
        #expect(try database.queryRows(
            "SELECT COUNT(*) AS value FROM cloud_capability_observations"
        ).first?.integer("value") == 0)
    }
}

private func validationPrompt(in json: [String: Any]) -> String? {
    if let input = json["input"] as? String {
        return input
    }
    guard let messages = json["messages"] as? [[String: Any]],
          let first = messages.first
    else {
        return nil
    }
    return first["content"] as? String
}

private func validationOutputLimit(in json: [String: Any]) -> Int? {
    if let value = json["max_output_tokens"] as? Int {
        return value
    }
    if let value = json["max_tokens"] as? Int {
        return value
    }
    return (json["generation_config"] as? [String: Any])?["max_output_tokens"] as? Int
}

private actor ValidationTransport: CloudHTTPTransport {
    private(set) var requests: [AuthorizedCloudHTTPRequest] = []
    private let failModelProbe: Bool
    private let beforeStream: (@Sendable () async throws -> Void)?

    init(
        failModelProbe: Bool = false,
        beforeStream: (@Sendable () async throws -> Void)? = nil
    ) {
        self.failModelProbe = failModelProbe
        self.beforeStream = beforeStream
    }

    func json(_ request: AuthorizedCloudHTTPRequest) async throws -> Data {
        requests.append(request)
        return Data(#"{"data":[{"id":"fixture-model"}]}"#.utf8)
    }

    func stream(
        _ request: AuthorizedCloudHTTPRequest
    ) async throws -> AsyncThrowingStream<SSEEvent, Error> {
        try await beforeStream?()
        requests.append(request)
        let fail = failModelProbe
        return AsyncThrowingStream { continuation in
            continuation.yield(.init(
                event: "response.created",
                id: nil,
                retryMilliseconds: nil,
                data: Data(#"{"response":{"id":"resp_validation","status":"in_progress"}}"#.utf8)
            ))
            if !fail {
                continuation.yield(.init(
                    event: "response.output_text.delta",
                    id: nil,
                    retryMilliseconds: nil,
                    data: Data(#"{"delta":"OK"}"#.utf8)
                ))
                continuation.yield(.init(
                    event: "response.completed",
                    id: nil,
                    retryMilliseconds: nil,
                    data: Data(#"{"response":{"id":"resp_validation","status":"completed","usage":{"input_tokens":4,"output_tokens":1}}}"#.utf8)
                ))
            }
            continuation.finish()
        }
    }
}

private struct ValidationHarness: Sendable {
    let directory: URL
    let databaseURL: URL
    let profiles: ProviderProfileStore
    let catalog: CloudCapabilityCatalogStore
    let credentials: ProviderCredentialStore
    let egress: ProviderEgressPolicy
    let epoch: HostProcessEpoch
    let catalogSigningKey: Curve25519.Signing.PrivateKey

    static func make(
        retentionMode: ProviderRetentionMode = .statelessRequired
    ) async throws -> Self {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "provider-validation-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("state.sqlite")
        let profiles = try ProviderProfileStore(
            fileURL: databaseURL,
            originValidator: ValidationOriginValidator()
        )
        let catalogSigningKey = Curve25519.Signing.PrivateKey()
        let catalogFixture = try signedCloudCatalog(
            revision: 1,
            signingKey: catalogSigningKey
        )
        let catalog = try CloudCapabilityCatalogStore(
            fileURL: databaseURL,
            trustedKeyRing: catalogFixture.keyRing
        )
        _ = try await catalog.accept(envelope: catalogFixture.envelope)
        let vault = ValidationVault()
        let credentials = try ProviderCredentialStore(fileURL: databaseURL, vault: vault)
        try await credentials.createSlot(
            credentialRef: "credential-main",
            initialSecret: SecretBytes(utf8: "test-only-key"),
            operationID: "create-validation"
        )
        _ = try await profiles.publish(ProviderProfileRevision(
            profileID: "profile-main",
            revision: 1,
            presetID: .openAI,
            displayName: "Fixture provider",
            baseURL: URL(string: "https://api.example.com/v1")!,
            credentialRef: "credential-main",
            retentionMode: retentionMode
        ))
        let prompt = ValidationPrompt()
        let retention = try ProviderRetentionPolicy(fileURL: databaseURL, prompt: prompt)
        if retentionMode == .providerStateApproved {
            _ = try await retention.approveProviderState(
                profileID: "profile-main",
                profileRevision: 1,
                disclosure: ProviderRetentionDisclosure(
                    behavior: .serverSideConversationState,
                    windowClass: .thirtyOneToSixtyDays
                )
            )
        }
        let egress = try ProviderEgressPolicy(
            fileURL: databaseURL,
            credentialStore: credentials,
            retentionPolicy: retention,
            prompt: prompt,
            idGenerator: { UUID().uuidString }
        )
        return Self(
            directory: directory,
            databaseURL: databaseURL,
            profiles: profiles,
            catalog: catalog,
            credentials: credentials,
            egress: egress,
            epoch: try HostProcessEpoch.generate(),
            catalogSigningKey: catalogSigningKey
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

private actor ValidationPrompt: EgressApprovalPrompting, ProviderRetentionApprovalPrompting {
    func requestOriginApproval(_ origin: EgressOrigin, profileName: String) async -> EgressDecision { .allow }
    func requestScopeApproval(origin: EgressOrigin, summary: EgressApprovalDisplaySummary) async -> EgressDecision { .allow }
    func requestProviderStateApproval(
        profileName: String,
        origin: EgressOrigin,
        disclosure: ProviderRetentionDisclosure
    ) async -> EgressDecision { .allow }
}

private struct ValidationOriginValidator: ProviderOriginValidating {
    func validate(_ baseURL: URL) async throws -> EgressOrigin {
        EgressOrigin(scheme: "https", host: baseURL.host ?? "invalid", port: 443)
    }
}

private actor ValidationVault: CredentialVault {
    private var values: [String: Data] = [:]
    func writeStaged(credentialRef: String, generation: UInt64, operationID: String, secret: SecretBytes) async throws {
        values[CredentialVaultAccount.staged(
            credentialRef: credentialRef,
            generation: generation,
            operationID: operationID
        )] = secret.dataCopyForVault()
    }
    func promoteStaged(credentialRef: String, generation: UInt64, operationID: String) async throws {
        let staged = CredentialVaultAccount.staged(
            credentialRef: credentialRef,
            generation: generation,
            operationID: operationID
        )
        let final = CredentialVaultAccount.final(credentialRef: credentialRef, generation: generation)
        values[final] = values.removeValue(forKey: staged)
    }
    func finalExists(credentialRef: String, generation: UInt64) async throws -> Bool {
        values[CredentialVaultAccount.final(credentialRef: credentialRef, generation: generation)] != nil
    }
    func loadFinal(credentialRef: String, generation: UInt64) async throws -> SecretBytes {
        guard let value = values[CredentialVaultAccount.final(
            credentialRef: credentialRef,
            generation: generation
        )] else { throw CredentialFailure(code: "credential.missing", message: "missing") }
        return SecretBytes(bytes: value)
    }
    func deleteStaged(credentialRef: String, generation: UInt64, operationID: String) async throws {
        values.removeValue(forKey: CredentialVaultAccount.staged(
            credentialRef: credentialRef,
            generation: generation,
            operationID: operationID
        ))
    }
    func deleteFinal(credentialRef: String, generation: UInt64) async throws {
        values.removeValue(forKey: CredentialVaultAccount.final(
            credentialRef: credentialRef,
            generation: generation
        ))
    }
}
