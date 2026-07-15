import Foundation
import LocalAgentLLMContracts
import LocalAgentLLMCore
import Testing
@testable import LocalAgentLLMLocal

@Suite("Prepared local session persistence")
struct PreparedLocalSessionTests {
    @Test
    func sessionIDsAreRandom256BitBase64URLValues() throws {
        let first = try PreparedLocalSession.generateSessionID()
        let second = try PreparedLocalSession.generateSessionID()
        #expect(first != second)
        #expect(first.utf8.count == 43)
        #expect(first.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }

    @Test
    func sessionSnapshotAndActiveLeasePersistAtomicallyAndCloseLeavesTombstone() throws {
        let fixture = try makeFixture()
        try fixture.store.persistPreparedLocalSession(
            fixture.session,
            activeSessionLease: fixture.activeLease
        )

        #expect(try fixture.store.preparedLocalSession(sessionID: fixture.session.sessionID) ==
            StoredPreparedLocalSession(session: fixture.session, state: .prepared))
        #expect(try fixture.store.modelUseLease(leaseID: fixture.activeLease.leaseID)?.state == .active)
        #expect(try fixture.store.modelUseLease(leaseID: fixture.loadedLease.leaseID)?.state == .active)

        try fixture.store.closePreparedLocalSession(sessionID: fixture.session.sessionID)
        #expect(try fixture.store.preparedLocalSession(sessionID: fixture.session.sessionID)?.state == .closed)
        #expect(try fixture.store.modelUseLease(leaseID: fixture.activeLease.leaseID)?.state == .released)
        #expect(try fixture.store.modelUseLease(leaseID: fixture.loadedLease.leaseID)?.state == .active)

        #expect(throws: LLMFailure.self) {
            try fixture.store.persistPreparedLocalSession(
                fixture.session,
                activeSessionLease: fixture.activeLease
            )
        }
    }

    @Test
    func invalidSessionLeaseRollsBackBothRecords() throws {
        let fixture = try makeFixture()
        let wrongLease = LocalModelUseLease(
            leaseID: fixture.activeLease.leaseID,
            installationID: "other-installation",
            purpose: .activeSession,
            hostProcessEpoch: fixture.epoch,
            state: .active,
            leaseRevision: 1
        )
        #expect(throws: LLMFailure.self) {
            try fixture.store.persistPreparedLocalSession(
                fixture.session,
                activeSessionLease: wrongLease
            )
        }
        #expect(try fixture.store.preparedLocalSession(sessionID: fixture.session.sessionID) == nil)
        #expect(try fixture.store.modelUseLease(leaseID: wrongLease.leaseID) == nil)
    }
}

private struct PreparedFixture {
    let store: LocalModelStore
    let epoch: HostProcessEpoch
    let loadedLease: LocalModelUseLease
    let activeLease: LocalModelUseLease
    let session: PreparedLocalSession
}

private func makeFixture() throws -> PreparedFixture {
    let store = try LocalModelStore.inMemory()
    var installation = try store.enqueueInstallation(
        installationID: "installation-1",
        modelRevision: LocalModelRevisionID(modelID: "model-1", revision: 2),
        rootPath: "/private/installations/installation-1"
    )
    installation = try store.transitionInstallation(
        installationID: installation.installationID,
        expectedStateRevision: installation.stateRevision,
        to: .downloading
    )
    installation = try store.transitionInstallation(
        installationID: installation.installationID,
        expectedStateRevision: installation.stateRevision,
        to: .verifying
    )
    installation = try store.transitionInstallation(
        installationID: installation.installationID,
        expectedStateRevision: installation.stateRevision,
        to: .installed
    )
    let epoch = try HostProcessEpoch.generate()
    let loadedLease = LocalModelUseLease(
        leaseID: "loaded-lease",
        installationID: installation.installationID,
        purpose: .loaded,
        hostProcessEpoch: epoch,
        state: .active,
        leaseRevision: 1
    )
    try store.acquireModelUseLease(loadedLease)
    let activeLease = LocalModelUseLease(
        leaseID: "active-lease",
        installationID: installation.installationID,
        purpose: .activeSession,
        hostProcessEpoch: epoch,
        state: .active,
        leaseRevision: 1
    )
    let subject = CapabilitySubject(
        engineID: "llama_cpp",
        llmTargetID: LLMTargetID(rawValue: "target-1"),
        llmTargetRevision: 1,
        modelID: "model-1",
        modelRevision: "2",
        catalogRevision: 7
    )
    let session = PreparedLocalSession(
        sessionID: "session-1",
        targetID: LLMTargetID(rawValue: "target-1"),
        targetRevision: 1,
        binding: HostBindingTuple(bindingID: "binding-1", bindingRevision: 3, bindingHash: "binding-hash"),
        requirementsHash: "requirements-hash",
        installationID: installation.installationID,
        installationStateRevision: installation.stateRevision,
        modelRevision: LocalModelRevisionID(modelID: "model-1", revision: 2),
        catalogRevision: 7,
        capabilitySnapshot: CapabilitySnapshot(
            capabilities: ["streaming": ResolvedCapability(support: .supported, verifiedUpperBound: nil)],
            subject: subject,
            contributingObservationDigests: ["observation-digest"],
            nearestExpiry: nil
        ),
        capabilitySnapshotDigest: "capability-digest",
        resolvedConfiguration: GenerationConfiguration().setting(.samplingTemperature, to: .decimal(0.2)),
        resolvedParametersDigest: "parameters-digest",
        template: LocalChatTemplateSelector(source: .gguf, templateID: "gemma"),
        toolCallCodecID: "json_tool_calls_v1",
        hostProcessEpoch: epoch,
        loadedModelLeaseID: loadedLease.leaseID,
        activeSessionLeaseID: activeLease.leaseID
    )
    return PreparedFixture(
        store: store,
        epoch: epoch,
        loadedLease: loadedLease,
        activeLease: activeLease,
        session: session
    )
}
