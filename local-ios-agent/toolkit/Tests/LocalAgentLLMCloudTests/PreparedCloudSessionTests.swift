import Foundation
import LocalAgentLLMContracts
@testable import LocalAgentLLMCore
import Testing
@testable import LocalAgentLLMCloud

@Suite("Prepared cloud session persistence")
struct PreparedCloudSessionTests {
    @Test
    func sessionIDsAreRandom256BitBase64URLValues() throws {
        let first = try PreparedCloudSession.generateSessionID()
        let second = try PreparedCloudSession.generateSessionID()
        #expect(first != second)
        #expect(first.utf8.count == 43)
        #expect(first.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }

    @Test
    func exactSnapshotPersistsReopensAndCloseLeavesTombstoneWithoutSensitiveFields() async throws {
        let fixture = try await PreparedCloudFixture.make()
        defer { fixture.cleanup() }
        try fixture.store.persistPreparedSession(
            fixture.session,
            snapshot: fixture.snapshot,
            credentialLease: fixture.lease
        )
        _ = try await fixture.credentials.bindPreparationLease(
            fixture.lease.leaseID,
            expectedRevision: fixture.lease.revision
        )

        #expect(try fixture.store.session(fixture.session.sessionID) == .init(
            session: fixture.session,
            lifecycle: .prepared
        ))
        #expect(try fixture.store.snapshot(fixture.snapshot.snapshotID) == fixture.snapshot)

        let reopened = try PreparedCloudSessionStore(fileURL: fixture.databaseURL)
        #expect(try reopened.session(fixture.session.sessionID)?.session == fixture.session)
        let persistedText = try reopened.persistedTextValuesForTesting().joined(separator: "\n")
        #expect(!persistedText.contains("test-only-key"))
        #expect(!persistedText.contains("/private/"))
        #expect(!persistedText.contains("provider_request"))
        #expect(!persistedText.contains("response_body"))

        let bound = try #require(await fixture.credentials.lease(fixture.lease.leaseID))
        let closing = try await fixture.credentials.beginClosingLease(
            bound.leaseID,
            expectedRevision: bound.revision
        )
        let tombstone = try reopened.closePreparedSession(
            sessionID: fixture.session.sessionID,
            expectedLifecycle: .prepared,
            closingLeaseRevision: closing.revision,
            disposition: .closed
        )
        #expect(tombstone.sessionID == fixture.session.sessionID)
        #expect(tombstone.disposition == .closed)
        #expect(try reopened.session(fixture.session.sessionID)?.lifecycle == .closed)
        #expect(try await fixture.credentials.lease(fixture.lease.leaseID) == nil)
    }

    @Test
    func newEpochClosesOnlyOldSessionsAndRemovesTheirLeasesAtomically() async throws {
        let fixture = try await PreparedCloudFixture.make()
        defer { fixture.cleanup() }
        try fixture.store.persistPreparedSession(
            fixture.session,
            snapshot: fixture.snapshot,
            credentialLease: fixture.lease
        )
        _ = try await fixture.credentials.bindPreparationLease(
            fixture.lease.leaseID,
            expectedRevision: fixture.lease.revision
        )

        let currentEpoch = try HostProcessEpoch.generate()
        let currentLease = try await fixture.credentials.acquireUseLease(
            credentialRef: fixture.session.credentialRef,
            purpose: .preparation,
            preparationID: "prep-current",
            hostProcessEpoch: currentEpoch
        )
        let currentSession = fixture.session.replacingProcessIdentity(
            sessionID: try PreparedCloudSession.generateSessionID(),
            preparationID: "prep-current",
            proposedRunID: "run-current",
            leaseID: currentLease.leaseID,
            leaseDigest: try credentialUseLeaseDigest(currentLease).hex,
            epoch: currentEpoch
        )
        let currentSnapshot = fixture.snapshot.replacing(
            snapshotID: "snapshot-current",
            sessionID: currentSession.sessionID,
            runID: currentSession.proposedRunID,
            preparationID: currentSession.preparationID,
            epoch: currentEpoch
        )
        try fixture.store.persistPreparedSession(
            currentSession,
            snapshot: currentSnapshot,
            credentialLease: currentLease
        )
        _ = try await fixture.credentials.bindPreparationLease(
            currentLease.leaseID,
            expectedRevision: currentLease.revision
        )

        #expect(try fixture.store.recoverOldEpoch(currentEpoch) == 1)
        #expect(try fixture.store.session(fixture.session.sessionID)?.lifecycle == .closed)
        #expect(try fixture.store.tombstone(fixture.session.sessionID)?.disposition == .epochEnded)
        #expect(try await fixture.credentials.lease(fixture.lease.leaseID) == nil)
        #expect(try fixture.store.session(currentSession.sessionID)?.lifecycle == .prepared)
        #expect(try await fixture.credentials.lease(currentLease.leaseID) != nil)
    }
}

private struct PreparedCloudFixture {
    let directory: URL
    let databaseURL: URL
    let store: PreparedCloudSessionStore
    let credentials: ProviderCredentialStore
    let lease: CredentialUseLease
    let session: PreparedCloudSession
    let snapshot: SanitizedCloudSessionSnapshot

    static func make() async throws -> Self {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "prepared-cloud-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("state.sqlite")
        _ = try ProviderProfileStore(
            fileURL: databaseURL,
            originValidator: PreparedCloudOriginValidator()
        )
        let credentials = try ProviderCredentialStore(
            fileURL: databaseURL,
            vault: PreparedCloudVault()
        )
        try await credentials.createSlot(
            credentialRef: "credential-main",
            initialSecret: SecretBytes(utf8: "test-only-key"),
            operationID: "create-prepared-cloud"
        )
        let epoch = try HostProcessEpoch.generate()
        let lease = try await credentials.acquireUseLease(
            credentialRef: "credential-main",
            purpose: .preparation,
            preparationID: "prep-1",
            hostProcessEpoch: epoch
        )
        let digest = String(repeating: "a", count: 64)
        let session = PreparedCloudSession(
            sessionID: try PreparedCloudSession.generateSessionID(),
            preparationID: "prep-1",
            proposedRunID: "run-1",
            targetID: LLMTargetID(rawValue: "target-cloud"),
            targetRevision: 3,
            bindingID: "binding-cloud",
            bindingRevision: 5,
            bindingHash: digest,
            requirementsHash: String(repeating: "b", count: 64),
            providerProfileID: "profile-main",
            providerProfileRevision: 1,
            origin: EgressOrigin(scheme: "https", host: "api.example.com", port: 443),
            credentialRef: "credential-main",
            credentialGeneration: lease.generation,
            retentionMode: .statelessRequired,
            retentionApprovalRevision: nil,
            retentionApprovalDigest: nil,
            credentialUseLeaseID: lease.leaseID,
            credentialUseLeaseDigest: try credentialUseLeaseDigest(lease).hex,
            modelID: "fixture-model",
            capabilitySnapshotDigest: String(repeating: "c", count: 64),
            resolvedParametersDigest: String(repeating: "d", count: 64),
            initialDisclosureDigest: String(repeating: "e", count: 64),
            scopeGrantID: "grant-1",
            generationAuthorizationID: "authorization-1",
            opaqueEgressSubjectDigest: String(repeating: "f", count: 64),
            egressAttestationDigest: String(repeating: "1", count: 64),
            hostProcessEpoch: epoch,
            adapterID: "openai.responses",
            adapterVersion: "1"
        )
        let snapshot = SanitizedCloudSessionSnapshot(
            snapshotID: "snapshot-1",
            sessionID: session.sessionID,
            runID: session.proposedRunID,
            preparationID: session.preparationID,
            hostProcessEpoch: epoch,
            capabilitySnapshot: CapabilitySnapshot(
                capabilities: [
                    "text_generation": .init(support: .supported, verifiedUpperBound: nil),
                ],
                subject: CapabilitySubject(
                    adapterID: session.adapterID,
                    providerProfileID: session.providerProfileID,
                    providerProfileRevision: session.providerProfileRevision,
                    credentialGeneration: session.credentialGeneration,
                    llmTargetID: session.targetID,
                    llmTargetRevision: session.targetRevision,
                    modelID: session.modelID,
                    retentionMode: session.retentionMode.rawValue
                ),
                contributingObservationDigests: [digest],
                nearestExpiry: nil
            ),
            resolvedConfiguration: GenerationConfiguration()
                .setting(.generationMaxOutputTokens, to: .integer(64))
        )
        return Self(
            directory: directory,
            databaseURL: databaseURL,
            store: try PreparedCloudSessionStore(fileURL: databaseURL),
            credentials: credentials,
            lease: lease,
            session: session,
            snapshot: snapshot
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

private extension PreparedCloudSession {
    func replacingProcessIdentity(
        sessionID: String,
        preparationID: String,
        proposedRunID: String,
        leaseID: String,
        leaseDigest: String,
        epoch: HostProcessEpoch
    ) -> PreparedCloudSession {
        PreparedCloudSession(
            sessionID: sessionID,
            preparationID: preparationID,
            proposedRunID: proposedRunID,
            targetID: targetID,
            targetRevision: targetRevision,
            bindingID: bindingID,
            bindingRevision: bindingRevision,
            bindingHash: bindingHash,
            requirementsHash: requirementsHash,
            providerProfileID: providerProfileID,
            providerProfileRevision: providerProfileRevision,
            origin: origin,
            credentialRef: credentialRef,
            credentialGeneration: credentialGeneration,
            retentionMode: retentionMode,
            retentionApprovalRevision: retentionApprovalRevision,
            retentionApprovalDigest: retentionApprovalDigest,
            credentialUseLeaseID: leaseID,
            credentialUseLeaseDigest: leaseDigest,
            modelID: modelID,
            capabilitySnapshotDigest: capabilitySnapshotDigest,
            resolvedParametersDigest: resolvedParametersDigest,
            initialDisclosureDigest: initialDisclosureDigest,
            scopeGrantID: scopeGrantID,
            generationAuthorizationID: generationAuthorizationID,
            opaqueEgressSubjectDigest: opaqueEgressSubjectDigest,
            egressAttestationDigest: egressAttestationDigest,
            hostProcessEpoch: epoch,
            adapterID: adapterID,
            adapterVersion: adapterVersion
        )
    }
}

private extension SanitizedCloudSessionSnapshot {
    func replacing(
        snapshotID: String,
        sessionID: String,
        runID: String,
        preparationID: String,
        epoch: HostProcessEpoch
    ) -> SanitizedCloudSessionSnapshot {
        SanitizedCloudSessionSnapshot(
            snapshotID: snapshotID,
            sessionID: sessionID,
            runID: runID,
            preparationID: preparationID,
            hostProcessEpoch: epoch,
            capabilitySnapshot: capabilitySnapshot,
            resolvedConfiguration: resolvedConfiguration
        )
    }
}

private struct PreparedCloudOriginValidator: ProviderOriginValidating {
    func validate(_ baseURL: URL) async throws -> EgressOrigin {
        EgressOrigin(scheme: "https", host: baseURL.host ?? "api.example.com", port: 443)
    }
}

private actor PreparedCloudVault: CredentialVault {
    private var final: [String: Data] = [:]
    private var staged: [String: Data] = [:]

    func writeStaged(
        credentialRef: String,
        generation: UInt64,
        operationID: String,
        secret: SecretBytes
    ) async throws {
        staged[CredentialVaultAccount.staged(
            credentialRef: credentialRef,
            generation: generation,
            operationID: operationID
        )] = secret.dataCopyForVault()
    }

    func promoteStaged(
        credentialRef: String,
        generation: UInt64,
        operationID: String
    ) async throws {
        let stagedKey = CredentialVaultAccount.staged(
            credentialRef: credentialRef,
            generation: generation,
            operationID: operationID
        )
        final[CredentialVaultAccount.final(
            credentialRef: credentialRef,
            generation: generation
        )] = staged.removeValue(forKey: stagedKey)
    }

    func finalExists(credentialRef: String, generation: UInt64) async throws -> Bool {
        final[CredentialVaultAccount.final(
            credentialRef: credentialRef,
            generation: generation
        )] != nil
    }

    func loadFinal(credentialRef: String, generation: UInt64) async throws -> SecretBytes {
        SecretBytes(bytes: final[CredentialVaultAccount.final(
            credentialRef: credentialRef,
            generation: generation
        )] ?? Data())
    }

    func deleteStaged(credentialRef: String, generation: UInt64, operationID: String) async throws {
        staged.removeValue(forKey: CredentialVaultAccount.staged(
            credentialRef: credentialRef,
            generation: generation,
            operationID: operationID
        ))
    }

    func deleteFinal(credentialRef: String, generation: UInt64) async throws {
        final.removeValue(forKey: CredentialVaultAccount.final(
            credentialRef: credentialRef,
            generation: generation
        ))
    }
}
